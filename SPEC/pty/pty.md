# PTY — child process in a pseudo-terminal

`PTYProcess` in `Sources/ATermCore/PTY/PTYProcess.swift` runs a program
attached to a new pseudo-terminal. Forking and executing happen in C
(`aterm_pty_spawn` in `Sources/CPTY/`) so that no Swift code runs in the child
between `fork` and `exec`. The app's `TerminalSession` creates one per pane with
the command from `LoginShell` and the environment from `ShellEnvironment`, plus
[ATerm's zsh integration](shell-integration.md) for zsh.

Output chunks and the exit status are delivered on the callback queue given at
creation (the main queue in the app). The exit status is the program's exit
code, or 128 + the signal number when it was killed by a signal.

## PTY-001 — A program runs in a pseudo-terminal of the requested size

Implement: `PTYProcess.start()` and `aterm_pty_spawn`, called by `TerminalSession.start()`.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-001 a program runs in a pseudo-terminal of the requested size"
- Given: the command `/bin/stty size` and a size of 80 columns × 24 rows
- When: it is started and runs to completion
- Then: its output contains `24 80` and its exit status is 0

- Given: the command `/bin/sh -c 'test -t 0 && test -t 1 && echo tty'`
- When: it is started and runs to completion
- Then: its output contains `tty`

## PTY-002 — Written input reaches the program

Implement: `PTYProcess.write(_:)` (non-blocking, buffered), called by `TerminalSession.send(_:)`.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-002 written input reaches the program"
- Given: `/bin/cat` started in a pseudo-terminal
- When: `ping` LF is written
- Then: the output contains `ping` CR LF `ping` CR LF (the terminal echo, then cat's copy)
- When: Ctrl-D (0x04) is written
- Then: the exit status is 0

## PTY-003 — Resizing updates the size and signals the program

Implement: `PTYProcess.resize(_:)`, called by `TerminalSession.resize(cols:rows:)`.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-003 resizing updates the size and signals the program"
- Given: `/bin/sh -c 'trap "stty size" WINCH; echo ready; while :; do sleep 0.05; done'` started at 80 × 24
- When: `ready` has been output and the pseudo-terminal is resized to 100 columns × 40 rows
- Then: the output contains `40 100`

## PTY-004 — The exit status is reported once, after the remaining output

Implement: exit monitoring in `PTYProcess`, observed by `TerminalSession` to close or keep the pane.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-004 the exit status is reported once after the remaining output"
- Given: `/bin/sh -c 'echo bye; exit 3'`
- When: it runs to completion
- Then: `bye` was delivered before the exit handler ran, the exit handler ran exactly once, with status 3, and afterwards `isRunning` is false and `currentDirectory` is nil (a reaped pid may already belong to another process: it is never inspected or signalled again)

- Given: `/bin/sh -c 'kill -9 $$'`
- When: it runs to completion
- Then: the exit handler ran exactly once, with status 137

## PTY-005 — The program starts with default signals and no inherited descriptors

Implement: signal reset and descriptor closing in `aterm_pty_spawn`, called by `PTYProcess.start()`.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-005 the program starts with default signals and no inherited descriptors"
- Given: the parent ignores SIGPIPE and has a file open without close-on-exec on descriptor N
- When: `/bin/sh -c 'yes | head -n 1; test -e /dev/fd/N && echo leaked || echo clean'` runs to completion
- Then: the output contains `y` and `clean`, and does not contain `Broken pipe`

## PTY-006 — The environment identifies the terminal and uses UTF-8

Implement: `ShellEnvironment.make(base:localeIdentifier:)` in `Sources/ATermCore/PTY/ShellEnvironment.swift`, called by `TerminalSession.start()`.

Test: unit · `Tests/ATermCoreTests/ShellEnvironmentTests.swift` · "PTY-006 the environment identifies the terminal and uses UTF-8"
- Given: the base environment `PATH=/usr/bin`, `TERM=dumb`, `TERM_SESSION_ID=x`, `ITERM_SESSION_ID=y`, `SHLVL=3` and the locale `fr_FR`
- When: the environment is made
- Then: `TERM` is `xterm-256color`, `COLORTERM` is `truecolor`, `TERM_PROGRAM` is `ATerm`, `TERM_PROGRAM_VERSION` is the app version, `LANG` is `fr_FR.UTF-8`, `PATH` is `/usr/bin`, and `TERM_SESSION_ID`, `ITERM_SESSION_ID` and `SHLVL` are absent

- Given: a base environment with `LANG=de_DE.UTF-8` and the locale `fr_FR`
- When: the environment is made
- Then: `LANG` is `de_DE.UTF-8`

- Given: a base environment without `LANG` and the locale `fr_FR@calendar=gregorian`
- When: the environment is made
- Then: `LANG` is `fr_FR.UTF-8`

- Given: a base environment without `LANG` and the locale `xx_YY` (not installed)
- When: the environment is made
- Then: `LANG` is `en_US.UTF-8`

## PTY-007 — The login shell comes from SHELL or the user account

Implement: `LoginShell.command(environment:accountShell:isExecutable:)` in `Sources/ATermCore/PTY/LoginShell.swift`, called by `TerminalSession.start()`.

Test: unit · `Tests/ATermCoreTests/ShellEnvironmentTests.swift` · "PTY-007 the login shell comes from SHELL or the user account"
- Given: `SHELL=/bin/zsh`, account shell `/bin/bash`, both executable
- When: the command is resolved
- Then: the executable is `/bin/zsh` and the arguments are `["-zsh"]`

- Given: no `SHELL`, account shell `/bin/bash`
- When: the command is resolved
- Then: the executable is `/bin/bash` and the arguments are `["-bash"]`

- Given: `SHELL=/nonexistent` (not executable), account shell `/usr/local/bin/fish`
- When: the command is resolved
- Then: the executable is `/usr/local/bin/fish` and the arguments are `["-fish"]`

- Given: no `SHELL` and no account shell
- When: the command is resolved
- Then: the executable is `/bin/zsh` and the arguments are `["-zsh"]`

## PTY-009 — The line discipline edits UTF-8 input and uses the usual control characters

Implement: the initial terminal settings passed to `forkpty` by `aterm_pty_spawn` (IUTF8, cooked mode, `erase` DEL, `intr` ^C…), called by `PTYProcess.start()`.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-009 the line discipline edits UTF-8 input and uses the usual control characters"
- Given: the command `/bin/stty -a`
- When: it runs to completion
- Then: its output shows `iutf8` (not `-iutf8`), `icanon`, `echo`, `erase = ^?`, `intr = ^C` and `susp = ^Z`

- Given: `/bin/sh -c 'read line; printf %s "$line" | od -An -tx1'` started in a pseudo-terminal
- When: `é`, DEL, `a` and LF are written
- Then: the output contains ` 61` and does not contain `c3` (erasing removed the whole `é`)

## PTY-008 — Process inspection reports the foreground job and the working directory

Implement: `PTYProcess.foregroundProcessName`, `hasForegroundJob` and `currentDirectory`, used by the app to title windows, confirm closing and open new tabs and panes in the same directory.

Test: unit · `Tests/ATermCoreTests/PTYProcessTests.swift` · "PTY-008 process inspection reports the foreground job and the working directory"
- Given: `/bin/bash --noprofile --norc -i` started with `PS1='$ '` and `BASH_SILENCE_DEPRECATION_WARNING=1`
- When: the prompt `$ ` has been output
- Then: `foregroundProcessName` is `bash` and `hasForegroundJob` is false
- When: `cd /tmp` LF is written and a new prompt has been output
- Then: `currentDirectory` is `/private/tmp`
- When: `sleep 5` LF is written
- Then: within 2 seconds `foregroundProcessName` is `sleep` and `hasForegroundJob` is true
