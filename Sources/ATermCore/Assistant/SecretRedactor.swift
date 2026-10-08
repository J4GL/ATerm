import Foundation

/// Replaces secrets by stable placeholders in every text sent to the model, and restores them in commands
/// just before they run. One redactor holds the placeholders of one conversation. See SPEC/assistant/redaction.md.
public final class SecretRedactor: @unchecked Sendable {
    /// A command ready to run: values that are not shell-safe are passed as variables.
    public struct ShellCommand: Equatable, Sendable {
        public var command: String
        public var environment: [String: String]
        /// Why the command cannot run as written (it is then returned to the model instead).
        public var problem: String?
    }

    private let lock = NSLock()
    /// Known values and their variants, longest first.
    private let knownValues: [(value: String, name: String)]
    private var placeholderForValue: [String: String] = [:]
    /// `NAME_N` → value.
    private var vault: [String: String] = [:]
    private var count = 0

    public init(knownSecrets: [KnownSecret]) {
        var values: [(String, String)] = []
        var seen = Set<String>()
        func add(_ value: String, _ name: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            values.append((value, name))
        }
        for secret in knownSecrets {
            add(secret.value, secret.name)
        }
        for secret in knownSecrets {
            let encoded = secret.value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? secret.value
            if encoded != secret.value { add(encoded, secret.name + "_URL") }
            add(Data(secret.value.utf8).base64EncodedString(), secret.name + "_BASE64")
        }
        knownValues = values.sorted { $0.0.count > $1.0.count }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Redaction

    private struct Claim {
        let range: Range<String.Index>
        let name: String
    }

    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var claims: [Claim] = []
        func claim(_ range: Range<String.Index>, _ name: String) {
            guard !range.isEmpty, !claims.contains(where: { $0.range.overlaps(range) }) else { return }
            claims.append(Claim(range: range, name: name))
        }
        // Values masked earlier in the conversation, then the known ones.
        let seen = lock.withLock { placeholderForValue.keys.sorted { $0.count > $1.count } }
        for value in seen {
            var searchStart = text.startIndex
            while let found = text.range(of: value, range: searchStart..<text.endIndex) {
                claim(found, "SECRET")
                searchStart = found.upperBound
            }
        }
        for (value, name) in knownValues {
            var searchStart = text.startIndex
            while let found = text.range(of: value, range: searchStart..<text.endIndex) {
                claim(found, name)
                searchStart = found.upperBound
            }
        }
        let whole = NSRange(text.startIndex..., in: text)
        for format in Self.formats {
            for match in format.pattern.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text) { claim(range, format.name) }
            }
        }
        for context in Self.contexts {
            for match in context.pattern.matches(in: text, range: whole) {
                guard let range = Range(match.range(at: context.valueGroup), in: text) else { continue }
                let value = text[range]
                guard value.count >= 4, !Self.looksLikeCode(value) else { continue }
                let name = context.nameGroup.flatMap { Range(match.range(at: $0), in: text) }
                    .map { String(text[$0]) } ?? context.name
                claim(range, name)
            }
        }
        guard !claims.isEmpty else { return text }
        claims.sort { $0.range.lowerBound < $1.range.lowerBound }
        return lock.withLock {
            var result = ""
            var position = text.startIndex
            for claim in claims {
                result += text[position..<claim.range.lowerBound]
                result += placeholder(for: String(text[claim.range]), name: claim.name)
                position = claim.range.upperBound
            }
            result += text[position...]
            return result
        }
    }

    /// Called with the lock held.
    private func placeholder(for value: String, name: String) -> String {
        if let existing = placeholderForValue[value] { return existing }
        count += 1
        let key = "\(Self.normalizedName(name))_\(count)"
        let placeholder = "<\(key):\(value.count)chars>"
        placeholderForValue[value] = placeholder
        vault[key] = value
        return placeholder
    }

    static func normalizedName(_ name: String) -> String {
        var result = ""
        for scalar in name.uppercased().unicodeScalars {
            let isAlphanumeric = (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            if isAlphanumeric {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("_") {
                result += "_"
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "SECRET" : trimmed
    }

    /// Values written as code rather than literally: a variable, an expression or a type name.
    private static func looksLikeCode(_ value: Substring) -> Bool {
        if value.hasPrefix("$") || value.hasPrefix("{") || value.hasPrefix("<") || value.hasPrefix("%") { return true }
        if value.contains("(") || value.contains("[") || value.contains("{") { return true }
        if value.hasPrefix("os.") || value.hasPrefix("process.") || value.hasPrefix("ENV") { return true }
        return codeWords.contains(value.lowercased())
    }

    private static let codeWords: Set<String> = ["none", "null", "nil", "true", "false", "undefined", "string", "str",
                                                 "bool", "boolean", "number", "int", "integer", "any", "object",
                                                 "required", "optional", "secret", "password", "changeme", "xxxxxxxx"]

    private struct Format {
        let pattern: NSRegularExpression
        let name: String
    }

    private static let formats: [Format] = [
        format(#"sk-or-v1-[0-9a-f]{64}"#, "OPENROUTER_KEY"),
        format(#"\bsk-[A-Za-z0-9_-]{20,}"#, "API_KEY"),
        format(#"\bgh[pousr]_[A-Za-z0-9]{36,}"#, "GITHUB_TOKEN"),
        format(#"\bgithub_pat_[A-Za-z0-9_]{22,}"#, "GITHUB_TOKEN"),
        format(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "AWS_ACCESS_KEY_ID"),
        format(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "SLACK_TOKEN"),
        format(#"\bglpat-[A-Za-z0-9_-]{20,}"#, "GITLAB_TOKEN"),
        format(#"\bAIza[0-9A-Za-z_-]{35}"#, "GOOGLE_API_KEY"),
        format(#"\bya29\.[0-9A-Za-z_-]{20,}"#, "GOOGLE_OAUTH_TOKEN"),
        format(#"\bnpm_[A-Za-z0-9]{36}"#, "NPM_TOKEN"),
        format(#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "JWT"),
        format(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#, "PRIVATE_KEY"),
    ]

    private struct Context {
        let pattern: NSRegularExpression
        let valueGroup: Int
        let nameGroup: Int?
        let name: String
    }

    private static let contexts: [Context] = [
        context(#"(?i)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|ACCESS_?KEY))\b\s*["']?\s*[:=]\s*(["']?)([^\s"'`,;]+)"#,
                value: 3, nameGroup: 1, "SECRET"),
        context(#"(?i)--(api-?key|token|password|secret|auth-token|access-token)[= ]([^\s"']+)"#,
                value: 2, nameGroup: 1, "SECRET"),
        context(#"(?i)\bauthorization:\s*(?:bearer|basic|token)\s+([A-Za-z0-9._~+/=-]{8,})"#,
                value: 1, nameGroup: nil, "AUTH_TOKEN"),
        context(#"\bmysql\b[^\n]*?\s-p([^\s-][^\s]*)"#, value: 1, nameGroup: nil, "PASSWORD"),
        context(#"\bsshpass\s+-p\s*(\S+)"#, value: 1, nameGroup: nil, "PASSWORD"),
        context(#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s:/@]+:([^\s@/]+)@"#, value: 1, nameGroup: nil, "PASSWORD"),
    ]

    private static func format(_ pattern: String, _ name: String) -> Format {
        Format(pattern: try! NSRegularExpression(pattern: pattern), name: name)
    }

    private static func context(_ pattern: String, value: Int, nameGroup: Int?, _ name: String) -> Context {
        Context(pattern: try! NSRegularExpression(pattern: pattern), valueGroup: value, nameGroup: nameGroup, name: name)
    }

    // MARK: - Restoration

    private static let placeholderPattern = try! NSRegularExpression(pattern: #"<([A-Z0-9_]+)_(\d+)(?::\d+chars)?>"#)
    private static let shellSafe = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.,:@%+=/~-]+$"#)

    private struct Found {
        let range: Range<String.Index>
        let number: String
        let value: String
    }

    private func placeholders(in text: String) -> [Found] {
        let matches = Self.placeholderPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return lock.withLock {
            matches.compactMap { match in
                guard let range = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text),
                      let number = Range(match.range(at: 2), in: text),
                      let value = vault["\(text[name])_\(text[number])"]
                else { return nil }
                return Found(range: range, number: String(text[number]), value: value)
            }
        }
    }

    /// `line` cut to `length` characters followed by `... [truncated]`, never inside a placeholder.
    public static func truncate(_ line: String, to length: Int) -> String {
        guard line.count > length else { return line }
        var end = line.index(line.startIndex, offsetBy: length)
        for match in placeholderPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            if range.lowerBound < end && end < range.upperBound { end = range.upperBound }
        }
        return end == line.endIndex ? line : String(line[..<end]) + "... [truncated]"
    }

    static func isShellSafe(_ value: String) -> Bool {
        shellSafe.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Restores placeholders in a shell command: shell-safe values inline, others as `${ATERM_SECRET_N}` passed
    /// in the environment (closing single quotes around it). Inside a quoted heredoc a variable would be written
    /// literally: the command is refused with a problem for the model.
    public func restoreForShell(_ command: String) -> ShellCommand {
        var result = command
        var environment: [String: String] = [:]
        var problem: String?
        let found = placeholders(in: command)
        let contexts = ShellQuoting.contexts(of: command, at: found.map(\.range.lowerBound))
        for (found, context) in zip(found, contexts).reversed() {
            if Self.isShellSafe(found.value) {
                result.replaceSubrange(found.range, with: found.value)
                continue
            }
            let variable = "ATERM_SECRET_\(found.number)"
            environment[variable] = found.value
            switch context {
            case .plain: result.replaceSubrange(found.range, with: "\"${\(variable)}\"")
            case .doubleQuoted: result.replaceSubrange(found.range, with: "${\(variable)}")
            case .singleQuoted: result.replaceSubrange(found.range, with: "'\"${\(variable)}\"'")
            case .quotedHeredoc:
                problem = "Error: a secret with special characters cannot be written inside a quoted heredoc (it "
                    + "would be written literally). Use an unquoted heredoc, or printf '%s' \"<placeholder>\" > file."
            }
        }
        return ShellCommand(command: result, environment: environment, problem: problem)
    }

    /// Restores placeholders as plain text; tells whether a value that is not shell-safe was restored.
    public func restorePlain(_ text: String) -> (text: String, restoredUnsafeValue: Bool) {
        var result = text
        var unsafe = false
        for found in placeholders(in: text).reversed() {
            result.replaceSubrange(found.range, with: found.value)
            if !Self.isShellSafe(found.value) { unsafe = true }
        }
        return (result, unsafe)
    }
}

/// Where a position of a shell command stands: plain, inside quotes, or in the body of a quoted heredoc.
enum ShellQuoting {
    enum Context: Equatable {
        case plain, singleQuoted, doubleQuoted, quotedHeredoc
    }

    static func contexts(of command: String, at positions: [String.Index]) -> [Context] {
        var result: [String.Index: Context] = [:]
        var wanted = Set(positions)
        var state = Context.plain
        var pendingHeredocs: [(delimiter: String, quoted: Bool)] = []
        var heredoc: (delimiter: String, quoted: Bool)?
        var index = command.startIndex
        while index < command.endIndex, !wanted.isEmpty {
            if let body = heredoc {
                // Inside a heredoc body, line by line until the delimiter line.
                let lineEnd = command[index...].firstIndex(of: "\n") ?? command.endIndex
                for position in wanted where position >= index && position < lineEnd {
                    result[position] = body.quoted ? .quotedHeredoc : .plain
                    wanted.remove(position)
                }
                if command[index..<lineEnd].trimmingCharacters(in: .whitespaces) == body.delimiter {
                    heredoc = pendingHeredocs.isEmpty ? nil : pendingHeredocs.removeFirst()
                }
                index = lineEnd < command.endIndex ? command.index(after: lineEnd) : lineEnd
                continue
            }
            if wanted.contains(index) {
                result[index] = state
                wanted.remove(index)
            }
            let character = command[index]
            switch (state, character) {
            case (.plain, "\\"), (.doubleQuoted, "\\"):
                index = command.index(after: index)
                if index < command.endIndex { index = command.index(after: index) }
                continue
            case (.plain, "'"): state = .singleQuoted
            case (.singleQuoted, "'"): state = .plain
            case (.plain, "\""): state = .doubleQuoted
            case (.doubleQuoted, "\""): state = .plain
            case (.plain, "<"):
                let rest = command[index...]
                if rest.hasPrefix("<<"), !rest.hasPrefix("<<<"),
                   let match = rest.firstMatch(of: /^<<-?\s*(['"\\]?)([A-Za-z0-9_]+)['"]?/) {
                    pendingHeredocs.append((String(match.2), !match.1.isEmpty))
                    index = match.range.upperBound
                    continue
                }
            case (.plain, "\n"):
                if !pendingHeredocs.isEmpty { heredoc = pendingHeredocs.removeFirst() }
            default: break
            }
            index = command.index(after: index)
        }
        return positions.map { result[$0] ?? state }
    }
}
