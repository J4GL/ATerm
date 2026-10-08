import CPTY
import Darwin
import Foundation

/// What happened to one `bash` call.
public struct CommandRun: Sendable, Equatable {
    /// The exit code, or 128 + the signal number; nil when the run timed out or was cancelled.
    public var exitCode: Int32?
    public var timedOut: Bool
    public var cancelled: Bool
    public var timeout: TimeInterval
    public var duration: TimeInterval
    /// The working directory after the command.
    public var workingDirectory: String
    public var directoryChanged: Bool
    /// Something the model must know about the run (e.g. a vanished working directory).
    public var notice: String?
    /// Holds everything the command wrote.
    public var outputFile: String
    /// The process group of the command (its bash's pid).
    public var processGroup: pid_t

    public init(exitCode: Int32?, timedOut: Bool, cancelled: Bool, timeout: TimeInterval, duration: TimeInterval,
                workingDirectory: String, directoryChanged: Bool, notice: String?, outputFile: String,
                processGroup: pid_t) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.timeout = timeout
        self.duration = duration
        self.workingDirectory = workingDirectory
        self.directoryChanged = directoryChanged
        self.notice = notice
        self.outputFile = outputFile
        self.processGroup = processGroup
    }
}

/// Runs the agent's `bash` calls: a new non-interactive bash per call in its own process group, stdin
/// `/dev/null`, output appended to a file, the working directory carried from call to call.
/// See SPEC/assistant/bash-tool.md.
public final class CommandRunner: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 120
    public static let maxTimeout: TimeInterval = 600
    public static let killGrace: TimeInterval = 3
    /// Output forwarded to the observer of one call, at most.
    public static let forwardedOutputLimit = 1 << 20

    public let environment: [String: String]
    public let outputDirectory: String
    public let bash: String
    private let home: String
    private let lock = NSLock()
    private var directory: String
    private var callCount = 0
    private var running: Set<pid_t> = []

    public init(environment: [String: String], workingDirectory: String, outputDirectory: String,
                bash: String? = nil, home: String = NSHomeDirectory()) {
        self.environment = environment
        self.outputDirectory = outputDirectory
        self.bash = bash ?? Self.bashPath(environment: environment)
        self.home = home
        directory = workingDirectory
    }

    public var workingDirectory: String { lock.withLock { directory } }

    /// Kills the process group of every running call at once (the app is quitting).
    public func killRunning() {
        for group in lock.withLock({ running }) { kill(-group, SIGKILL) }
    }

    /// The login environment made non-interactive: no pager, no editor, no colors, no credential prompt.
    public static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        for key in ["COLORTERM", "BASH_ENV", "ENV", "PROMPT_COMMAND", "PS1", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
                    "TERM_SESSION_ID", "ITERM_SESSION_ID", "SHLVL", "OLDPWD", "PWD", "COLUMNS", "LINES"] {
            environment[key] = nil
        }
        environment.merge(["NO_COLOR": "1", "TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat", "GH_PAGER": "cat",
                           "GIT_TERMINAL_PROMPT": "0", "EDITOR": "true", "VISUAL": "true", "GIT_EDITOR": "true"]) { $1 }
        if environment["LANG"]?.isEmpty ?? true { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    /// The first `bash` on the PATH (a newer Homebrew bash when installed), else `/bin/bash`.
    public static func bashPath(environment: [String: String]) -> String {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = directory + "/bash"
            if FileManager.default.isExecutableFile(atPath: String(candidate)) { return String(candidate) }
        }
        return "/bin/bash"
    }

    private static let wrapper = """
        __aterm_cwd_file=$1
        __aterm_command_file=$2
        cd -- "$3" || exit 125
        trap 'pwd -P > "$__aterm_cwd_file"' EXIT
        set --
        . "$__aterm_command_file"
        """

    public func run(_ command: String, timeout: TimeInterval = CommandRunner.defaultTimeout,
                    extraEnvironment: [String: String] = [:],
                    onOutput: (@Sendable (Data) -> Void)? = nil) async -> CommandRun {
        let (number, previous) = lock.withLock { () -> (Int, String) in
            callCount += 1
            return (callCount, directory)
        }
        let commandFile = (outputDirectory as NSString).appendingPathComponent("cmd-\(number).sh")
        let outputFile = (outputDirectory as NSString).appendingPathComponent("out-\(number).txt")
        let directoryFile = (outputDirectory as NSString).appendingPathComponent("cwd-\(number)")
        defer {
            try? FileManager.default.removeItem(atPath: commandFile)
            try? FileManager.default.removeItem(atPath: directoryFile)
        }

        var start = previous
        var notice: String?
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: start, isDirectory: &isDirectory) || !isDirectory.boolValue {
            notice = "The working directory \(start) no longer exists; now in \(home)."
            start = home
            lock.withLock { directory = home }
        }
        let clampedTimeout = min(max(1, timeout), Self.maxTimeout)
        let begin = Date()

        guard FileManager.default.createFile(atPath: commandFile, contents: Data(command.utf8)),
              FileManager.default.createFile(atPath: outputFile, contents: nil)
        else {
            return failure("Could not write to \(outputDirectory).", start, outputFile, clampedTimeout, notice)
        }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let output = open(outputFile, O_WRONLY | O_APPEND | O_CLOEXEC)
        defer {
            if input >= 0 { close(input) }
            if output >= 0 { close(output) }
        }
        let arguments = [bash, "-c", Self.wrapper, "bash", directoryFile, commandFile, start]
        let variables = environment.merging(extraEnvironment) { $1 }.map { "\($0.key)=\($0.value)" }
        let pid = withCStrings(arguments) { argv in
            withCStrings(variables) { envp in
                aterm_spawn(bash, argv, envp, input, output)
            }
        }
        guard pid > 0, input >= 0, output >= 0 else {
            return failure("Could not start \(bash): \(String(cString: strerror(errno))).", start, outputFile,
                           clampedTimeout, notice)
        }

        lock.withLock { _ = running.insert(pid) }
        let child = RunningCommand(pid: pid, outputFile: outputFile, onOutput: onOutput)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.start(timeout: clampedTimeout, continuation: continuation)
            }
        } onCancel: {
            child.stop(cancelled: true)
        }
        lock.withLock { _ = running.remove(pid) }

        var changed = false
        if let data = FileManager.default.contents(atPath: directoryFile),
           let reported = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !reported.isEmpty {
            changed = lock.withLock { () -> Bool in
                let changed = reported != directory
                directory = reported
                return changed
            }
        }
        return CommandRun(exitCode: outcome.timedOut || outcome.cancelled ? nil : outcome.exitCode,
                          timedOut: outcome.timedOut, cancelled: outcome.cancelled, timeout: clampedTimeout,
                          duration: Date().timeIntervalSince(begin), workingDirectory: workingDirectory,
                          directoryChanged: changed, notice: notice, outputFile: outputFile, processGroup: pid)
    }

    private func failure(_ message: String, _ directory: String, _ outputFile: String, _ timeout: TimeInterval,
                         _ notice: String?) -> CommandRun {
        CommandRun(exitCode: 126, timedOut: false, cancelled: false, timeout: timeout, duration: 0,
                   workingDirectory: directory, directoryChanged: false,
                   notice: [notice, message].compactMap { $0 }.joined(separator: " "), outputFile: outputFile,
                   processGroup: 0)
    }
}

extension CommandRunner {
    /// Runs `executable` with `arguments` (argv[0] first), stdin `/dev/null` and the output appended to
    /// `outputFile`, stopping its process group after `timeout`. Returns the exit code, nil when it timed out.
    static func runProcess(_ executable: String, arguments: [String], environment: [String: String],
                           outputFile: String, timeout: TimeInterval) async -> Int32? {
        guard FileManager.default.createFile(atPath: outputFile, contents: nil) else { return nil }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let output = open(outputFile, O_WRONLY | O_APPEND | O_CLOEXEC)
        defer {
            if input >= 0 { close(input) }
            if output >= 0 { close(output) }
        }
        let variables = environment.map { "\($0.key)=\($0.value)" }
        let pid = withCStrings(arguments) { argv in
            withCStrings(variables) { envp in aterm_spawn(executable, argv, envp, input, output) }
        }
        guard pid > 0, input >= 0, output >= 0 else { return nil }
        let child = RunningCommand(pid: pid, outputFile: outputFile, onOutput: nil)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in child.start(timeout: timeout, continuation: continuation) }
        } onCancel: {
            child.stop(cancelled: true)
        }
        return outcome.timedOut || outcome.cancelled ? nil : outcome.exitCode
    }
}

/// Calls `body` with a NULL-terminated array of C strings.
func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}

/// A started command: waits for its exit, forwards its output, stops its process group on timeout or cancel.
/// All state lives on `queue`.
final class RunningCommand: @unchecked Sendable {
    struct Outcome {
        var exitCode: Int32?
        var timedOut = false
        var cancelled = false
    }

    let pid: pid_t
    private let queue = DispatchQueue(label: "ATerm.command")
    private let reader: FileHandle?
    private let onOutput: (@Sendable (Data) -> Void)?
    private var forwarded = 0
    private var outcome = Outcome()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var processSource: DispatchSourceProcess?
    private var pollTimer: DispatchSourceTimer?
    private var finished = false
    private var stopping = false

    init(pid: pid_t, outputFile: String, onOutput: (@Sendable (Data) -> Void)?) {
        self.pid = pid
        self.onOutput = onOutput
        reader = onOutput == nil ? nil : FileHandle(forReadingAtPath: outputFile)
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<Outcome, Never>) {
        queue.async { [self] in
            self.continuation = continuation
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            // The exit event can come before the process can be waited for: wait for it.
            source.setEventHandler { [self] in reap(blocking: true) }
            processSource = source
            source.resume()
            if reader != nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
                timer.setEventHandler { [self] in forwardOutput() }
                pollTimer = timer
                timer.resume()
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in stopOnQueue(cancelled: false) }
            // The command may have exited before the source was armed.
            reap(blocking: false)
        }
    }

    func stop(cancelled: Bool) {
        queue.async { [self] in stopOnQueue(cancelled: cancelled) }
    }

    private func stopOnQueue(cancelled: Bool) {
        guard !finished, !stopping else { return }
        stopping = true
        if cancelled { outcome.cancelled = true } else { outcome.timedOut = true }
        kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + CommandRunner.killGrace) { [self] in
            if !finished { kill(-pid, SIGKILL) }
        }
    }

    private func reap(blocking: Bool) {
        guard !finished else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, blocking ? 0 : WNOHANG) == pid else { return }
        finished = true
        outcome.exitCode = PTYProcess.exitCode(fromWaitStatus: status)
        if stopping {
            // Leftover members of the group (background jobs) go with the stopped command.
            kill(-pid, SIGKILL)
        }
        processSource?.cancel()
        processSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        forwardOutput()
        try? reader?.close()
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func forwardOutput() {
        guard let reader, let onOutput, forwarded < CommandRunner.forwardedOutputLimit else { return }
        let data = reader.readData(ofLength: CommandRunner.forwardedOutputLimit - forwarded)
        guard !data.isEmpty else { return }
        forwarded += data.count
        onOutput(data)
    }
}
