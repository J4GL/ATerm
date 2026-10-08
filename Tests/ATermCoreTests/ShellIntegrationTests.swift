import Darwin
import Foundation
import Testing
import ATermCore

/// The startup files and directories of PTY-SHELL-001: H (home), Z (`ZDOTDIR`) and D (the integration).
struct ShellFixture {
    enum Case: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// The user's files in Z, `ZDOTDIR=Z`.
        case zdotdir
        /// The user's files in H, no `ZDOTDIR`.
        case home
        /// As `zdotdir`, zsh-autosuggestions loaded by `.zshrc`.
        case zshAutosuggestions
        /// `/bin/bash`, no file.
        case bash

        var testDescription: String { rawValue }
    }

    let temporary: TemporaryDirectory
    let home: String
    let zdotdir: String
    let directory: String
    var environment: [String: String]

    init(_ testCase: Case) throws {
        temporary = try TemporaryDirectory()
        home = temporary.file("H")
        zdotdir = temporary.file("Z")
        directory = temporary.file("D")
        try temporary.makeDirectory("H")
        try temporary.makeDirectory("Z")
        if testCase != .bash {
            let startup = testCase == .home ? "H" : "Z"
            var rc = "PROMPT='$ '\nprint -r -- zshrc\n"
            if testCase == .zshAutosuggestions { rc += "_zsh_autosuggest_start() { : }\n" }
            try temporary.write("\(startup)/.zshenv", "print -r -- \"zshenv ${ZDOTDIR-unset}\"\n")
            try temporary.write("\(startup)/.zshrc", rc)
        }
        environment = testEnvironment
        environment["HOME"] = home
        if testCase == .zdotdir || testCase == .zshAutosuggestions { environment["ZDOTDIR"] = zdotdir }
    }
}

/// The screen and the delegate's record after feeding everything the shell wrote to a fresh 80×24 terminal.
private func replay(_ recorder: PTYRecorder) -> (terminal: Terminal, delegate: RecordingDelegate) {
    let terminal = Terminal(cols: 80, rows: 24)
    let delegate = RecordingDelegate()
    terminal.delegate = delegate
    terminal.feed(Array(recorder.output.utf8))
    return (terminal, delegate)
}

/// Waits for the prompt `$ ` on the cursor row and returns that row.
private func waitForPrompt(_ recorder: PTYRecorder) async -> Int? {
    var row: Int?
    _ = await eventually {
        let terminal = replay(recorder).terminal
        let cursor = terminal.cursorPosition
        row = terminal.text(row: cursor.row) == "$" && cursor.col == 2 ? cursor.row : nil
        return row != nil
    }
    return row
}

private func isFIFO(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
}

/// Ranges of `parts` in `text`, in order, each after the previous one.
private func showsInOrder(_ parts: [String], in text: String) -> Bool {
    var start = text.startIndex
    for part in parts {
        guard let range = text.range(of: part, range: start..<text.endIndex) else { return false }
        start = range.upperBound
    }
    return true
}

private let query = #"print -r -- "${ZDOTDIR-unset}|${ATERM_ZSH_ZDOTDIR-none}|${ATERM_SUGGEST_FIFO-none}|${ATERM_SUGGEST_NONCE-none}|$widgets[forward-char]""#

@Test("PTY-SHELL-001 zsh runs the user's own startup files then ATerm's additions",
      arguments: ShellFixture.Case.allCases)
func PTY_SHELL_001(_ testCase: ShellFixture.Case) async throws {
    var fixture = try ShellFixture(testCase)
    let base = fixture.environment
    let executable = testCase == .bash ? "/bin/bash" : "/bin/zsh"
    let integration = ShellIntegration.install(for: executable, environment: &fixture.environment,
                                               directory: fixture.directory)
    if testCase == .bash {
        #expect(integration == nil)
        #expect(fixture.environment == base)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory))
        return
    }
    let installed = try #require(integration)
    defer { installed.remove() }
    let environment = fixture.environment
    #expect(installed.nonce.count == 32 && installed.nonce.allSatisfy(\.isHexDigit))
    #expect((installed.fifoPath as NSString).deletingLastPathComponent == fixture.directory)
    #expect(isFIFO(installed.fifoPath))
    let zsh = fixture.directory + "/zsh"
    #expect(environment["ZDOTDIR"] == zsh)
    #expect(environment["ATERM_ZSH_ZDOTDIR"] == (testCase == .home ? nil : fixture.zdotdir))
    #expect(environment["ATERM_SUGGEST_FIFO"] == installed.fifoPath)
    #expect(environment["ATERM_SUGGEST_NONCE"] == installed.nonce)
    let permissions = try FileManager.default.attributesOfItem(atPath: zsh)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
    #expect(FileManager.default.fileExists(atPath: zsh + "/.zshenv"))
    #expect(FileManager.default.fileExists(atPath: zsh + "/aterm.zsh"))

    let (process, recorder) = try startPTY(["/bin/zsh", "-l", "-i"], environment: environment)
    defer { process.terminate() }
    #expect(await waitForPrompt(recorder) != nil, "\(recorder.output.debugDescription)")
    process.write(Array((query + "\r").utf8))
    let zdotdir = testCase == .home ? "unset" : fixture.zdotdir
    let widget = testCase == .zshAutosuggestions ? "builtin" : "user:_aterm_accept"
    let expected = ["zshenv \(zdotdir)", "zshrc", "\(zdotdir)|none|none|none|\(widget)"]
    #expect(await eventually { showsInOrder(expected, in: recorder.output) }, "\(recorder.output.debugDescription)")
}

@Test("PTY-SHELL-002 zsh asks for a completion when its history has none and shows the one it is sent")
func PTY_SHELL_002() async throws {
    var fixture = try ShellFixture(.zdotdir)
    let integration = try #require(ShellIntegration.install(for: "/bin/zsh", environment: &fixture.environment,
                                                            directory: fixture.directory))
    defer { integration.remove() }
    let (process, recorder) = try startPTY(["/bin/zsh", "-l", "-i"], environment: fixture.environment)
    defer { process.terminate() }
    let row = try #require(await waitForPrompt(recorder), "\(recorder.output.debugDescription)")
    let nonce = integration.nonce

    func lastRequest() -> CompletionRequest? { replay(recorder).delegate.completionRequests.last }
    func colors(_ columns: Range<Int>) -> [TerminalColor] {
        let terminal = replay(recorder).terminal
        return columns.map { terminal.cell(row, $0).attributes.foreground }
    }

    for key in ["f", "f", "m"] {
        process.write(Array(key.utf8))
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(await eventually { lastRequest() == CompletionRequest(nonce: nonce, line: "ffm") },
            "\(String(describing: lastRequest()))")
    #expect(replay(recorder).terminal.text(row: row) == "$ ffm")

    #expect(integration.send("ffmpeg -i in.mov"))
    #expect(await eventually { replay(recorder).terminal.text(row: row) == "$ ffmpeg -i in.mov" })
    let shown = replay(recorder).terminal
    #expect(shown.cursorPosition == P(row, 5))
    #expect(colors(2..<5).allSatisfy { $0 == .default })
    #expect(colors(5..<18).allSatisfy { $0 == .indexed(8) }, "\(colors(5..<18))")
    #expect(await eventually { lastRequest() == CompletionRequest(nonce: nonce, line: "") })

    process.write(Array("x".utf8))
    #expect(await eventually { replay(recorder).terminal.text(row: row) == "$ ffmx" })
    #expect(await eventually { lastRequest() == CompletionRequest(nonce: nonce, line: "ffmx") })

    process.write([0x7F])
    #expect(await eventually { replay(recorder).terminal.text(row: row) == "$ ffmpeg -i in.mov" })
    process.write(Array("\u{1B}[C".utf8))
    #expect(await eventually { replay(recorder).terminal.cursorPosition == P(row, 18) })
    #expect(replay(recorder).terminal.text(row: row) == "$ ffmpeg -i in.mov")
    #expect(colors(2..<18).allSatisfy { $0 == .default }, "\(colors(2..<18))")

    process.write([0x15] + Array("exit\r".utf8))
    #expect(await eventually { !recorder.exitStatuses.isEmpty })
    #expect(!integration.send("x"))
    integration.remove()
    #expect(!FileManager.default.fileExists(atPath: integration.fifoPath))
}

@Test("PTY-SHELL-003 a click sent to zsh removes the highlight of pasted text")
func PTY_SHELL_003() async throws {
    var fixture = try ShellFixture(.zdotdir)
    let integration = try #require(ShellIntegration.install(for: "/bin/zsh", environment: &fixture.environment,
                                                            directory: fixture.directory))
    defer { integration.remove() }
    let (process, recorder) = try startPTY(["/bin/zsh", "-l", "-i"], environment: fixture.environment)
    defer { process.terminate() }
    let row = try #require(await waitForPrompt(recorder), "\(recorder.output.debugDescription)")
    func inverse(_ columns: ClosedRange<Int>) -> [Bool] {
        let terminal = replay(recorder).terminal
        return columns.map { terminal.cell(row, $0).attributes.flags.contains(.inverse) }
    }

    process.write(Array("\u{1B}[200~/tmp/a\\ b.txt \u{1B}[201~".utf8))
    #expect(await eventually {
        replay(recorder).terminal.text(row: row) == "$ /tmp/a\\ b.txt" && inverse(2...15).allSatisfy { $0 }
    }, "\(recorder.output.debugDescription)")

    #expect(integration.sendClick())
    #expect(await eventually { inverse(2...15).allSatisfy { !$0 } }, "\(recorder.output.debugDescription)")
    let shown = replay(recorder).terminal
    #expect(shown.text(row: row) == "$ /tmp/a\\ b.txt")
    #expect(shown.cursorPosition == P(row, 16))

    let before = recorder.output
    #expect(integration.sendClick())
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(recorder.output == before, "\(recorder.output.dropFirst(before.count).debugDescription)")
}
