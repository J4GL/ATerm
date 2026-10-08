# Changelog

All notable changes to ATerm. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-09

First release: a native macOS terminal written from scratch in Swift (AppKit
and Core Text, no third-party dependency), signed with a Developer ID and
notarized by Apple, universal (Apple silicon and Intel). Requires macOS 14
or later.

### Added

- **Terminal engine**: xterm-compatible (`TERM=xterm-256color`) VT500 parser
  with UTF-8 decoding; 16, 256 and 24-bit colors; bold, dim, italic,
  underline styles (single, double, curly, dotted, dashed, colored),
  strikethrough, overline and inverse; scroll regions, insert mode, tab
  stops, DEC line drawing, alternate screen, bracketed paste, focus events,
  mouse reporting (X10, normal, button, any; legacy and SGR), synchronized
  output, device and cursor reports, OSC titles, working directory (OSC 7)
  and color queries.
- **Unicode**: wide CJK characters, combining marks, emoji with ZWJ
  sequences, skin tones and flags.
- **Reflow**: soft-wrapped lines re-wrap through the scrollback when the
  window is resized.
- **Rendering**: Core Text glyph runs with font fallback, box-drawing and
  block characters drawn geometrically, block, underline and bar cursors.
- **Tabs**: Chrome-style tabs in the title bar (click, ×, middle click, +,
  drag to reorder), ⌘T in the current directory, ⌘1…⌘9, ⌘{ ⌘}.
- **Split panes**: ⌘D splits the active pane side by side, ⇧⌘D stacks; ⌥⌘
  arrows move between panes, dividers drag, ⇧⌘↩ zooms the active pane, ⌃⌘=
  equalizes; a thin dark blue frame marks the active pane; ⌘W closes a pane.
- **macOS integration**: login shell, dead keys and input methods, Option
  composing characters, Option+←/→ word moves, selection by drag, double and
  triple click, copy and paste, file drop as escaped paths, ⌘-click on
  links, confirmation before closing or quitting with a running program.
  Every command is listed in the menus with its shortcut.
- **zsh suggestions**: the end of the latest matching history command shown
  in grey, else the model's completion after a pause; →, End or ⌃E accept
  it, ⌥→ one word. Pasted text loses its highlight when the terminal is
  clicked.
- **Assistant** (OpenRouter): hold ⌘ and ask in plain words; a one-line job
  becomes suggested commands for the active pane (risky ones marked), a task
  opens an agent tab with two tools (`bash`, `search`) that works until its
  goal is checked. Secrets are masked before anything leaves the Mac; the
  API key is kept in the Keychain. Settings (⌘,) for the endpoint, key and
  model.
