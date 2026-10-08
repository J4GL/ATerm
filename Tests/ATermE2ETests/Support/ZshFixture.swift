import AppKit
import Foundation
@testable import ATermApp
import ATermCore

@MainActor
extension AppHarness {
    /// The zsh fixture of SPEC/app/suggestions.md: a login zsh whose `ZDOTDIR` is a fresh temporary directory, with
    /// `PROMPT='$ '` and `history` (oldest first) as its history; the integration in another fresh temporary
    /// directory; an empty in-memory key store without environment fallback.
    static func zshFixture(history: [String] = [], rc: String = "") -> AppConfiguration {
        var configuration = fixture()
        let zdotdir = makeTemporaryDirectory()
        configuration.shell = ShellOverride(executable: "/bin/zsh", arguments: ["-zsh"])
        configuration.environment["PS1"] = nil
        configuration.environment["ZDOTDIR"] = zdotdir
        configuration.shellIntegrationDirectory = makeTemporaryDirectory()
        try? Data("PROMPT='$ '\n\(rc)".utf8).write(to: URL(fileURLWithPath: zdotdir + "/.zshrc"))
        try? Data(history.map { $0 + "\n" }.joined().utf8)
            .write(to: URL(fileURLWithPath: zdotdir + "/.zsh_history"))
        configuration.assistant.keyStore = MemoryAPIKeyStore()
        configuration.assistant.environmentKeyFallback = false
        return configuration
    }

    /// A fresh temporary directory, symlinks resolved, removed by `shutDown()`.
    static func makeTemporaryDirectory() -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ATermE2E-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = realpath(base.path, nil)!
        defer { free(resolved) }
        let path = String(cString: resolved)
        temporaryDirectories.insert(path)
        return path
    }

    /// The row of the cursor and its text.
    var cursorRow: (row: Int, text: String) {
        let terminal = controller.session.terminal
        let row = terminal.cursorPosition.row
        return (row, terminal.text(row: row))
    }

    /// The foreground colors of `columns` on `row`.
    func foregrounds(row: Int, _ columns: Range<Int>) -> [TerminalColor] {
        let line = controller.session.terminal.line(row)
        return columns.map { line.cells[$0].attributes.foreground }
    }
}

/// A harness of the assistant fixture whose shell is the zsh fixture's. See SPEC/app/suggestions.md.
@MainActor
func assistantZshHarness(_ fake: FakeOpenRouter, history: [String] = [],
                         keyStore: APIKeyStore = MemoryAPIKeyStore(key: "test-key"),
                         configure: (inout AppConfiguration) -> Void = { _ in }) -> AppHarness {
    var configuration = AppHarness.zshFixture(history: history)
    configuration.assistant = fake.assistantConfiguration(keyStore: keyStore)
    configure(&configuration)
    let harness = AppHarness(configuration: configuration)
    harness.reportKey(true)
    return harness
}
