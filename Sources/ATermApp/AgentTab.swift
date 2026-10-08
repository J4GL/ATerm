import AppKit
import ATermCore

/// The agent of an agent tab: it runs `Agent`, prints its work in the tab, and owns the tab's keyboard —
/// read-only while the agent works (⌃C stops it, Return / Esc answer an approval), typing replies once it is
/// idle. See SPEC/app/assistant.md.
@MainActor
final class AgentTab: AgentSessionOwner {
    private weak var pane: TerminalPane?
    private let session: TerminalSession
    private let services: AssistantServices
    private let launch: AgentLaunch
    private(set) var agent: Agent?
    private var runner: CommandRunner?
    private var outputDirectory: String?
    private var task: Task<Void, Never>?
    private var formatter = TranscriptFormatter()
    private var pendingApproval: CheckedContinuation<Bool, Never>?
    private var thinkingSince: Date?
    /// The retry of the current request and when its wait ends.
    private var retry: (info: RetryInfo, until: Date)?
    private var closed = false
    private(set) var isRunning = false

    init(pane: TerminalPane, session: TerminalSession, services: AssistantServices, launch: AgentLaunch) {
        self.pane = pane
        self.session = session
        self.services = services
        self.launch = launch
    }

    var currentDirectory: String {
        runner?.workingDirectory ?? launch.context.workingDirectory
    }

    private var baseTitle: String {
        let goal = launch.goal.count > 60 ? String(launch.goal.prefix(59)) + "…" : launch.goal
        return "Agent — " + goal
    }

    func start() {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("aterm-agent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        outputDirectory = directory
        let runner = CommandRunner(environment: CommandRunner.environment(from: launch.context.loginEnvironment),
                                   workingDirectory: launch.context.workingDirectory, outputDirectory: directory)
        self.runner = runner
        let prompt = AgentPrompts.system(goal: launch.goal, environment: launch.context.environmentBlock,
                                         projectInstructions: launch.context.projectInstructions)
        var configuration = Agent.Configuration(model: services.model)
        configuration.reasoningEffort = services.reasoningEffort
        agent = Agent(client: services.makeClient(), configuration: configuration,
                      systemPrompt: prompt, runner: runner, redactor: launch.context.redactor,
                      approve: { [weak self] command, reason in
                          await self?.askApproval(command: command, reason: reason) ?? false
                      },
                      onEvent: { [weak self] event in self?.handle(event) })
        session.display(TranscriptFormatter.title(baseTitle))
        session.display(formatter.header(model: services.model, goal: launch.goal))
        begin(launch.request)
    }

    /// Continues the conversation with the user's reply.
    func reply(_ text: String) {
        guard !isRunning, !closed, agent != nil else { return }
        session.display(formatter.userReply(text))
        begin(text)
    }

    func stop() {
        task?.cancel()
        resolveApproval(false)
    }

    /// The app is quitting: no time to wait for the run to end.
    func terminateNow() {
        stop()
        runner?.killRunning()
        removeOutputs()
    }

    /// The tab is closing: stop, and remove the output files once the run is over.
    func close() {
        closed = true
        stop()
        if !isRunning { removeOutputs() }
    }

    private func begin(_ message: String) {
        guard let agent else { return }
        isRunning = true
        let outputs = outputDirectory
        task = Task { [weak self] in
            await agent.run(message)
            if let self {
                self.runEnded()
            } else if let outputs {
                try? FileManager.default.removeItem(atPath: outputs)
            }
        }
    }

    private func runEnded() {
        isRunning = false
        thinkingSince = nil
        session.display(TranscriptFormatter.title(baseTitle))
        if closed { removeOutputs() }
    }

    private func removeOutputs() {
        guard let outputDirectory else { return }
        try? FileManager.default.removeItem(atPath: outputDirectory)
        self.outputDirectory = nil
    }

    // MARK: - Events

    private func handle(_ event: Agent.Event) {
        switch event {
        case .thinking:
            startThinking()
        case .retrying(let info):
            retry = (info, Date().addingTimeInterval(info.wait))
            showThinking()
        case .reasoning, .approvalRequired:
            return
        default:
            thinkingSince = nil
            retry = nil
            session.display(formatter.event(event))
        }
    }

    /// Shows `… thinking (N s)` until the model answers, with its retries.
    private func startThinking() {
        let started = Date()
        thinkingSince = started
        retry = nil
        showThinking()
        tickThinking(started)
    }

    private func showThinking() {
        guard let started = thinkingSince else { return }
        let note = retry.map { retry in
            TranscriptFormatter.retryNote(retry.info, secondsLeft: Int(retry.until.timeIntervalSinceNow.rounded(.up)))
        }
        session.display(formatter.thinking(seconds: Int(Date().timeIntervalSince(started)), retry: note))
    }

    private func tickThinking(_ started: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.thinkingSince == started else { return }
                self.showThinking()
                self.tickThinking(started)
            }
        }
    }

    // MARK: - Approval

    private func askApproval(command: String, reason: String) async -> Bool {
        thinkingSince = nil
        session.display(formatter.approval(command: command, reason: reason))
        session.display(TranscriptFormatter.title("⚠ " + baseTitle))
        NSSound.beep()
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    pendingApproval = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(false) }
        }
        session.display(TranscriptFormatter.title(baseTitle))
        return approved
    }

    private func resolveApproval(_ approved: Bool) {
        guard let continuation = pendingApproval else { return }
        pendingApproval = nil
        continuation.resume(returning: approved)
    }

    // MARK: - Keyboard

    func receiveInput(_ bytes: [UInt8]) {
        if pendingApproval != nil {
            switch bytes {
            case [0x0D]: resolveApproval(true)
            case [0x1B]: resolveApproval(false)
            case [0x03]: stop()
            default: break
            }
            return
        }
        if isRunning {
            if bytes == [0x03] { stop() }
            return
        }
        // Idle: typing starts a reply.
        guard bytes.first != 0x1B, let text = String(bytes: bytes, encoding: .utf8) else { return }
        if bytes == [0x0D] {
            pane?.assistant.open()
        } else if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            pane?.assistant.open(initialText: text)
        }
    }
}
