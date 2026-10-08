# Assistant — the `bash` tool

`CommandRunner` in `Sources/ATermCore/Assistant/CommandRunner.swift` runs
each call in a new `bash -c` process started by `aterm_spawn`
(`Sources/CPTY/cpty.c`): default signal handlers, empty signal mask, its own
process group, only descriptors 0–2 inherited, stdin `/dev/null`, stdout and
stderr appended to one output file (the full output). The call is over when
bash exits. `BashTool` in `BashTool.swift` turns a run into the text the
model reads.

## ASSIST-BASH-001 — A command runs with bash in a clean, non-interactive environment

Implement: `CommandRunner.run(_:timeout:extraEnvironment:onOutput:)` over `aterm_spawn`, called by `Agent` for the `bash` tool, with the login shell environment prepared by `CommandRunner.environment(from:)`.
Uses: [Assistant contract](contract.md), [PTY](../pty/pty.md)

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-001 a command runs with bash in a clean non-interactive environment"
- Given: a runner in an empty temporary directory, with the environment `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `LANG=en_US.UTF-8`, `COLORTERM=truecolor` and `BASH_ENV` naming a script that prints `SOURCED`, prepared by `CommandRunner.environment(from:)`; the test process ignores SIGPIPE and holds an open descriptor D
- When: each command below runs
- Then: it gives the exit code and the exact output file content:

| Command | Exit code | Output |
|---|---|---|
| `echo out; echo err >&2; exit 3` | 3 | `out` LF `err` LF |
| `pwd -P` | 0 | the directory, resolved, LF |
| `read line; echo "got [$line]"` | 0 | `got []` LF |
| `test -t 1 && echo tty \|\| echo notty` | 0 | `notty` LF |
| `echo "$PAGER $GIT_PAGER $GH_PAGER $NO_COLOR $TERM $GIT_TERMINAL_PROMPT $EDITOR $VISUAL $GIT_EDITOR [$COLORTERM] [$BASH_ENV]"` | 0 | `cat cat cat 1 dumb 0 true true true [] []` LF |
| `yes \| head -n 1` | 0 | `y` LF |
| `test -e /dev/fd/D && echo leaked \|\| echo clean` | 0 | `clean` LF |
| `echo "[$1] [$#]"` | 0 | `[] [0]` LF |

- When: `echo live; sleep 1; echo done` runs with an output observer
- Then: the observer receives `live` before the run returns and before `done` is written, and in total receives `live` LF `done` LF

## ASSIST-BASH-002 — The working directory persists between calls, variables do not

Implement: the `cd` tracking of `CommandRunner` (an EXIT trap writes `pwd -P` to a file read after the run).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-002 the working directory persists between calls and variables do not"
- Given: a runner in a temporary directory T holding the directory `sub`
- When: `cd sub && export X=1` runs
- Then: the runner's working directory is `T/sub` and the result says it changed
- When: `pwd -P; echo "[$X]"` runs
- Then: the output is `T/sub` LF `[]` LF and the result says it did not change
- When: `cd .. && exit 4` runs
- Then: the exit code is 4 and the working directory is `T`
- When: `cd sub; trap 'echo bye' EXIT` runs (the command replaces the trap)
- Then: the output is `bye` LF and the working directory stays `T`
- When: `mkdir gone && cd gone` runs, then the test deletes `T/gone`, then `pwd -P` runs
- Then: the last output is the home directory and its result carries the notice `The working directory T/gone no longer exists; now in <home>.`

## ASSIST-BASH-003 — A timeout or a cancellation kills the whole process group

Implement: the timeout and cancellation handling of `CommandRunner.run` (SIGTERM to the group, SIGKILL 3 s later).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-003 a timeout or a cancellation kills the whole process group"
- Given: a runner in a temporary directory, for each case below, running `echo start; sleep 30 & sleep 30; echo never`
- When: it runs with a 1 s timeout
- Then: within 5 s the result says it timed out, the output is `start` LF and no process of its group is left
- When: it runs without timeout in a task cancelled 0.5 s later
- Then: within 5 s the result says it was cancelled and no process of its group is left
- When: `trap '' TERM; echo start; sleep 30` runs with a 1 s timeout (SIGTERM ignored)
- Then: within 6 s the result says it timed out and no process of its group is left

## ASSIST-BASH-004 — A server started in the background keeps serving after the call returns

Implement: `CommandRunner` writing the output to a file (no pipe for a background process to break) and returning when bash exits.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-004 a server started in the background keeps serving after the call returns"
- Given: a runner in a temporary directory and a free TCP port P
- When: `python3 -m http.server P --bind 127.0.0.1 & echo $!` runs (the server's log is not redirected)
- Then: the call returns within 3 s with exit code 0 and the server's pid as output
- When: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:P/` runs, retried for up to 5 s until it answers, then runs twice more
- Then: each of the last two runs prints `200`

## ASSIST-BASH-005 — The model reads a cleaned, redacted and truncated output

Implement: `BashTool.result(for:output:command:redactor:)` (the output file named by the run), used by `Agent` for every `bash` call with the output read by `BashTool.readOutput(_:)`.
Uses: [Assistant contract](contract.md), [Redaction](redaction.md)

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-005 the model reads a cleaned redacted and truncated output"
- Given: a run of `cmd` with exit code 0, 0.4 s, unchanged directory, the output file `/tmp/out-1.txt`, and a redactor knowing `API_TOKEN=tok-9a8b7c6d5e`
- When: the result is built for each output below
- Then: it is `Exit code: 0` LF `Wall time: 0.4 s` LF `Output:` LF followed by:

| Output | Text after `Output:` |
|---|---|
| (empty) | `(no output)` |
| `⎋[31mred⎋[0m plain⎋]0;title BEL` LF | `red plain` |
| `progress 10%` CR `progress 100%` LF `a` CR LF `b` LF | `progress 100%` LF `a` LF `b` |
| `token tok-9a8b7c6d5e` LF | `token <API_TOKEN_1:14chars>` |
| 1 000 `z` LF | 500 `z` + `... [truncated]` |
| `line 1` … `line 2200`, the last one being `line 2200 tok-9a8b7c6d5e` | `line 1` … `line 100`, `[Showing lines 1-100 and 1901-2200 of 2200. Full output: /tmp/out-1.txt]`, `line 1901` … `line 2199`, `line 2200 <API_TOKEN_1:14chars>` |
| 350 lines of 400 `q` | the first 20 lines, `[Showing lines 1-20 and 311-350 of 350. Full output: /tmp/out-1.txt]`, the last 40 lines |

- When: the result is built for 537 lines where a private key block starts at line 96 and ends at line 101 (across the first-lines cut)
- Then: no line of the key's body appears; the block is one placeholder (the whole output is redacted before it is cut)
- When: the result is built for `gh auth token`, `security find-generic-password -s x -w`, `gcloud auth print-access-token` and `aws configure export-credentials` with the output `secret-value-1234`
- Then: the text after `Output:` is `[output withheld: prints secrets]`; for `printenv PATH` it is the output itself
- When: the result is built for a run that timed out after 120 s in the directory `/tmp/x` it moved to, with output `start` LF
- Then: it is `Timed out after 120 s; the process group was killed` LF `Wall time: 120.0 s` LF `Working directory: /tmp/x` LF `Output:` LF `start`

## ASSIST-BASH-006 — Every command's end is collected, even when many end at once on a busy machine

Implement: the exit monitoring of `CommandRunner.run` (`RunningCommand`): the exit event of the command's process can come before the process can be waited for, so the handler waits for it (`waitpid` without `WNOHANG`); the check made before the event is armed does not wait.

Test: unit · `Tests/ATermCoreTests/Assistant/BashToolTests.swift` · "ASSIST-BASH-006 every command's end is collected even when many end at once on a busy machine"
- Given: 8 `yes > /dev/null` processes keeping the CPUs busy, and a runner in a temporary directory
- When: 600 runs of `true` by that runner, each with a 120 s timeout, start at once
- Then: every run has returned, with the exit code 0, within 60 seconds
