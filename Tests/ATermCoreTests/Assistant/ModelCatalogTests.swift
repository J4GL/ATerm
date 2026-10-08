import Foundation
import Testing
import ATermCore

private let threeModels = #"""
{"data":[{"id":"a/one","name":"A: One","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003"}},{"id":"b/two","name":"B: Two","pricing":{"prompt":"0","completion":"0"}},{"id":"c/three","name":"C: Three","pricing":{"prompt":"n/a"}}]}
"""#

private func json(_ status: Int, _ body: String) -> StubServer.Response {
    StubServer.Response(status: status, headers: ["Content-Type": "application/json"], chunks: [Data(body.utf8)])
}

struct ModelCatalogCase: CustomTestStringConvertible, Sendable {
    let name: String
    var key: String? = "test-key"
    let responses: @Sendable () -> [StubServer.Response]
    let paths: [String]
    /// A catalog stub is given; it must not be asked.
    var withCatalog = false
    let check: @Sendable (Result<ModelList, Error>) -> Void

    var testDescription: String { name }
}

@Test("ASSIST-MODELS-001 the model list is fetched with the key parsed and failures are typed", arguments: [
    ModelCatalogCase(name: "models/user answers", responses: { [json(200, threeModels)] },
                     paths: ["/api/v1/models/user"]) { result in
        let list = try? result.get()
        #expect(list?.checksKey == true)
        #expect(list?.models == [
            ModelInfo(id: "a/one", name: "A: One", inputPrice: 0.000003, cachedPrice: 0.0000003, outputPrice: 0.000015),
            ModelInfo(id: "b/two", name: "B: Two", inputPrice: 0, cachedPrice: nil, outputPrice: 0),
            ModelInfo(id: "c/three", name: "C: Three", inputPrice: nil, cachedPrice: nil, outputPrice: nil),
        ])
    },
    ModelCatalogCase(name: "404 falls back to models",
                     responses: { [json(404, #"{"error":{"code":404,"message":"Not Found"}}"#),
                                   json(200, #"{"object":"list","data":[{"id":"a/one","object":"model"}]}"#)] },
                     paths: ["/api/v1/models/user", "/api/v1/models"]) { result in
        let list = try? result.get()
        #expect(list?.checksKey == false)
        #expect(list?.models == [ModelInfo(id: "a/one", name: "a/one", inputPrice: nil, cachedPrice: nil,
                                           outputPrice: nil)])
    },
    ModelCatalogCase(name: "404 HTML pages are a clean bad request",
                     responses: { [.error(404, htmlPage), .error(404, htmlPage)] },
                     paths: ["/api/v1/models/user", "/api/v1/models"]) { result in
        #expect(error(of: result) == .badRequest("HTTP 404 (not found)"))
    },
    ModelCatalogCase(name: "OpenRouter levels", responses: { [json(200, #"{"data":[{"id":"a/one","name":"A","reasoning":{"supported_efforts":["max","high","low"],"default_effort":"high"}},{"id":"b/two","name":"B","reasoning":{"mandatory":false}}]}"#)] },
                     paths: ["/api/v1/models/user"], withCatalog: true) { result in
        let models = (try? result.get())?.models ?? []
        #expect(models.map(\.reasoningEfforts) == [["low", "high", "max"], []])
        #expect(models.map(\.defaultEffort) == ["high", nil])
    },
    ModelCatalogCase(name: "401 is unauthorized",
                     responses: { [json(401, #"{"error":{"code":401,"message":"User not found."}}"#)] },
                     paths: ["/api/v1/models/user"]) { result in
        #expect(error(of: result) == .unauthorized("User not found."))
    },
    ModelCatalogCase(name: "dropped connection is a network error", responses: { [.dropped()] },
                     paths: ["/api/v1/models/user"]) { result in
        guard case .network = error(of: result) else {
            Issue.record("expected a network error, got \(result)")
            return
        }
    },
    ModelCatalogCase(name: "not json is an invalid response", responses: { [json(200, "not json")] },
                     paths: ["/api/v1/models/user"]) { result in
        guard case .invalidResponse = error(of: result) else {
            Issue.record("expected an invalid response, got \(result)")
            return
        }
    },
    ModelCatalogCase(name: "no key", key: nil, responses: { [] }, paths: []) { result in
        #expect(error(of: result) == .missingAPIKey)
    },
    ModelCatalogCase(name: "empty key", key: "", responses: { [] }, paths: []) { result in
        #expect(error(of: result) == .missingAPIKey)
    },
])
func ASSIST_MODELS_001(_ scenario: ModelCatalogCase) async throws {
    let server = StubServer(responses: scenario.responses())
    let catalog = StubServer()
    let result: Result<ModelList, Error>
    do {
        result = .success(try await ModelCatalog.fetch(endpoint: server.endpoint, key: scenario.key,
                                                       configuration: StubServer.configuration,
                                                       catalog: scenario.withCatalog ? catalog.endpoint : nil))
    } catch {
        result = .failure(error)
    }
    scenario.check(result)
    #expect(catalog.requests.isEmpty)
    #expect(server.requests.map { $0.request.url?.path ?? "" } == scenario.paths)
    for recorded in server.requests {
        #expect(recorded.request.httpMethod == "GET")
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }
}

private func error(of result: Result<ModelList, Error>) -> AssistantError? {
    guard case .failure(let error) = result else { return nil }
    return error as? AssistantError
}

@Test("ASSIST-MODELS-002 prices are shown in dollars per million tokens", arguments: [
    (0.000003, 0.0000003, 0.000015, "in $3.00 · cached $0.30 · out $15.00 /M"),
    (0.000000075, nil, 0.0000003, "in $0.075 · cached — · out $0.30 /M"),
    (0, 0, 0.000001, "in $0 · cached $0 · out $1.00 /M"),
    (0, nil, 0, "free"),
    (nil, nil, nil, ""),
] as [(Double?, Double?, Double?, String)])
func ASSIST_MODELS_002(input: Double?, cached: Double?, output: Double?, summary: String) {
    let model = ModelInfo(id: "m/x", name: "M", inputPrice: input, cachedPrice: cached, outputPrice: output)
    #expect(model.priceSummary == summary)
}

private func endpointList() -> StubServer.Response {
    json(200, #"{"data":[{"id":"space-bunny-free"},{"id":"glm-5.3"},{"id":"unknown-x"}]}"#)
}

struct CatalogCase: CustomTestStringConvertible, Sendable {
    let name: String
    /// The catalog's answer, given the endpoint URL.
    let answer: @Sendable (URL) -> StubServer.Response
    let enriched: Bool

    var testDescription: String { name }
}

@Test("ASSIST-MODELS-003 levels and prices missing from the endpoint come from the models dev catalog", arguments: [
    CatalogCase(name: "provider found", answer: { endpoint in
        json(200, #"{"other":{"api":"https://elsewhere.test/v1","models":{}},"opencode-go":{"api":"\#(endpoint.absoluteString)/","models":{"space-bunny-free":{"name":"Space Bunny Free","reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],"cost":{"input":0,"output":0,"cache_read":0}},"glm-5.3":{"name":"GLM-5.3","reasoning_options":[{"type":"toggle"},{"type":"effort","values":["max","high","low"]}],"cost":{"input":1.4,"output":4.4,"cache_read":0.26}}}}}"#)
    }, enriched: true),
    CatalogCase(name: "no provider for the endpoint", answer: { _ in
        json(200, #"{"other":{"api":"https://elsewhere.test/v1","models":{}}}"#)
    }, enriched: false),
    CatalogCase(name: "catalog error", answer: { _ in json(500, "oops") }, enriched: false),
    CatalogCase(name: "catalog unreachable", answer: { _ in .dropped() }, enriched: false),
])
func ASSIST_MODELS_003(_ scenario: CatalogCase) async throws {
    let server = StubServer(responses: [json(404, #"{"error":{"message":"Not Found"}}"#), endpointList()])
    let catalog = StubServer(responses: [scenario.answer(server.endpoint)])
    let list = try await ModelCatalog.fetch(endpoint: server.endpoint, key: "test-key",
                                            configuration: StubServer.configuration, catalog: catalog.endpoint)
    #expect(catalog.requests.count == 1)
    #expect(catalog.requests.first?.request.httpMethod == "GET")
    #expect(catalog.requests.first?.request.value(forHTTPHeaderField: "Authorization") == nil)
    let models = list.models
    #expect(models.map(\.id) == ["space-bunny-free", "glm-5.3", "unknown-x"])
    if scenario.enriched {
        #expect(models.map(\.name) == ["Space Bunny Free", "GLM-5.3", "unknown-x"])
        #expect(models.map(\.reasoningEfforts) == [["low", "medium", "high", "xhigh", "max"], ["low", "high", "max"], []])
        #expect(models.map(\.priceSummary) == ["free", "in $1.40 · cached $0.26 · out $4.40 /M", ""])
    } else {
        #expect(models.map(\.name) == ["space-bunny-free", "glm-5.3", "unknown-x"])
        #expect(models.allSatisfy { $0.reasoningEfforts.isEmpty && $0.priceSummary.isEmpty })
    }
}
