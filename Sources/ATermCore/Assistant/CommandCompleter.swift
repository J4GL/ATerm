import Foundation

/// Asks the model how the command line being typed at the zsh prompt ends. See SPEC/assistant/completer.md.
public struct CommandCompleter: Sendable {
    /// The longest completion kept, in UTF-8 bytes.
    public static let maxBytes = 500

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
            "name": .string("completion"),
            "strict": .bool(true),
            "schema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("command")]),
                "properties": .object(["command": .object(["type": .string("string")])]),
            ]),
        ]),
    ])

    /// The line completed by the model, nil when it has nothing longer; `line` and `environment` must already be
    /// redacted. One request, never corrected: a late completion is useless.
    public func complete(line: String, environment: String) async throws -> String? {
        let reply = try await client.complete(
            ChatRequest(model: model, messages: [.system(AgentPrompts.completer + "\n\n" + environment), .user(line)],
                        responseFormat: Self.responseFormat, temperature: 0, reasoningEffort: reasoningEffort)
        ) { _ in }
        return Self.parse(reply.content, line: line)
    }

    /// The completion in a reply, which may wrap its JSON object in a code fence or in prose.
    static func parse(_ text: String, line: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
              var command = object["command"] as? String
        else { return nil }
        while let last = command.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            command.unicodeScalars.removeLast()
        }
        // zsh shows it only while it extends the line byte for byte; a control character could run part of it.
        guard command.unicodeScalars.starts(with: line.unicodeScalars),
              command.unicodeScalars.count > line.unicodeScalars.count, command.utf8.count <= maxBytes,
              !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return command
    }
}
