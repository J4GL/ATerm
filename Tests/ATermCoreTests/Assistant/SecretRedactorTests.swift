import Foundation
import Testing
import ATermCore

@Test("ASSIST-REDACT-001 known secret values become stable placeholders")
func ASSIST_REDACT_001() throws {
    let directory = try TemporaryDirectory()
    try directory.write(".env", "API_SECRET=dotenv-secret-42\nAPP_NAME=development-server\n")
    try directory.write(".env.example", "API_SECRET=example-only-value\n")
    try directory.write("credentials", """
        [default]
        aws_secret_access_key = wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY
        //registry.npmjs.org/:_authToken=npm-token-value-77

        """)
    let environment = [
        "GITHUB_TOKEN": "tok_live_4f9a8b7c6d", "DB_PASSWORD": "p@ss w0rd!", "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
        "GIT_AUTHOR_NAME": "Jane Doe Developer", "KEYCHAIN_PATH": "/Users/me/Library/k.db", "SESSION_TTL": "86400000",
        "SHORT_KEY": "abc",
    ]
    let secrets = SecretSources.collect(environments: [environment], dotEnvDirectories: [directory.path],
                                        credentialFiles: [directory.file("credentials")])
    let redactor = SecretRedactor(knownSecrets: secrets)

    let text = """
        t=tok_live_4f9a8b7c6d again tok_live_4f9a8b7c6d
        db=p@ss w0rd! url=p%40ss%20w0rd%21 b64=cEBzcyB3MHJkIQ==
        sock=/private/tmp/agent.sock author=Jane Doe Developer ttl=86400000
        env=dotenv-secret-42 example=example-only-value app=development-server
        aws=wJalrXUtnFEMIbPxRfiCYEXAMPLEKEY npm=npm-token-value-77
        """
    let expected = """
        t=<GITHUB_TOKEN_1:19chars> again <GITHUB_TOKEN_1:19chars>
        db=<DB_PASSWORD_2:10chars> url=<DB_PASSWORD_URL_3:16chars> b64=<DB_PASSWORD_BASE64_4:16chars>
        sock=/private/tmp/agent.sock author=Jane Doe Developer ttl=86400000
        env=<API_SECRET_5:16chars> example=example-only-value app=development-server
        aws=<AWS_SECRET_ACCESS_KEY_6:31chars> npm=<AUTHTOKEN_7:18chars>
        """
    #expect(redactor.redact(text) == expected)
    #expect(redactor.redact("again tok_live_4f9a8b7c6d then p@ss w0rd!")
        == "again <GITHUB_TOKEN_1:19chars> then <DB_PASSWORD_2:10chars>")

    #expect(redactor.redact("password: hunter22xyz") == "password: <PASSWORD_8:11chars>")
    #expect(redactor.redact("value hunter22xyz") == "value <PASSWORD_8:11chars>")
}

struct RedactionCase: CustomTestStringConvertible, Sendable {
    let line: String
    let expected: String

    var testDescription: String { line.prefix(40).description }
}

private let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"

private let maskedLines: [RedactionCase] = [
    RedactionCase(line: "key sk-or-v1-" + String(repeating: "0123456789abcdef", count: 4),
                  expected: "key <OPENROUTER_KEY_1:73chars>"),
    RedactionCase(line: "OPENAI=sk-proj-AbCdEfGhIjKlMnOpQrStUvWx", expected: "OPENAI=<API_KEY_1:32chars>"),
    RedactionCase(line: "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789", expected: "<GITHUB_TOKEN_1:40chars>"),
    RedactionCase(line: "github_pat_11ABCDEFG0123456789_abcdefghijklmnop", expected: "<GITHUB_TOKEN_1:47chars>"),
    RedactionCase(line: "id AKIAIOSFODNN7EXAMPLE", expected: "id <AWS_ACCESS_KEY_ID_1:20chars>"),
    RedactionCase(line: "xoxb-123456789012-abcdefghij", expected: "<SLACK_TOKEN_1:28chars>"),
    RedactionCase(line: "glpat-abcdefghij0123456789", expected: "<GITLAB_TOKEN_1:26chars>"),
    // Built in two parts so that the fake key is not a literal that secret scanners report.
    RedactionCase(line: "AIza" + "SyA1234567890abcdefghijklmnopqrstuv", expected: "<GOOGLE_API_KEY_1:39chars>"),
    RedactionCase(line: "ya29.a0AfH6SMBx1234567890abcdef", expected: "<GOOGLE_OAUTH_TOKEN_1:31chars>"),
    RedactionCase(line: "npm_abcdefghijklmnopqrstuvwxyz0123456789", expected: "<NPM_TOKEN_1:40chars>"),
    RedactionCase(line: "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                  expected: "jwt <JWT_1:84chars>"),
    RedactionCase(line: privateKey, expected: "<PRIVATE_KEY_1:94chars>"),
    RedactionCase(line: "x\n-----BEGIN RSA PRIVATE KEY-----\nMIIEabc\nMIIEdef", expected: "x\n<PRIVATE_KEY_1:47chars>"),
    RedactionCase(line: "password=hunter22", expected: "password=<PASSWORD_1:8chars>"),
    RedactionCase(line: "DB_PASSWORD: \"s3cr3t!!\"", expected: "DB_PASSWORD: \"<DB_PASSWORD_1:8chars>\""),
    RedactionCase(line: "GITHUB_TOKEN=abc123def456", expected: "GITHUB_TOKEN=<GITHUB_TOKEN_1:12chars>"),
    RedactionCase(line: "curl --api-key k3yvalue123 x", expected: "curl --api-key <API_KEY_1:11chars> x"),
    RedactionCase(line: "Authorization: Bearer abcdef123456789", expected: "Authorization: Bearer <AUTH_TOKEN_1:15chars>"),
    RedactionCase(line: "mysql -uroot -pr00tpass db", expected: "mysql -uroot -p<PASSWORD_1:8chars> db"),
    RedactionCase(line: "sshpass -p s3cretpw ssh host", expected: "sshpass -p <PASSWORD_1:8chars> ssh host"),
    RedactionCase(line: "postgres://app:pa55word@db:5432/x", expected: "postgres://app:<PASSWORD_1:8chars>@db:5432/x"),
]

private let keptLines = [
    "mkdir -p src/app", "docker run -p 8080:80 nginx", "password = os.environ[\"DB_PASSWORD\"]", "password: str",
    "token: ${{ secrets.NPM_TOKEN }}", "API_KEY=$API_KEY", "password=None", "max_tokens=1000",
    "commit 9fceb02d0ae598e95dc970b74767f19372d61af8", "id 123e4567-e89b-12d3-a456-426614174000",
    "/Users/me/Library/Application Support/Code/User/settings.json", "https://example.com/path?q=1",
].map { RedactionCase(line: $0, expected: $0) }

@Test("ASSIST-REDACT-002 known formats and keyword contexts are masked", arguments: maskedLines + keptLines)
func ASSIST_REDACT_002(_ testCase: RedactionCase) {
    let redactor = SecretRedactor(knownSecrets: [])
    #expect(redactor.redact(testCase.line) == testCase.expected)
}

@Test("ASSIST-REDACT-003 placeholders are restored just before execution")
func ASSIST_REDACT_003() throws {
    let redactor = SecretRedactor(knownSecrets: [
        KnownSecret(name: "GITHUB_TOKEN", value: "tok_live_4f9a8b7c6d"),
        KnownSecret(name: "DB_PASSWORD", value: "p@ss w0rd!"),
        KnownSecret(name: "EVIL_TOKEN", value: "$(touch pwned)"),
    ])
    #expect(redactor.redact("tok_live_4f9a8b7c6d p@ss w0rd! $(touch pwned)")
        == "<GITHUB_TOKEN_1:19chars> <DB_PASSWORD_2:10chars> <EVIL_TOKEN_3:14chars>")

    let safe = redactor.restoreForShell("curl -H \"Authorization: Bearer <GITHUB_TOKEN_1:19chars>\" x")
    #expect(safe.command == "curl -H \"Authorization: Bearer tok_live_4f9a8b7c6d\" x")
    #expect(safe.environment.isEmpty)

    let unsafe = redactor.restoreForShell("printf '%s|%s' \"<DB_PASSWORD_2:10chars>\" \"<EVIL_TOKEN_3>\" > out.txt")
    #expect(unsafe.command == "printf '%s|%s' \"${ATERM_SECRET_2}\" \"${ATERM_SECRET_3}\" > out.txt")
    #expect(unsafe.environment == ["ATERM_SECRET_2": "p@ss w0rd!", "ATERM_SECRET_3": "$(touch pwned)"])
    let directory = try TemporaryDirectory()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", unsafe.command]
    process.currentDirectoryURL = URL(fileURLWithPath: directory.path)
    process.environment = ["PATH": "/usr/bin:/bin"].merging(unsafe.environment) { $1 }
    try process.run()
    process.waitUntilExit()
    #expect(directory.read("out.txt") == "p@ss w0rd!|$(touch pwned)")
    #expect(!directory.exists("pwned"))

    #expect(redactor.restoreForShell("echo <OTHER_9:5chars>").command == "echo <OTHER_9:5chars>")

    let quoted = redactor.restoreForShell("mysql -p'<DB_PASSWORD_2:10chars>' db")
    #expect(quoted.command == "mysql -p''\"${ATERM_SECRET_2}\"'' db")
    #expect(quoted.problem == nil)
    let heredoc = redactor.restoreForShell("cat > .env <<'EOF'\nPASS=<DB_PASSWORD_2:10chars>\nEOF")
    #expect(heredoc.problem?.hasPrefix("Error: ") == true)

    let plain = redactor.restorePlain("grep <DB_PASSWORD_2:10chars> and <GITHUB_TOKEN_1>")
    #expect(plain.text == "grep p@ss w0rd! and tok_live_4f9a8b7c6d")
    #expect(plain.restoredUnsafeValue)
    #expect(!redactor.restorePlain("x <GITHUB_TOKEN_1:19chars>").restoredUnsafeValue)
}
