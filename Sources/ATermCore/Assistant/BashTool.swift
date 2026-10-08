import Foundation

/// Turns a `bash` call into the text the model reads: status lines, then the output cleaned of escape
/// sequences, redacted and cut to its first and last lines. See SPEC/assistant/bash-tool.md.
public enum BashTool {
    public static let maxLines = 400
    public static let maxBytes = 24 * 1024
    public static let headLines = 100
    public static let headBytes = 8 * 1024
    public static let tailLines = 300
    public static let tailBytes = 16 * 1024
    public static let maxLineLength = 500
    /// Lines are cut to this length before redaction, to bound its cost.
    static let redactedLineLength = 4096
    /// Output files larger than this are read partially.
    static let fullReadLimit = 8 << 20

    public static let withheldText = "[output withheld: prints secrets]"

    public static func result(for run: CommandRun, output: Data, command: String, redactor: SecretRedactor) -> String {
        var lines: [String] = []
        if run.timedOut {
            lines.append("Timed out after \(Int(run.timeout)) s; the process group was killed")
        } else if let code = run.exitCode {
            lines.append("Exit code: \(code)")
        } else {
            lines.append("Stopped")
        }
        lines.append("Wall time: " + String(format: "%.1f", run.duration) + " s")
        if run.directoryChanged { lines.append("Working directory: \(run.workingDirectory)") }
        if let notice = run.notice { lines.append(notice) }
        lines.append("Output:")
        let text = withholdsOutput(of: command)
            ? withheldText
            : modelText(output, outputFile: run.outputFile, redactor: redactor)
        return (lines + [text]).joined(separator: "\n")
    }

    /// The content of an output file, or its beginning and end when it is very large.
    public static func readOutput(_ path: String) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(fullReadLimit) else { return handle.readDataToEndOfFile() }
        let head = handle.readData(ofLength: 1 << 20)
        try? handle.seek(toOffset: size - UInt64(4 << 20))
        let tail = handle.readDataToEndOfFile()
        let skipped = size - UInt64(head.count + tail.count)
        return head + Data("\n[... \(skipped) bytes not read ...]\n".utf8) + tail
    }

    // MARK: - Output

    static func modelText(_ output: Data, outputFile: String, redactor: SecretRedactor) -> String {
        let cleaned = cleanLines(output).map { $0.count > redactedLineLength ? String($0.prefix(redactedLineLength)) : $0 }
        guard !cleaned.isEmpty else { return "(no output)" }
        // Redacted as a whole first: a secret spanning lines (a private key) is never split by the cut.
        let lines = redactor.redact(cleaned.joined(separator: "\n")).components(separatedBy: "\n")
        let total = lines.count
        let bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        guard total > maxLines || bytes > maxBytes else {
            return prepared(lines).joined(separator: "\n")
        }
        let headCount = min(headLines, total)
        let tailCount = min(tailLines, total - headCount)
        let head = within(prepared(Array(lines.prefix(headCount))), bytes: headBytes, fromStart: true)
        let tail = within(prepared(Array(lines.suffix(tailCount))), bytes: tailBytes, fromStart: false)
        let notice = "[Showing lines 1-\(head.count) and \(total - tail.count + 1)-\(total) of \(total). "
            + "Full output: \(outputFile)]"
        return (head + [notice] + tail).joined(separator: "\n")
    }

    /// Cut to `maxLineLength`.
    private static func prepared(_ lines: [String]) -> [String] {
        lines.map { SecretRedactor.truncate($0, to: maxLineLength) }
    }

    /// The most lines, from the start or from the end, that fit in `bytes`.
    private static func within(_ lines: [String], bytes: Int, fromStart: Bool) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in fromStart ? lines : lines.reversed() {
            used += line.utf8.count + 1
            if used > bytes { break }
            kept.append(line)
        }
        return fromStart ? kept : kept.reversed()
    }

    /// Lines of text without escape sequences or control characters; a line overwritten through carriage
    /// returns keeps its last state; trailing empty lines are dropped.
    static func cleanLines(_ output: Data) -> [String] {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var scalars = String(decoding: output, as: UTF8.self).unicodeScalars.makeIterator()
        func finishLine() {
            var text = String(line)
            if let lastReturn = text.lastIndex(of: "\r") {
                text = String(text[text.index(after: lastReturn)...])
            }
            lines.append(text)
            line = String.UnicodeScalarView()
        }
        while let scalar = scalars.next() {
            switch scalar.value {
            case 0x0A:
                if line.last == "\r" { line.removeLast() }
                finishLine()
            case 0x0D, 0x09:
                line.append(scalar)
            case 0x08:
                if !line.isEmpty { line.removeLast() }
            case 0x1B:
                skipEscapeSequence(&scalars)
            case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                break
            default:
                line.append(scalar)
            }
        }
        if !line.isEmpty { finishLine() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func skipEscapeSequence(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let introducer = scalars.next() else { return }
        switch introducer {
        case "[":
            while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
        case "]", "P", "X", "^", "_":
            var previous: Unicode.Scalar?
            while let next = scalars.next() {
                if next.value == 0x07 || (previous?.value == 0x1B && next == "\\") { break }
                previous = next
            }
        case "(", ")", "*", "+", "#", "%":
            _ = scalars.next()
        default:
            break
        }
    }

    // MARK: - Secret-printing commands

    private static let withheldCommands: [NSRegularExpression] = [
        #"\bsecurity\b[^;&|\n]*\bfind-(generic|internet)-password\b[^;&|\n]*\s-[a-zA-Z]*[wg]\b"#,
        #"\bgh\s+auth\s+token\b"#,
        #"\bgcloud\b[^;&|\n]*\bauth\s+(application-default\s+)?print-(access|identity)-token\b"#,
        #"\baws\s+configure\s+export-credentials\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Commands whose whole output is a secret: it is not shown to the model at all.
    public static func withholdsOutput(of command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return withheldCommands.contains { $0.firstMatch(in: command, range: range) != nil }
    }
}
