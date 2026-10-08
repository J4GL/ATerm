# App — the assistant bar and agent tabs

Holding ⌘ opens the assistant bar of a shell pane — the active pane of its
tab, see [Split panes](splits.md) — (`AssistantBar`, driven by the pane's
`AssistantController`). A request is routed: suggested commands run in that
pane, an agent task opens an agent tab (`AgentTab`), read-only while the
agent works. Every spec uses the **assistant fixture**: the e2e fixture of the
[App contract](contract.md) plus

- a fake OpenRouter endpoint unique to the harness (`https://fake-<uuid>.test/api/v1`),
  served by a `URLProtocol` installed in the assistant's session
  configuration: it records every request and answers with the replies the
  test queues, in order (a request waits until its reply is queued);
- an in-memory key store holding `test-key`, without environment fallback;
- no retry delay, the login environment `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
  and `HOME`, no credential file, no system input during a ⌘ hold;
- the shell moved first to a fresh temporary directory T (`cd T`).

Router replies are queued as the JSON objects of the
[Assistant contract](../assistant/contract.md); agent replies as streamed
text and tool calls.

## APP-ASSIST-001 — Holding ⌘ alone opens the assistant bar

Implement: `TerminalView.flagsChanged(with:)` and the view's input handlers feeding `CommandHoldDetector`; `AssistantController` showing the hint and opening `AssistantBar`; Shell ▸ Ask… (`AppDelegate.askAssistant(_:)`).
Uses: [Holding ⌘](../input/hold.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-001 holding command alone opens the assistant bar"
- Given: a window of the assistant fixture showing the prompt, for each case below
- When / Then:

| Events | Result |
|---|---|
| ⌘ down at time t; 0.5 s later | the bar shows the hint `Release ⌘ to ask` |
| then ⌘ up at t + 0.6 | the bar shows the empty request field, which is the window's first responder; the terminal view is not focused |
| ⌘ down at t; ⌘ up at t + 0.1; 0.5 s later | the bar is hidden and the terminal view is the first responder |
| ⌘ down at t; 0.5 s later ⌘C, delivered as AppKit does (window key equivalents, then the main menu) | the hint is hidden; after ⌘ up at t + 0.8 the bar is still hidden |
| ⌘ down at t; 0.5 s later a click on cell (0, 0); ⌘ up at t + 0.8 | the hint is hidden, then the bar is still hidden |
| Shell ▸ Ask… | the bar shows the request field, first responder |

## APP-ASSIST-002 — Esc closes the bar and gives the keyboard back to the shell

Implement: `AssistantBar` handling `cancelOperation:` in its field; `AssistantController.close()` making the terminal view first responder.

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-002 esc closes the bar and gives the keyboard back to the shell"
- Given: a window of the assistant fixture whose bar is open with `abc` typed in the field
- When: Esc is pressed
- Then: the bar is hidden and the terminal view is the first responder
- When: `echo back` is typed and Return pressed
- Then: the screen shows a line `back`

## APP-ASSIST-003 — Suggested commands run or are inserted in the current tab

Implement: `AssistantController` routing the request with `Router`, `AssistantBar` listing the suggestions (↑/↓, Return, ⌥Return), and running one in the session: ⌃U, the command as a paste, then Return unless the tab is busy; a full-screen program gets nothing, the command is copied instead.
Uses: [Router](../assistant/router.md), [Paste](../input/paste-focus.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-003 suggested commands run or are inserted in the current tab"
- Given: a window of the assistant fixture showing the prompt, and the router reply suggesting `echo first-choice` (`First`) then `echo second-choice` (`Second`)
- When: ⌘ is held and released, `say it` typed and Return pressed
- Then: one request was sent, whose user message is `say it`; the bar lists `echo first-choice` with `First` (selected) then `echo second-choice` with `Second`
- When: ↓ then Return are pressed
- Then: the bar is hidden, the terminal view is the first responder, and the screen shows `$ echo second-choice` followed by the line `second-choice`
- Given: the same, then ⌥Return pressed on the first suggestion
- Then: the prompt row reads `$ echo first-choice` and 0.5 s later no line `first-choice` follows it
- Given: the same, with `abc` typed at the prompt before the bar was opened, then Return on the first suggestion
- Then: the screen shows `$ echo first-choice` (without `abc`) followed by the line `first-choice`
- Given: the same, with `sleep 3` running when Return is pressed on the first suggestion
- Then: the bar shows `Inserted without running: a program is running in this tab.`; once `sleep` has ended, the prompt row ends with `$ echo first-choice` (the terminal echoed the typed-ahead text first) and no line `first-choice` follows it
- Given: the same, with `less` showing a file (a full-screen program) when Return is pressed on the first suggestion
- Then: nothing is typed into `less`: the bar shows `Copied: a full-screen program is running in this tab.` and the pasteboard holds `echo first-choice`

## APP-ASSIST-004 — An agent task runs in a new read-only tab that shows its work

Implement: `AssistantController` opening an agent tab through `AppDelegate.openAgentTab(from:launch:)`; `AgentTab` running `Agent` and printing its events with `TranscriptFormatter` into a session without process, command output cleaned of control sequences.
Uses: [Agent](../assistant/agent.md), [bash](../assistant/bash-tool.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-004 an agent task runs in a new read-only tab that shows its work"
- Given: a window of the assistant fixture showing the prompt; the router reply is an agent task with the goal `proof.txt contains hello`; the agent replies are `I'll create it.` followed by the sequences `⎋]0;evil2 BEL` and `⎋]10;#1e1f26 BEL` (the model's text cannot drive the terminal either), with the call `c1` `bash` `echo a; sleep 1; echo b; printf hello > proof.txt; printf '\033]0;evil\007\033[6n'`, then `Created.` LF `GOAL MET`
- When: ⌘ is held and released, `make proof` typed and Return pressed
- Then: the bar closes and a second tab opens in the same window, selected; its screen shows, in this order, `◎ Goal: proof.txt contains hello`, `I'll create it.`, `$ echo a; sleep 1; echo b; printf hello > proof.txt; printf '\033]0;evil\007\033[6n'`, `a`, `b`, `Created.`, `✓ Goal met`; at one moment it shows `a` without `b`; its title is `Agent — proof.txt contains hello` and its foreground color is the default one; `T/proof.txt` holds `hello`; three requests were sent (router, agent, agent) and the last one ends with the tool message `c1` containing `Exit code: 0` and `a` LF `b`; the agent tab's bar never opened

## APP-ASSIST-005 — The agent tab ignores typing while the agent works, and ⌃C or ⌘. stops it

Implement: `AgentTab` as the input handler of its session (typing ignored while running, ⌃C stops) and Shell ▸ Stop Agent (⌘.) through `AppDelegate.stopAgent(_:)`; quitting kills the running command's group (`AppDelegate.applicationWillTerminate(_:)`).
Uses: [Agent](../assistant/agent.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-005 the agent tab ignores typing while the agent works and stops on request"
- Given: an agent tab of the assistant fixture whose agent runs the call `bash` `sleep 30`, for each stop gesture: ⌃C typed in the agent tab, ⌘. through the main menu, quitting the app (`applicationWillTerminate`)
- When: once the screen shows `$ sleep 30`, `x` is typed in the agent tab
- Then: the screen is unchanged and the bar stays hidden
- When: the stop gesture is made
- Then: within 3 s no process of the command's group is left and no other request was sent; for ⌃C and ⌘. the screen shows `■ Stopped`

## APP-ASSIST-006 — A risky command waits for Return or Esc in the agent tab

Implement: `AgentTab` answering `Agent`'s approval requests from Return / Esc typed in the tab, with a `⚠` title and a bell while waiting.
Uses: [Risky commands](../assistant/safety.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-006 a risky command waits for return or esc in the agent tab"
- Given: an agent tab of the assistant fixture where `T/build/` exists and the agent replies the call `c1` `bash` `rm -rf build`, then `ok` LF `GOAL MET`, for each key below
- When: once the screen shows `⚠ Risky command` and `Press Return to run it, Esc to skip.` and the title starts with `⚠`, the key is typed in the agent tab
- Then:

| Key | Result |
|---|---|
| Esc | `T/build` exists and the last request's tool message `c1` says the user denied the command |
| Return | `T/build` no longer exists and the last request's tool message `c1` starts with `Exit code: 0` |

## APP-ASSIST-007 — Typing in an idle agent tab replies to the agent in the same conversation

Implement: `AgentTab` opening the bar in reply mode with the typed text, and `Agent.run(_:)` continuing the conversation without routing.
Uses: [Agent](../assistant/agent.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-007 typing in an idle agent tab replies to the agent in the same conversation"
- Given: an agent tab of the assistant fixture whose run ended with `Which port?` LF `NEED INPUT`, its screen showing `? Needs input`
- When: `8` is typed in the agent tab
- Then: the agent tab's bar is open in reply mode with `8` in its field
- When: `080` is typed and Return pressed, the agent replying `Using 8080.` LF `GOAL MET`
- Then: the new request is an agent request (no router request in between) whose messages are the previous ones followed by the user message `8080`, and the screen shows `Using 8080.` then `✓ Goal met`

## APP-ASSIST-008 — Requests carry the real machine, user, directory and recent output

Implement: `AssistantController` building `EnvironmentContext.snapshot(...)` from the session (directory, foreground program, size, recent lines) and the system.
Uses: [Context](../assistant/context.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-008 requests carry the real machine user directory and recent output"
- Given: a window of the assistant fixture where `echo marker-4242` was run
- When: ⌘ is held and released, `what is here` typed and Return pressed
- Then: the router request's system message contains `cwd: ` followed by T resolved, `user: ` followed by the login name, `os: macOS ` followed by the system version, `terminal: 80x24, running bash`, and inside `<recent_terminal_output>` the line `marker-4242`; its user message is `what is here`

## APP-ASSIST-009 — No secret reaches the network; placeholders are restored when a command runs

Implement: `AssistantController` and `AgentTab` building a `SecretRedactor` from the app, login shell and session environments, redacting every outgoing text and restoring placeholders in commands.
Uses: [Redaction](../assistant/redaction.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-009 no secret reaches the network and placeholders are restored when a command runs"
- Given: an assistant fixture whose shell and login environment define `ATERM_CANARY_TOKEN=cnry-7f3a9d2e41`, where `echo $ATERM_CANARY_TOKEN` was run; the router reply is an agent task; the agent replies the call `bash` `printf %s "<ATERM_CANARY_TOKEN_1:15chars>" > canary.txt && cat canary.txt`, then `done` LF `GOAL MET`
- When: ⌘ is held and released, `use the canary` typed and Return pressed
- Then: no request body contains `cnry-7f3a9d2e41`; the router request contains `<ATERM_CANARY_TOKEN_1:15chars>`; `T/canary.txt` holds `cnry-7f3a9d2e41`; the last request's tool message contains `<ATERM_CANARY_TOKEN_1:15chars>`

## APP-ASSIST-010 — A missing or rejected key is asked for in the bar

Implement: `AssistantBar`'s key mode (secure field) and `AssistantController` saving the key to the key store, reached when no key is found and after a 401. Settings (⌘,) also changes the key: see [Settings](settings.md).
Uses: [Keys](../assistant/keys.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-010 a missing or rejected key is asked for in the bar"
- Given: a window of the assistant fixture with an empty key store
- When: ⌘ is held and released
- Then: the bar shows the secure key field, first responder
- When: `test-key-2` is typed and Return pressed
- Then: the store holds `test-key-2` and the bar shows the request field
- When: `hi` is typed and Return pressed
- Then: the request has `Authorization: Bearer test-key-2`
- Given: the same window, the fake answering 401 `{"error":{"code":401,"message":"User not found."}}` to the next request
- When: the bar is opened, `hi` typed and Return pressed
- Then: the bar shows the key field with the message `Invalid API key: User not found.`

## APP-ASSIST-011 — The bar is centered in the terminal

Implement: `AssistantBar.layoutInSuperview()`, called by `AssistantController` when the bar's mode or the terminal view's size changes.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-011 the bar is centered in the terminal"
- Given: a window of the assistant fixture showing the prompt, the router reply two suggested commands
- When: ⌘ is held for 0.5 s
- Then: the bar shows the hint, and its center is within 0.5 point of the terminal view's center
- When: ⌘ is released
- Then: the bar shows the request field, taller than the hint, and its center is within 0.5 point of the view's center
- When: `say it` is typed and Return pressed
- Then: the bar lists the two suggestions, taller than the request field alone, and its center is within 0.5 point of the view's center
- When: the window's content size is set to the tab strip plus a 120 × 40 grid
- Then: the bar's center is within 0.5 point of the view's new center

## APP-ASSIST-012 — The agent tab shows when a request is retried

Implement: `AgentTab` handling `Agent.Event.retrying` (from the client's `ChatDelta.retrying`, see [client](../assistant/client.md) ASSIST-CLIENT-004) by adding the retry to its thinking line, `TranscriptFormatter.thinking(seconds:retry:)`: `… thinking (N s) · ↻ <reason>, retry <attempt>/<of> in <seconds left> s`, then `· ↻ <reason>, retry <attempt>/<of>` once the wait is over.
Uses: [Agent](../assistant/agent.md)

Test: e2e · `Tests/ATermE2ETests/AssistantTests.swift` · "APP-ASSIST-012 the agent tab shows when a request is retried"
- Given: a window of the assistant fixture whose retry delay is 1 s (one retry); the router reply is an agent task; the fake answers the first agent request with 503 `{"error":{"code":503,"message":"Overloaded"}}`, then the agent reply `Done.` LF `GOAL MET`
- When: ⌘ is held and released, `go` typed and Return pressed
- Then: at one moment the agent tab's screen shows `↻ HTTP 503, retry 2/2 in 1 s`; then it shows `Done.` and `✓ Goal met`; three requests were sent (router, agent, agent)
