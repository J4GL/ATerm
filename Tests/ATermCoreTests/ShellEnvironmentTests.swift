import Testing
import ATermCore

struct EnvironmentCase: CustomTestStringConvertible, Sendable {
    let name: String
    let base: [String: String]
    let locale: String
    let expected: [String: String]
    var absent: [String] = []

    var testDescription: String { name }
}

@Test("PTY-006 the environment identifies the terminal and uses UTF-8", arguments: [
    EnvironmentCase(
        name: "terminal identity",
        base: ["PATH": "/usr/bin", "TERM": "dumb", "TERM_SESSION_ID": "x", "ITERM_SESSION_ID": "y", "SHLVL": "3"],
        locale: "fr_FR",
        expected: ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "ATerm",
                   "TERM_PROGRAM_VERSION": ATermVersion.string, "LANG": "fr_FR.UTF-8", "PATH": "/usr/bin"],
        absent: ["TERM_SESSION_ID", "ITERM_SESSION_ID", "SHLVL"]),
    EnvironmentCase(name: "existing LANG is kept", base: ["LANG": "de_DE.UTF-8"], locale: "fr_FR",
                    expected: ["LANG": "de_DE.UTF-8"]),
    EnvironmentCase(name: "locale keywords are ignored", base: [:], locale: "fr_FR@calendar=gregorian",
                    expected: ["LANG": "fr_FR.UTF-8"]),
    EnvironmentCase(name: "unknown locale falls back", base: [:], locale: "xx_YY", expected: ["LANG": "en_US.UTF-8"]),
])
func PTY_006(_ testCase: EnvironmentCase) {
    let environment = ShellEnvironment.make(base: testCase.base, localeIdentifier: testCase.locale)
    for (key, value) in testCase.expected {
        #expect(environment[key] == value, "\(key)")
    }
    for key in testCase.absent {
        #expect(environment[key] == nil, "\(key)")
    }
}

struct LoginShellCase: CustomTestStringConvertible, Sendable {
    let name: String
    let environment: [String: String]
    let accountShell: String?
    let executable: String
    let arguments: [String]

    var testDescription: String { name }
}

@Test("PTY-007 the login shell comes from SHELL or the user account", arguments: [
    LoginShellCase(name: "SHELL wins", environment: ["SHELL": "/bin/zsh"], accountShell: "/bin/bash",
                   executable: "/bin/zsh", arguments: ["-zsh"]),
    LoginShellCase(name: "account shell", environment: [:], accountShell: "/bin/bash",
                   executable: "/bin/bash", arguments: ["-bash"]),
    LoginShellCase(name: "unusable SHELL", environment: ["SHELL": "/nonexistent"], accountShell: "/usr/local/bin/fish",
                   executable: "/usr/local/bin/fish", arguments: ["-fish"]),
    LoginShellCase(name: "fallback", environment: [:], accountShell: nil, executable: "/bin/zsh", arguments: ["-zsh"]),
])
func PTY_007(_ testCase: LoginShellCase) {
    let command = LoginShell.command(environment: testCase.environment, accountShell: testCase.accountShell,
                                     isExecutable: { $0 != "/nonexistent" })
    #expect(command.executable == testCase.executable)
    #expect(command.arguments == testCase.arguments)
}
