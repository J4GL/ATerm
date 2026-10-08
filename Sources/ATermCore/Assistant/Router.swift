import Foundation

/// A command proposed for a request, with the reason it needs care.
public struct CommandSuggestion: Sendable, Equatable {
    public var command: String
    public var explanation: String
    /// Why the command is risky (`CommandRisk`), nil when it is not.
    public var risk: String?

    public init(command: String, explanation: String, risk: String?) {
        self.command = command
        self.explanation = explanation
        self.risk = risk
    }
}

/// What a request becomes.
public enum Route: Sendable, Equatable {
    /// Commands to run now, the best first.
    case commands([CommandSuggestion])
    /// A task for the agent, with its verifiable goal.
    case agent(goal: String)
}

/// Asks the model whether a request is one command to run now or a task for the agent.
/// See SPEC/assistant/router.md.
public struct Router: Sendable {
    public static let maxSuggestions = 4

    public let client: ChatClient
    public let model: String
    public let reasoningEffort: String?

    public init(client: ChatClient, model: String, reasoningEffort: String? = nil) {
        self.client = client
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public static let responseFormat: JSONValue = .object([
        "type": .string("json_schema"),
        "json_schema": .object([
            "name": .string("route"),
            "strict": .bool(true),
            "schema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("mode"), .string("commands"), .string("goal")]),
                "properties": .object([
                    "mode": .object(["type": .string("string"), "enum": .array([.string("command"), .string("agent")])]),
                    "commands": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "required": .array([.string("command"), .string("explanation")]),
                            "properties": .object([
                                "command": .object(["type": .string("string")]),
                                "explanation": .object(["type": .string("string")]),
                            ]),
                        ]),
                    ]),
                    "goal": .object(["type": .string("string")]),
                ]),
            ]),
        ]),
    ])

    /// Routes a request; `prompt` and `environment` must already be redacted.
    public func route(prompt: String, environment: String) async throws -> Route {
        var messages: [ChatMessage] = [.system(AgentPrompts.router + "\n\n" + environment), .user(prompt)]
        for attempt in 0..<2 {
            let reply = try await client.complete(
                ChatRequest(model: model, messages: messages, responseFormat: Self.responseFormat, temperature: 0,
                            reasoningEffort: reasoningEffort)
            ) { _ in }
            if let route = Self.parse(reply.content) { return route }
            if attempt == 0 {
                messages.append(ChatMessage(role: .assistant, content: reply.content))
                messages.append(.user("""
                    Your reply is not a valid answer. Reply again with only the JSON object: {"mode": "command" or \
                    "agent", "commands": [{"command": …, "explanation": …}], "goal": …}, with at least one command \
                    for mode command, or a goal for mode agent.
                    """))
            }
        }
        throw AssistantError.invalidResponse("the model did not classify the request")
    }

    /// The route in a reply, which may wrap its JSON object in a code fence or in prose.
    static func parse(_ text: String) -> Route? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
              let mode = object["mode"] as? String
        else { return nil }
        switch mode {
        case "command":
            let suggestions = (object["commands"] as? [[String: Any]] ?? []).compactMap { item -> CommandSuggestion? in
                let command = (item["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // A line break could run part of it while it is only inserted.
                guard !command.isEmpty, !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                else { return nil }
                let explanation = (item["explanation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return CommandSuggestion(command: command, explanation: explanation, risk: CommandRisk.assess(command))
            }.prefix(maxSuggestions)
            return suggestions.isEmpty ? nil : .commands(Array(suggestions))
        case "agent":
            let goal = (object["goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return goal.isEmpty ? nil : .agent(goal: goal)
        default:
            return nil
        }
    }
}
