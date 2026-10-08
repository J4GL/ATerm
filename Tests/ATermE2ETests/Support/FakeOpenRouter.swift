import Foundation
@testable import ATermApp
import ATermCore

/// A fake OpenRouter endpoint for one harness: it records every request and answers the replies the test
/// queued, in order; a request waits (up to 10 s) until its reply is queued. See SPEC/app/assistant.md.
final class FakeOpenRouter: @unchecked Sendable {
    enum Reply {
        /// A router reply: the JSON object as the message content.
        case route(String)
        /// An agent reply: streamed text and tool calls (id, name, arguments JSON).
        case agent(String, calls: [(id: String, name: String, arguments: String)])
        /// An HTTP error.
        case status(Int, String)
        /// A JSON answer (the model list).
        case json(Int, String)

        static func agentText(_ text: String) -> Reply { .agent(text, calls: []) }

        static func bash(_ id: String, _ command: String, text: String = "") -> Reply {
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: ["command": command]),
                                   as: UTF8.self)
            return .agent(text, calls: [(id, "bash", arguments)])
        }

        static func commands(_ commands: [(String, String)]) -> Reply {
            let items = commands.map { ["command": $0.0, "explanation": $0.1] }
            let object: [String: Any] = ["mode": "command", "commands": items, "goal": ""]
            return .route(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }

        /// A completer reply: the completed command line.
        static func completion(_ command: String) -> Reply {
            .route(String(decoding: try! JSONSerialization.data(withJSONObject: ["command": command]), as: UTF8.self))
        }

        static func agentTask(_ goal: String) -> Reply {
            let object: [String: Any] = ["mode": "agent", "commands": [], "goal": goal]
            return .route(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var messages: [[String: Any]] { json["messages"] as? [[String: Any]] ?? [] }
        var isRouter: Bool { json["response_format"] != nil && !isCompletion }
        /// A completer request (its `completion` JSON schema).
        var isCompletion: Bool {
            let format = json["response_format"] as? [String: Any]
            return (format?["json_schema"] as? [String: Any])?["name"] as? String == "completion"
        }
        var bodyText: String { String(decoding: body, as: UTF8.self) }

        func content(_ index: Int) -> String { messages[index]["content"] as? String ?? "" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fakes: [String: FakeOpenRouter] = [:]

    let host = "fake-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var queued: [Reply] = []
    private var recorded: [Recorded] = []

    init() {
        Self.lock.withLock { Self.fakes[host] = self }
    }

    var endpoint: URL { URL(string: "https://\(host)/api/v1")! }

    var requests: [Recorded] { lock.withLock { recorded } }

    func queue(_ replies: Reply...) {
        lock.withLock { queued += replies }
    }

    static func fake(for host: String) -> FakeOpenRouter? {
        lock.withLock { fakes[host] }
    }

    fileprivate func next(for request: URLRequest, body: Data) -> Reply? {
        lock.withLock { recorded.append(Recorded(request: request, body: body)) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let reply = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) { return reply }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    /// The assistant configuration of the assistant fixture. See SPEC/app/assistant.md.
    func assistantConfiguration(keyStore: APIKeyStore = MemoryAPIKeyStore(key: "test-key"),
                                loginEnvironment: [String: String] = [:]) -> AssistantConfiguration {
        var configuration = AssistantConfiguration()
        configuration.endpoint = endpoint
        configuration.keyStore = keyStore
        configuration.environmentKeyFallback = false
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FakeOpenRouterProtocol.self]
        configuration.sessionConfiguration = session
        configuration.retryDelays = [0, 0, 0, 0]
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
            .merging(loginEnvironment) { $1 }
        configuration.loginEnvironment = { environment }
        configuration.credentialFiles = []
        configuration.modelCatalogURL = nil
        configuration.systemInputAge = { nil }
        return configuration
    }

    static func sse(_ reply: Reply) -> (status: Int, body: Data) {
        func line(_ object: [String: Any]) -> String {
            "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
        }
        switch reply {
        case .route(let json):
            return (200, Data((line(["choices": [["delta": ["content": json]]]])
                + line(["choices": [["delta": [:], "finish_reason": "stop"]]]) + "data: [DONE]\n\n").utf8))
        case .agent(let text, let calls):
            var delta: [String: Any] = [:]
            if !text.isEmpty { delta["content"] = text }
            if !calls.isEmpty {
                delta["tool_calls"] = calls.enumerated().map { index, call in
                    ["index": index, "id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
                }
            }
            return (200, Data((line(["choices": [["delta": delta]]])
                + line(["choices": [["delta": [:], "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]]])
                + "data: [DONE]\n\n").utf8))
        case .status(let status, let body), .json(let status, let body):
            return (status, Data(body.utf8))
        }
    }
}

final class FakeOpenRouterProtocol: URLProtocol, @unchecked Sendable {
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        DispatchQueue.global().async { [self] in
            guard let host = request.url?.host, let fake = FakeOpenRouter.fake(for: host),
                  let reply = fake.next(for: request, body: body)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            guard !stopped else { return }
            let (status, data) = FakeOpenRouter.sse(reply)
            var contentType = status == 200 ? "text/event-stream" : "application/json"
            if case .json = reply { contentType = "application/json" }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
