# ATerm specifications

ATerm is a native macOS terminal emulator written from scratch in Swift
(AppKit + Core Text), with no third-party dependency. Each spec below describes
one observable behavior and names the automated test that proves it.

## Modules

| Module | Code | Specs |
|---|---|---|
| Parser — byte stream to actions | `Sources/ATermCore/Parser/` | [contract](parser/contract.md), [parser](parser/parser.md) |
| Screen — terminal model | `Sources/ATermCore/Screen/` | [contract](screen/contract.md), [printing](screen/printing.md), [cursor](screen/cursor.md), [erase](screen/erase.md), [scrolling](screen/scrolling.md), [SGR](screen/sgr.md), [modes](screen/modes.md), [reports](screen/reports.md), [resize](screen/resize.md) |
| Input — keyboard, mouse, paste and focus encoding, ⌘ hold | `Sources/ATermCore/Input/` | [keys](input/keys.md), [mouse](input/mouse.md), [paste and focus](input/paste-focus.md), [⌘ hold](input/hold.md) |
| Selection — text selection and extraction | `Sources/ATermCore/Selection/` | [selection](selection/selection.md) |
| PTY — child process in a pseudo-terminal, zsh integration | `Sources/ATermCore/PTY/`, `Sources/CPTY/` | [pty](pty/pty.md), [zsh integration](pty/shell-integration.md) |
| Assistant — LLM routing, agent loop, tools, secrets | `Sources/ATermCore/Assistant/`, `Sources/CPTY/` | [contract](assistant/contract.md), [client](assistant/client.md), [router](assistant/router.md), [context](assistant/context.md), [redaction](assistant/redaction.md), [risky commands](assistant/safety.md), [bash tool](assistant/bash-tool.md), [search tool](assistant/search-tool.md), [agent](assistant/agent.md), [keys](assistant/keys.md), [model list](assistant/models.md), [completer](assistant/completer.md) |
| App — windows, tabs, split panes, rendering, input, assistant (AppKit) | `Sources/ATermApp/`, `Sources/ATerm/` | [contract](app/contract.md), [windows](app/window.md), [rendering](app/rendering.md), [input](app/input.md), [scrollback and selection](app/scroll-selection.md), [tabs and fonts](app/tabs-fonts.md), [tab strip](app/tab-strip.md), [split panes](app/splits.md), [edit](app/edit.md), [assistant](app/assistant.md), [settings](app/settings.md), [suggestions](app/suggestions.md), [bundle](app/bundle.md) |

## Running the tests

All tests use Swift Testing and run through `scripts/test.sh`, a thin wrapper
around `swift test` (it works around a Command Line Tools bug that sometimes
drops the Swift Testing macro plugin).

```bash
scripts/test.sh                                  # every Swift test (unit and e2e)
scripts/test.sh --filter ATermCoreTests       # unit tests only
scripts/test.sh --filter ATermE2ETests        # e2e tests only
scripts/test.sh --filter ATermModalTests      # APP-SETTINGS-007 (a real modal loop, in its own process)
scripts/test.sh --filter PARSER_001              # one spec
scripts/test-bundle.sh                           # APP-BUNDLE-001 and 002 (builds the release app)
scripts/test-release.sh                          # APP-BUNDLE-003 (signs, notarizes and staples: needs the credentials)
```

`make live-check` runs `Tests/ATermLiveTests` against the real OpenRouter
API to check the prompts with the configured model. It is not a spec test:
it only runs when `OPENROUTER_API_KEY` is set, and it spends free-tier
requests.

E2E tests drive the real app classes in-process (see the
[App contract](app/contract.md)); they open windows off screen and run real
shells, so they need a logged-in macOS session.

A test function is named after its spec ID with `-` replaced by `_`
(`PARSER-001` → `PARSER_001`); its display name starts with the spec ID.
`--filter` matches function names, not display names.
