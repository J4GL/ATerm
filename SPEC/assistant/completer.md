# Assistant — completing the command line

`CommandCompleter` in `Sources/ATermCore/Assistant/CommandCompleter.swift`
asks the model how the command line being typed at the zsh prompt ends, for
the suggestions of ATerm's zsh integration (see
[Suggestions](../app/suggestions.md)). Tests use a scripted `ChatClient` that
records requests.

## ASSIST-COMPLETE-001 — The model completes the line being typed, or nothing is suggested

Implement: `CommandCompleter.complete(line:environment:)`, called by `AssistantController.requestCompletion(of:)` after a pause in typing, with the redacted line and environment block.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/CommandCompleterTests.swift` · "ASSIST-COMPLETE-001 the model completes the line being typed or nothing is suggested"
- Given: a completer for the model `m/x` whose client answers the reply below, and the environment block `ENV`
- When: it completes `git pu`
- Then: the only request uses the model `m/x`, `temperature` 0, the contract's `completion` JSON schema as `response_format`, no tools, no session id, no reasoning level (a completer given the level `low` sends `low`), and the messages system (the completer instructions, an empty line, `ENV`) and user `git pu`; the completion is:

| Reply | Completion |
|---|---|
| `{"command":"git push origin main"}` | `git push origin main` |
| the same object wrapped in `` ```json `` … `` ``` `` | `git push origin main` |
| `{"command":"git pull --rebase "}` LF | `git pull --rebase` (trailing spaces and line breaks dropped) |
| `{"command":"git pu"}` | none (nothing longer) |
| `{"command":"push origin main"}` | none (does not start with the line) |
| `{"command":"git push"}` with a line break, then `rm -rf x` inside the string | none (a line break or a control character could run part of it) |
| `{"command":"git push "}` with 500 × `x` appended inside the string | none (longer than 500 bytes) |
| `I would run git push` | none |

- Given: a completer whose client fails with `rateLimited("slow down")`
- When: it completes `git pu`
- Then: it throws `rateLimited("slow down")` after one request
