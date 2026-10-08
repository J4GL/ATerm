# App — suggestions at the zsh prompt

When the shell of a pane is zsh, `TerminalSession` starts it with ATerm's
[zsh integration](../pty/shell-integration.md) unless
`AppConfiguration.autosuggestions` is off (`Autosuggestions` false in the user
defaults, read by `AppConfiguration.standard(defaults:)`). While a line is
typed, the most recent history entry starting with it, else the model's
completion, is shown after it in grey (the indexed color 8, (95, 98, 112)).
→, End, ⌃E and ⌃F at the end of the line accept it, ⌥→ accepts it up to the
next word, Return and ⌃C leave no grey text behind.

The model's completion: zsh asks for one when its history has nothing for the
line (OSC 6973). `TerminalSession` passes on the requests carrying its
integration's nonce, `TerminalPane` gives them to its `AssistantController`. A
new request, or an empty line, cancels the pending one. When
`AssistantConfiguration.completionDelay` (1 s) has passed without another
request, the request is sent if the model's completions are on (Settings,
`AssistantServices.commandCompletions`), the line has at least 3 characters
besides spaces, a key is known and no completion request failed in the last
60 s: the redacted line and environment block go to `CommandCompleter`
([Completer](../assistant/completer.md)) through a client that never retries;
the completion, its secrets restored, goes back to the shell
(`TerminalSession.sendCompletion(_:)`) when it still starts with the line.

Every spec uses the **zsh fixture**: the e2e fixture of the
[App contract](contract.md), running `/bin/zsh` as a login shell (argv
`-zsh`) with `ZDOTDIR` set to a fresh temporary directory Z whose `.zshrc` sets
`PROMPT='$ '` and whose `.zsh_history` holds the history lines a spec gives,
oldest first; the integration's directory is another fresh temporary
directory; the key store is in memory and empty, without environment
fallback. Specs about the model's completion use the assistant fixture of
[Assistant](assistant.md) with this shell; its fake endpoint answers the
completion requests with the replies the test queues.

## APP-SUGGEST-001 — Typing the start of a command from the history shows its end in grey

Implement: `TerminalSession.init` installing `ShellIntegration` for zsh when `AppConfiguration.autosuggestions` is on; the history suggestion of `aterm.zsh`.
Uses: [zsh integration](../pty/shell-integration.md)

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-001 typing the start of a command from the history shows its end in grey"
- Given: a window of the zsh fixture with the history `git status --short` then `git stash list`, showing the prompt
- When: `git st` is typed
- Then: the cursor row reads `$ git stash list` and the cursor is at column 8; the cells of `git st` have the default foreground and those of `ash list` the indexed color 8; the rendered cell at column 8 has pixels matching (95, 98, 112) within 12 and none matching the foreground (217, 219, 227) within 12
- When: `at` is typed
- Then: the cursor row reads `$ git status --short`, the cursor is at column 10 and the cells of `us --short` have the indexed color 8
- When: `x` is typed
- Then: the cursor row reads `$ git statx` and the cursor is at column 11

- Given: a window of the zsh fixture with an empty history, where `echo first-run` was run
- When: `echo f` is typed
- Then: the cursor row reads `$ echo first-run` and the cells of `irst-run` have the indexed color 8

## APP-SUGGEST-002 — →, End and ⌃E accept the suggestion at the end of the line, ⌥→ one word

Implement: the accepting widgets of `aterm.zsh` (`forward-char`, `end-of-line`, `forward-word`, End bound when unbound), reached through `TerminalView.keyDown(with:)` and `KeyEncoder`.
Uses: [zsh integration](../pty/shell-integration.md), [Keys](../input/keys.md)

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-002 right arrow end and control-e accept the suggestion at the end of the line option-right arrow one word"
- Given: a window of the zsh fixture with the history `echo alpha beta gamma`, where `echo a` was typed: the cursor row reads `$ echo alpha beta gamma`, the cursor is at column 8
- When: ⌥→ is pressed
- Then: the cursor is at column 13, the cells of `echo alpha ` have the default foreground and those of `beta gamma` the indexed color 8
- When: → is pressed
- Then: the cursor row reads `$ echo alpha beta gamma`, every cell in the default foreground, and the cursor is at column 23
- When: Return is pressed
- Then: the next row reads `alpha beta gamma`

- Given: the same window where `echo a` was typed, for each key: End, ⌃E
- When: the key is pressed
- Then: the cursor row reads `$ echo alpha beta gamma`, every cell in the default foreground, and the cursor is at column 23

- Given: the same window where `echo a` was typed
- When: ← then → are pressed
- Then: the cursor is at column 8 and the cells of `lpha beta gamma` still have the indexed color 8

## APP-SUGGEST-003 — Return and ⌃C leave no grey text behind

Implement: the `line-finish` hook and the `TRAPINT` function of `aterm.zsh`.
Uses: [zsh integration](../pty/shell-integration.md)

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-003 return and control-c leave no grey text behind"
- Given: a window of the zsh fixture with the history `echo hello-ghost`, where `ech` was typed: the cursor row R reads `$ echo hello-ghost`
- When: Return is pressed
- Then: row R reads `$ ech` and row R + 1 reads `zsh: command not found: ech`

- Given: the same window where `ech` was typed
- When: ⌃C is pressed
- Then: row R reads `$ ech` and the prompt `$` is on row R + 1

## APP-SUGGEST-004 — With Autosuggestions off, zsh starts without the integration

Implement: `AppConfiguration.autosuggestions`, read from `Autosuggestions` by `AppConfiguration.standard(defaults:)` (true when absent), checked by `TerminalSession.init`.

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-004 with autosuggestions off zsh starts without the integration"
- Given: user defaults without `Autosuggestions`
- When: `AppConfiguration.standard(defaults:)` reads them
- Then: `autosuggestions` is on

- Given: user defaults holding `Autosuggestions` false, and a window of the zsh fixture whose `autosuggestions` is read from them by `AppConfiguration.standard(defaults:)`, with the history `git status`
- When: `print -r -- $ZDOTDIR` is run
- Then: the next row reads Z
- When: `git s` is typed
- Then: after 300 ms the cursor row reads `$ git s`

## APP-SUGGEST-005 — When the history has nothing, the model's completion is shown after a pause

Implement: `TerminalSession` passing on the requests carrying its nonce, `TerminalPane` wiring them to `AssistantController.requestCompletion(of:)` (delay, context, `CommandCompleter`, secrets restored), `TerminalSession.sendCompletion(_:)`; `AssistantServices.makeClient(retrying:)`.
Uses: [Completer](../assistant/completer.md), [Redaction](../assistant/redaction.md)

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-005 when the history has nothing the model's completion is shown after a pause"
- Given: a window of the assistant fixture running the zsh fixture's shell with the history `echo unrelated`, showing the prompt in T, the fake answering the completion `{"command":"ffmpeg -i in.mov out.mp4"}`
- When: `ffmpeg -i` is typed
- Then: 0.5 s later no request was sent
- When: 1.5 s more pass
- Then: exactly one request was sent, with the default model, `temperature` 0, the contract's `completion` schema, the system message (the completer instructions, an empty line, then the environment block, which holds `cwd: T`) and the user message `ffmpeg -i`; the cursor row reads `$ ffmpeg -i in.mov out.mp4`, the cursor is at column 11 and the cells of ` in.mov out.mp4` have the indexed color 8
- When: → is pressed
- Then: the cursor row reads `$ ffmpeg -i in.mov out.mp4`, every cell in the default foreground, and the cursor is at column 26

- Given: the same window, the fake answering `{"command":"API_TOKEN=<API_TOKEN_1:17chars> ./deploy --prod"}`
- When: `API_TOKEN=s3cr3t-value-9876 ./deploy` is typed and 2 s pass
- Then: one request was sent, whose user message is `API_TOKEN=<API_TOKEN_1:17chars> ./deploy`, and no message of which holds `s3cr3t-value-9876`; the cursor row reads `$ API_TOKEN=s3cr3t-value-9876 ./deploy --prod` and the cells of ` --prod` have the indexed color 8

## APP-SUGGEST-006 — No completion is requested when it cannot help or is not allowed

Implement: the conditions of `AssistantController.requestCompletion(of:)` (`AssistantServices.commandCompletions`, the key, the 60 s pause after a failure) and the history-first rule of `aterm.zsh`.
Uses: [Completer](../assistant/completer.md)

Test: e2e · `Tests/ATermE2ETests/SuggestionTests.swift` · "APP-SUGGEST-006 no completion is requested when it cannot help or is not allowed"
- Given: a window of the assistant fixture running the zsh fixture's shell, showing the prompt, for each case below
- When / Then:

| Case | Requests 2 s later |
|---|---|
| the history holds `ffmpeg -i a.mov`; `ffmpeg -i` is typed | none, and the cells of ` a.mov` have the indexed color 8 |
| `ffmpeg -i` is typed, Return pressed 0.2 s later | none |
| `ls` is typed (fewer than 3 characters) | none |
| the model's completions are off (`AssistantConfiguration.commandCompletions` false); `ffmpeg -i` is typed | none |
| the key store is empty; `ffmpeg -i` is typed | none |
| the fake answers HTTP 429 to the first request, made for `ffmpeg -i`; then ⌃U and `ffprobe -v` are typed | the first one only |
