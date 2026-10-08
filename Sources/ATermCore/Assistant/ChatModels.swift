import Foundation

/// Any JSON value: tool schemas, reasoning details passed back verbatim.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts a `JSONSerialization` object.
    public init(any value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// An object for `JSONSerialization`.
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    /// The JSON text of the arguments, as the model wrote it.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var reasoning: String?
    public var reasoningDetails: [JSONValue]?
    /// The model that produced the reasoning; it is sent back only to that model.
    public var reasoningModel: String?

    public init(role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
                reasoning: String? = nil, reasoningDetails: [JSONValue]? = nil, reasoningModel: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
        self.reasoningModel = reasoningModel
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
    public static func tool(id: String, content: String) -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallID: id)
    }
}

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// A JSON schema.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var responseFormat: JSONValue?
    public var temperature: Double?
    /// Keeps a conversation's requests on one provider and its prompt cache.
    public var sessionID: String?
    /// The reasoning level (`low`, `high`…); nil leaves the model's default.
    public var reasoningEffort: String?

    public init(model: String, messages: [ChatMessage], tools: [ToolDefinition] = [], responseFormat: JSONValue? = nil,
                temperature: Double? = nil, sessionID: String? = nil, reasoningEffort: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.sessionID = sessionID
        self.reasoningEffort = reasoningEffort
    }
}

public struct Usage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct ChatReply: Sendable, Equatable {
    public var content: String
    public var reasoning: String
    public var reasoningDetails: [JSONValue]
    public var toolCalls: [ToolCall]
    public var finishReason: String?
    public var usage: Usage?

    public init(content: String = "", reasoning: String = "", reasoningDetails: [JSONValue] = [],
                toolCalls: [ToolCall] = [], finishReason: String? = nil, usage: Usage? = nil) {
        self.content = content
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// Text streamed while a reply is generated.
public enum ChatDelta: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    /// The request failed and is about to be sent again.
    case retrying(RetryInfo)
}

/// A retry: the attempt about to be made (from 2) out of the attempts allowed, after waiting.
public struct RetryInfo: Sendable, Equatable {
    public var attempt: Int
    public var of: Int
    public var wait: TimeInterval
    /// `HTTP 429`, `HTTP 503`, `connection lost`, `empty reply`…
    public var reason: String

    public init(attempt: Int, of: Int, wait: TimeInterval, reason: String) {
        self.attempt = attempt
        self.of = of
        self.wait = wait
        self.reason = reason
    }
}

/// What a client reports about its requests. Durations are seconds since the attempt was sent.
/// See SPEC/assistant/client.md (ASSIST-CLIENT-004).
public enum ClientEvent: Sendable, Equatable {
    case sent(model: String, attempt: Int)
    /// The response headers arrived.
    case responded(status: Int, after: TimeInterval)
    case finished(after: TimeInterval, usage: Usage?)
    case retrying(RetryInfo)
    case failed(AssistantError, after: TimeInterval)

    /// One line for a log: no key, no message text.
    public var logLine: String {
        switch self {
        case .sent(let model, let attempt): "→ \(model), attempt \(attempt)"
        case .responded(let status, let after): "← HTTP \(status) after \(Self.seconds(after))"
        case .finished(let after, let usage):
            "✓ done in \(Self.seconds(after))" + (usage.map { ", \($0.promptTokens) → \($0.completionTokens) tokens" } ?? "")
        case .retrying(let info): "↻ \(info.reason), retry \(info.attempt)/\(info.of) in \(Self.seconds(info.wait))"
        case .failed(let error, let after): "✗ \(error.message) after \(Self.seconds(after))"
        }
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }
}

/// Sends chat requests to a model. `OpenRouterClient` in the app, scripted clients in tests.
public protocol ChatClient: Sendable {
    func complete(_ request: ChatRequest, onDelta: @escaping @Sendable (ChatDelta) -> Void) async throws -> ChatReply
}

/// Why a request failed. See SPEC/assistant/contract.md.
public enum AssistantError: Error, Equatable, Sendable {
    case missingAPIKey
    case unauthorized(String)
    case insufficientCredits(String)
    case rateLimited(String)
    case contextLengthExceeded(String)
    case badRequest(String)
    case server(Int, String)
    case network(String)
    case emptyReply
    case invalidResponse(String)

    /// A sentence for the user.
    public var message: String {
        switch self {
        case .missingAPIKey: "No OpenRouter API key."
        case .unauthorized(let message): "Invalid API key: \(message)"
        case .insufficientCredits(let message): "Insufficient credits: \(message)"
        case .rateLimited(let message): "Rate limited: \(message)"
        case .contextLengthExceeded(let message): "The conversation is too long for the model: \(message)"
        case .badRequest(let message): "Request refused: \(message)"
        case .server(let status, let message): "OpenRouter error \(status): \(message)"
        case .network(let message): "Network error: \(message)"
        case .emptyReply: "The model returned an empty reply."
        case .invalidResponse(let message): "Unexpected reply: \(message)"
        }
    }
}
