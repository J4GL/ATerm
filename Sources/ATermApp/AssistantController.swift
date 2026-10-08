import AppKit
import ATermCore
import os

/// What the assistant shared by every window needs: the configuration, the key, the endpoint and model chosen
/// in Settings, the OpenRouter client and the model list.
@MainActor
final class AssistantServices {
    let configuration: AssistantConfiguration
    let appConfiguration: AppConfiguration
    private(set) var endpoint: URL
    private(set) var model: String
    private(set) var reasoningEffort: String?
    /// The model completes the line typed at the zsh prompt (Settings).
    private(set) var commandCompletions: Bool
    /// After a failed completion request, the next ones wait until then.
    var completionsPausedUntil: Date?
    /// The model list last fetched, for the Settings model completion.
    var models: [ModelInfo]?
    private var client: OpenRouterClient?
    /// The client of completion requests, which never retries: a late completion is useless.
    private var completionClient: OpenRouterClient?

    init(appConfiguration: AppConfiguration) {
        self.appConfiguration = appConfiguration
        configuration = appConfiguration.assistant
        endpoint = configuration.endpoint
        model = configuration.model
        reasoningEffort = configuration.reasoningEffort
        commandCompletions = configuration.commandCompletions
    }

    /// The endpoint of the next request; nil restores the default.
    func setEndpoint(_ endpoint: URL?) {
        let endpoint = endpoint ?? OpenRouterClient.defaultEndpoint
        guard endpoint != self.endpoint else { return }
        self.endpoint = endpoint
        client = nil
        completionClient = nil
    }

    /// Turns the model's completions at the zsh prompt on or off for the next requests.
    func setCommandCompletions(_ on: Bool) {
        commandCompletions = on
    }

    /// The model of the next request; nil restores the default.
    func setModel(_ model: String?) {
        self.model = model ?? OpenRouterClient.defaultModel
    }

    /// The reasoning level of the next requests; nil leaves the model's default.
    func setReasoningEffort(_ effort: String?) {
        reasoningEffort = effort
    }

    func fetchModels(endpoint: URL, key: String?) async throws -> ModelList {
        try await ModelCatalog.fetch(endpoint: endpoint, key: key, configuration: configuration.sessionConfiguration,
                                     catalog: configuration.modelCatalogURL)
    }

    var keySource: APIKeySource {
        APIKeySource(store: configuration.keyStore, environmentFallback: configuration.environmentKeyFallback)
    }

    func apiKey() -> String? {
        keySource.key()
    }

    /// The client of the next requests; with `retrying` false, one that never retries.
    func makeClient(retrying: Bool = true) -> ChatClient {
        if let client = retrying ? client : completionClient { return client }
        let source = keySource
        let logger = Logger(subsystem: "gl.j4.ATerm", category: "network")
        let host = endpoint.host ?? endpoint.absoluteString
        let client = OpenRouterClient(endpoint: endpoint, apiKey: { source.key() },
                                      configuration: configuration.sessionConfiguration,
                                      retryDelays: retrying ? configuration.retryDelays : [],
                                      onEvent: { event in logger.log("\(host, privacy: .public) \(event.logLine, privacy: .public)") })
        if retrying { self.client = client } else { completionClient = client }
        return client
    }
}

/// Everything the model is told about a pane, with the redactor that hides its secrets.
struct AssistantContext {
    let environmentBlock: String
    let projectInstructions: String
    let workingDirectory: String
    let loginEnvironment: [String: String]
    let redactor: SecretRedactor
}

/// What a new agent tab starts from.
struct AgentLaunch {
    let goal: String
    let request: String
    let context: AssistantContext
}

/// The assistant of one pane: the ⌘ hold, the bar, routing a request to commands or to an agent tab.
/// See SPEC/app/assistant.md.
@MainActor
final class AssistantController {
    let bar = AssistantBar()
    private weak var pane: TerminalPane?
    private let services: AssistantServices
    private var detector: CommandHoldDetector?
    private var routeTask: Task<Void, Never>?
    /// The pending completion of the line typed at the zsh prompt.
    private var completionTask: Task<Void, Never>?
    /// The redactor of the request whose suggestions are shown.
    private var suggestionsRedactor: SecretRedactor?

    init(services: AssistantServices) {
        self.services = services
    }

    func attach(to pane: TerminalPane) {
        self.pane = pane
        let configuration = services.configuration
        detector = CommandHoldDetector(
            delay: configuration.holdDelay,
            schedule: { delay, work in
                let work = UncheckedSendable(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work.value() } }
            },
            systemInputAge: { MainActor.assumeIsolated { configuration.systemInputAge() } },
            output: { [weak self] output in self?.holdOutput(output) })
        let view = pane.terminalView
        bar.install(in: view)
        view.onHoldInput = { [weak self] input in self?.handle(input) }
        view.onSizeChange = { [weak self] in self?.bar.layoutInSuperview() }
        bar.onSubmit = { [weak self] text in self?.submit(text) }
        bar.onChoose = { [weak self] index, run in self?.choose(index, run: run) }
        bar.onSaveKey = { [weak self] key in self?.saveKey(key) }
        bar.onCancel = { [weak self] in self?.close() }
    }

    // MARK: - Holding ⌘

    private func handle(_ input: TerminalView.HoldInput) {
        switch input {
        case .commandDown(let time): detector?.commandDown(at: time)
        case .commandUp(let time): detector?.commandUp(at: time)
        case .other: detector?.otherInput()
        }
    }

    private func holdOutput(_ output: CommandHoldDetector.Output) {
        switch output {
        case .showHint:
            if bar.mode == .hidden && !(pane?.agentTab?.isRunning ?? false) { bar.showHint() }
        case .hideHint:
            if bar.mode == .hint { bar.hide() }
        case .trigger:
            open()
        }
    }

    // MARK: - Opening and closing

    /// Opens the bar: the key field when no key is known, else the request field (a reply in an agent tab).
    func open(initialText: String = "") {
        guard let pane else { return }
        if let agentTab = pane.agentTab, agentTab.isRunning {
            bar.hide()
            return
        }
        guard services.apiKey() != nil else {
            openKeyEntry()
            return
        }
        bar.showPrompt(reply: pane.agentTab != nil, text: initialText)
        focus(bar.field)
    }

    func openKeyEntry(message: String? = nil) {
        routeTask?.cancel()
        bar.showKey(message: message)
        focus(bar.keyField)
    }

    func close() {
        routeTask?.cancel()
        routeTask = nil
        bar.hide()
        guard let pane else { return }
        pane.window?.makeFirstResponder(pane.terminalView)
    }

    private func focus(_ field: NSTextField) {
        guard let window = pane?.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    private func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try services.configuration.keyStore.save(key)
            open()
        } catch {
            bar.setStatus("The key could not be saved in the Keychain (\(error)).")
        }
    }

    // MARK: - Requests

    private func submit(_ text: String) {
        guard let pane else { return }
        if let agentTab = pane.agentTab {
            close()
            agentTab.reply(text)
            return
        }
        bar.showThinking()
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            guard let self else { return }
            let context = await self.makeContext()
            await self.route(text, context: context)
        }
    }

    private func route(_ text: String, context: AssistantContext) async {
        let redactor = context.redactor
        do {
            let router = Router(client: services.makeClient(), model: services.model,
                                reasoningEffort: services.reasoningEffort)
            let route = try await router.route(prompt: redactor.redact(text),
                                               environment: redactor.redact(context.environmentBlock))
            guard !Task.isCancelled, let pane else { return }
            switch route {
            case .commands(let suggestions):
                suggestionsRedactor = redactor
                bar.showSuggestions(suggestions, request: text)
            case .agent(let goal):
                close()
                pane.tab?.windowController?.appDelegate?.openAgentTab(from: pane,
                                                                      launch: AgentLaunch(goal: goal, request: text,
                                                                                          context: context))
            }
        } catch is CancellationError {
        } catch let error as AssistantError {
            guard !Task.isCancelled else { return }
            show(error, request: text)
        } catch {
            guard !Task.isCancelled else { return }
            bar.showPrompt(reply: false, text: text, status: "\(error)")
        }
    }

    private func show(_ error: AssistantError, request: String) {
        switch error {
        case .missingAPIKey:
            openKeyEntry()
        case .unauthorized:
            openKeyEntry(message: error.message)
        default:
            bar.showPrompt(reply: false, text: request, status: error.message)
            focus(bar.field)
        }
    }

    /// Runs a suggestion in the pane: ⌃U clears the line, the command is pasted, Return runs it. A busy pane gets
    /// the command typed ahead without Return; a full-screen program gets nothing (the command is copied).
    private func choose(_ index: Int, run: Bool) {
        guard let pane, index < bar.suggestions.count else { return }
        let restored = suggestionsRedactor?.restorePlain(bar.suggestions[index].command)
            ?? (text: bar.suggestions[index].command, restoredUnsafeValue: false)
        let session = pane.session
        let terminal = session.terminal
        if terminal.isAlternateScreenActive {
            pane.terminalView.pasteboard.clearContents()
            pane.terminalView.pasteboard.setString(restored.text, forType: .string)
            bar.setStatus("Copied: a full-screen program is running in this tab.")
            return
        }
        let busy = session.hasRunningJob
        let execute = run && !busy && !restored.restoredUnsafeValue
        var bytes: [UInt8] = [0x15] + PasteEncoder.encode(restored.text, bracketed: terminal.modes.bracketedPaste)
        if execute { bytes.append(0x0D) }
        pane.terminalView.sendInput(bytes)
        if run && !execute {
            bar.setStatus(busy ? "Inserted without running: a program is running in this tab."
                : "Inserted without running: check the secret it holds, then press Return.")
            return
        }
        close()
    }

    // MARK: - Completions

    /// A completion request of the pane's zsh, an empty line withdrawing the pending one: after a pause without
    /// another request, the model completes the line. See SPEC/app/suggestions.md.
    func requestCompletion(of line: String) {
        completionTask?.cancel()
        completionTask = nil
        guard services.commandCompletions, line.filter({ !$0.isWhitespace }).count >= 3 else { return }
        let delay = services.configuration.completionDelay
        completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.complete(line)
        }
    }

    private func complete(_ line: String) async {
        guard services.commandCompletions, services.apiKey() != nil,
              services.completionsPausedUntil.map({ $0 <= Date() }) ?? true
        else { return }
        let context = await makeContext()
        guard !Task.isCancelled else { return }
        let redactor = context.redactor
        let completer = CommandCompleter(client: services.makeClient(retrying: false), model: services.model,
                                         reasoningEffort: services.reasoningEffort)
        do {
            let redactedLine = redactor.redact(line)
            guard let completion = try await completer.complete(line: redactedLine,
                                                                environment: redactor.redact(context.environmentBlock)),
                  !Task.isCancelled
            else { return }
            let restored = redactor.restorePlain(completion).text
            guard restored.unicodeScalars.starts(with: line.unicodeScalars),
                  restored.unicodeScalars.count > line.unicodeScalars.count
            else { return }
            pane?.session.sendCompletion(restored)
        } catch {
            // A cancelled request is not a failure; anything else pauses the completions (no key, no credits…).
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            services.completionsPausedUntil = Date().addingTimeInterval(60)
        }
    }

    // MARK: - Context

    /// The environment block, the project instructions and the redactor for the pane's current state.
    func makeContext() async -> AssistantContext {
        guard let pane else {
            return AssistantContext(environmentBlock: "", projectInstructions: "", workingDirectory: NSHomeDirectory(),
                                    loginEnvironment: [:], redactor: SecretRedactor(knownSecrets: []))
        }
        let session = pane.session
        let terminal = session.terminal
        let directory = session.currentDirectory ?? NSHomeDirectory()
        let recent = EnvironmentContext.recentLines(of: terminal)
        let columns = terminal.cols
        let rows = terminal.rows
        let foreground = session.process?.foregroundProcessName
        let loginEnvironment = await services.configuration.loginEnvironment()
        let bash = await LoginEnvironmentCache.shared.bashDescription(environment: loginEnvironment)
        let base = ProcessInfo.processInfo.environment
        let loginShell = LoginShell.command(environment: base, accountShell: LoginShell.accountShell()).executable
        let snapshot = EnvironmentContext.snapshot(workingDirectory: directory, environment: loginEnvironment,
                                                   loginShell: loginShell, bash: bash, terminalColumns: columns,
                                                   terminalRows: rows, foregroundProgram: foreground,
                                                   recentOutput: recent)
        let gitRoot = EnvironmentContext.gitRoot(of: directory)
        let secrets = SecretSources.collect(
            environments: [base, loginEnvironment, services.appConfiguration.environment],
            dotEnvDirectories: [directory] + (gitRoot.map { [$0] } ?? []),
            credentialFiles: services.configuration.credentialFiles)
        return AssistantContext(environmentBlock: EnvironmentContext.render(snapshot),
                                projectInstructions: EnvironmentContext.projectInstructions(workingDirectory: directory),
                                workingDirectory: directory, loginEnvironment: loginEnvironment,
                                redactor: SecretRedactor(knownSecrets: secrets))
    }
}

/// Carries a main-thread closure through a dispatch to the main queue.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
