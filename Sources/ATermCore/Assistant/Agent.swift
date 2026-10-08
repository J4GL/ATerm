import Foundation

/// Runs a conversation with the `bash` and `search` tools until the model ends a turn with a status line.
/// One agent is one conversation: `run(_:)` can be called again with the user's reply.
/// See SPEC/assistant/agent.md.
@MainActor
public final class Agent {
    public struct Configuration: Sendable {
        public var model: String
        /// The reasoning level of every request; nil leaves the model's default.
        public var reasoningEffort: String?
        public var maxToolCalls = 60
        public var budgetWarningAt = 50
        public var repeatLimit = 3
        /// Tokens (4 bytes each) of the most recent tool outputs never cleared.
        public var protectedOutputTokens = 40_000
        /// Older outputs are cleared only when that frees at least this many tokens.
        public var minimumPruneTokens = 20_000
        /// Outputs kept when the model reports the context is too long.
        public var outputsKeptOnOverflow = 3

        public init(model: String) {
            self.model = model
        }
    }

    public enum Status: Equatable, Sendable {
        case goalMet, goalNotMet, needInput
    }

    public enum Outcome: Equatable, Sendable {
        /// A reply without tool calls, with its status line when it has one.
        case finished(Status?)
        case stepLimit
        case stopped
        case failed(AssistantError)
    }

    public enum Event: Equatable, Sendable {
        /// A request was sent to the model.
        case thinking
        /// The request failed and is sent again after a wait.
        case retrying(RetryInfo)
        case reasoning(String)
        case text(String)
        case commandStarted(id: String, command: String)
        case commandOutput(Data)
        case commandFinished(id: String, exitCode: Int32?, timedOut: Bool)
        case searchStarted(id: String, request: SearchRequest)
        case searchFinished(id: String, summary: String)
        case toolFailed(id: String, message: String)
        case approvalRequired(command: String, reason: String)
        case ended(Outcome, message: String)
    }

    public static let clearedOutput = "[Output cleared to save context — re-run the command if you need it]"
    public static let deniedResult = "The user denied this command. Do not run it again; find another way or ask the user."
    public static let stoppedResult = "Stopped by the user."

    public var configuration: Configuration
    public private(set) var messages: [ChatMessage]
    /// Sent with every request of the conversation, for OpenRouter's sticky routing and prompt caching.
    public let sessionID = UUID().uuidString.lowercased()
    public private(set) var isRunning = false
    /// The process group of the last command run (its processes may still be around after a stop).
    public private(set) var lastProcessGroup: pid_t?

    private let client: ChatClient
    private let runner: CommandRunner
    private let redactor: SecretRedactor
    private let approve: @MainActor (String, String) async -> Bool
    private let onEvent: @MainActor (Event) -> Void

    public init(client: ChatClient, configuration: Configuration, systemPrompt: String, runner: CommandRunner,
                redactor: SecretRedactor, approve: @escaping @MainActor (String, String) async -> Bool,
                onEvent: @escaping @MainActor (Event) -> Void) {
        self.client = client
        self.configuration = configuration
        self.runner = runner
        self.redactor = redactor
        self.approve = approve
        self.onEvent = onEvent
        messages = [.system(redactor.redact(systemPrompt))]
    }

    /// The directory the next command starts in.
    public var workingDirectory: String { runner.workingDirectory }

    public static let tools = [AgentPrompts.bashTool, AgentPrompts.searchTool]

    // MARK: - The loop

    /// Adds the user's message and works until the model ends its turn; run it in a task to be able to stop it.
    @discardableResult
    public func run(_ userMessage: String) async -> Outcome {
        isRunning = true
        defer { isRunning = false }
        messages.append(.user(redactor.redact(userMessage)))
        var toolCalls = 0
        var reminded = false
        var lastSignature: String?
        var repeats = 0
        var overflowRetried = false

        while true {
            if Task.isCancelled { return end(.stopped) }
            pruneOldOutputs()
            onEvent(.thinking)
            let reply: ChatReply
            do {
                reply = try await requestReply()
            } catch is CancellationError {
                return end(.stopped)
            } catch AssistantError.contextLengthExceeded(let message) {
                if Task.isCancelled { return end(.stopped) }
                guard !overflowRetried else { return end(.failed(.contextLengthExceeded(message))) }
                overflowRetried = true
                clearOutputs(keepingLast: configuration.outputsKeptOnOverflow)
                continue
            } catch let error as AssistantError {
                return Task.isCancelled ? end(.stopped) : end(.failed(error))
            } catch {
                return Task.isCancelled ? end(.stopped) : end(.failed(.network("\(error)")))
            }
            overflowRetried = false
            messages.append(ChatMessage(role: .assistant, content: reply.content, toolCalls: reply.toolCalls,
                                        reasoning: reply.reasoning.isEmpty ? nil : reply.reasoning,
                                        reasoningDetails: reply.reasoningDetails.isEmpty ? nil : reply.reasoningDetails,
                                        reasoningModel: configuration.model))

            if reply.toolCalls.isEmpty {
                let status = Self.status(of: reply.content)
                if status == nil && !reminded {
                    reminded = true
                    messages.append(.user(AgentPrompts.statusReminder))
                    continue
                }
                return end(.finished(status), message: reply.content)
            }

            for (index, call) in reply.toolCalls.enumerated() {
                if toolCalls >= configuration.maxToolCalls {
                    messages.append(.tool(id: call.id, content:
                        "Not run: the step limit of \(configuration.maxToolCalls) tool calls was reached."))
                    continue
                }
                if Task.isCancelled {
                    abandon(reply.toolCalls[index...])
                    return end(.stopped)
                }
                toolCalls += 1
                guard var result = await execute(call) else {
                    messages.append(.tool(id: call.id, content: Self.stoppedResult))
                    abandon(reply.toolCalls[(index + 1)...])
                    return end(.stopped)
                }
                let signature = call.name + "\u{0}" + call.arguments
                repeats = signature == lastSignature ? repeats + 1 : 1
                lastSignature = signature
                if repeats >= configuration.repeatLimit {
                    result += "\n\n[Warning: this exact call ran \(repeats) times in a row. Change your approach.]"
                }
                if toolCalls == configuration.budgetWarningAt {
                    let left = configuration.maxToolCalls - toolCalls
                    result += "\n\n[Warning: \(left) tool call\(left == 1 ? "" : "s") left in this run. "
                        + "Verify the goal and conclude.]"
                }
                messages.append(.tool(id: call.id, content: result))
            }
            if toolCalls >= configuration.maxToolCalls {
                return end(.stepLimit, message: "Stopped after \(configuration.maxToolCalls) tool calls.")
            }
        }
    }

    private func end(_ outcome: Outcome, message: String = "") -> Outcome {
        onEvent(.ended(outcome, message: message))
        return outcome
    }

    /// Answers the calls that will not run, so the history stays valid for a reply.
    private func abandon(_ calls: ArraySlice<ToolCall>) {
        for call in calls {
            messages.append(.tool(id: call.id, content: "Not run: stopped by the user."))
        }
    }

    private func requestReply() async throws -> ChatReply {
        let request = ChatRequest(model: configuration.model, messages: messages, tools: Self.tools, sessionID: sessionID,
                                  reasoningEffort: configuration.reasoningEffort)
        let onEvent = self.onEvent
        return try await client.complete(request) { delta in
            // The main queue keeps the deltas in order, before the reply is handled.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch delta {
                    case .content(let text): onEvent(.text(text))
                    case .reasoning(let text): onEvent(.reasoning(text))
                    case .retrying(let info): onEvent(.retrying(info))
                    }
                }
            }
        }
    }

    /// The status on the last non-empty line of a final reply.
    static func status(of reply: String) -> Status? {
        guard let line = reply.split(whereSeparator: \.isNewline).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        var text = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*`_#[]"))
        if text.hasSuffix(".") { text.removeLast() }
        switch text.trimmingCharacters(in: .whitespaces).uppercased() {
        case "GOAL MET": return .goalMet
        case "GOAL NOT MET": return .goalNotMet
        case "NEED INPUT": return .needInput
        default: return nil
        }
    }

    // MARK: - Tools

    /// The result for the model, or nil when the user stopped the run during the call.
    private func execute(_ call: ToolCall) async -> String? {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        switch call.name {
        case "bash":
            guard let arguments, let command = arguments["command"] as? String, !command.isEmpty else {
                onEvent(.toolFailed(id: call.id, message: "invalid arguments for bash"))
                return #"Error: invalid arguments for bash: expected {"command": string, "timeout"?: integer}."#
            }
            return await runCommand(command, timeout: Self.number(arguments["timeout"]), id: call.id)
        case "search":
            guard let arguments, let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
                onEvent(.toolFailed(id: call.id, message: "invalid arguments for search"))
                return #"Error: invalid arguments for search: expected {"pattern": string, "path"?: string, "glob"?: string, "ignore_case"?: boolean, "literal"?: boolean, "context"?: integer, "limit"?: integer}."#
            }
            return await search(pattern: pattern, arguments: arguments, id: call.id)
        default:
            onEvent(.toolFailed(id: call.id, message: "unknown tool \(call.name)"))
            return #"Error: unknown tool "\#(call.name)". Available tools: bash, search."#
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private func runCommand(_ command: String, timeout: Double?, id: String) async -> String? {
        if let reason = CommandRisk.assess(command) {
            onEvent(.approvalRequired(command: command, reason: reason))
            let approved = await approve(command, reason)
            if Task.isCancelled { return nil }
            guard approved else {
                onEvent(.toolFailed(id: id, message: "denied by the user"))
                return Self.deniedResult
            }
        }
        let restored = redactor.restoreForShell(command)
        if let problem = restored.problem {
            onEvent(.toolFailed(id: id, message: "secret in a quoted heredoc"))
            return problem
        }
        onEvent(.commandStarted(id: id, command: command))
        let onEvent = self.onEvent
        let run = await runner.run(restored.command, timeout: timeout ?? CommandRunner.defaultTimeout,
                                   extraEnvironment: restored.environment) { data in
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(.commandOutput(data)) } }
        }
        lastProcessGroup = run.processGroup > 0 ? run.processGroup : lastProcessGroup
        if run.cancelled { return nil }
        let output = await Task.detached { BashTool.readOutput(run.outputFile) }.value
        let result = BashTool.result(for: run, output: output, command: command, redactor: redactor)
        onEvent(.commandFinished(id: id, exitCode: run.exitCode, timedOut: run.timedOut))
        return result
    }

    private func search(pattern: String, arguments: [String: Any], id: String) async -> String {
        func restored(_ key: String) -> String? {
            (arguments[key] as? String).map { redactor.restorePlain($0).text }
        }
        let request = SearchRequest(pattern: redactor.restorePlain(pattern).text, path: restored("path"),
                                    glob: restored("glob"), ignoreCase: arguments["ignore_case"] as? Bool ?? false,
                                    literal: arguments["literal"] as? Bool ?? false,
                                    context: Self.number(arguments["context"]).map { Int($0) } ?? 0,
                                    limit: Self.number(arguments["limit"]).map { Int($0) } ?? SearchTool.defaultLimit)
        onEvent(.searchStarted(id: id, request: SearchRequest(
            pattern: pattern, path: arguments["path"] as? String, glob: arguments["glob"] as? String,
            ignoreCase: request.ignoreCase, literal: request.literal, context: request.context, limit: request.limit)))
        let directory = runner.workingDirectory
        let lineRedactor = redactor
        let output = await Task.detached {
            SearchTool.run(request, workingDirectory: directory, redact: lineRedactor.redact)
        }.value
        let result = redactor.redact(output)
        onEvent(.searchFinished(id: id, summary: Self.summary(ofSearch: result)))
        return result
    }

    static func summary(ofSearch output: String) -> String {
        if output.hasPrefix("Error:") || output == "No matches found." { return output }
        let matches = output.split(separator: "\n").filter { line in
            !line.hasPrefix("[") && line != "--" && line.split(separator: ":", maxSplits: 2).count == 3
                && line.split(separator: ":", maxSplits: 2)[1].allSatisfy(\.isNumber)
        }.count
        return matches == 1 ? "1 match" : "\(matches) matches"
    }

    // MARK: - Context

    private func isToolOutput(_ index: Int) -> Bool {
        messages[index].role == .tool && messages[index].content != Self.clearedOutput
    }

    /// Clears the oldest outputs beyond the protected recent ones, when that frees enough tokens.
    private func pruneOldOutputs() {
        var protected = 0
        var candidates: [Int] = []
        var candidateTokens = 0
        let latest = messages.indices.last(where: isToolOutput)
        for index in messages.indices.reversed() where isToolOutput(index) {
            let tokens = messages[index].content.utf8.count / 4
            if index == latest || (candidates.isEmpty && protected + tokens <= configuration.protectedOutputTokens) {
                protected += tokens
            } else {
                candidates.append(index)
                candidateTokens += tokens
            }
        }
        guard candidateTokens >= configuration.minimumPruneTokens else { return }
        for index in candidates { messages[index].content = Self.clearedOutput }
    }

    private func clearOutputs(keepingLast count: Int) {
        let outputs = messages.indices.filter(isToolOutput)
        for index in outputs.dropLast(count) { messages[index].content = Self.clearedOutput }
    }
}
