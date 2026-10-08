# PTY — zsh integration

`ShellIntegration` in `Sources/ATermCore/PTY/ShellIntegration.swift` adds
fish-style suggestions to an interactive zsh started by ATerm. zsh keeps
editing the line; the integration only tells it what to show after it.

`ShellIntegration.install(for:environment:directory:)` does nothing for
another shell. For zsh it writes `D/zsh/.zshenv` and `D/zsh/aterm.zsh` into
the directory D (private to its owner), makes a FIFO `D/<name>.fifo` and a
random nonce, and points the environment at them: `ZDOTDIR=D/zsh`,
`ATERM_ZSH_ZDOTDIR` = the previous `ZDOTDIR` (only when there was one),
`ATERM_SUGGEST_FIFO` and `ATERM_SUGGEST_NONCE`.

- `.zshenv` restores `ZDOTDIR` (or unsets it), sources the user's `.zshenv`,
  then, in an interactive shell, `aterm.zsh`; zsh goes on with the user's
  `.zprofile`, `.zshrc` and `.zlogin` as usual. The `ATERM_*` variables
  are removed, so commands never see them.
- `aterm.zsh` sets up at the first prompt, after the user's `.zshrc`,
  unless zsh-autosuggestions is loaded (`_zsh_autosuggest_start` is defined)
  or zsh is older than 5.9. While a line is typed, the most recent history
  entry starting with it, else the model's completion, is shown after it
  (`POSTDISPLAY`) in the indexed color 8. `forward-char`, `end-of-line`,
  `vi-forward-char` and `vi-end-of-line` at the end of the line accept it;
  `forward-word` and `emacs-forward-word` accept it up to where they move; End
  and Home as ATerm sends them (`⎋[F`, `⎋[H`) are bound to `end-of-line`
  and `beginning-of-line` when nothing uses them. The suggestion is cleared
  when the line is accepted or interrupted (⌃C), and never shown after a
  history or search widget.
- Model completions: when the history has no entry for a non-empty line
  without control characters, zsh asks for one with
  `OSC 6973 ; <nonce> ; <line>` ([OSC 6973](../screen/reports.md)) each time
  the line it asks for changes; an empty line withdraws the request (the line
  got a suggestion, was emptied, accepted or interrupted). ATerm answers by
  writing the completed line and LF into the FIFO (`ShellIntegration.send(_:)`,
  at most 511 bytes, never blocking); zsh shows it while it extends the line.
- Clicks: zsh shows pasted (or yanked) text in reverse video until the next
  key. A completion is never empty, so an empty line in the FIFO
  (`ShellIntegration.sendClick()`) tells zsh the user clicked in the
  terminal: if the line shows that highlight, zsh redraws it without; if not,
  it does nothing.

## PTY-SHELL-001 — zsh runs the user's own startup files, then ATerm's additions

Implement: `ShellIntegration.install(for:environment:directory:)`, `.zshenv` and the setup of `aterm.zsh`, called by `TerminalSession.init` for the shell of a pane when `AppConfiguration.autosuggestions` is on.

Test: unit · `Tests/ATermCoreTests/ShellIntegrationTests.swift` · "PTY-SHELL-001 zsh runs the user's own startup files then ATerm's additions"
- Given: temporary directories H, Z and D; `Z/.zshenv` runs `print -r -- "zshenv ${ZDOTDIR-unset}"`; `Z/.zshrc` sets `PROMPT='$ '` and runs `print -r -- zshrc`; the environment `HOME=H`, `ZDOTDIR=Z`
- When: the integration is installed for `/bin/zsh` into D
- Then: it returns an integration whose nonce is 32 hexadecimal digits and whose FIFO, in D, is a FIFO; the environment has `ZDOTDIR=D/zsh`, `ATERM_ZSH_ZDOTDIR=Z`, `ATERM_SUGGEST_FIFO` = the FIFO's path and `ATERM_SUGGEST_NONCE` = the nonce; `D/zsh` has the permissions 0700 and holds `.zshenv` and `aterm.zsh`
- When: `/bin/zsh -l -i` starts with that environment in an 80×24 pseudo-terminal, and once `$ ` is shown `print -r -- "${ZDOTDIR-unset}|${ATERM_ZSH_ZDOTDIR-none}|${ATERM_SUGGEST_FIFO-none}|${ATERM_SUGGEST_NONCE-none}|$widgets[forward-char]"` and Return are written
- Then: the output shows `zshenv Z`, then `zshrc`, then `Z|none|none|none|user:_aterm_accept`

- Given: the same two files in H instead of Z, and no `ZDOTDIR` in the environment
- When: the integration is installed for `/bin/zsh` into D and the shell started and asked as above
- Then: the environment has no `ATERM_ZSH_ZDOTDIR`; the output shows `zshenv unset`, then `zshrc`, then `unset|none|none|none|user:_aterm_accept`

- Given: the first case's files, `Z/.zshrc` also defining the function `_zsh_autosuggest_start` (zsh-autosuggestions is loaded)
- When: the integration is installed for `/bin/zsh` into D and the shell started and asked as above
- Then: the output shows `Z|none|none|none|builtin` (nothing is wrapped)

- Given: the environment `HOME=H` only
- When: the integration is installed for `/bin/bash` into D
- Then: it returns nil, the environment is unchanged and D does not exist

## PTY-SHELL-002 — zsh asks for a completion when its history has none and shows the one it is sent

Implement: the model completion part of `aterm.zsh` (the OSC 6973 request, the FIFO read by `zle -F`), `ShellIntegration.send(_:)` and `ShellIntegration.remove()`, used by `TerminalSession`.
Uses: [OSC 6973](../screen/reports.md)

Test: unit · `Tests/ATermCoreTests/ShellIntegrationTests.swift` · "PTY-SHELL-002 zsh asks for a completion when its history has none and shows the one it is sent"
- Given: zsh started as in the first case of PTY-SHELL-001 (an empty history), its output fed to an 80×24 `Terminal` whose delegate records the completion requests, showing `$ ` on row R
- When: `f`, `f` and `m` are written 100 ms apart
- Then: the last request carries the integration's nonce and the line `ffm`; row R reads `$ ffm`
- When: `ffmpeg -i in.mov` is sent
- Then: sending succeeded; row R reads `$ ffmpeg -i in.mov`, the cursor is at (R, 5), the cells of `ffm` have the default foreground and those of `peg -i in.mov` the indexed color 8; the last request carries an empty line
- When: `x` is written
- Then: row R reads `$ ffmx` (the completion no longer extends the line) and the last request carries the line `ffmx`
- When: DEL, then `⎋[C` (→) are written
- Then: row R reads `$ ffmpeg -i in.mov`, every cell in the default foreground, and the cursor is at (R, 18)
- When: ⌃U, `exit` and CR are written and the shell has exited
- Then: sending `x` fails; after `remove()` the FIFO no longer exists

## PTY-SHELL-003 — A click sent to zsh removes the highlight of pasted text

Implement: `ShellIntegration.sendClick()` and the handling of an empty line by `aterm.zsh`, used by `TerminalSession`.

Test: unit · `Tests/ATermCoreTests/ShellIntegrationTests.swift` · "PTY-SHELL-003 a click sent to zsh removes the highlight of pasted text"
- Given: zsh started as in the first case of PTY-SHELL-001, its output fed to an 80×24 `Terminal`, showing `$ ` on row R
- When: `⎋[200~/tmp/a\ b.txt ⎋[201~` (a bracketed paste) is written
- Then: row R reads `$ /tmp/a\ b.txt` and the cells of columns 2 to 15 are inverse
- When: `sendClick()` is called
- Then: it succeeded; row R reads `$ /tmp/a\ b.txt`, no cell of columns 2 to 15 is inverse, and the cursor is at (R, 16)
- When: `sendClick()` is called again
- Then: it succeeded and the shell writes nothing within 300 ms
