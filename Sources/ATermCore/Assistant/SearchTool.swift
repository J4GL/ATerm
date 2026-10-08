import Foundation

/// The arguments of the `search` tool. See SPEC/assistant/contract.md.
public struct SearchRequest: Sendable, Equatable {
    public var pattern: String
    public var path: String?
    public var glob: String?
    public var ignoreCase: Bool
    public var literal: Bool
    public var context: Int
    public var limit: Int

    public init(pattern: String, path: String? = nil, glob: String? = nil, ignoreCase: Bool = false,
                literal: Bool = false, context: Int = 0, limit: Int = SearchTool.defaultLimit) {
        self.pattern = pattern
        self.path = path
        self.glob = glob
        self.ignoreCase = ignoreCase
        self.literal = literal
        self.context = context
        self.limit = limit
    }
}

/// A ripgrep-like content search: `.gitignore` files respected, `.git` and binary files skipped, hidden files
/// searched, results sorted by path. See SPEC/assistant/search-tool.md.
public enum SearchTool {
    public static let defaultLimit = 100
    public static let maxLimit = 1000
    public static let maxContext = 10
    public static let maxLineLength = 500
    public static let maxOutputBytes = 24 * 1024
    static let binaryProbeLength = 8192

    /// `redact` is applied to each line before it is cut, so a secret is never split in two.
    public static func run(_ request: SearchRequest, workingDirectory: String,
                           redact: (String) -> String = { $0 }) -> String {
        let pattern = request.literal ? NSRegularExpression.escapedPattern(for: request.pattern) : request.pattern
        guard !request.pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: request.ignoreCase ? [.caseInsensitive] : [])
        else {
            return "Error: invalid regular expression: " + request.pattern.replacingOccurrences(of: "\n", with: " ")
        }
        let given = request.path.flatMap { $0.isEmpty ? nil : $0 }
        let root = given.map { resolve($0, in: workingDirectory) } ?? workingDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            return "Error: no such file or directory: \(given ?? root)"
        }
        let limit = min(max(1, request.limit), maxLimit)
        let context = min(max(0, request.context), maxContext)

        let files: [(path: String, display: String)]
        if isDirectory.boolValue {
            let prefix = given.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            files = collectFiles(root: root, filter: GlobFilter(request.glob)).map { relative in
                (root + "/" + relative, prefix.map { $0 + "/" + relative } ?? relative)
            }
        } else {
            files = [(root, given ?? root)]
        }

        var output: [String] = []
        var outputBytes = 0
        var matchCount = 0
        var limitReached = false
        var sizeReached = false
        for file in files {
            guard let lines = textLines(of: file.path) else { continue }
            var matches: [Int] = []
            for (index, line) in lines.enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                matches.append(index)
                matchCount += 1
                if matchCount == limit {
                    limitReached = true
                    break
                }
            }
            guard !matches.isEmpty else { continue }
            func append(_ line: String) {
                outputBytes += line.utf8.count + 1
                if outputBytes > maxOutputBytes { sizeReached = true } else { output.append(line) }
            }
            if context > 0 && !output.isEmpty { append("--") }
            var lastPrinted = -1
            for match in matches where !sizeReached {
                let first = max(0, match - context, lastPrinted + 1)
                if context > 0 && lastPrinted >= 0 && first > lastPrinted + 1 { append("--") }
                for index in first...min(lines.count - 1, match + context) where index > lastPrinted && !sizeReached {
                    let separator = matches.contains(index) ? ":" : "-"
                    append(file.display + separator + String(index + 1) + separator + cut(redact(bounded(lines[index]))))
                    lastPrinted = index
                }
            }
            if limitReached || sizeReached { break }
        }
        if output.isEmpty && !sizeReached { return "No matches found." }
        if sizeReached {
            output.append("[Output limit of 24 KiB reached. Use path, glob or a narrower pattern]")
        } else if limitReached {
            output.append("[\(limit) matches limit reached. Use limit=\(limit * 2) for more, or refine the pattern]")
        }
        return output.joined(separator: "\n")
    }

    static func resolve(_ path: String, in directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    /// Lines are bounded before redaction, to bound its cost.
    private static func bounded(_ line: String) -> String {
        line.count > 4096 ? String(line.prefix(4096)) : line
    }

    private static func cut(_ line: String) -> String {
        SecretRedactor.truncate(line, to: maxLineLength)
    }

    /// The lines of a text file; nil for a binary or unreadable file.
    private static func textLines(of path: String) -> [String]? {
        guard let data = FileManager.default.contents(atPath: path),
              !data.prefix(binaryProbeLength).contains(0)
        else { return nil }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    // MARK: - Walking the tree

    /// Relative paths of the files to search below `root`, sorted.
    private static func collectFiles(root: String, filter: GlobFilter) -> [String] {
        var stack = parentRules(of: root)
        var files: [String] = []
        walk(root, relative: "", rules: &stack, filter: filter, files: &files)
        return files.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// `.gitignore` files from the enclosing git work tree's root down to `root` (exclusive).
    private static func parentRules(of root: String) -> [GitignoreRules] {
        var ancestors: [String] = []
        var current = root
        while !current.isEmpty {
            if current != root { ancestors.append(current) }
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return ancestors.reversed().compactMap { GitignoreRules.load(directory: $0) }
            }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return []
    }

    private static func walk(_ directory: String, relative: String, rules: inout [GitignoreRules],
                             filter: GlobFilter, files: inout [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let pushed = GitignoreRules.load(directory: directory)
        if let pushed { rules.append(pushed) }
        defer { if pushed != nil { rules.removeLast() } }
        for name in names where name != ".git" {
            let path = directory + "/" + name
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                guard !GitignoreRules.isIgnored(path, isDirectory: true, by: rules),
                      !filter.excludesDirectory(childRelative)
                else { continue }
                walk(path, relative: childRelative, rules: &rules, filter: filter, files: &files)
            } else if type == S_IFREG {
                guard !GitignoreRules.isIgnored(path, isDirectory: false, by: rules), filter.accepts(childRelative)
                else { continue }
                files.append(childRelative)
            }
        }
    }
}
