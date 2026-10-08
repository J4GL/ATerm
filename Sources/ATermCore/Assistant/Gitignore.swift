import Foundation

/// A glob over `/`-separated relative paths: `*`, `?`, `[…]`, `**` and `{a,b}`.
struct Glob {
    private let regex: NSRegularExpression
    /// Matches the whole relative path; otherwise only the last path component.
    let matchesFullPath: Bool

    init?(_ glob: String, matchesFullPath: Bool) {
        guard let regex = try? NSRegularExpression(pattern: "^" + Self.regexPattern(glob) + "$") else { return nil }
        self.regex = regex
        self.matchesFullPath = matchesFullPath
    }

    func matches(_ relativePath: String) -> Bool {
        let subject = matchesFullPath ? relativePath : (relativePath as NSString).lastPathComponent
        return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    static func regexPattern(_ glob: String) -> String {
        let characters = Array(glob)
        var pattern = ""
        var index = 0
        var braceDepth = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let atSegmentStart = index == 0 || characters[index - 1] == "/"
                    let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                    if atSegmentStart && followedBySlash {
                        pattern += "(?:.*/)?"
                        index += 3
                    } else {
                        pattern += ".*"
                        index += 2
                    }
                    continue
                }
                pattern += "[^/]*"
            case "?":
                pattern += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    pattern += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close + 1
                    continue
                }
                pattern += "\\["
            case "{":
                braceDepth += 1
                pattern += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                pattern += ")"
            case "," where braceDepth > 0:
                pattern += "|"
            case "\\":
                if index + 1 < characters.count {
                    pattern += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                    index += 2
                    continue
                }
                pattern += "\\\\"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return pattern
    }
}

/// The rules of one `.gitignore` file, applying below its directory.
struct GitignoreRules {
    struct Rule {
        let glob: Glob
        let negated: Bool
        let directoryOnly: Bool
    }

    /// The directory holding the file (absolute).
    let base: String
    let rules: [Rule]

    init(base: String, text: String) {
        self.base = base
        var rules: [Rule] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
                line.removeFirst()
            }
            var directoryOnly = false
            if line.hasSuffix("/") {
                directoryOnly = true
                line.removeLast()
            }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty, let glob = Glob(line, matchesFullPath: anchored) else { continue }
            rules.append(Rule(glob: glob, negated: negated, directoryOnly: directoryOnly))
        }
        self.rules = rules
    }

    static func load(directory: String) -> GitignoreRules? {
        let file = (directory as NSString).appendingPathComponent(".gitignore")
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        let rules = GitignoreRules(base: directory, text: String(decoding: data, as: UTF8.self))
        return rules.rules.isEmpty ? nil : rules
    }

    /// Whether this file decides about `path` (absolute): true = ignored, false = re-included, nil = no rule.
    func decision(for path: String, isDirectory: Bool) -> Bool? {
        guard path.hasPrefix(base + "/") else { return nil }
        let relative = String(path.dropFirst(base.count + 1))
        var result: Bool?
        for rule in rules where (!rule.directoryOnly || isDirectory) && rule.glob.matches(relative) {
            result = !rule.negated
        }
        return result
    }

    /// True when the last rule matching `path` among `stack` (outermost first) ignores it.
    static func isIgnored(_ path: String, isDirectory: Bool, by stack: [GitignoreRules]) -> Bool {
        var ignored = false
        for rules in stack {
            if let decision = rules.decision(for: path, isDirectory: isDirectory) { ignored = decision }
        }
        return ignored
    }
}

/// The `glob` argument of `search`: globs separated by spaces, `!` excluding.
struct GlobFilter {
    private var included: [Glob] = []
    private var excluded: [Glob] = []

    init(_ text: String?) {
        for word in (text ?? "").split(whereSeparator: \.isWhitespace).map(String.init) {
            let negated = word.hasPrefix("!")
            let glob = negated ? String(word.dropFirst()) : word
            guard !glob.isEmpty, let compiled = Glob(glob, matchesFullPath: glob.contains("/")) else { continue }
            if negated { excluded.append(compiled) } else { included.append(compiled) }
        }
    }

    func accepts(_ relativePath: String) -> Bool {
        if excluded.contains(where: { $0.matches(relativePath) }) { return false }
        return included.isEmpty || included.contains { $0.matches(relativePath) }
    }

    /// A directory whose subtree is excluded as a whole.
    func excludesDirectory(_ relativePath: String) -> Bool {
        excluded.contains { $0.matches(relativePath) }
    }
}
