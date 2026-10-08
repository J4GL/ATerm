# Assistant — dynamic context

The environment block and the project instructions that tell the model where
it runs: `EnvironmentContext` in
`Sources/ATermCore/Assistant/EnvironmentContext.swift`, and the login shell
environment from `LoginEnvironment` in `LoginEnvironment.swift`.

## ASSIST-CONTEXT-001 — The environment block describes the machine, the user, the directory and the terminal

Implement: `EnvironmentContext.render(_:)` and `EnvironmentContext.recentLines(of:count:)`; the app fills the snapshot with `EnvironmentContext.snapshot(...)` for every router and agent request.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/EnvironmentContextTests.swift` · "ASSIST-CONTEXT-001 the environment block describes the machine the user the directory and the terminal"
- Given: a snapshot with os `macOS 27.0 (26A428)`, arch `arm64`, host `studio`, user `jdoe` (`Jane Doe`), home `/Users/jdoe`, shell `/bin/zsh`, bash `/bin/bash 3.2.57(1)-release`, locale `fr_FR`, languages `fr-FR`, `en-US`, date 2026-09-24 12:03:12 UTC in `Europe/Paris`, cwd `/Users/jdoe/blog`, git root `/Users/jdoe/blog` on branch `main`, entries `Gemfile`, `app/`, `config/`, tools `git`, `node`, terminal 120×32 running `zsh`, and the recent lines of a 20×5 terminal fed `one` CR LF, 30 `x` (wrapping), CR LF, `$ `
- When: the snapshot is rendered
- Then: the text is exactly
  `<environment>` LF
  `os: macOS 27.0 (26A428), arm64` LF
  `host: studio` LF
  `user: jdoe (Jane Doe), home /Users/jdoe` LF
  `shell: /bin/zsh; commands run with /bin/bash 3.2.57(1)-release` LF
  `locale: fr_FR; languages: fr-FR, en-US` LF
  `date: 2026-09-24T14:03:12+02:00 (Europe/Paris)` LF
  `cwd: /Users/jdoe/blog` LF
  `git: /Users/jdoe/blog on branch main` LF
  `entries: Gemfile, app/, config/` LF
  `tools: git, node` LF
  `terminal: 120x32, running zsh` LF
  `</environment>` LF
  `<recent_terminal_output>` LF
  `one` LF 30 `x` LF `$` LF
  `</recent_terminal_output>`
- Given: the same snapshot without git root and without foreground program, and a terminal showing the alternate screen with `vim screen` on its first row (its main screen holding `before`)
- When: its recent lines are taken and it is rendered
- Then: the `git:` line is absent, the terminal line reads `terminal: 120x32`, and the recent output is the single line `vim screen`
- Given: a 20×5 terminal fed `n1` CR LF … `n60` CR LF, CR LF, CR LF, `$ `
- When: its recent lines are taken with a count of 50
- Then: they are the 50 lines `n14` … `n60`, two empty lines, `$`
- Given: a 20×5 terminal fed `a` CR LF CR LF (the cursor on an empty line)
- When: its recent lines are taken
- Then: they are the single line `a` (trailing empty lines removed)

## ASSIST-CONTEXT-002 — Project instructions are read from the git root down to the working directory

Implement: `EnvironmentContext.projectInstructions(workingDirectory:maxBytes:)`, added to the agent's system prompt.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/EnvironmentContextTests.swift` · "ASSIST-CONTEXT-002 project instructions are read from the git root down to the working directory"
- Given: a directory R holding `.git/`, `AGENTS.md` (`root rules`), `app/CLAUDE.md` (`app rules`), `app/web/AGENTS.md` (`web rules`) and `app/web/CLAUDE.md` (`not read`)
- When: the instructions are read for the working directory `R/app/web`
- Then: the text is `<project_instructions path="R/AGENTS.md">` LF `root rules` LF `</project_instructions>` LF `<project_instructions path="R/app/CLAUDE.md">` LF `app rules` LF `</project_instructions>` LF `<project_instructions path="R/app/web/AGENTS.md">` LF `web rules` LF `</project_instructions>`
- Given: a directory without `.git` above it holding `AGENTS.md` (`solo`), and a parent holding `AGENTS.md` (`parent`)
- When: the instructions are read for that directory
- Then: only `solo` is included
- Given: a git root whose `AGENTS.md` holds 40 000 `a` and a working directory below it holding `AGENTS.md` (`late`)
- When: the instructions are read with the default limit of 32 KiB
- Then: the text is at most 32 KiB plus the tags, ends the first file's content with `[truncated]`, and does not include `late`

## ASSIST-CONTEXT-003 — The login shell's environment is resolved with a time limit

Implement: `LoginEnvironment.resolve(shell:base:timeout:)`, run once by the app (cached) to give agent commands the user's `PATH` and variables.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/LoginEnvironmentTests.swift` · "ASSIST-CONTEXT-003 the login shell environment is resolved with a time limit"
- Given: a fake shell script that, run as `fake -i -l -c CMD`, prints `welcome!`, exports `FROM_PROFILE=yes` and `PATH=/opt/fake/bin:$PATH`, then runs `CMD`
- When: the environment is resolved with the base `PATH=/usr/bin:/bin` and a 5 s limit
- Then: it contains `FROM_PROFILE=yes` and a `PATH` starting with `/opt/fake/bin:`, and no variable named after the `welcome!` noise
- Given: a fake shell that sleeps 30 s
- When: the environment is resolved with a 0.5 s limit
- Then: the result is nil within 3 s and the fake shell's process group is gone
