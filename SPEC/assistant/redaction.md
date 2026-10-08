# Assistant — secret redaction

Every text sent to the model (environment block, recent terminal output,
requests, tool results) goes through `SecretRedactor.redact(_:)` first;
placeholders written by the model are turned back into the real values just
before a command runs. Code: `Sources/ATermCore/Assistant/SecretRedactor.swift`
and `SecretSources.swift`.

## ASSIST-REDACT-001 — Known secret values become stable placeholders

Implement: `SecretSources.collect(environments:dotEnvDirectories:credentialFiles:)` and `SecretRedactor.redact(_:)`, used by `Router` and `Agent` for every outgoing text; the app passes its own environment, the login shell environment, the configured shell variables, the session directory and its git root, and the default credential files.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/SecretRedactorTests.swift` · "ASSIST-REDACT-001 known secret values become stable placeholders"
- Given: the environment `GITHUB_TOKEN=tok_live_4f9a8b7c6d`, `DB_PASSWORD=p@ss w0rd!`, `SSH_AUTH_SOCK=/private/tmp/agent.sock`, `GIT_AUTHOR_NAME=Jane Doe Developer`, `KEYCHAIN_PATH=/Users/me/Library/k.db`, `SESSION_TTL=86400000`, `SHORT_KEY=abc`; a directory holding `.env` (`API_SECRET=dotenv-secret-42`, `APP_NAME=development-server`) and `.env.example` (`API_SECRET=example-only-value`); a credential file holding `aws_secret_access_key = wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY` and `//registry.npmjs.org/:_authToken=npm-token-value-77`
- When: the known secrets are collected and a redactor built from them redacts
  `t=tok_live_4f9a8b7c6d again tok_live_4f9a8b7c6d` LF
  `db=p@ss w0rd! url=p%40ss%20w0rd%21 b64=cEBzcyB3MHJkIQ==` LF
  `sock=/private/tmp/agent.sock author=Jane Doe Developer ttl=86400000` LF
  `env=dotenv-secret-42 example=example-only-value app=development-server` LF
  `aws=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY npm=npm-token-value-77`
- Then: the result is
  `t=<GITHUB_TOKEN_1:19chars> again <GITHUB_TOKEN_1:19chars>` LF
  `db=<DB_PASSWORD_2:10chars> url=<DB_PASSWORD_URL_3:16chars> b64=<DB_PASSWORD_BASE64_4:16chars>` LF
  `sock=/private/tmp/agent.sock author=Jane Doe Developer ttl=86400000` LF
  `env=<API_SECRET_5:16chars> example=example-only-value app=development-server` LF
  `aws=<AWS_SECRET_ACCESS_KEY_6:31chars> npm=<AUTHTOKEN_7:18chars>`
- When: the same redactor redacts `again tok_live_4f9a8b7c6d then p@ss w0rd!`
- Then: the result is `again <GITHUB_TOKEN_1:19chars> then <DB_PASSWORD_2:10chars>`
- When: it redacts `password: hunter22xyz`, then `value hunter22xyz`
- Then: the results are `password: <PASSWORD_8:11chars>` and `value <PASSWORD_8:11chars>` (a value masked once by a rule stays masked wherever it appears later)

## ASSIST-REDACT-002 — Known formats and keyword contexts are masked, ordinary text is kept

Implement: the format and context layers of `SecretRedactor.redact(_:)`.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/SecretRedactorTests.swift` · "ASSIST-REDACT-002 known formats and keyword contexts are masked"
- Given: a redactor with no known secret, for each line below (a fresh redactor per line)
- When: the line is redacted
- Then: it becomes the expected text:

| Line | Expected |
|---|---|
| `key sk-or-v1-` + `0123456789abcdef` × 4 | `key <OPENROUTER_KEY_1:73chars>` |
| `OPENAI=sk-proj-AbCdEfGhIjKlMnOpQrStUvWx` | `OPENAI=<API_KEY_1:32chars>` |
| `ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789` | `<GITHUB_TOKEN_1:40chars>` |
| `github_pat_11ABCDEFG0123456789_abcdefghijklmnop` | `<GITHUB_TOKEN_1:47chars>` |
| `id AKIAIOSFODNN7EXAMPLE` | `id <AWS_ACCESS_KEY_ID_1:20chars>` |
| `xoxb-123456789012-abcdefghij` | `<SLACK_TOKEN_1:28chars>` |
| `glpat-abcdefghij0123456789` | `<GITLAB_TOKEN_1:26chars>` |
| `AIza` + `SyA1234567890abcdefghijklmnopqrstuv` | `<GOOGLE_API_KEY_1:39chars>` |
| `ya29.a0AfH6SMBx1234567890abcdef` | `<GOOGLE_OAUTH_TOKEN_1:31chars>` |
| `npm_abcdefghijklmnopqrstuvwxyz0123456789` | `<NPM_TOKEN_1:40chars>` |
| `jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U` | `jwt <JWT_1:84chars>` |
| `-----BEGIN OPENSSH PRIVATE KEY-----` LF `b3BlbnNzaC1rZXktdjEAAAAA` LF `-----END OPENSSH PRIVATE KEY-----` | `<PRIVATE_KEY_1:94chars>` |
| `x` LF `-----BEGIN RSA PRIVATE KEY-----` LF `MIIEabc` LF `MIIEdef` (no END line) | `x` LF `<PRIVATE_KEY_1:47chars>` |
| `password=hunter22` | `password=<PASSWORD_1:8chars>` |
| `DB_PASSWORD: "s3cr3t!!"` | `DB_PASSWORD: "<DB_PASSWORD_1:8chars>"` |
| `GITHUB_TOKEN=abc123def456` | `GITHUB_TOKEN=<GITHUB_TOKEN_1:12chars>` |
| `curl --api-key k3yvalue123 x` | `curl --api-key <API_KEY_1:11chars> x` |
| `Authorization: Bearer abcdef123456789` | `Authorization: Bearer <AUTH_TOKEN_1:15chars>` |
| `mysql -uroot -pr00tpass db` | `mysql -uroot -p<PASSWORD_1:8chars> db` |
| `sshpass -p s3cretpw ssh host` | `sshpass -p <PASSWORD_1:8chars> ssh host` |
| `postgres://app:pa55word@db:5432/x` | `postgres://app:<PASSWORD_1:8chars>@db:5432/x` |

- Given: a redactor with no known secret
- When: each of these lines is redacted: `mkdir -p src/app`, `docker run -p 8080:80 nginx`, `password = os.environ["DB_PASSWORD"]`, `password: str`, `token: ${{ secrets.NPM_TOKEN }}`, `API_KEY=$API_KEY`, `password=None`, `max_tokens=1000`, `commit 9fceb02d0ae598e95dc970b74767f19372d61af8`, `id 123e4567-e89b-12d3-a456-426614174000`, `/Users/me/Library/Application Support/Code/User/settings.json`, `https://example.com/path?q=1`
- Then: each line is unchanged

## ASSIST-REDACT-003 — Placeholders are restored just before execution, without shell injection

Implement: `SecretRedactor.restoreForShell(_:)` (used by `Agent` for `bash` commands) and `SecretRedactor.restorePlain(_:)` (used for `search` arguments and for suggestions, which become insert-only when an unsafe value was restored).
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/SecretRedactorTests.swift` · "ASSIST-REDACT-003 placeholders are restored just before execution"
- Given: a redactor built from `GITHUB_TOKEN=tok_live_4f9a8b7c6d`, `DB_PASSWORD=p@ss w0rd!` and `EVIL_TOKEN=$(touch pwned)`, which redacted `tok_live_4f9a8b7c6d p@ss w0rd! $(touch pwned)` into `<GITHUB_TOKEN_1:19chars> <DB_PASSWORD_2:10chars> <EVIL_TOKEN_3:14chars>`
- When: `restoreForShell` is called on `curl -H "Authorization: Bearer <GITHUB_TOKEN_1:19chars>" x`
- Then: the command is `curl -H "Authorization: Bearer tok_live_4f9a8b7c6d" x` and no variable is added
- When: `restoreForShell` is called on `printf '%s|%s' "<DB_PASSWORD_2:10chars>" "<EVIL_TOKEN_3>" > out.txt` and the result runs with `/bin/bash -c` in an empty directory with the returned variables
- Then: the command is `printf '%s|%s' "${ATERM_SECRET_2}" "${ATERM_SECRET_3}" > out.txt`, the variables are `ATERM_SECRET_2=p@ss w0rd!` and `ATERM_SECRET_3=$(touch pwned)`, `out.txt` holds exactly `p@ss w0rd!|$(touch pwned)` and no file `pwned` exists
- When: `restoreForShell` is called on `echo <OTHER_9:5chars>`
- Then: the command is unchanged
- When: `restoreForShell` is called on `mysql -p'<DB_PASSWORD_2:10chars>' db` (inside single quotes)
- Then: the command is `mysql -p''"${ATERM_SECRET_2}"'' db` (the quotes are closed around the variable)
- When: `restoreForShell` is called on a quoted heredoc (`cat > .env <<'EOF'` LF `PASS=<DB_PASSWORD_2:10chars>` LF `EOF`)
- Then: it reports a problem starting with `Error: ` (a variable would be written literally), which the agent returns to the model instead of running the command
- When: `restorePlain` is called on `grep <DB_PASSWORD_2:10chars> and <GITHUB_TOKEN_1>`
- Then: the text is `grep p@ss w0rd! and tok_live_4f9a8b7c6d` and it reports that an unsafe value was restored; on `x <GITHUB_TOKEN_1:19chars>` it reports none
