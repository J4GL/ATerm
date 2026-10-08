import Foundation

/// The environment of the user's login shell (its `PATH` with Homebrew, nvm, pyenv…), which an app started
/// from the Finder does not inherit. See SPEC/assistant/context.md.
public enum LoginEnvironment {
    static let marker = "__ATERM_ENVIRONMENT__"

    /// Runs `shell -i -l -c` to print its environment; nil when it fails or takes longer than `timeout`.
    public static func resolve(shell: String, base: [String: String], timeout: TimeInterval = 5) async
        -> [String: String]? {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("aterm-env-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let outputFile = (directory as NSString).appendingPathComponent("environment")
        let command = "printf '\\n%s\\n' \(marker); /usr/bin/env -0; printf '%s' \(marker)"
        let name = (shell as NSString).lastPathComponent
        guard await CommandRunner.runProcess(shell, arguments: [name, "-i", "-l", "-c", command], environment: base,
                                             outputFile: outputFile, timeout: timeout) == 0,
              let data = FileManager.default.contents(atPath: outputFile)
        else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [String: String]? {
        guard let start = output.range(of: marker + "\n"),
              let end = output.range(of: marker, options: .backwards, range: start.upperBound..<output.endIndex)
        else { return nil }
        var environment: [String: String] = [:]
        for entry in output[start.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }

    /// The app's environment with the usual tool directories added to `PATH`, when the login shell fails.
    public static func fallback(base: [String: String]) -> [String: String] {
        var environment = base
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let home = base["HOME"] ?? NSHomeDirectory()
        for directory in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home + "/.local/bin"].reversed()
        where !path.contains(directory) && FileManager.default.fileExists(atPath: directory) {
            path.insert(directory, at: 0)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}

/// Resolves the login environment once per launch, and describes the bash the agent uses.
public actor LoginEnvironmentCache {
    public static let shared = LoginEnvironmentCache()

    private var environmentTask: Task<[String: String], Never>?
    private var bashDescriptions: [String: String] = [:]

    public func environment() async -> [String: String] {
        if let environmentTask { return await environmentTask.value }
        let base = ProcessInfo.processInfo.environment
        let shell = LoginShell.command(environment: base, accountShell: LoginShell.accountShell()).executable
        let task = Task { await LoginEnvironment.resolve(shell: shell, base: base) ?? LoginEnvironment.fallback(base: base) }
        environmentTask = task
        return await task.value
    }

    /// The bash found on the environment's PATH, with its version (`/bin/bash 3.2.57(1)-release`).
    public func bashDescription(environment: [String: String]) async -> String {
        let path = CommandRunner.bashPath(environment: environment)
        if let known = bashDescriptions[path] { return known }
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("aterm-bash-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let output = (directory as NSString).appendingPathComponent("version")
        var description = path
        if await CommandRunner.runProcess(path, arguments: ["bash", "-c", "printf %s \"$BASH_VERSION\""],
                                          environment: environment, outputFile: output, timeout: 3) == 0,
           let data = FileManager.default.contents(atPath: output), !data.isEmpty {
            description += " " + String(decoding: data, as: UTF8.self)
        }
        bashDescriptions[path] = description
        return description
    }
}
