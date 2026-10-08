# Assistant — routing a request

`Router` in `Sources/ATermCore/Assistant/Router.swift` asks the model
whether a request is one command to run now or a task for the agent. Tests
use a scripted `ChatClient` that records requests.

## ASSIST-ROUTE-001 — A request is classified as commands to run or a goal for the agent

Implement: `Router.route(prompt:environment:)`, called by `AssistantController` when the bar's request is submitted in a shell pane, with the redacted request and environment block.
Uses: [Assistant contract](contract.md), [Risky commands](safety.md)

Test: unit · `Tests/ATermCoreTests/Assistant/RouterTests.swift` · "ASSIST-ROUTE-001 a request is classified as commands to run or a goal for the agent"
- Given: a router for the model `m/x` whose client answers the reply below, and the environment block `ENV`
- When: it routes `find big files`
- Then: the only request uses the model `m/x`, `temperature` 0, the contract's `route` JSON schema as `response_format`, no tools, no session id, no reasoning level (a router given the level `low` sends `low`), and the messages system (the router instructions, an empty line, `ENV`) and user `find big files`; the route is:

| Reply | Route |
|---|---|
| `{"mode":"command","commands":[{"command":"du -sh * \| sort -h","explanation":"Sizes"},{"command":"rm -rf tmp","explanation":"Clean"}],"goal":""}` | commands `du -sh * \| sort -h` (`Sizes`, not risky) then `rm -rf tmp` (`Clean`, risky) |
| the same object with 5 commands `echo 1` … `echo 5`, wrapped in `` ```json `` … `` ``` `` | commands `echo 1` … `echo 4` |
| commands `git fetch` LF `git reset --hard` (`Two lines`) then `git pull` (`Pull`) | commands `git pull` only (a command holding a line break or a control character is dropped: it could run while only inserted) |
| `Sure! {"mode":"agent","commands":[],"goal":"GET / returns 2xx"} Done.` | agent with the goal `GET / returns 2xx` |

## ASSIST-ROUTE-002 — An invalid reply is corrected once, then reported

Implement: the retry of `Router.route(prompt:environment:)`.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/RouterTests.swift` · "ASSIST-ROUTE-002 an invalid reply is corrected once then reported"
- Given: a router whose client answers `I think you should run ls`, then `{"mode":"command","commands":[{"command":"ls","explanation":"List"}],"goal":""}`
- When: it routes `list`
- Then: the route is the command `ls`; the second request repeats the first messages, then the assistant reply `I think you should run ls`, then a user message asking for the JSON object only
- Given: a router whose client answers `nope`, then `{"mode":"command","commands":[],"goal":""}`
- When: it routes `list`
- Then: it throws `invalidResponse` after 2 requests
