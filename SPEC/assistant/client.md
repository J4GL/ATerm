# Assistant — OpenRouter client

`OpenRouterClient` in `Sources/ATermCore/Assistant/OpenRouterClient.swift`
sends chat requests and assembles streamed replies (`SSEParser`,
`ChatStreamAccumulator`). Tests answer through a `URLProtocol` stub installed
in the client's `URLSessionConfiguration` and replace waiting by a recorder.

## ASSIST-CLIENT-001 — A chat request is sent as OpenRouter (or opencode) expects

Implement: `OpenRouterClient.complete(_:onDelta:)`, the `ChatClient` used by `Router` and `Agent`, created by the app from `AssistantConfiguration` (endpoint, key store).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/OpenRouterClientTests.swift` · "ASSIST-CLIENT-001 a chat request is sent as OpenRouter or opencode expects"
- Given: a client for `https://fake.test/api/v1` with the key `test-key`, answering `data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}` then `data: [DONE]`
- When: it completes a request for the model `m/x` with the session id `s-1`, the tool `bash` and the messages: system `sys`; user `hi`; assistant `calling` with the tool call `c1` `bash` `{"command":"ls"}` and the reasoning details `[{"type":"reasoning.text","text":"think","index":0}]` from model `m/x`; tool `c1` `Exit code: 0`; assistant `old` with the reasoning `r` from model `other/y`
- Then: one POST reached `https://fake.test/api/v1/chat/completions` with `Authorization: Bearer test-key`, `Content-Type: application/json` and `X-OpenRouter-Title: ATerm`; its JSON body has `model` `m/x`, `session_id` `s-1`, `stream` true, `tool_choice` `auto`, `tools` `[{"type":"function","function":{"name":"bash","description":…,"parameters":…}}]` and the messages `{"role":"system","content":"sys"}`, `{"role":"user","content":"hi"}`, `{"role":"assistant","content":"calling","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}],"reasoning_details":[{"type":"reasoning.text","text":"think","index":0}]}`, `{"role":"tool","tool_call_id":"c1","content":"Exit code: 0"}`, `{"role":"assistant","content":"old"}`; the reply's content is `ok`
- Given: the same client
- When: it completes a request with no session id
- Then: the JSON body has no `session_id` key
- Given: a request with the reasoning level `high`, and one with no level
- When: its body is built for `https://fake.test/api/v1`, for opencode's `https://opencode.ai/zen/go/v1`, and for OpenRouter's `https://openrouter.ai/api/v1`
- Then: with the level, the first two bodies have `"reasoning_effort":"high"` and no `reasoning` key, the OpenRouter body has `"reasoning":{"effort":"high"}` and no `reasoning_effort` key; without level, no body has either key
- Given: a client for the opencode endpoint `https://opencode.ai/zen/go/v1` (any host `opencode.ai` or ending with `.opencode.ai`) with the key `test-key`, answering the stream `ok`
- When: it completes a request with the session id `s-2`
- Then: the POST reached `https://opencode.ai/zen/go/v1/chat/completions` with the header `x-opencode-session: s-2`, and its JSON body has no `session_id` key
- When: it completes two requests with no session id (opencode refuses a request without the header)
- Then: both have the header `x-opencode-session` set to the same non-empty value, the client's own session id, which is not `s-2`
- Given: the same client with no key
- When: it completes a request
- Then: it throws `missingAPIKey` and sends nothing

## ASSIST-CLIENT-002 — A streamed reply is assembled from its fragments

Implement: `SSEParser` and `ChatStreamAccumulator`, fed by `OpenRouterClient` with the response bytes.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/OpenRouterClientTests.swift` · "ASSIST-CLIENT-002 a streamed reply is assembled from its fragments"
- Given: a response body made of the lines
  `: OPENROUTER PROCESSING` CR LF, an empty line,
  `data: {"choices":[{"delta":{"reasoning":"Let me ","reasoning_details":[{"type":"reasoning.text","text":"Let me ","index":0,"format":"f1"}]}}]}`,
  `data: {"choices":[{"delta":{"reasoning":"think","reasoning_details":[{"type":"reasoning.text","text":"think","index":0,"signature":"sig"}]}}]}`,
  `data: {"choices":[{"delta":{"content":"Héllo "}}]}`,
  `data: {"choices":[{"delta":{"content":"wörld","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\"comm"}}]}}]}`,
  `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}},{"index":1,"id":"call_2","type":"function","function":{"name":"search","arguments":"{}"}}]}}]}`,
  `data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
  `data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150}}`,
  `data: [DONE]`, each ending with LF, delivered in chunks of 1 byte, of 7 bytes, or all at once
- When: the client completes a request, recording the deltas
- Then: the reply has the content `Héllo wörld`, the reasoning `Let me think`, the reasoning details `[{"type":"reasoning.text","text":"Let me think","index":0,"format":"f1","signature":"sig"}]`, the tool calls `call_1` `bash` `{"command":"ls"}` and `call_2` `search` `{}`, the finish reason `tool_calls`, and the usage 120 prompt / 30 completion tokens; the deltas are, in order, reasoning `Let me `, reasoning `think`, content `Héllo `, content `wörld`

## ASSIST-CLIENT-003 — Failures are typed and transient ones are retried

Implement: the status and error mapping and the retry loop of `OpenRouterClient.complete(_:onDelta:)`.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/OpenRouterClientTests.swift` · "ASSIST-CLIENT-003 failures are typed and transient ones are retried"
- Given: a client with the retry delays 0.5, 1, 2, 4 s, whose waits are recorded instead of slept, and for each case the scripted responses below
- When: it completes a request
- Then: it gives the result, sends the number of requests and records the waits below:

| Responses | Result | Requests | Waits |
|---|---|---|---|
| 401 `{"error":{"code":401,"message":"No auth credentials found"}}` | throws `unauthorized("No auth credentials found")` | 1 | none |
| 402 `{"error":{"code":402,"message":"Insufficient credits"}}` | throws `insufficientCredits("Insufficient credits")` | 1 | none |
| 400 `{"error":{"code":400,"message":"This endpoint's maximum context length is 512000 tokens"}}` | throws `contextLengthExceeded` | 1 | none |
| 400 `{"error":{"code":400,"message":"Invalid model"}}` | throws `badRequest("Invalid model")` | 1 | none |
| 404 with an HTML page `<!DOCTYPE html><html>…</html>` | throws `badRequest("HTTP 404 (not found)")` | 1 | none |
| 429 with `Retry-After: 7`, then the stream `ok` | content `ok` | 2 | 7 |
| 503 five times | throws `server(503, …)` | 5 | 0.5, 1, 2, 4 (each up to 10 % longer) |
| an empty stream (`data: [DONE]` only), then the stream `ok` | content `ok` | 2 | 0.5 (up to 10 % longer) |
| a dropped connection, then the stream `ok` | content `ok` | 2 | 0.5 (up to 10 % longer) |
| 429 with `X-RateLimit-Reset` three hours ahead | throws `rateLimited` | 1 | none |
| 429 `{"error":{"code":429,"message":"Rate limit exceeded: free-models-per-day"}}` | throws `rateLimited` | 1 | none |
| the content `partial`, then `data: {"error":{"code":502,"message":"Provider disconnected"}}` | throws `server(502, "Provider disconnected")` after the delta `partial` | 1 | none |

## ASSIST-CLIENT-004 — Requests, responses and retries are reported

Implement: the `onEvent` callback of `OpenRouterClient` (`ClientEvent`), written to the macOS log by `AssistantServices.makeClient()` (subsystem `gl.j4.ATerm`, category `network`, never the key nor message text) and printed by `make live-check`; each retry is also streamed to the request's `onDelta` as `ChatDelta.retrying(RetryInfo)`, which `Agent` reports as `Event.retrying` (see [App assistant](../app/assistant.md), APP-ASSIST-012).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/OpenRouterClientTests.swift` · "ASSIST-CLIENT-004 requests responses and retries are reported"
- Given: a client for the model `m/x` with the retry delays 0.5, 1, 2, 4 s, whose waits are recorded instead of slept, recording its events and deltas, and for each case the scripted responses below
- When: it completes a request
- Then: it reports the events below, in order (every duration ≥ 0), and the retry deltas below:

| Responses | Events | Retry deltas |
|---|---|---|
| the stream `ok` | `sent(m/x, attempt 1)`, `responded(200)`, `finished` | none |
| 429 with `Retry-After: 7`, then the stream `ok` | `sent(m/x, 1)`, `responded(429)`, `retrying(attempt 2 of 5, wait 7, "HTTP 429")`, `sent(m/x, 2)`, `responded(200)`, `finished` | attempt 2 of 5, wait 7, `HTTP 429` |
| a dropped connection, then the stream `ok` | `sent(m/x, 1)`, `retrying(2 of 5, "connection lost")`, `sent(m/x, 2)`, `responded(200)`, `finished` | one, `connection lost` |
| 503 five times | `sent`, `responded(503)` and `retrying(n of 5, "HTTP 503")` for n = 2…5, then `sent(m/x, 5)`, `responded(503)`, `failed(server(503, …))` | four, `HTTP 503` |
| 401 | `sent(m/x, 1)`, `responded(401)`, `failed(unauthorized(…))` | none |
