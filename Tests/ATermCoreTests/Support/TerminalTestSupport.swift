import Foundation
import Testing
import ATermCore

/// A completion request of ATerm's zsh integration (OSC 6973).
struct CompletionRequest: Equatable {
    let nonce: String
    let line: String
}

/// Records everything a `Terminal` reports to its delegate.
final class RecordingDelegate: TerminalDelegate {
    private(set) var sent: [UInt8] = []
    private(set) var titleChanges = 0
    private(set) var bells = 0
    private(set) var workingDirectoryChanges = 0
    private(set) var paletteChanges = 0
    private(set) var completionRequests: [CompletionRequest] = []

    /// Sent bytes as text, ESC shown as `⎋`.
    var sentText: String {
        String(decoding: sent, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "⎋")
    }

    func terminal(_ terminal: Terminal, send bytes: [UInt8]) { sent += bytes }
    func terminalTitleDidChange(_ terminal: Terminal) { titleChanges += 1 }
    func terminalBell(_ terminal: Terminal) { bells += 1 }
    func terminalWorkingDirectoryDidChange(_ terminal: Terminal) { workingDirectoryChanges += 1 }
    func terminalPaletteDidChange(_ terminal: Terminal) { paletteChanges += 1 }
    func terminal(_ terminal: Terminal, didRequestCompletionOf line: String, nonce: String) {
        completionRequests.append(CompletionRequest(nonce: nonce, line: line))
    }
}

extension Terminal {
    /// Feeds text where `⎋` stands for ESC.
    func feed(_ text: String) {
        feed(bytes(text))
    }

    var cursor: Position { cursorPosition }

    func cell(_ row: Int, _ col: Int) -> Cell { line(row).cells[col] }
}

func P(_ row: Int, _ col: Int) -> Position { Position(row: row, col: col) }

/// `1` CR LF `2` … CR LF `n`.
func numberedRows(_ count: Int) -> String {
    (1...count).map(String.init).joined(separator: "\r\n")
}

/// A scripted terminal scenario: steps run in order on a fresh terminal, each
/// followed by its checks (which use `#expect`).
struct TerminalCase: CustomTestStringConvertible, @unchecked Sendable {
    enum Action {
        case feed(String)
        case resize(cols: Int, rows: Int)
    }

    struct Step {
        let action: Action
        let check: (Terminal, RecordingDelegate) -> Void
    }

    let name: String
    let cols: Int
    let rows: Int
    var scrollbackLimit = 10_000
    let steps: [Step]

    init(_ name: String, cols: Int, rows: Int, scrollbackLimit: Int = 10_000, steps: [Step]) {
        self.name = name
        self.cols = cols
        self.rows = rows
        self.scrollbackLimit = scrollbackLimit
        self.steps = steps
    }

    /// Single-step shorthand: feed `input`, then run `check`.
    init(_ name: String, cols: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000, _ input: String,
         check: @escaping (Terminal, RecordingDelegate) -> Void) {
        self.init(name, cols: cols, rows: rows, scrollbackLimit: scrollbackLimit,
                  steps: [Step(action: .feed(input), check: check)])
    }

    var testDescription: String { name }

    func run() {
        let terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: scrollbackLimit)
        let delegate = RecordingDelegate()
        terminal.delegate = delegate
        for step in steps {
            switch step.action {
            case .feed(let input): terminal.feed(input)
            case .resize(let cols, let rows): terminal.resize(cols: cols, rows: rows)
            }
            step.check(terminal, delegate)
        }
    }
}

func feedStep(_ input: String, _ check: @escaping (Terminal, RecordingDelegate) -> Void) -> TerminalCase.Step {
    TerminalCase.Step(action: .feed(input), check: check)
}

func resizeStep(cols: Int, rows: Int, _ check: @escaping (Terminal, RecordingDelegate) -> Void) -> TerminalCase.Step {
    TerminalCase.Step(action: .resize(cols: cols, rows: rows), check: check)
}
