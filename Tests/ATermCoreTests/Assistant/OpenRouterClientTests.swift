import Foundation
import Testing
import ATermCore

/// Records the waits a client asks for instead of sleeping.
final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    func wait(_ seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
    }

    var waits: [TimeInterval] { lock.withLock { recorded } }
}

/// Records streamed deltas.
final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatDelta] = []

    func append(_ delta: ChatDelta) { lock.withLock { recorded.append(delta) } }

    var deltas: [ChatDelta] { lock.withLock { recorded } }
}

func makeClient(_ server: StubServer, key: String? = "test-key", waits: WaitRecorder = WaitRecorder())
    -> OpenRouterClient {
    OpenRouterClient(endpoint: server.endpoint, apiKey: { key }, configuration: StubServer.configuration,
                     retryDelays: [0.5, 1, 2, 4], wait: { try await waits.wait($0) })
}

let bashDefinition = ToolDefinition(name: "bash", description: "Run a command.",
                                    parameters: .object(["type": .string("object")]))

func dataLine(_ json: String) -> String { "data: " + json }

/// An error page served by a web site instead of an API.
let htmlPage = #"<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><script>window.$HY=1</script></head><body>Not found</body></html>"#

@Test("ASSIST-CLIENT-001 a chat request is sent as OpenRouter or opencode expects")
func ASSIST_CLIENT_001() async throws {
    let server = StubServer(responses: [.stream([
        dataLine(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#), "data: [DONE]",
    ])])
    let reasoning: [JSONValue] = [.object(["type": .string("reasoning.text"), "text": .string("think"),
                                           "index": .number(0)])]
    let request = ChatRequest(model: "m/x", messages: [
        .system("sys"),
        .user("hi"),
        ChatMessage(role: .assistant, content: "calling",
                    toolCalls: [ToolCall(id: "c1", name: "bash", arguments: #"{"command":"ls"}"#)],
                    reasoningDetails: reasoning, reasoningModel: "m/x"),
        .tool(id: "c1", content: "Exit code: 0"),
        ChatMessage(role: .assistant, content: "old", reasoning: "r", reasoningModel: "other/y"),
    ], tools: [bashDefinition], sessionID: "s-1")
    let reply = try await makeClient(server).complete(request) { _ in }
    #expect(reply.content == "ok")

    let recorded = try #require(server.requests.first)
    #expect(server.requests.count == 1)
    #expect(recorded.request.httpMethod == "POST")
    #expect(recorded.request.url == server.endpoint.appendingPathComponent("chat/completions"))
    #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(recorded.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(recorded.request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "ATerm")
    let body = recorded.json
    #expect(body["model"] as? String == "m/x")
    #expect(body["session_id"] as? String == "s-1")
    #expect(body["stream"] as? Bool == true)
    #expect(body["tool_choice"] as? String == "auto")
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools.first?["type"] as? String == "function")
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "bash")
    #expect(function["description"] as? String == "Run a command.")
    #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")

    let messages = try #require(body["messages"] as? [[String: Any]])
    let expected: [[String: Any]] = [
        ["role": "system", "content": "sys"],
        ["role": "user", "content": "hi"],
        ["role": "assistant", "content": "calling",
         "tool_calls": [["id": "c1", "type": "function", "function": ["name": "bash", "arguments": #"{"command":"ls"}"#]]],
         "reasoning_details": [["type": "reasoning.text", "text": "think", "index": 0]]],
        ["role": "tool", "tool_call_id": "c1", "content": "Exit code: 0"],
        ["role": "assistant", "content": "old"],
    ]
    #expect(messages.count == expected.count)
    for (message, expectedMessage) in zip(messages, expected) {
        #expect(NSDictionary(dictionary: message).isEqual(to: expectedMessage), "\(message)")
    }

    var sessionless = request
    sessionless.sessionID = nil
    #expect(OpenRouterClient.body(for: sessionless)["session_id"] == nil)

    var thinking = request
    thinking.reasoningEffort = "high"
    for endpoint in ["https://fake.test/api/v1", "https://opencode.ai/zen/go/v1", "https://openrouter.ai/api/v1"] {
        let url = URL(string: endpoint)!
        let withLevel = OpenRouterClient.body(for: thinking, endpoint: url)
        let withoutLevel = OpenRouterClient.body(for: request, endpoint: url)
        if endpoint.contains("openrouter.ai") {
            #expect((withLevel["reasoning"] as? [String: Any])?["effort"] as? String == "high", "\(endpoint)")
            #expect(withLevel["reasoning_effort"] == nil, "\(endpoint)")
        } else {
            #expect(withLevel["reasoning_effort"] as? String == "high", "\(endpoint)")
            #expect(withLevel["reasoning"] == nil, "\(endpoint)")
        }
        #expect(withoutLevel["reasoning_effort"] == nil && withoutLevel["reasoning"] == nil, "\(endpoint)")
    }

    let keyless = StubServer()
    await #expect(throws: AssistantError.missingAPIKey) {
        _ = try await makeClient(keyless, key: nil).complete(request) { _ in }
    }
    #expect(keyless.requests.isEmpty)

    let okStream = StubServer.Response.stream([
        dataLine(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#), "data: [DONE]",
    ])
    let opencode = StubServer(responses: [okStream, okStream, okStream], host: "opencode.ai")
    let opencodeEndpoint = URL(string: "https://opencode.ai/zen/go/v1")!
    let opencodeClient = OpenRouterClient(endpoint: opencodeEndpoint, apiKey: { "test-key" },
                                          configuration: StubServer.configuration, retryDelays: [])
    var opencodeRequest = request
    opencodeRequest.sessionID = "s-2"
    _ = try await opencodeClient.complete(opencodeRequest) { _ in }
    _ = try await opencodeClient.complete(sessionless) { _ in }
    _ = try await opencodeClient.complete(sessionless) { _ in }
    #expect(opencode.requests.count == 3)
    let withSession = try #require(opencode.requests.first)
    #expect(withSession.request.url?.absoluteString == "https://opencode.ai/zen/go/v1/chat/completions")
    #expect(withSession.request.value(forHTTPHeaderField: "x-opencode-session") == "s-2")
    #expect(withSession.json["session_id"] == nil)
    let clientSessions = opencode.requests.dropFirst().map { $0.request.value(forHTTPHeaderField: "x-opencode-session") }
    #expect(clientSessions.count == 2 && clientSessions[0] == clientSessions[1])
    #expect(!(clientSessions[0] ?? "").isEmpty && clientSessions[0] != "s-2")
}

enum ChunkSize: Int, CaseIterable, CustomTestStringConvertible, Sendable {
    case oneByte = 1, sevenBytes = 7, whole = 0

    var testDescription: String { self == .whole ? "whole body" : "\(rawValue)-byte chunks" }
}

@Test("ASSIST-CLIENT-002 a streamed reply is assembled from its fragments", arguments: ChunkSize.allCases)
func ASSIST_CLIENT_002(_ chunkSize: ChunkSize) async throws {
    let lines = [
        ": OPENROUTER PROCESSING\r",
        "",
        dataLine(#"{"choices":[{"delta":{"reasoning":"Let me ","reasoning_details":[{"type":"reasoning.text","text":"Let me ","index":0,"format":"f1"}]}}]}"#),
        dataLine(#"{"choices":[{"delta":{"reasoning":"think","reasoning_details":[{"type":"reasoning.text","text":"think","index":0,"signature":"sig"}]}}]}"#),
        dataLine(#"{"choices":[{"delta":{"content":"Héllo "}}]}"#),
        dataLine(#"{"choices":[{"delta":{"content":"wörld","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"comm"}}]}}]}"#),
        dataLine(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}},{"index":1,"id":"call_2","type":"function","function":{"name":"search","arguments":"{}"}}]}}]}"#),
        dataLine(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
        dataLine(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150}}"#),
        "data: [DONE]",
    ]
    let server = StubServer(responses: [.stream(lines, chunkSize: chunkSize == .whole ? nil : chunkSize.rawValue)])
    let deltas = DeltaRecorder()
    let reply = try await makeClient(server).complete(ChatRequest(model: "m/x", messages: [.user("hi")])) {
        deltas.append($0)
    }
    #expect(reply.content == "Héllo wörld")
    #expect(reply.reasoning == "Let me think")
    #expect(reply.reasoningDetails == [.object(["type": .string("reasoning.text"), "text": .string("Let me think"),
                                                "index": .number(0), "format": .string("f1"),
                                                "signature": .string("sig")])])
    #expect(reply.toolCalls == [ToolCall(id: "call_1", name: "bash", arguments: #"{"command":"ls"}"#),
                                ToolCall(id: "call_2", name: "search", arguments: "{}")])
    #expect(reply.finishReason == "tool_calls")
    #expect(reply.usage == Usage(promptTokens: 120, completionTokens: 30))
    #expect(deltas.deltas == [.reasoning("Let me "), .reasoning("think"), .content("Héllo "), .content("wörld")])
}

struct FailureCase: CustomTestStringConvertible, @unchecked Sendable {
    let name: String
    let responses: () -> [StubServer.Response]
    /// nil: the reply's content is `ok`.
    let error: ((AssistantError) -> Bool)?
    let requests: Int
    let waits: [TimeInterval]
    var jitter = false
    var partialDelta = false

    var testDescription: String { name }
}

private let ok = StubServer.Response.stream([dataLine(#"{"choices":[{"delta":{"content":"ok"}}]}"#), "data: [DONE]"])

private func errorBody(_ code: Int, _ message: String) -> String {
    #"{"error":{"code":\#(code),"message":"\#(message)"}}"#
}

private let failureCases: [FailureCase] = [
    FailureCase(name: "401", responses: { [.error(401, errorBody(401, "No auth credentials found"))] },
                error: { $0 == .unauthorized("No auth credentials found") }, requests: 1, waits: []),
    FailureCase(name: "402", responses: { [.error(402, errorBody(402, "Insufficient credits"))] },
                error: { $0 == .insufficientCredits("Insufficient credits") }, requests: 1, waits: []),
    FailureCase(name: "400 context length",
                responses: { [.error(400, errorBody(400, "This endpoint's maximum context length is 512000 tokens"))] },
                error: { if case .contextLengthExceeded = $0 { true } else { false } }, requests: 1, waits: []),
    FailureCase(name: "400", responses: { [.error(400, errorBody(400, "Invalid model"))] },
                error: { $0 == .badRequest("Invalid model") }, requests: 1, waits: []),
    FailureCase(name: "404 HTML page", responses: { [.error(404, htmlPage)] },
                error: { $0 == .badRequest("HTTP 404 (not found)") }, requests: 1, waits: []),
    FailureCase(name: "429 with Retry-After",
                responses: { [.error(429, errorBody(429, "Slow down"), headers: ["Retry-After": "7"]), ok] },
                error: nil, requests: 2, waits: [7]),
    FailureCase(name: "503 five times",
                responses: { Array(repeating: .error(503, errorBody(503, "Overloaded")), count: 5) },
                error: { if case .server(503, _) = $0 { true } else { false } }, requests: 5, waits: [0.5, 1, 2, 4],
                jitter: true),
    FailureCase(name: "empty stream", responses: { [.stream(["data: [DONE]"]), ok] }, error: nil, requests: 2,
                waits: [0.5], jitter: true),
    FailureCase(name: "dropped connection", responses: { [.dropped(), ok] }, error: nil, requests: 2, waits: [0.5],
                jitter: true),
    FailureCase(name: "429 quota resetting in three hours",
                responses: {
                    let reset = Int((Date().timeIntervalSince1970 + 3 * 3600) * 1000)
                    return [.error(429, errorBody(429, "Rate limit exceeded"), headers: ["X-RateLimit-Reset": "\(reset)"])]
                },
                error: { if case .rateLimited = $0 { true } else { false } }, requests: 1, waits: []),
    FailureCase(name: "429 per-day",
                responses: { [.error(429, errorBody(429, "Rate limit exceeded: free-models-per-day"))] },
                error: { if case .rateLimited = $0 { true } else { false } }, requests: 1, waits: []),
    FailureCase(name: "error chunk after content",
                responses: { [.stream([dataLine(#"{"choices":[{"delta":{"content":"partial"}}]}"#),
                                       dataLine(#"{"error":{"code":502,"message":"Provider disconnected"}}"#)])] },
                error: { $0 == .server(502, "Provider disconnected") }, requests: 1, waits: [], partialDelta: true),
]

@Test("ASSIST-CLIENT-003 failures are typed and transient ones are retried", arguments: failureCases)
func ASSIST_CLIENT_003(_ testCase: FailureCase) async throws {
    let server = StubServer(responses: testCase.responses())
    let waits = WaitRecorder()
    let deltas = DeltaRecorder()
    let client = makeClient(server, waits: waits)
    do {
        let reply = try await client.complete(ChatRequest(model: "m/x", messages: [.user("hi")])) { deltas.append($0) }
        #expect(testCase.error == nil)
        #expect(reply.content == "ok")
    } catch let error as AssistantError {
        #expect(testCase.error?(error) == true, "\(error)")
    }
    #expect(server.requests.count == testCase.requests)
    #expect(waits.waits.count == testCase.waits.count)
    for (wait, expected) in zip(waits.waits, testCase.waits) {
        if testCase.jitter {
            #expect(wait >= expected && wait <= expected * 1.1 + 1e-9, "\(wait)")
        } else {
            #expect(wait == expected)
        }
    }
    if testCase.partialDelta {
        #expect(deltas.deltas == [.content("partial")])
    }
}

/// Records a client's events.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ClientEvent] = []

    func append(_ event: ClientEvent) { lock.withLock { recorded.append(event) } }

    var events: [ClientEvent] { lock.withLock { recorded } }
}

/// An event without its durations.
private func describe(_ event: ClientEvent) -> String {
    switch event {
    case .sent(let model, let attempt): "sent \(model) \(attempt)"
    case .responded(let status, _): "responded \(status)"
    case .finished: "finished"
    case .retrying(let info): "retrying \(info.attempt)/\(info.of) \(info.reason)"
    case .failed(let error, _):
        switch error {
        case .server(let status, _): "failed server \(status)"
        case .unauthorized: "failed unauthorized"
        default: "failed \(error)"
        }
    }
}

private func durations(_ event: ClientEvent) -> [TimeInterval] {
    switch event {
    case .sent: []
    case .responded(_, let after), .finished(let after, _), .failed(_, let after): [after]
    case .retrying(let info): [info.wait]
    }
}

struct EventCase: CustomTestStringConvertible, @unchecked Sendable {
    let name: String
    let responses: () -> [StubServer.Response]
    let events: [String]
    /// The wait of the first retry, when it is exact.
    var firstWait: TimeInterval?

    var testDescription: String { name }
}

private let eventCases: [EventCase] = [
    EventCase(name: "ok", responses: { [ok] }, events: ["sent m/x 1", "responded 200", "finished"]),
    EventCase(name: "429 then ok",
              responses: { [.error(429, errorBody(429, "Slow down"), headers: ["Retry-After": "7"]), ok] },
              events: ["sent m/x 1", "responded 429", "retrying 2/5 HTTP 429", "sent m/x 2", "responded 200",
                       "finished"],
              firstWait: 7),
    EventCase(name: "dropped connection then ok", responses: { [.dropped(), ok] },
              events: ["sent m/x 1", "retrying 2/5 connection lost", "sent m/x 2", "responded 200", "finished"]),
    EventCase(name: "503 five times",
              responses: { Array(repeating: .error(503, errorBody(503, "Overloaded")), count: 5) },
              events: (2...5).flatMap { ["sent m/x \($0 - 1)", "responded 503", "retrying \($0)/5 HTTP 503"] }
                  + ["sent m/x 5", "responded 503", "failed server 503"]),
    EventCase(name: "401", responses: { [.error(401, errorBody(401, "No auth credentials found"))] },
              events: ["sent m/x 1", "responded 401", "failed unauthorized"]),
]

@Test("ASSIST-CLIENT-004 requests responses and retries are reported", arguments: eventCases)
func ASSIST_CLIENT_004(_ testCase: EventCase) async throws {
    let server = StubServer(responses: testCase.responses())
    let waits = WaitRecorder()
    let recorder = EventRecorder()
    let deltas = DeltaRecorder()
    let client = OpenRouterClient(endpoint: server.endpoint, apiKey: { "test-key" },
                                  configuration: StubServer.configuration, retryDelays: [0.5, 1, 2, 4],
                                  wait: { try await waits.wait($0) }, onEvent: { recorder.append($0) })
    _ = try? await client.complete(ChatRequest(model: "m/x", messages: [.user("hi")])) { deltas.append($0) }

    let events = recorder.events
    #expect(events.map(describe) == testCase.events)
    #expect(events.flatMap(durations).allSatisfy { $0 >= 0 })
    let retries = events.compactMap { event -> RetryInfo? in
        if case .retrying(let info) = event { info } else { nil }
    }
    #expect(retries.map(\.wait) == waits.waits)
    if let firstWait = testCase.firstWait { #expect(retries.first?.wait == firstWait) }
    #expect(deltas.deltas.compactMap { delta -> RetryInfo? in
        if case .retrying(let info) = delta { info } else { nil }
    } == retries)
}
