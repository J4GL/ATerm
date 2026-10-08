import Darwin
import Foundation

/// What the model is told about where it runs. See SPEC/assistant/contract.md (Environment block).
public struct EnvironmentSnapshot: Sendable, Equatable {
    public var osVersion: String
    public var architecture: String
    public var hostName: String
    public var userName: String
    public var fullName: String
    public var home: String
    public var loginShell: String
    /// The bash running the agent's commands, with its version.
    public var bash: String
    public var locale: String
    public var languages: [String]
    public var date: Date
    public var timeZone: TimeZone
    public var workingDirectory: String
    public var gitRoot: String?
    public var gitBranch: String?
    public var entries: [String]
    public var tools: [String]
    public var terminalColumns: Int
    public var terminalRows: Int
    public var foregroundProgram: String?
    public var recentOutput: [String]

    public init(osVersion: String, architecture: String, hostName: String, userName: String, fullName: String,
                home: String, loginShell: String, bash: String, locale: String, languages: [String], date: Date,
                timeZone: TimeZone, workingDirectory: String, gitRoot: String?, gitBranch: String?, entries: [String],
                tools: [String], terminalColumns: Int, terminalRows: Int, foregroundProgram: String?,
                recentOutput: [String]) {
        self.osVersion = osVersion
        self.architecture = architecture
        self.hostName = hostName
        self.userName = userName
        self.fullName = fullName
        self.home = home
        self.loginShell = loginShell
        self.bash = bash
        self.locale = locale
        self.languages = languages
        self.date = date
        self.timeZone = timeZone
        self.workingDirectory = workingDirectory
        self.gitRoot = gitRoot
        self.gitBranch = gitBranch
        self.entries = entries
        self.tools = tools
        self.terminalColumns = terminalColumns
        self.terminalRows = terminalRows
        self.foregroundProgram = foregroundProgram
        self.recentOutput = recentOutput
    }
}

/// Builds the environment block and the project instructions. See SPEC/assistant/context.md.
public enum EnvironmentContext {
    public static let recentLineCount = 50
    public static let maxEntries = 60
    public static let maxInstructionBytes = 32 * 1024
    /// Tools worth mentioning when they are on the PATH.
    static let knownTools = ["git", "brew", "python3", "pip3", "uv", "node", "npm", "npx", "pnpm", "yarn", "bun", "deno",
                             "ruby", "gem", "bundle", "go", "cargo", "rustc", "swift", "xcodebuild", "java", "mvn",
                             "gradle", "php", "composer", "docker", "kubectl", "terraform", "make", "cmake", "curl",
                             "wget", "jq", "rg", "fd", "gh", "psql", "mysql", "sqlite3", "redis-cli", "nginx", "ssh",
                             "rsync"]

    public static func render(_ snapshot: EnvironmentSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = snapshot.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        var lines = [
            "<environment>",
            "os: \(snapshot.osVersion), \(snapshot.architecture)",
            "host: \(snapshot.hostName)",
            "user: \(snapshot.userName) (\(snapshot.fullName)), home \(snapshot.home)",
            "shell: \(snapshot.loginShell); commands run with \(snapshot.bash)",
            "locale: \(snapshot.locale); languages: \(snapshot.languages.joined(separator: ", "))",
            "date: \(formatter.string(from: snapshot.date)) (\(snapshot.timeZone.identifier))",
            "cwd: \(snapshot.workingDirectory)",
        ]
        if let root = snapshot.gitRoot {
            lines.append("git: \(root)" + (snapshot.gitBranch.map { " on branch \($0)" } ?? ""))
        }
        lines.append("entries: \(snapshot.entries.joined(separator: ", "))")
        lines.append("tools: \(snapshot.tools.joined(separator: ", "))")
        lines.append("terminal: \(snapshot.terminalColumns)x\(snapshot.terminalRows)"
            + (snapshot.foregroundProgram.map { ", running \($0)" } ?? ""))
        lines.append("</environment>")
        lines.append("<recent_terminal_output>")
        lines += snapshot.recentOutput
        lines.append("</recent_terminal_output>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Recent output

    /// The last logical lines up to the cursor (the visible screen on the alternate screen), without trailing
    /// empty lines.
    public static func recentLines(of terminal: Terminal, count: Int = recentLineCount) -> [String] {
        var lines: [String]
        if terminal.isAlternateScreenActive {
            lines = terminal.screenLines
        } else {
            lines = []
            let first = terminal.linesDropped
            var index = terminal.firstScreenLineIndex + terminal.cursorPosition.row
            while index >= first, lines.count < count {
                var start = index
                while start > first, terminal.line(absolute: start - 1)?.isWrapped == true { start -= 1 }
                var text = ""
                for row in start...index {
                    guard let line = terminal.line(absolute: row) else { continue }
                    text += line.text(from: 0, to: line.cells.count, trimmingTrailingSpaces: row == index)
                }
                lines.insert(text, at: 0)
                index = start - 1
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    // MARK: - Project instructions

    /// AGENTS.md (else CLAUDE.md) of each directory from the git root down to `workingDirectory`, capped.
    public static func projectInstructions(workingDirectory: String, maxBytes: Int = maxInstructionBytes) -> String {
        let directories = gitRoot(of: workingDirectory).map { directoryChain(from: $0, to: workingDirectory) }
            ?? [workingDirectory]
        var blocks: [String] = []
        var budget = maxBytes
        for directory in directories {
            guard budget > 0 else { break }
            let candidates = ["AGENTS.md", "CLAUDE.md"].map { (directory as NSString).appendingPathComponent($0) }
            guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  let data = FileManager.default.contents(atPath: file)
            else { continue }
            var text = String(decoding: data, as: UTF8.self)
            while text.hasSuffix("\n") { text.removeLast() }
            if text.utf8.count > budget {
                text = String(decoding: Array(text.utf8.prefix(budget)), as: UTF8.self) + "\n[truncated]"
                budget = 0
            } else {
                budget -= text.utf8.count
            }
            blocks.append("<project_instructions path=\"\(file)\">\n\(text)\n</project_instructions>")
        }
        return blocks.joined(separator: "\n")
    }

    /// The directory holding `.git` at or above `directory`.
    public static func gitRoot(of directory: String) -> String? {
        var current = directory
        while !current.isEmpty {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func directoryChain(from root: String, to directory: String) -> [String] {
        var chain: [String] = []
        var current = directory
        while current.count >= root.count {
            chain.insert(current, at: 0)
            if current == root || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return chain
    }

    // MARK: - Live values

    /// The current branch, or the short commit of a detached head.
    public static func gitBranch(root: String) -> String? {
        var gitDirectory = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitDirectory, isDirectory: &isDirectory), !isDirectory.boolValue,
           let link = try? String(contentsOfFile: gitDirectory, encoding: .utf8), link.hasPrefix("gitdir: ") {
            let target = link.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = target.hasPrefix("/") ? target : (root as NSString).appendingPathComponent(target)
        }
        guard let head = try? String(contentsOfFile: (gitDirectory as NSString).appendingPathComponent("HEAD"),
                                     encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(12))
    }

    /// Sorted entries, directories ending with `/`, at most `limit` then `… (N more)`.
    public static func directoryEntries(_ directory: String, limit: Int = maxEntries) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var entries = names.prefix(limit).map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(name),
                                           isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        if names.count > limit { entries.append("… (\(names.count - limit) more)") }
        return entries
    }

    /// The known tools found on `path`.
    public static func availableTools(path: String) -> [String] {
        let directories = path.split(separator: ":").map(String.init)
        return knownTools.filter { tool in
            directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + tool) }
        }
    }

    /// Everything but the terminal state, read from the running system.
    public static func snapshot(workingDirectory: String, environment: [String: String], loginShell: String,
                                bash: String, terminalColumns: Int, terminalRows: Int, foregroundProgram: String?,
                                recentOutput: [String], date: Date = Date()) -> EnvironmentSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var versionText = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { versionText += ".\(version.patchVersion)" }
        let root = gitRoot(of: workingDirectory)
        return EnvironmentSnapshot(
            osVersion: "macOS \(versionText) (\(sysctlString("kern.osversion") ?? "?"))",
            architecture: machine(), hostName: hostName(), userName: NSUserName(), fullName: NSFullUserName(),
            home: NSHomeDirectory(), loginShell: loginShell, bash: bash, locale: Locale.current.identifier,
            languages: Locale.preferredLanguages, date: date, timeZone: .current, workingDirectory: workingDirectory,
            gitRoot: root, gitBranch: root.flatMap(gitBranch(root:)), entries: directoryEntries(workingDirectory),
            tools: availableTools(path: environment["PATH"] ?? ""), terminalColumns: terminalColumns,
            terminalRows: terminalRows, foregroundProgram: foregroundProgram, recentOutput: recentOutput)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
