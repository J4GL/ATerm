import Foundation

/// Scripted HTTP answers for one host, recorded requests included.
final class StubServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        /// Fails the connection after the chunks (before any response when there is no chunk and no status).
        var error: URLError?
        var failsBeforeResponse = false

        static func stream(_ lines: [String], chunkSize: Int? = nil) -> Response {
            let body = Data(lines.map { $0 + "\n" }.joined().utf8)
            guard let chunkSize else { return Response(chunks: [body]) }
            return Response(chunks: stride(from: 0, to: body.count, by: chunkSize).map {
                body.subdata(in: $0..<min(body.count, $0 + chunkSize))
            })
        }

        static func error(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 },
                     chunks: [Data(body.utf8)])
        }

        static func dropped() -> Response {
            Response(error: URLError(.networkConnectionLost), failsBeforeResponse: true)
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    let host: String
    private let lock = NSLock()
    private var queued: [Response] = []
    private var recorded: [Recorded] = []

    /// `host` defaults to a host unique to the server; a real host (e.g. `opencode.ai`) is served by the last
    /// server created for it.
    init(responses: [Response] = [], host: String? = nil) {
        self.host = host ?? "stub-\(UUID().uuidString.lowercased()).test"
        queued = responses
        Self.lock.withLock { Self.servers[self.host] = self }
    }

    var endpoint: URL { URL(string: "https://\(host)/api/v1")! }

    var requests: [Recorded] { lock.withLock { recorded } }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    static func server(for host: String) -> StubServer? {
        lock.withLock { servers[host] }
    }

    func enqueue(_ response: Response) {
        lock.withLock { queued.append(response) }
    }

    /// Records the request and returns the next queued response, waiting up to 10 s for one.
    func next(for request: URLRequest, body: Data) -> Response {
        lock.withLock { recorded.append(Recorded(request: request, body: body)) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let response = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) { return response }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return .error(599, "no scripted response")
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        DispatchQueue.global().async { [self] in
            guard let host = request.url?.host, let server = StubServer.server(for: host) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            let response = server.next(for: request, body: body)
            guard !stopped else { return }
            if response.failsBeforeResponse, let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            for chunk in response.chunks where !stopped {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
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
