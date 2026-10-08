import Foundation

/// Turns agent events into the text of an agent tab: styled lines for the goal, the commands and the result,
/// command output cleaned of control sequences (no title, mouse mode, alternate screen or query from it).
/// See SPEC/app/assistant.md.
public struct TranscriptFormatter {
    public static let maxCommandLines = 6

    private static let reset = "\u{1B}[0m"
    private static let bold = "\u{1B}[1m"
    private static let dim = "\u{1B}[2m"
    private static let green = "\u{1B}[1;32m"
    private static let red = "\u{1B}[1;31m"
    private static let yellow = "\u{1B}[1;33m"
    private static let magenta = "\u{1B}[1;35m"
    private static let clearLine = "\r\u{1B}[2K"

    private var atLineStart = true
    private var statusLineShown = false
    private var sanitizer = OutputSanitizer()
    /// The model's streamed text is cleaned too: it cannot drive the terminal either.
    private var textSanitizer = OutputSanitizer()

    public init() {}

    /// The first lines of an agent tab; the tab has no cursor.
    public mutating func header(model: String, goal: String) -> [UInt8] {
        text("\u{1B}[?25l" + Self.dim + "● ATerm agent · \(model)" + Self.reset + "\n"
            + Self.bold + "◎ Goal: " + Self.oneLine(goal) + Self.reset + "\n\n")
    }

    /// The window title, as an OSC 0 sequence.
    public static func title(_ title: String) -> [UInt8] {
        Array("\u{1B}]0;\(oneLine(title))\u{07}".utf8)
    }

    /// Shown in place while the model thinks, with the retry under way if any.
    public mutating func thinking(seconds: Int, retry: String? = nil) -> [UInt8] {
        var output = statusLineShown ? Self.clearLine : (atLineStart ? "" : "\r\n")
        output += Self.dim + "… thinking (\(seconds) s)" + (retry.map { " · " + $0 } ?? "") + Self.reset
        statusLineShown = true
        atLineStart = false
        return Array(output.utf8)
    }

    /// `↻ HTTP 503, retry 2/5 in 3 s`, without the delay once the wait is over.
    public static func retryNote(_ retry: RetryInfo, secondsLeft: Int) -> String {
        "↻ \(retry.reason), retry \(retry.attempt)/\(retry.of)" + (secondsLeft > 0 ? " in \(secondsLeft) s" : "")
    }

    public mutating func userReply(_ reply: String) -> [UInt8] {
        text(lineStart() + "\n" + Self.bold + "› " + Self.oneLine(reply) + Self.reset + "\n\n")
    }

    public mutating func approval(command: String, reason: String) -> [UInt8] {
        text(lineStart() + Self.yellow + "⚠ Risky command (\(reason)):" + Self.reset + "\n"
            + Self.commandLines(command, prefix: "  ") + "\n"
            + Self.yellow + "  Press Return to run it, Esc to skip." + Self.reset + "\n")
    }

    public mutating func event(_ event: Agent.Event) -> [UInt8] {
        switch event {
        case .thinking, .retrying, .reasoning, .approvalRequired:
            return []
        case .text(let content):
            let cleaned = textSanitizer.clean(Data(content.utf8))
            guard !cleaned.isEmpty else { return [] }
            return output(cleaned)
        case .commandStarted(_, let command):
            sanitizer = OutputSanitizer()
            return text(lineStart() + Self.green + "$" + Self.reset + Self.bold + " "
                + Self.commandLines(command, prefix: "  ").dropFirst(2) + Self.reset + "\n")
        case .commandOutput(let data):
            return output(sanitizer.clean(data))
        case .commandFinished(_, let exitCode, let timedOut):
            var line = lineStart()
            if timedOut {
                line += Self.yellow + "↳ timed out" + Self.reset + "\n"
            } else if let exitCode, exitCode != 0 {
                line += Self.red + "↳ exit \(exitCode)" + Self.reset + "\n"
            }
            return text(line)
        case .searchStarted(_, let request):
            var line = Self.magenta + "⌕" + Self.reset + " search " + Self.oneLine(request.pattern)
            if let path = request.path { line += " in " + Self.oneLine(path) }
            if let glob = request.glob { line += " (" + Self.oneLine(glob) + ")" }
            return text(lineStart() + line + "\n")
        case .searchFinished(_, let summary):
            return text(lineStart() + Self.dim + "  " + Self.oneLine(summary) + Self.reset + "\n")
        case .toolFailed(_, let message):
            return text(lineStart() + Self.red + "✗ " + Self.oneLine(message) + Self.reset + "\n")
        case .ended(let outcome, _):
            let status = switch outcome {
            case .finished(.goalMet): Self.green + "✓ Goal met"
            case .finished(.goalNotMet): Self.red + "✗ Goal not met"
            case .finished(.needInput): Self.yellow + "? Needs input"
            case .finished(nil): Self.bold + "■ Done"
            case .stepLimit: Self.yellow + "■ Step limit reached — reply \"continue\" to go on"
            case .stopped: Self.yellow + "■ Stopped"
            case .failed(let error): Self.red + "✗ " + Self.oneLine(error.message)
            }
            return text(lineStart() + "\n" + status + Self.reset + "\n"
                + Self.dim + "Type to reply to the agent · ⌘T opens a shell here" + Self.reset + "\n")
        }
    }

    // MARK: - Output

    /// Text of our own: line feeds become CR LF, after the thinking line is cleared.
    private mutating func text(_ text: String) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        var output = statusLineShown ? Self.clearLine : ""
        statusLineShown = false
        output += text.replacingOccurrences(of: "\n", with: "\r\n")
        if let last = text.last { atLineStart = last == "\n" }
        return Array(output.utf8)
    }

    /// Cleaned command output.
    private mutating func output(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        var output = statusLineShown ? Array(Self.clearLine.utf8) : []
        statusLineShown = false
        output += bytes
        atLineStart = bytes.last == 0x0A
        return output
    }

    private mutating func lineStart() -> String {
        atLineStart ? "" : "\n"
    }

    private static func oneLine(_ text: String) -> String {
        String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F || (0x80..<0xA0).contains($0.value)
            ? " " : Character($0) })
    }

    /// A command's first lines; the continuation lines indented.
    private static func commandLines(_ command: String, prefix: String) -> String {
        let lines = command.components(separatedBy: "\n")
        var shown = lines.prefix(maxCommandLines).map { prefix + oneLine($0) }
        if lines.count > maxCommandLines { shown.append(prefix + "… (\(lines.count - maxCommandLines) more lines)") }
        return shown.joined(separator: "\n")
    }
}

/// Removes escape sequences and control characters from command output, keeping text, tabs, carriage returns
/// and line feeds (as CR LF). Sequences and UTF-8 characters split between chunks are handled.
struct OutputSanitizer {
    private enum State {
        case text, escape, csi, string, stringEscape, charset
    }

    private var state = State.text
    private var pending: [UInt8] = []

    mutating func clean(_ data: Data) -> [UInt8] {
        let bytes = pending + Array(data)
        pending = []
        // Keep an incomplete UTF-8 character for the next chunk.
        var end = bytes.count
        var back = 0
        while back < 3, end - back - 1 >= 0, bytes[end - back - 1] & 0xC0 == 0x80 { back += 1 }
        if end - back - 1 >= 0 {
            let lead = bytes[end - back - 1]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if length > back + 1 {
                pending = Array(bytes[(end - back - 1)...])
                end -= back + 1
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(end)
        for scalar in String(decoding: bytes[..<end], as: UTF8.self).unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B: state = .escape
                case 0x0A: output += [0x0D, 0x0A]
                case 0x0D, 0x09: output.append(UInt8(value))
                case 0x00..<0x20, 0x7F, 0x80..<0xA0: break
                default: output += Array(String(scalar).utf8)
                }
            case .escape:
                switch value {
                case 0x5B: state = .csi                      // [
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .string   // ] P X ^ _
                case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25: state = .charset
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(value) { state = .text }
            case .string:
                if value == 0x07 { state = .text } else if value == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = value == 0x5C ? .text : .string
            case .charset:
                state = .text
            }
        }
        return output
    }
}
