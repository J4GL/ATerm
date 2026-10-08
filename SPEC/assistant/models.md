# Assistant — model list

`ModelCatalog` in `Sources/ATermCore/Assistant/ModelCatalog.swift` fetches
the models an API key can use, to check the key and to complete the model
field of [Settings](../app/settings.md). OpenRouter's `GET /models` answers
any key, so the catalog asks `GET /models/user`, which rejects an invalid key
with 401; an endpoint without it (404, e.g. a generic OpenAI-compatible
server) is asked `GET /models` instead. Both answer
`{"data":[{"id":…,"name":…,"pricing":{"prompt":…,"completion":…,"input_cache_read":…}}]}`,
prices being decimal strings in US dollars per token. OpenRouter also gives each
model's reasoning levels: `"reasoning":{"supported_efforts":[…],"default_effort":…}`.
Levels are kept in the order `none, minimal, low, medium, high, xhigh, max`
(unknown ones last). An endpoint whose list gives no reasoning information
(opencode's) is looked up in the models.dev catalog (`https://models.dev/api.json`,
the one opencode uses) for its levels and missing prices. Tests answer through
the `URLProtocol` stub of the [client](client.md) tests, and pass no catalog
unless the spec says otherwise.

## ASSIST-MODELS-001 — The model list is fetched with the key, parsed, and failures are typed

Implement: `ModelCatalog.fetch(endpoint:key:configuration:)`, called by `AssistantServices.fetchModels(endpoint:key:)` for the Settings window.
Uses: [Assistant contract](contract.md), [client](client.md)

Test: unit · `Tests/ATermCoreTests/Assistant/ModelCatalogTests.swift` · "ASSIST-MODELS-001 the model list is fetched with the key parsed and failures are typed"
- Given: a stub endpoint `https://stub-….test/api/v1`, the key `test-key`, and for each case the scripted responses below
- When: the catalog fetches the list
- Then: it gives the result (with whether the list came from `models/user`, which checks the key) and sends the requests below, each a GET with `Authorization: Bearer test-key`:

| Responses | Result | Requests |
|---|---|---|
| 200 `{"data":[{"id":"a/one","name":"A: One","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003"}},{"id":"b/two","name":"B: Two","pricing":{"prompt":"0","completion":"0"}},{"id":"c/three","name":"C: Three","pricing":{"prompt":"n/a"}}]}` | `a/one` `A: One` prices 0.000003 / 0.0000003 / 0.000015; `b/two` `B: Two` 0 / none / 0; `c/three` `C: Three` none / none / none — in that order; key checked | `/api/v1/models/user` |
| 404, then 200 `{"object":"list","data":[{"id":"a/one","object":"model"}]}` | `a/one` named `a/one`, no price; key not checked | `/api/v1/models/user`, `/api/v1/models` |
| 401 `{"error":{"code":401,"message":"User not found."}}` | throws `unauthorized("User not found.")` | `/api/v1/models/user` |
| a dropped connection | throws `network(…)` | `/api/v1/models/user` |
| 200 `not json` | throws `invalidResponse(…)` | `/api/v1/models/user` |
| 404 then 404, both an HTML page `<!DOCTYPE html><html>…</html>` | throws `badRequest("HTTP 404 (not found)")` | `/api/v1/models/user`, `/api/v1/models` |
| 200 `{"data":[{"id":"a/one","name":"A","reasoning":{"supported_efforts":["max","high","low"],"default_effort":"high"}},{"id":"b/two","name":"B","reasoning":{"mandatory":false}}]}`, with a catalog given | `a/one` with the levels `low, high, max` and the default `high`; `b/two` with no level; the catalog is not requested | `/api/v1/models/user` |

- Given: the same endpoint with no key (nil or empty)
- When: the catalog fetches the list
- Then: it throws `missingAPIKey` and sends nothing

## ASSIST-MODELS-002 — Prices are shown in dollars per million tokens

Implement: `ModelInfo.priceSummary`, shown next to each model by the Settings model completion.

Test: unit · `Tests/ATermCoreTests/Assistant/ModelCatalogTests.swift` · "ASSIST-MODELS-002 prices are shown in dollars per million tokens"
- Given: a model with the per-token input, cached input and output prices below
- When: its `priceSummary` is read
- Then: it is the text below:

| Input | Cached | Output | Summary |
|---|---|---|---|
| 0.000003 | 0.0000003 | 0.000015 | `in $3.00 · cached $0.30 · out $15.00 /M` |
| 0.000000075 | none | 0.0000003 | `in $0.075 · cached — · out $0.30 /M` |
| 0 | 0 | 0.000001 | `in $0 · cached $0 · out $1.00 /M` |
| 0 | none | 0 | `free` |
| none | none | none | (empty: the endpoint gives no price) |

## ASSIST-MODELS-003 — Levels and prices missing from the endpoint come from the models.dev catalog

Implement: `ModelCatalog.fetch(endpoint:key:configuration:catalog:)` reading the catalog (`ModelCatalog.modelsDevURL` in the app, `AssistantConfiguration.modelCatalogURL`) when no model of the endpoint's list has reasoning information.
Uses: [client](client.md)

Test: unit · `Tests/ATermCoreTests/Assistant/ModelCatalogTests.swift` · "ASSIST-MODELS-003 levels and prices missing from the endpoint come from the models dev catalog"
- Given: a stub endpoint E answering 404 on `models/user` and `{"data":[{"id":"space-bunny-free"},{"id":"glm-5.3"},{"id":"unknown-x"}]}` on `models`, and a stub catalog answering as below
- When: the catalog fetches E's list with the catalog
- Then: the catalog was asked once, with a GET and no `Authorization` header, and the list is as below:

| Catalog answers | List |
|---|---|
| `{"other":{"api":"https://elsewhere.test/v1","models":{}},"opencode-go":{"api":"<E>/","models":{"space-bunny-free":{"name":"Space Bunny Free","reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],"cost":{"input":0,"output":0,"cache_read":0}},"glm-5.3":{"name":"GLM-5.3","reasoning_options":[{"type":"toggle"},{"type":"effort","values":["max","high","low"]}],"cost":{"input":1.4,"output":4.4,"cache_read":0.26}}}}}` | `space-bunny-free` named `Space Bunny Free`, levels `low, medium, high, xhigh, max`, prices `free`; `glm-5.3` named `GLM-5.3`, levels `low, high, max`, prices `in $1.40 · cached $0.26 · out $4.40 /M`; `unknown-x` unchanged (no level, no price) |
| `{"other":{"api":"https://elsewhere.test/v1","models":{}}}` (no provider for E) | the three models unchanged |
| 500 | the three models unchanged, no error |
| a dropped connection | the three models unchanged, no error |
