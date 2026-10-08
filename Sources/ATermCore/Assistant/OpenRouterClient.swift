import Foundation

/// Sends chat requests to OpenRouter and assembles the streamed replies. See SPEC/assistant/client.md.
public final class OpenRouterClient: ChatClient, @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1")!
    public static let defaultModel = "dots-studio/dots-3-note-preview:free"
    public static let defaultRetryDelays: [TimeInterval] = [0.5, 1, 2, 4]
    /// A stream silent for this long fails.
    public static let idleTimeout: TimeInterval = 120
    static let maxRetryAfter: TimeInterval = 60

    private let endpoint: URL
    private let apiKey: @Sendable () -> String?
    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let onEvent: @Sendable (ClientEvent) -> Void
    /// The opencode session of the requests that belong to no conversation (the router's): opencode refuses a
    /// request without one.
    private let clientSessionID = UUID().uuidString.lowercased()

    public init(endpoint: URL, apiKey: @escaping @Sendable () -> String?,
                configuration: URLSessionConfiguration = .default,
                retryDelays: [TimeInterval] = OpenRouterClient.defaultRetryDelays,
                wait: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                },
                onEvent: @escaping @Sendable (ClientEvent) -> Void = { _ in }) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        session = URLSession(configuration: configuration)
        self.retryDelays = retryDelays
        self.wait = wait
        self.onEvent = onEvent
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func complete(_ request: ChatRequest,
                         onDelta: @escaping @Sendable (ChatDelta) -> Void) async throws -> ChatReply {
        guard let key = apiKey(), !key.isEmpty else { throw AssistantError.missingAPIKey }
        let urlRequest = try makeURLRequest(request, key: key)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let started = Date()
            onEvent(.sent(model: request.model, attempt: attempt + 1))
            do {
                let reply = try await send(urlRequest, started: started, onDelta: onDelta)
                onEvent(.finished(after: Date().timeIntervalSince(started), usage: reply.usage))
                return reply
            } catch let failure as Failure {
                guard failure.retryable, attempt < retryDelays.count else {
                    onEvent(.failed(failure.error, after: Date().timeIntervalSince(started)))
                    throw failure.error
                }
                let delay = failure.retryAfter ?? retryDelays[attempt] * (1 + Double.random(in: 0...0.1))
                let retry = RetryInfo(attempt: attempt + 2, of: retryDelays.count + 1, wait: delay,
                                      reason: Self.retryReason(failure.error))
                onEvent(.retrying(retry))
                onDelta(.retrying(retry))
                try await wait(delay)
                attempt += 1
            }
        }
    }

    /// Why a request is retried, in a few words.
    private static func retryReason(_ error: AssistantError) -> String {
        switch error {
        case .rateLimited: "HTTP 429"
        case .server(let status, _): "HTTP \(status)"
        case .network: "connection lost"
        case .emptyReply: "empty reply"
        default: error.message
        }
    }

    // MARK: - Request

    private func makeURLRequest(_ request: ChatRequest, key: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("ATerm", forHTTPHeaderField: "X-OpenRouter-Title")
        // opencode keeps a conversation on one provider by its header, required on every request; OpenRouter by
        // `session_id` in the body.
        let opencode = Self.isOpenCode(endpoint)
        if opencode {
            urlRequest.setValue(request.sessionID ?? clientSessionID, forHTTPHeaderField: "x-opencode-session")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, endpoint: endpoint))
        return urlRequest
    }

    /// An opencode endpoint (`opencode.ai` or one of its subdomains).
    static func isOpenCode(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return host == "opencode.ai" || host.hasSuffix(".opencode.ai")
    }

    /// An OpenRouter endpoint, whose reasoning level is `reasoning.effort`.
    static func isOpenRouter(_ endpoint: URL) -> Bool {
        endpoint.host?.lowercased() == "openrouter.ai"
    }

    /// The JSON body of a request to `endpoint`. See SPEC/assistant/contract.md.
    public static func body(for request: ChatRequest, endpoint: URL = defaultEndpoint) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": request.messages.map { encode($0, model: request.model) },
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters.any]]
            }
            body["tool_choice"] = "auto"
        }
        if let format = request.responseFormat { body["response_format"] = format.any }
        if let temperature = request.temperature { body["temperature"] = temperature }
        // opencode takes the session in a header (see makeURLRequest).
        if !isOpenCode(endpoint), let sessionID = request.sessionID { body["session_id"] = sessionID }
        if let effort = request.reasoningEffort {
            if isOpenRouter(endpoint) {
                body["reasoning"] = ["effort": effort]
            } else {
                body["reasoning_effort"] = effort
            }
        }
        return body
    }

    private static func encode(_ message: ChatMessage, model: String) -> [String: Any] {
        var encoded: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        switch message.role {
        case .tool:
            encoded["tool_call_id"] = message.toolCallID ?? ""
        case .assistant:
            if !message.toolCalls.isEmpty {
                encoded["tool_calls"] = message.toolCalls.map { call in
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                }
            }
            if message.reasoningModel == model {
                if let details = message.reasoningDetails, !details.isEmpty {
                    encoded["reasoning_details"] = details.map(\.any)
                } else if let reasoning = message.reasoning, !reasoning.isEmpty {
                    encoded["reasoning"] = reasoning
                }
            }
        case .system, .user:
            break
        }
        return encoded
    }

    // MARK: - Response

    private struct Failure: Error {
        let error: AssistantError
        var retryable = false
        var retryAfter: TimeInterval?
    }

    private func send(_ urlRequest: URLRequest, started: Date,
                      onDelta: @escaping @Sendable (ChatDelta) -> Void) async throws -> ChatReply {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw Self.transportFailure(error, delivered: false)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(error: .invalidResponse("not an HTTP response"))
        }
        onEvent(.responded(status: http.statusCode, after: Date().timeIntervalSince(started)))
        if http.statusCode != 200 {
            var body = Data()
            do {
                for try await byte in bytes where body.count < 65_536 { body.append(byte) }
            } catch {
                throw Self.transportFailure(error, delivered: false)
            }
            throw Self.httpFailure(status: http.statusCode, body: body, response: http)
        }

        var parser = SSEParser()
        var accumulator = ChatStreamAccumulator()
        var delivered = false
        var line = [UInt8]()
        func handle(_ payloads: [String]) throws {
            for payload in payloads where payload != "[DONE]" {
                guard let data = payload.data(using: .utf8),
                      let chunk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                if let error = chunk["error"] as? [String: Any] {
                    let failure = Self.providerFailure(error)
                    throw Failure(error: failure.error, retryable: failure.retryable && !delivered)
                }
                for delta in accumulator.apply(chunk) {
                    if case .content = delta { delivered = true }
                    onDelta(delta)
                }
                if accumulator.hasToolCalls { delivered = true }
            }
        }
        do {
            for try await byte in bytes {
                line.append(byte)
                if byte == 0x0A {
                    try handle(parser.feed(line))
                    line.removeAll(keepingCapacity: true)
                }
            }
            try handle(parser.feed(line) + parser.finish())
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.transportFailure(error, delivered: delivered)
        }
        let reply = accumulator.reply
        guard !reply.content.isEmpty || !reply.toolCalls.isEmpty else {
            throw Failure(error: .emptyReply, retryable: true)
        }
        return reply
    }

    private static func transportFailure(_ error: Error, delivered: Bool) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            return CancellationError()
        }
        let message = (error as? URLError)?.localizedDescription ?? "\(error)"
        return Failure(error: .network(message), retryable: !delivered)
    }

    /// The error message of a failed response: the API's JSON message, else its text; a web page (a wrong
    /// endpoint) gives `HTTP 404 (not found)`.
    private static func message(in body: Data, status: Int) -> (message: String, errorType: String?) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let metadata = error?["metadata"] as? [String: Any]
        if let text = error?["message"] as? String { return (text, metadata?["error_type"] as? String) }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<") {
            return ("HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))", nil)
        }
        return (text, nil)
    }

    /// The error of a failed HTTP response.
    static func error(status: Int, body: Data, response: HTTPURLResponse) -> AssistantError {
        httpFailure(status: status, body: body, response: response).error
    }

    private static func httpFailure(status: Int, body: Data, response: HTTPURLResponse) -> Failure {
        let (text, errorType) = message(in: body, status: status)
        switch status {
        case 401:
            return Failure(error: .unauthorized(text))
        case 402:
            return Failure(error: .insufficientCredits(text))
        case 400 where isContextLength(text, errorType):
            return Failure(error: .contextLengthExceeded(text))
        case 400, 403, 404, 413, 422:
            return Failure(error: .badRequest(text))
        case 429:
            if text.lowercased().contains("per-day") || resetsLater(response) {
                return Failure(error: .rateLimited(text))
            }
            return Failure(error: .rateLimited(text), retryable: true, retryAfter: retryAfter(response))
        case 408, 500, 502, 503, 504:
            return Failure(error: .server(status, text), retryable: true, retryAfter: retryAfter(response))
        default:
            return Failure(error: .server(status, text))
        }
    }

    private static func providerFailure(_ error: [String: Any]) -> Failure {
        let code = (error["code"] as? Int) ?? Int(error["code"] as? String ?? "") ?? 500
        let text = error["message"] as? String ?? "unknown error"
        let errorType = (error["metadata"] as? [String: Any])?["error_type"] as? String
        if isContextLength(text, errorType) { return Failure(error: .contextLengthExceeded(text)) }
        return Failure(error: .server(code, text), retryable: [408, 429, 500, 502, 503, 504].contains(code))
    }

    private static func isContextLength(_ message: String, _ errorType: String?) -> Bool {
        let lowered = message.lowercased()
        return errorType == "context_length_exceeded" || lowered.contains("context length")
            || lowered.contains("context_length") || lowered.contains("context window")
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(value),
              seconds >= 0, seconds <= maxRetryAfter
        else { return nil }
        return seconds
    }

    /// The rate limit resets more than a minute from now (e.g. the daily quota of free models).
    private static func resetsLater(_ response: HTTPURLResponse) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = Double(value) else {
            return false
        }
        return reset / 1000 - Date().timeIntervalSince1970 > maxRetryAfter
    }
}

/// Splits a server-sent event stream into the payloads of its `data:` lines.
struct SSEParser {
    private var pending: [UInt8] = []

    /// Feeds bytes; returns the payloads of the complete lines.
    mutating func feed(_ bytes: [UInt8]) -> [String] {
        pending += bytes
        var payloads: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = Array(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if let payload = Self.payload(line) { payloads.append(payload) }
        }
        return payloads
    }

    /// The payload of an unterminated last line.
    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return Self.payload(pending).map { [$0] } ?? []
    }

    private static func payload(_ line: [UInt8]) -> String? {
        let prefix = Array("data:".utf8)
        guard line.count >= prefix.count, Array(line[..<prefix.count]) == prefix else { return nil }
        var start = prefix.count
        if start < line.count, line[start] == 0x20 { start += 1 }
        return String(decoding: line[start...], as: UTF8.self)
    }
}

/// Assembles the chunks of a streamed reply.
struct ChatStreamAccumulator {
    private var content = ""
    private var reasoning = ""
    private var details: [Int: [String: JSONValue]] = [:]
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var finishReason: String?
    private var usage: Usage?

    var hasToolCalls: Bool { !calls.isEmpty }

    /// Applies a chunk; returns the text it streamed.
    mutating func apply(_ chunk: [String: Any]) -> [ChatDelta] {
        if let usage = chunk["usage"] as? [String: Any] {
            self.usage = Usage(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                               completionTokens: usage["completion_tokens"] as? Int ?? 0)
        }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
        if finishReason == nil, let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] else { return [] }
        var deltas: [ChatDelta] = []
        if let text = delta["reasoning"] as? String, !text.isEmpty {
            reasoning += text
            deltas.append(.reasoning(text))
        }
        for detail in delta["reasoning_details"] as? [[String: Any]] ?? [] {
            merge(detail)
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            content += text
            deltas.append(.content(text))
        }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? calls.count
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if entry.id.isEmpty, let id = call["id"] as? String { entry.id = id }
            let function = call["function"] as? [String: Any]
            if entry.name.isEmpty, let name = function?["name"] as? String { entry.name = name }
            if let arguments = function?["arguments"] as? String { entry.arguments += arguments }
            calls[index] = entry
        }
        return deltas
    }

    private mutating func merge(_ detail: [String: Any]) {
        let index = detail["index"] as? Int ?? 0
        var merged = details[index] ?? [:]
        for (key, value) in detail {
            let converted = JSONValue(any: value)
            switch key {
            case "text", "summary", "data":
                merged[key] = .string((merged[key]?.string ?? "") + (converted.string ?? ""))
            default:
                if merged[key] == nil || merged[key] == .string("") { merged[key] = converted }
            }
        }
        details[index] = merged
    }

    var reply: ChatReply {
        ChatReply(content: content, reasoning: reasoning,
                  reasoningDetails: details.sorted { $0.key < $1.key }.map { .object($0.value) },
                  toolCalls: calls.sorted { $0.key < $1.key }.map { ToolCall(id: $0.value.id, name: $0.value.name,
                                                                                arguments: $0.value.arguments) },
                  finishReason: finishReason, usage: usage)
    }
}
