# ATerm

A native macOS terminal emulator written from scratch in Swift — AppKit and
Core Text for the UI, a hand-written VT/xterm engine, a tiny C shim for
`forkpty`. No third-party dependency.

## Features

- **xterm-compatible engine** (`TERM=xterm-256color`): VT500 parser with UTF-8
  decoding, 16/256/24-bit colors, bold/dim/italic/underline styles (single,
  double, curly, dotted, dashed, colored)/strikethrough/overline/inverse,
  scroll regions, insert mode, tab stops, DEC line drawing, alternate screen,
  bracketed paste, focus events, mouse reporting (X10, normal, button, any;
  legacy and SGR encodings), synchronized output (mode 2026), device and
  cursor reports, OSC titles, working directory (OSC 7) and color queries.
- **Unicode**: wide CJK characters, combining marks, emoji with ZWJ sequences,
  skin tones and flags.
- **Reflow**: soft-wrapped lines re-wrap when the window is resized, through
  the scrollback.
- **Rendering**: Core Text glyph runs with font fallback, emoji scaled to two
  cells, box-drawing and block characters drawn geometrically so borders join
  without gaps, pixel-aligned decorations, block/underline/bar cursors.
- **macOS integration**: Chrome-style tabs in the title bar (click, ×, middle click, +, drag to reorder), login shell (`-zsh`), UTF-8
  locale, dead keys and input methods (`NSTextInputClient`), Option composing
  characters on French layouts (`|`, `{`, `~`…), Option+←/→ word moves,
  selection by drag / double-click (word) / triple-click (line), copy/paste,
  file drop inserts escaped paths, ⌘-click opens links, confirmation before
  closing a pane, tab or window with a running program.
- **Split panes**: ⌘D splits the active pane side by side, ⇧⌘D stacks; the new
  pane runs a shell in the current directory. Click a pane or press ⌥⌘ and an
  arrow to move between panes (a thin dark blue frame marks the active one), drag
  a divider to resize, ⇧⌘↩ zooms the active pane and ⌃⌘= equalizes them.
- **Fast**: ~90 MB/s of plain text, ~50 MB/s of heavily colored text, ~40 MB/s
  of CJK text through the parser and model (release build, Apple silicon).
- **Suggestions** (zsh): as you type, the end of the latest matching command
  from your history is shown in grey after the cursor, fish style; when the
  history has nothing, the model completes the line after a 1 s pause. →,
  End or ⌃E accept it, ⌥→ one word.
- **Assistant** (OpenRouter): hold ⌘ and ask in plain words. A one-line job
  becomes suggested commands for the active pane; a task (“the blog's home page
  returns a 500, fix it”) gets a verifiable goal and runs in an agent tab until
  that goal is checked. Secrets are masked before anything leaves the Mac.

## Requirements

macOS 14 or later, Swift 6 (Command Line Tools are enough; Xcode is not needed).

## Build and run

```bash
make app        # build/ATerm.app (release, ad hoc signed)
```

```bash
make run        # build and open the app
```

```bash
swift run ATerm   # debug build, without the app bundle
```

## Release

```bash
make release    # dist/ATerm-<version>.zip: universal, Developer ID signed, notarized, stapled
```

It needs a *Developer ID Application* identity in the keychain and notarytool
credentials stored once as a keychain profile (`NOTARY_PROFILE`, see
`scripts/release.sh`). The release notes are the version's section of
[CHANGELOG.md](CHANGELOG.md), written to `dist/RELEASE_NOTES-<version>.md`.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌘N / ⌘T | New window / new tab (in the current directory); the Dock icon's menu also has New Window |
| ⌘, | Settings: endpoint, API key (with a test), model |
| ⌘D / ⇧⌘D | Split the active pane: new pane on the right / below, in the current directory |
| ⌘W / ⌘⇧W | Close the active pane (its tab with its last pane) / close the window (asks first when a program is running) |
| ⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓ | Select the pane on the left / right / above / below |
| ⇧⌘↩ | Zoom the active pane; again to restore the layout |
| ⌃⌘= | Equalize the panes |
| ⌘⇧[ / ⌘⇧], ⌘1…⌘9 | Previous / next tab, tab 1…8, last tab |
| ⌘C / ⌘V / ⌘A | Copy / paste / select all |
| ⌘K | Clear scrollback, keeping the current line |
| ⌘+ / ⌘- / ⌘0 | Bigger / smaller / default font size |
| ⌃⌘F | Full screen |
| Page Up / Page Down | Scroll the scrollback (Shift+Page keys go to the program) |
| ⌥← / ⌥→ | Move by word (sends `ESC b` / `ESC f`); ⌥→ takes a grey suggestion up to its next word |
| → / End / ⌃E at the end of the line | Take the grey suggestion (zsh) |
| ⌘-click | Open the link under the pointer |
| Shift+click/drag | Select even when the program captures the mouse |
| Hold ⌘ alone, then release | Open the assistant bar |
| ⌘. or ⌃C in an agent tab | Stop the agent |

View ▸ *Use Option as Meta Key* makes Option send `ESC` + key instead of
composing characters.

## Suggestions

In zsh (the macOS default shell), ATerm shows after the cursor, in grey,
how the line being typed probably ends:

- the most recent command of your history that starts with the line (the
  zsh history: previous sessions and this one);
- else, after 1 s without typing, the model's completion (see the Assistant
  below): the line and the tab's context, secrets masked, are sent once per
  pause, only for lines of 3 characters or more. Each completion is one
  request of your quota (free models: 50 a day without credits); Settings ▸
  *Complete commands with the model* turns it off, and a failed request
  pauses completions for 60 s.

→, End or ⌃E at the end of the line take the suggestion, ⌥→ takes it up to
its next word; Return runs only what you typed, and Return or ⌃C leave no
grey text behind. zsh keeps editing the line: ATerm starts it with a
`ZDOTDIR` that runs your own startup files first, then loads its additions
(nothing is changed when zsh-autosuggestions is already loaded, or with zsh
older than 5.9).

## Assistant

Hold ⌘ alone for a moment and release it: the assistant bar opens in the center
of the active pane (also Shell ▸ Ask…). Type what you want and press Return.

- **A command**: the model proposes the best command and alternatives (⚠
  marks risky ones). ↑/↓ choose, Return runs it in this tab, ⌥Return only
  inserts it, Esc closes. In a busy tab the command is typed without Return;
  over a full-screen program (vim, less) it is copied instead.
- **A task**: the model states a verifiable goal and an **agent tab** opens.
  The agent works with two tools only — `bash` (a fresh non-interactive bash
  per call, `cd` kept, 120 s timeout) and `search` (a ripgrep-like search that
  honours `.gitignore`) — and ends with `✓ Goal met`, `✗ Goal not met` or
  `? Needs input`. The tab is read-only while the agent works: ⌃C or ⌘. stops
  it, and a risky command (`rm -r`, `sudo`, `git push`, `reset --hard`,
  `DROP TABLE`, a secret placeholder sent with `curl`…) waits for Return (run) or Esc (skip). Afterwards, type in the
  tab to reply; ⌘T opens a shell in the agent's directory.

The model is told the macOS version, the user, the shell, the directory and
its entries, the tools on the PATH, the last 50 lines of the tab and the
project's `AGENTS.md` (or `CLAUDE.md`). Secrets are replaced by placeholders
such as `<GITHUB_TOKEN_1:40chars>` before any request — secret-named
variables, `.env` files, `~/.aws/credentials`, `~/.npmrc` and other credential
files, known token formats, `password=…`-style values — and put back only
when a command runs on your Mac. Masking is best effort: free models may log
what they receive.

**Settings** (ATerm ▸ Settings…, ⌘,, a modal window): the endpoint (the
base URL of any OpenAI-compatible API, without `/chat/completions`:
OpenRouter's `https://openrouter.ai/api/v1` by default, or e.g. opencode's
`https://opencode.ai/zen/go/v1`), the API key and the model. **Test** checks
the key by fetching the models it can use (`/models/user`, else `/models`,
which some endpoints answer without checking the key); the model field then
completes from that list, each model with its price per million tokens
(input · cached input · output). **Reasoning** offers the levels the chosen
model accepts (`low` … `max`), sent with every request (`reasoning.effort` to
OpenRouter, `reasoning_effort` elsewhere); `Default` sends none.
**Suggestions** turns the model's completions at the zsh prompt on (the
default) or off (`AssistantSuggestions`). OpenRouter's
list gives prices and levels; for opencode they come from the
[models.dev](https://models.dev) catalog (the one opencode uses). An agent
conversation is kept on one provider by `session_id` (OpenRouter) or the
`x-opencode-session` header (opencode, which requires it on every request:
the router's requests carry the app's own session id).

**Requests log**: every request, response and retry (with its delay and
cause) goes to the macOS log; an agent tab also shows a retry on its
`… thinking` line (`↻ HTTP 429, retry 2/5 in 7 s`).

```bash
log stream --predicate 'subsystem == "gl.j4.ATerm"'
```

**API key**: the first time, the bar asks for your OpenRouter key; it is kept
in the login Keychain (Settings changes it). The app is ad hoc signed, so
macOS asks again for Keychain access after each rebuild.
`OPENROUTER_API_KEY` in the app's environment is used when no key is stored.

**Model**: `dots-studio/dots-3-note-preview:free` by default. Free models
allow 20 requests a minute and 50 a day without credits (1 000 with 10
credits); an agent task uses one request per step, so about two tasks a day.
Each agent conversation sends its own `session_id`, so OpenRouter keeps its
requests on one provider and reuses the prompt cache from the first step.
Settings saves the endpoint and the model in the user defaults
(`AssistantEndpoint`, `AssistantModel`).

## Configuration

Settings are read from the user defaults of `gl.j4.ATerm`:

```bash
defaults write gl.j4.ATerm FontName "JetBrains Mono"
```

```bash
defaults write gl.j4.ATerm FontSize -float 14
```

```bash
defaults write gl.j4.ATerm ScrollbackLines -int 50000
```

```bash
defaults write gl.j4.ATerm Autosuggestions -bool false   # start zsh without ATerm's suggestions
```

## Development

The project is spec-driven: every behavior is described in [`SPEC/`](SPEC/README.md)
and proven by the test named after its ID, written before the code
(red → green → refactor).

```bash
make test         # unit and e2e tests (Swift Testing)
```

```bash
make test-bundle  # APP-BUNDLE-001: builds and checks the .app
```

```bash
OPENROUTER_API_KEY=… make live-check   # the prompts against the real model (not a spec test)
# ATERM_ENDPOINT, ATERM_MODEL and ATERM_REASONING choose another endpoint, model and level;
# the run prints every request, response and retry with its time.
```

| Module | Role |
|---|---|
| `Sources/CPTY` | `forkpty` + `execve` in C, so no Swift code runs between fork and exec |
| `Sources/ATermCore` | parser, terminal model, reflow, selection, key/mouse/paste encoders, PTY process, zsh integration |
| `Sources/ATermCore/Assistant` | OpenRouter client, router, completer, agent loop, `bash` and `search` tools, context, secret masking |
| `Sources/ATermApp` | AppKit: app delegate and menus, window controller, tab strip, tabs, session, terminal view, assistant bar, agent tabs |
| `Sources/ATerm` | executable entry point |
| `Tests/ATermCoreTests` | unit tests |
| `Tests/ATermE2ETests` | e2e tests driving the real app in-process: real shells, synthesized events, rendered pixels |
| `Tests/ATermModalTests` | APP-SETTINGS-007, the real modal loop, alone in its own test process |
| `Tests/ATermLiveTests` | opt-in checks against the real OpenRouter API (`make live-check`) |

## License

CC0 1.0 Universal: see [LICENSE](LICENSE).
