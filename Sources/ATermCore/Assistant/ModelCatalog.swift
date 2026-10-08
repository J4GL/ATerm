import Foundation

/// A model an API key can use, with its prices in US dollars per token and its reasoning levels.
public struct ModelInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var inputPrice: Double?
    public var cachedPrice: Double?
    public var outputPrice: Double?
    /// The reasoning levels the model accepts (`ModelInfo.effortOrder`), empty when unknown or none.
    public var reasoningEfforts: [String]
    public var defaultEffort: String?

    /// Reasoning levels from the lightest to the heaviest.
    public static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    public init(id: String, name: String, inputPrice: Double?, cachedPrice: Double?, outputPrice: Double?,
                reasoningEfforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.name = name
        self.inputPrice = inputPrice
        self.cachedPrice = cachedPrice
        self.outputPrice = outputPrice
        self.reasoningEfforts = Self.ordered(reasoningEfforts)
        self.defaultEffort = defaultEffort
    }

    /// Levels in `effortOrder`, unknown ones last, without duplicates.
    static func ordered(_ efforts: [String]) -> [String] {
        var unique: [String] = []
        for effort in efforts where !unique.contains(effort) { unique.append(effort) }
        let known = effortOrder.filter(unique.contains)
        return known + unique.filter { !effortOrder.contains($0) }
    }

    /// The prices per million tokens: `in $3.00 · cached $0.30 · out $15.00 /M`, `free`, or empty when unknown.
    public var priceSummary: String {
        if inputPrice == 0 && outputPrice == 0 { return "free" }
        if inputPrice == nil && cachedPrice == nil && outputPrice == nil { return "" }
        return "in \(Self.format(inputPrice)) · cached \(Self.format(cachedPrice)) · out \(Self.format(outputPrice)) /M"
    }

    /// Dollars per million tokens, with two to four decimals.
    private static func format(_ perToken: Double?) -> String {
        guard let perToken else { return "—" }
        let perMillion = perToken * 1_000_000
        if perMillion == 0 { return "$0" }
        var text = String(format: "%.4f", perMillion)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return "$" + text
    }
}

/// The models of an endpoint, and whether fetching them checked the key.
public struct ModelList: Equatable, Sendable {
    public var models: [ModelInfo]
    /// The list came from `models/user`, which rejects an invalid key; `models` may answer any key.
    public var checksKey: Bool

    public init(models: [ModelInfo], checksKey: Bool) {
        self.models = models
        self.checksKey = checksKey
    }
}

/// Fetches the models an API key can use. See SPEC/assistant/models.md.
public enum ModelCatalog {
    /// The catalog opencode uses: levels and prices of the models of many endpoints.
    public static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    /// Asks `models/user` (which rejects an invalid key), then `models` when the endpoint has no `models/user`.
    /// A list without reasoning information is completed from `catalog`, when given.
    public static func fetch(endpoint: URL, key: String?, configuration: URLSessionConfiguration = .default,
                             catalog: URL? = nil) async throws -> ModelList {
        guard let key, !key.isEmpty else { throw AssistantError.missingAPIKey }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var (data, response) = try await get(endpoint.appendingPathComponent("models/user"), key: key, session: session)
        let checksKey = response.statusCode != 404
        if !checksKey {
            (data, response) = try await get(endpoint.appendingPathComponent("models"), key: key, session: session)
        }
        let parsed = try parse(data, response: response)
        var models = parsed.models
        if let catalog, !parsed.hasReasoning {
            models = await completed(models, endpoint: endpoint, catalog: catalog, session: session)
        }
        return ModelList(models: models, checksKey: checksKey)
    }

    /// Fills the levels, the missing prices and names of the endpoint's models from the provider of `catalog`
    /// whose `api` is the endpoint. A catalog that fails leaves the models unchanged.
    private static func completed(_ models: [ModelInfo], endpoint: URL, catalog: URL,
                                  session: URLSession) async -> [ModelInfo] {
        guard let (data, response) = try? await get(catalog, key: nil, session: session), response.statusCode == 200,
              let providers = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return models }
        let base = trimmedSlash(endpoint.absoluteString)
        guard let provider = providers.values.compactMap({ $0 as? [String: Any] })
            .first(where: { ($0["api"] as? String).map(trimmedSlash) == base }),
              let entries = provider["models"] as? [String: Any]
        else { return models }
        return models.map { model in
            guard let entry = entries[model.id] as? [String: Any] else { return model }
            var model = model
            if model.name == model.id, let name = entry["name"] as? String { model.name = name }
            let options = entry["reasoning_options"] as? [[String: Any]] ?? []
            let efforts = options.filter { $0["type"] as? String == "effort" }
                .flatMap { $0["values"] as? [String] ?? [] }
            if !efforts.isEmpty { model.reasoningEfforts = ModelInfo.ordered(efforts) }
            let cost = entry["cost"] as? [String: Any] ?? [:]
            func perToken(_ key: String) -> Double? { price(cost[key]).map { $0 / 1_000_000 } }
            model.inputPrice = model.inputPrice ?? perToken("input")
            model.cachedPrice = model.cachedPrice ?? perToken("cache_read")
            model.outputPrice = model.outputPrice ?? perToken("output")
            return model
        }
    }

    private static func trimmedSlash(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private static func get(_ url: URL, key: String?, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ATerm", forHTTPHeaderField: "X-OpenRouter-Title")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AssistantError.network((error as? URLError)?.localizedDescription ?? "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse("not an HTTP response")
        }
        return (data, http)
    }

    /// The models of a list, and whether it gives reasoning information (OpenRouter's `reasoning`).
    private static func parse(_ data: Data, response: HTTPURLResponse) throws
        -> (models: [ModelInfo], hasReasoning: Bool) {
        guard response.statusCode == 200 else {
            throw OpenRouterClient.error(status: response.statusCode, body: data, response: response)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["data"] as? [[String: Any]]
        else {
            throw AssistantError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            let pricing = item["pricing"] as? [String: Any] ?? [:]
            let reasoning = item["reasoning"] as? [String: Any] ?? [:]
            return ModelInfo(id: id, name: item["name"] as? String ?? id,
                             inputPrice: price(pricing["prompt"]), cachedPrice: price(pricing["input_cache_read"]),
                             outputPrice: price(pricing["completion"]),
                             reasoningEfforts: reasoning["supported_efforts"] as? [String] ?? [],
                             defaultEffort: reasoning["default_effort"] as? String)
        }
        return (models, items.contains { $0["reasoning"] != nil })
    }

    private static func price(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }
}
