import Foundation
import Testing
import ATermCore

private func terminal(cols: Int = 20, rows: Int = 5, fed text: String) -> Terminal {
    let terminal = Terminal(cols: cols, rows: rows)
    terminal.feed(Array(text.utf8))
    return terminal
}

private func sampleSnapshot(recentOutput: [String]) -> EnvironmentSnapshot {
    EnvironmentSnapshot(
        osVersion: "macOS 27.0 (26A428)", architecture: "arm64", hostName: "studio", userName: "jdoe",
        fullName: "Jane Doe", home: "/Users/jdoe", loginShell: "/bin/zsh", bash: "/bin/bash 3.2.57(1)-release",
        locale: "fr_FR", languages: ["fr-FR", "en-US"], date: Date(timeIntervalSince1970: 1_790_251_392),
        timeZone: TimeZone(identifier: "Europe/Paris")!, workingDirectory: "/Users/jdoe/blog",
        gitRoot: "/Users/jdoe/blog", gitBranch: "main", entries: ["Gemfile", "app/", "config/"], tools: ["git", "node"],
        terminalColumns: 120, terminalRows: 32, foregroundProgram: "zsh", recentOutput: recentOutput)
}

@Test("ASSIST-CONTEXT-001 the environment block describes the machine the user the directory and the terminal")
func ASSIST_CONTEXT_001() {
    let x30 = String(repeating: "x", count: 30)
    let recent = EnvironmentContext.recentLines(of: terminal(fed: "one\r\n" + x30 + "\r\n$ "), count: 50)
    #expect(EnvironmentContext.render(sampleSnapshot(recentOutput: recent)) == """
        <environment>
        os: macOS 27.0 (26A428), arm64
        host: studio
        user: jdoe (Jane Doe), home /Users/jdoe
        shell: /bin/zsh; commands run with /bin/bash 3.2.57(1)-release
        locale: fr_FR; languages: fr-FR, en-US
        date: 2026-09-24T14:03:12+02:00 (Europe/Paris)
        cwd: /Users/jdoe/blog
        git: /Users/jdoe/blog on branch main
        entries: Gemfile, app/, config/
        tools: git, node
        terminal: 120x32, running zsh
        </environment>
        <recent_terminal_output>
        one
        \(x30)
        $
        </recent_terminal_output>
        """)

    let alternate = terminal(fed: "before\r\n\u{1B}[?1049h\u{1B}[Hvim screen")
    var bare = sampleSnapshot(recentOutput: EnvironmentContext.recentLines(of: alternate, count: 50))
    bare.gitRoot = nil
    bare.gitBranch = nil
    bare.foregroundProgram = nil
    let rendered = EnvironmentContext.render(bare)
    #expect(!rendered.contains("git:"))
    #expect(rendered.contains("\nterminal: 120x32\n"))
    #expect(rendered.hasSuffix("<recent_terminal_output>\nvim screen\n</recent_terminal_output>"))

    let long = terminal(fed: (1...60).map { "n\($0)\r\n" }.joined() + "\r\n\r\n$ ")
    #expect(EnvironmentContext.recentLines(of: long, count: 50) == (14...60).map { "n\($0)" } + ["", "", "$"])

    #expect(EnvironmentContext.recentLines(of: terminal(fed: "a\r\n\r\n"), count: 50) == ["a"])
}

@Test("ASSIST-CONTEXT-002 project instructions are read from the git root down to the working directory")
func ASSIST_CONTEXT_002() throws {
    let root = try TemporaryDirectory()
    try root.makeDirectory(".git")
    try root.write("AGENTS.md", "root rules\n")
    try root.write("app/CLAUDE.md", "app rules\n")
    try root.write("app/web/AGENTS.md", "web rules\n")
    try root.write("app/web/CLAUDE.md", "not read\n")
    #expect(EnvironmentContext.projectInstructions(workingDirectory: root.file("app/web")) == """
        <project_instructions path="\(root.file("AGENTS.md"))">
        root rules
        </project_instructions>
        <project_instructions path="\(root.file("app/CLAUDE.md"))">
        app rules
        </project_instructions>
        <project_instructions path="\(root.file("app/web/AGENTS.md"))">
        web rules
        </project_instructions>
        """)

    let loose = try TemporaryDirectory()
    try loose.write("AGENTS.md", "parent\n")
    try loose.write("solo/AGENTS.md", "solo\n")
    let solo = EnvironmentContext.projectInstructions(workingDirectory: loose.file("solo"))
    #expect(solo.contains("solo"))
    #expect(!solo.contains("parent"))

    let big = try TemporaryDirectory()
    try big.makeDirectory(".git")
    try big.write("AGENTS.md", String(repeating: "a", count: 40_000))
    try big.write("deep/AGENTS.md", "late\n")
    let capped = EnvironmentContext.projectInstructions(workingDirectory: big.file("deep"))
    #expect(capped.utf8.count <= 32 * 1024 + 200)
    #expect(capped.contains("a\n[truncated]\n</project_instructions>"))
    #expect(!capped.contains("late"))
}
