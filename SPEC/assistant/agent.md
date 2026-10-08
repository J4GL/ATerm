# Assistant — the agent loop

`Agent` in `Sources/ATermCore/Assistant/Agent.swift` runs a conversation
with the two tools until the model ends a turn with a status line. It reports
what happens as `Agent.Event`s, which the agent tab prints. Prompts live in
`AgentPrompts.swift`. Tests use a scripted `ChatClient` recording the
requests, a real `CommandRunner` in a temporary directory, and an approval
handler returning a fixed answer.

## ASSIST-AGENT-001 — The first request carries the goal, the context and exactly two tools

Implement: `Agent.run(_:)` with the system prompt from `AgentPrompts.system(goal:environment:projectInstructions:)`, started by `AgentTab` with the router's goal and the user's request.
Uses: [Assistant contract](contract.md), [Redaction](redaction.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-001 the first request carries the goal the context and exactly two tools"
- Given: an agent for the model `m/x` with the system prompt for the goal `G1`, the environment `ENV` and the project instructions `PI`, a redactor knowing `API_TOKEN=supersecret-123`, and a client answering `Done.` LF `GOAL MET`
- When: it runs `fix it supersecret-123`
- Then: the only request uses the model `m/x`, `tool_choice` `auto` and exactly the tools `bash` then `search` with the contract's parameters; its messages are the system prompt (containing `G1`, `ENV`, `PI`, `GOAL MET`, `GOAL NOT MET`, `NEED INPUT` and `sed -i ''`) and the user message `fix it <API_TOKEN_1:15chars>`; the run ends with the status goal met and the message `Done.` LF `GOAL MET`; the request carries a lowercase UUID as its session id
- When: it runs the reply `and more`, then a second agent with the same configuration runs `go`
- Then: the reply's request carries the same session id as the first; the second agent's request carries a different lowercase UUID; no request carries a reasoning level
- When: an agent configured with the reasoning level `high` runs `go`
- Then: its request carries the level `high`

## ASSIST-AGENT-002 — Tool calls run in order and the run ends on a status line

Implement: the loop of `Agent.run(_:)`: tool results in the `tool` role with their call ids, errors returned to the model, the final status, one reminder when it is missing.
Uses: [Assistant contract](contract.md), [bash](bash-tool.md), [search](search-tool.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-002 tool calls run in order and the run ends on a status line"
- Given: an agent in an empty temporary directory whose client answers (1) `Checking.` with the tool calls `c1` `bash` `{"command":"echo one > f.txt; cat f.txt"}`, `c2` `search` `{"pattern":"one"}`, `c3` `bash` `{not json`, `c4` `nope` `{}`; (2) `All good`; (3) `Verified.` LF `GOAL MET`
- When: it runs `make f`
- Then: the second request ends with the assistant message `Checking.` carrying the four calls, then the tool messages `c1` (starting `Exit code: 0`, ending `Output:` LF `one`), `c2` (`f.txt:1:one`), `c3` (starting `Error: invalid arguments for bash`) and `c4` (`Error: unknown tool "nope". Available tools: bash, search.`); the third request ends with the assistant message `All good` and a user message naming `GOAL MET`, `GOAL NOT MET` and `NEED INPUT`; the events are, in order: text `Checking.`, command started `c1`, output `one` LF, command finished `c1` with exit code 0, search started `c2`, search finished `c2`, tool failed `c3`, tool failed `c4`, text `All good`, text `Verified.` LF `GOAL MET`, finished with the status goal met
- Given: for each case, an agent whose client answers the replies below
- When: it runs `go`
- Then: the run ends as stated:

| Replies | End |
|---|---|
| `Tried.` LF `**GOAL NOT MET**` | status goal not met, after 1 request |
| `Which port?` LF `Need input.` | status needs input, after 1 request |
| `x`, then `y` | no status, after 2 requests (a single reminder) |

## ASSIST-AGENT-003 — A risky command waits for the user's approval

Implement: the approval step of `Agent` for `bash` calls flagged by `CommandRisk.assess(_:)`; the agent tab asks with Return / Esc.
Uses: [Risky commands](safety.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-003 a risky command waits for the user's approval"
- Given: an agent in a temporary directory T holding `build/`, whose client answers the call `c1` `bash` `{"command":"rm -rf build"}`, then `ok` LF `GOAL MET`, and whose approval handler answers no
- When: it runs `clean`
- Then: the handler was asked once with `rm -rf build` and a non-empty reason, `T/build` still exists, and the tool message `c1` is `The user denied this command. Do not run it again; find another way or ask the user.`
- Given: the same agent whose approval handler answers yes
- When: it runs `clean`
- Then: `T/build` no longer exists and the tool message `c1` starts with `Exit code: 0`

## ASSIST-AGENT-004 — Repeated calls and the step budget are signalled, the step limit ends the run

Implement: the guards of `Agent` (`Agent.Configuration.maxToolCalls` 60, `budgetWarningAt` 50, `repeatLimit` 3).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-004 repeated calls and the step budget are signalled and the step limit ends the run"
- Given: an agent limited to 4 tool calls with the budget warning at 3, whose client answers three times the call `bash` `{"command":"echo same"}`, then the calls `c4` `bash` `{"command":"echo four"}` and `c5` `bash` `{"command":"echo five"}`
- When: it runs `go`
- Then: the first two tool results carry no warning; the third ends with `[Warning: this exact call ran 3 times in a row. Change your approach.]` and `[Warning: 1 tool call left in this run. Verify the goal and conclude.]`; `c4` ran; the result of `c5` is `Not run: the step limit of 4 tool calls was reached.`; the run ends with the step limit after 4 requests

## ASSIST-AGENT-005 — Old tool outputs are cleared to keep the context small

Implement: the pruning of `Agent` before each request (`protectedOutputTokens` 40 000, `minimumPruneTokens` 20 000, 4 bytes per token) and its reaction to `contextLengthExceeded`.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-005 old tool outputs are cleared to keep the context small"
- Given: an agent protecting 100 tokens of outputs and pruning at least 50, whose client answers four times a `bash` call printing 240 `a`, then `done` LF `GOAL MET`
- When: it runs `go`
- Then: in the second request the first output is intact; in the fifth request the first three outputs read `[Output cleared to save context — re-run the command if you need it]` and the fourth is intact; the calls themselves are unchanged
- Given: the same limits, and a single `bash` call printing 100 lines of 10 `a` (more than the protected tokens), then `done` LF `GOAL MET`
- When: it runs `go`
- Then: the second request holds that output intact (the latest output is never cleared)
- Given: an agent with the default thresholds whose client answers five times a `bash` call `echo N`, then fails the next request once with `contextLengthExceeded`, then answers `done` LF `GOAL MET`
- When: it runs `go`
- Then: the request is sent again once, with the first two outputs cleared and the last three intact, and the run ends with the status goal met
- Given: the same agent whose client fails that request twice
- When: it runs `go`
- Then: the run ends as failed with `contextLengthExceeded`

## ASSIST-AGENT-006 — Reasoning is sent back with the messages it belongs to

Implement: `Agent` storing each reply's `reasoning_details` (or reasoning text) and model on its assistant message, across runs of the same conversation.
Uses: [Assistant contract](contract.md), [Client](client.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-006 reasoning is sent back with the messages it belongs to"
- Given: an agent for the model `m/x` whose client answers (1) the reasoning details `[{"type":"reasoning.text","text":"r1","index":0}]` with the call `bash` `{"command":"echo hi"}`, (2) `Done` LF `GOAL MET`, (3) `Again` LF `GOAL MET`
- When: it runs `go`, then `again`
- Then: in the second and the third requests the first assistant message carries those reasoning details and the model `m/x`; the third request ends with the user message `again`

## ASSIST-AGENT-007 — Stopping ends the run at once

Implement: `Agent.run(_:)` under task cancellation: the stream is cancelled, the running command's group killed, a pending approval resolved; the history stays valid for a reply.
Uses: [bash](bash-tool.md)

Test: unit · `Tests/ATermCoreTests/Assistant/AgentTests.swift` · "ASSIST-AGENT-007 stopping ends the run at once"
- Given: an agent in a temporary directory run in a task, for each case below
- When: the task is cancelled at the moment described
- Then: within 5 s the run ends as stopped, no other request is sent, and:

| Client answer | Cancelled | Also |
|---|---|---|
| the call `c1` `bash` `{"command":"sleep 30"}` | once the command started | no process of its group is left; the last message is the tool message `c1` `Stopped by the user.` |
| the call `c1` `bash` `{"command":"rm -rf build"}` (T holds `build/`) | while the approval is pending | `build/` still exists |
| a stream that never ends | while waiting for it | the history holds only the user message |
