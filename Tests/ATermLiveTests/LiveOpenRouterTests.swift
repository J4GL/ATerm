import Foundation
import Testing
import ATermCore

/// Checks the prompts against the real model. Not a spec test: it runs only with `make live-check`
/// (ATERM_LIVE=1 and OPENROUTER_API_KEY set) and spends free-tier requests. ATERM_ENDPOINT and ATERM_MODEL
/// choose another endpoint and model (e.g. opencode's `https://opencode.ai/zen/go/v1`, with its key), ATERM_REASONING
/// a reasoning level (`low`, `high`…).
private let environment = ProcessInfo.processInfo.environment
private let enabled = environment["ATERM_LIVE"] == "1" && !(environment["OPENROUTER_API_KEY"] ?? "").isEmpty
private let model = environment["ATERM_MODEL"] ?? OpenRouterClient.defaultModel
private let endpoint = environment["ATERM_ENDPOINT"].flatMap(URL.init(string:)) ?? OpenRouterClient.defaultEndpoint
private let reasoningEffort = environment["ATERM_REASONING"].flatMap { $0.isEmpty ? nil : $0 }

private let liveStart = Date()

private func liveAgentConfiguration() -> Agent.Configuration {
    var configuration = Agent.Configuration(model: model)
    configuration.reasoningEffort = reasoningEffort
    return configuration
}

/// Prints every request, response and retry with the time since the run started.
private func liveClient() -> OpenRouterClient {
    OpenRouterClient(endpoint: endpoint, apiKey: { environment["OPENROUTER_API_KEY"] },
                     onEvent: { event in
                         print(String(format: "[live +%.1f s] ", Date().timeIntervalSince(liveStart)) + event.logLine)
                     })
}

private let sampleEnvironment = """
    <environment>
    os: macOS 27.0 (26A428), arm64
    user: dev (Dev), home /Users/dev
    shell: /bin/zsh; commands run with /bin/bash 3.2.57(1)-release
    locale: fr_FR; languages: fr-FR, en-US
    cwd: /Users/dev/blog
    entries: Gemfile, app/, config/, public/
    tools: git, brew, ruby, bundle, curl, python3
    terminal: 120x32, running zsh
    </environment>
    <recent_terminal_output>
    </recent_terminal_output>
    """

@Suite(.serialized, .enabled(if: enabled)) struct Live {
    @Test("live: the router classifies typical requests", arguments: [
        ("liste les fichiers de plus de 100 Mo dans ce dossier", false),
        ("quelle est mon adresse IP locale ?", false),
        ("la page principale de mon blog renvoie une erreur 500, corrige le bug", true),
    ])
    func router(_ request: String, _ isAgentTask: Bool) async throws {
        let route = try await Router(client: liveClient(), model: model, reasoningEffort: reasoningEffort).route(prompt: request,
                                                                               environment: sampleEnvironment)
        print("[live] \(request) → \(route)")
        switch route {
        case .commands(let suggestions):
            #expect(!isAgentTask)
            #expect(!suggestions.isEmpty)
        case .agent(let goal):
            #expect(isAgentTask)
            #expect(!goal.isEmpty)
        }
    }

    @Test("live: the completer completes the line being typed", arguments: ["git stat", "bundle exec rails s"])
    func completer(_ line: String) async throws {
        let completion = try await CommandCompleter(client: liveClient(), model: model,
                                                    reasoningEffort: reasoningEffort).complete(line: line,
                                                                                              environment: sampleEnvironment)
        print("[live] \(line) → \(completion ?? "nothing")")
        let completed = try #require(completion)
        #expect(completed.hasPrefix(line) && completed.count > line.count)
    }

    @Test("live: the agent completes a small task and verifies it") @MainActor
    func agent() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("aterm-live-\(UUID().uuidString)")
        let outputs = directory + "-outputs"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: directory)
            try? FileManager.default.removeItem(atPath: outputs)
        }
        let runner = CommandRunner(environment: CommandRunner.environment(from: environment),
                                   workingDirectory: directory, outputDirectory: outputs)
        let goal = "hello.txt exists in the current directory and contains exactly the line: bonjour"
        let system = AgentPrompts.system(goal: goal, environment: sampleEnvironment.replacingOccurrences(
            of: "/Users/dev/blog", with: directory), projectInstructions: "")
        let agent = Agent(client: liveClient(), configuration: liveAgentConfiguration(), systemPrompt: system,
                          runner: runner, redactor: SecretRedactor(knownSecrets: []), approve: { _, _ in false },
                          onEvent: { event in
                              switch event {
                              case .text(let text): print(text, terminator: "")
                              case .commandStarted(_, let command): print("\n[live] $ \(command)")
                              case .ended(let outcome, _): print("\n[live] ended: \(outcome)")
                              default: break
                              }
                          })
        let outcome = await agent.run("crée hello.txt avec le mot bonjour, puis vérifie-le")
        #expect(outcome == .finished(.goalMet))
        let content = try String(contentsOfFile: directory + "/hello.txt", encoding: .utf8)
        #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == "bonjour")
    }
}
