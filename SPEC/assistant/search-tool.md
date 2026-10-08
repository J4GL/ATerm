# Assistant — the `search` tool

A native, ripgrep-like content search: `SearchTool.run(_:workingDirectory:)`
in `Sources/ATermCore/Assistant/SearchTool.swift`, with `.gitignore` and glob
matching in `Gitignore.swift`. Paths are shown like ripgrep does: the given
path joined with the path below it, relative to the working directory when no
path is given.

## ASSIST-SEARCH-001 — Matching lines come back sorted, with options and notices

Implement: `SearchTool.run(_:workingDirectory:)`, called by `Agent` for the `search` tool with the agent's working directory.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/SearchToolTests.swift` · "ASSIST-SEARCH-001 matching lines come back sorted with options and notices"
- Given: a working directory holding `notes.txt` (`alpha`, `Beta`, `alphabet`), `src/main.swift` (`let alpha = 1`, `// TODO: fix`, `let x = ALPHA + 2`), `src/util.txt` (`nothing here`, `call(x)`), `ctx.txt` (`one`, `two`, `mark A`, `four`, `five`, `six`, `seven`, `mark B`, `nine`), `long.txt` (one line of 600 `y`) and `many.txt` (`hit 1` … `hit 150`)
- When: `search` runs with each argument set below
- Then: the output is exactly:

| Arguments | Output |
|---|---|
| `pattern: "alpha"` | `notes.txt:1:alpha` LF `notes.txt:3:alphabet` LF `src/main.swift:1:let alpha = 1` |
| `pattern: "alpha", ignore_case: true` | the three lines above, then `src/main.swift:3:let x = ALPHA + 2` |
| `pattern: "call(x)", literal: true` | `src/util.txt:2:call(x)` |
| `pattern: "call(x)"` | `No matches found.` |
| `pattern: "mark", path: "ctx.txt", context: 1` | `ctx.txt-2-two` LF `ctx.txt:3:mark A` LF `ctx.txt-4-four` LF `--` LF `ctx.txt-7-seven` LF `ctx.txt:8:mark B` LF `ctx.txt-9-nine` |
| `pattern: "hit", path: "many.txt", limit: 2` | `many.txt:1:hit 1` LF `many.txt:2:hit 2` LF `[2 matches limit reached. Use limit=4 for more, or refine the pattern]` |
| `pattern: "y+", path: "long.txt"` | `long.txt:1:` + 500 `y` + `... [truncated]` |
| `pattern: "zzz"` | `No matches found.` |
| `pattern: "("` | a single line starting with `Error: invalid regular expression` |
| `pattern: "x", path: "missing"` | `Error: no such file or directory: missing` |

- When: `search` runs on `secret.txt` (480 `s`, a space, then a `ghp_` token of 40 characters) with a redaction function
- Then: the line shows `<GITHUB_TOKEN_1:40chars>` and no `ghp_` (lines are redacted before they are cut)
- When: `search` runs on `wide.txt` (1000 matching lines of about 400 characters) with `limit: 1000`
- Then: the output is at most 24 KiB and ends with `[Output limit of 24 KiB reached. Use path, glob or a narrower pattern]`
- When: `search` runs with `pattern: "hit"` (default limit)
- Then: the output has the 100 lines `many.txt:1:hit 1` … `many.txt:100:hit 100` followed by `[100 matches limit reached. Use limit=200 for more, or refine the pattern]`

## ASSIST-SEARCH-002 — Hidden files are searched; ignored, git and binary files are not

Implement: the directory walk of `SearchTool.run(_:workingDirectory:)` with `GitignoreRules` and `GlobFilter`.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/SearchToolTests.swift` · "ASSIST-SEARCH-002 hidden files are searched and ignored git and binary files are not"
- Given: a git work tree holding the rule files `.gitignore` (`*.log`, `build/`, `/root-only.txt`, `!keep.log`, `docs/**/*.tmp`) and `sub/.gitignore` (`local.txt`), the file `bin.dat` (`needle` then a NUL byte), and these files each holding the line `needle`: `.git/config`, `app.log`, `keep.log`, `root-only.txt`, `sub/root-only.txt`, `build/out.txt`, `sub/build/x.txt`, `docs/a/b/c.tmp`, `docs/c.tmp`, `docs/readme.md`, `sub/local.txt`, `local.txt`, `.hidden/h.txt`, `.env.example`, `src/a.swift`, `src/b.ts`, `src/gen/c.swift`
- When: `search` runs with `pattern: "needle"` and each argument set below
- Then: the output lists exactly these `path:1:needle` lines, in this order:

| Arguments | Paths |
|---|---|
| (none) | `.env.example`, `.hidden/h.txt`, `docs/readme.md`, `keep.log`, `local.txt`, `src/a.swift`, `src/b.ts`, `src/gen/c.swift`, `sub/root-only.txt` |
| `glob: "*.swift"` | `src/a.swift`, `src/gen/c.swift` |
| `glob: "src/** !src/gen/**"` | `src/a.swift`, `src/b.ts` |
| `glob: "*.{swift,ts}"` | `src/a.swift`, `src/b.ts`, `src/gen/c.swift` |
| `path: "sub"` | `sub/root-only.txt` |
| `path: "app.log"` | `app.log` |
