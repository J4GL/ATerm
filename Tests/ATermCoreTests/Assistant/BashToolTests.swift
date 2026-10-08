import Darwin
import Foundation
import Testing
import ATermCore

/// Records output chunks with the time they arrived.
final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [(Date, Data)] = []

    func append(_ data: Data) { lock.withLock { chunks.append((Date(), data)) } }

    var text: String { lock.withLock { String(decoding: chunks.reduce(Data()) { $0 + $1.1 }, as: UTF8.self) } }

    /// When the recorded text first contained `needle`.
    func time(of needle: String) -> Date? {
        lock.withLock {
            var data = Data()
            for (time, chunk) in chunks {
                data += chunk
                if String(decoding: data, as: UTF8.self).contains(needle) { return time }
            }
            return nil
        }
    }
}

func makeRunner(in directory: TemporaryDirectory, outputs: TemporaryDirectory,
                extra: [String: String] = [:]) -> CommandRunner {
    let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    return CommandRunner(environment: CommandRunner.environment(from: base.merging(extra) { $1 }),
                         workingDirectory: directory.path, outputDirectory: outputs.path)
}

func outputText(_ run: CommandRun) -> String {
    (try? String(contentsOfFile: run.outputFile, encoding: .utf8)) ?? ""
}

/// True once no process is left in the group.
func processGroupIsGone(_ group: pid_t) async -> Bool {
    await eventually(timeout: 3) { kill(-group, 0) != 0 && errno == ESRCH }
}

@Test("ASSIST-BASH-001 a command runs with bash in a clean non-interactive environment")
func ASSIST_BASH_001() async throws {
    signal(SIGPIPE, SIG_IGN)
    let directory = try TemporaryDirectory()
    let outputs = try TemporaryDirectory()
    try outputs.write("bashenv.sh", "echo SOURCED\n")
    let descriptor = open("/dev/null", O_RDONLY)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    let runner = makeRunner(in: directory, outputs: outputs,
                            extra: ["COLORTERM": "truecolor", "BASH_ENV": outputs.file("bashenv.sh")])

    let cases: [(command: String, exitCode: Int32, output: String)] = [
        ("echo out; echo err >&2; exit 3", 3, "out\nerr\n"),
        ("pwd -P", 0, directory.path + "\n"),
        ("read line; echo \"got [$line]\"", 0, "got []\n"),
        ("test -t 1 && echo tty || echo notty", 0, "notty\n"),
        ("echo \"$PAGER $GIT_PAGER $GH_PAGER $NO_COLOR $TERM $GIT_TERMINAL_PROMPT $EDITOR $VISUAL $GIT_EDITOR [$COLORTERM] [$BASH_ENV]\"",
         0, "cat cat cat 1 dumb 0 true true true [] []\n"),
        ("yes | head -n 1", 0, "y\n"),
        ("test -e /dev/fd/\(descriptor) && echo leaked || echo clean", 0, "clean\n"),
        ("echo \"[$1] [$#]\"", 0, "[] [0]\n"),
    ]
    for testCase in cases {
        let run = await runner.run(testCase.command)
        #expect(run.exitCode == testCase.exitCode, "\(testCase.command)")
        #expect(outputText(run) == testCase.output, "\(testCase.command)")
    }

    let recorder = OutputRecorder()
    let run = await runner.run("echo live; sleep 1; echo done", onOutput: { recorder.append($0) })
    let returned = Date()
    #expect(run.exitCode == 0)
    #expect(recorder.text == "live\ndone\n")
    let liveTime = try #require(recorder.time(of: "live"))
    #expect(returned.timeIntervalSince(liveTime) > 0.5)
}

@Test("ASSIST-BASH-002 the working directory persists between calls and variables do not")
func ASSIST_BASH_002() async throws {
    let directory = try TemporaryDirectory()
    let outputs = try TemporaryDirectory()
    try directory.makeDirectory("sub")
    let runner = makeRunner(in: directory, outputs: outputs)
    let sub = directory.file("sub")

    var run = await runner.run("cd sub && export X=1")
    #expect(runner.workingDirectory == sub)
    #expect(run.workingDirectory == sub)
    #expect(run.directoryChanged)

    run = await runner.run("pwd -P; echo \"[$X]\"")
    #expect(outputText(run) == sub + "\n[]\n")
    #expect(!run.directoryChanged)

    run = await runner.run("cd .. && exit 4")
    #expect(run.exitCode == 4)
    #expect(runner.workingDirectory == directory.path)

    run = await runner.run("cd sub; trap 'echo bye' EXIT")
    #expect(outputText(run) == "bye\n")
    #expect(runner.workingDirectory == directory.path)

    run = await runner.run("mkdir gone && cd gone")
    #expect(runner.workingDirectory == directory.file("gone"))
    try FileManager.default.removeItem(atPath: directory.file("gone"))
    run = await runner.run("pwd -P")
    let home = String(cString: realpath(NSHomeDirectory(), nil))
    #expect(outputText(run) == home + "\n")
    #expect(run.notice == "The working directory \(directory.file("gone")) no longer exists; now in \(NSHomeDirectory()).")
}

enum StopCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case timeout, cancellation, ignoredTerm

    var testDescription: String { rawValue }
}

@Test("ASSIST-BASH-003 a timeout or a cancellation kills the whole process group", arguments: StopCase.allCases)
func ASSIST_BASH_003(_ stopCase: StopCase) async throws {
    let directory = try TemporaryDirectory()
    let outputs = try TemporaryDirectory()
    let runner = makeRunner(in: directory, outputs: outputs)
    let started = Date()
    let run: CommandRun
    switch stopCase {
    case .timeout:
        run = await runner.run("echo start; sleep 30 & sleep 30; echo never", timeout: 1)
        #expect(run.timedOut)
        #expect(outputText(run) == "start\n")
    case .cancellation:
        let task = Task { await runner.run("echo start; sleep 30 & sleep 30; echo never") }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        run = await task.value
        #expect(run.cancelled)
    case .ignoredTerm:
        run = await runner.run("trap '' TERM; echo start; sleep 30", timeout: 1)
        #expect(run.timedOut)
    }
    #expect(Date().timeIntervalSince(started) < (stopCase == .ignoredTerm ? 6 : 5))
    #expect(await processGroupIsGone(run.processGroup))
}

/// A TCP port nobody listens on right now.
func freePort() -> UInt16 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

@Test("ASSIST-BASH-004 a server started in the background keeps serving after the call returns")
func ASSIST_BASH_004() async throws {
    let directory = try TemporaryDirectory()
    let outputs = try TemporaryDirectory()
    let runner = makeRunner(in: directory, outputs: outputs)
    let port = freePort()

    let started = Date()
    let server = await runner.run("python3 -m http.server \(port) --bind 127.0.0.1 & echo $!")
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(server.exitCode == 0)
    let pid = try #require(pid_t(outputText(server).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(pid, SIGTERM) }

    let probe = "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:\(port)/"
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, outputText(await runner.run(probe)) != "200" {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    for _ in 0..<2 {
        #expect(outputText(await runner.run(probe)) == "200")
    }
}

struct ModelOutputCase: CustomTestStringConvertible, Sendable {
    let name: String
    let output: String
    let expected: String

    var testDescription: String { name }
}

private let notice = "Full output: /tmp/out-1.txt]"

private let modelOutputCases: [ModelOutputCase] = [
    ModelOutputCase(name: "empty", output: "", expected: "(no output)"),
    ModelOutputCase(name: "escape sequences", output: "\u{1B}[31mred\u{1B}[0m plain\u{1B}]0;title\u{07}\n",
                    expected: "red plain"),
    ModelOutputCase(name: "carriage returns", output: "progress 10%\rprogress 100%\na\r\nb\n",
                    expected: "progress 100%\na\nb"),
    ModelOutputCase(name: "secret", output: "token tok-9a8b7c6d5e\n", expected: "token <API_TOKEN_1:14chars>"),
    ModelOutputCase(name: "long line", output: String(repeating: "z", count: 1000) + "\n",
                    expected: String(repeating: "z", count: 500) + "... [truncated]"),
    ModelOutputCase(
        name: "many lines",
        output: (1...2199).map { "line \($0)\n" }.joined() + "line 2200 tok-9a8b7c6d5e\n",
        expected: ((1...100).map { "line \($0)" }
            + ["[Showing lines 1-100 and 1901-2200 of 2200. " + notice]
            + (1901...2199).map { "line \($0)" } + ["line 2200 <API_TOKEN_1:14chars>"]).joined(separator: "\n")),
    ModelOutputCase(
        name: "many bytes",
        output: String(repeating: String(repeating: "q", count: 400) + "\n", count: 350),
        expected: (Array(repeating: String(repeating: "q", count: 400), count: 20)
            + ["[Showing lines 1-20 and 311-350 of 350. " + notice]
            + Array(repeating: String(repeating: "q", count: 400), count: 40)).joined(separator: "\n")),
]

private func sampleRun(timedOut: Bool = false, directoryChanged: Bool = false,
                       workingDirectory: String = "/tmp") -> CommandRun {
    CommandRun(exitCode: timedOut ? nil : 0, timedOut: timedOut, cancelled: false, timeout: 120,
               duration: timedOut ? 120 : 0.4, workingDirectory: workingDirectory, directoryChanged: directoryChanged,
               notice: nil, outputFile: "/tmp/out-1.txt", processGroup: 0)
}

@Test("ASSIST-BASH-005 the model reads a cleaned redacted and truncated output", arguments: modelOutputCases)
func ASSIST_BASH_005(_ testCase: ModelOutputCase) {
    let redactor = SecretRedactor(knownSecrets: [KnownSecret(name: "API_TOKEN", value: "tok-9a8b7c6d5e")])
    let result = BashTool.result(for: sampleRun(), output: Data(testCase.output.utf8), command: "cmd",
                                 redactor: redactor)
    #expect(result == "Exit code: 0\nWall time: 0.4 s\nOutput:\n" + testCase.expected)

    for command in ["gh auth token", "security find-generic-password -s x -w", "gcloud auth print-access-token",
                    "aws configure export-credentials"] {
        let withheld = BashTool.result(for: sampleRun(), output: Data("secret-value-1234\n".utf8), command: command,
                                       redactor: redactor)
        #expect(withheld.hasSuffix("Output:\n[output withheld: prints secrets]"), "\(command)")
    }
    let keyLines = (1...95).map { "l \($0)" } + ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        + (1...4).map { "KEYBODY\($0)" } + ["-----END OPENSSH PRIVATE KEY-----"] + (102...537).map { "l \($0)" }
    let split = BashTool.result(for: sampleRun(), output: Data(keyLines.joined(separator: "\n").utf8), command: "cmd",
                                redactor: redactor)
    #expect(!split.contains("KEYBODY"))
    #expect(split.contains("<PRIVATE_KEY_"))

    let path = BashTool.result(for: sampleRun(), output: Data("/usr/bin:/bin\n".utf8), command: "printenv PATH",
                               redactor: redactor)
    #expect(path.hasSuffix("Output:\n/usr/bin:/bin"))

    let timedOut = BashTool.result(for: sampleRun(timedOut: true, directoryChanged: true, workingDirectory: "/tmp/x"),
                                   output: Data("start\n".utf8), command: "cmd", redactor: redactor)
    #expect(timedOut == "Timed out after 120 s; the process group was killed\nWall time: 120.0 s\n"
        + "Working directory: /tmp/x\nOutput:\nstart")
}

/// Counts what concurrent tasks report.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [Int32?] = []

    func append(_ code: Int32?) {
        lock.withLock { codes.append(code) }
    }

    var all: [Int32?] { lock.withLock { codes } }
}

@Test("ASSIST-BASH-006 every command's end is collected even when many end at once on a busy machine")
func ASSIST_BASH_006() async throws {
    let directory = try TemporaryDirectory()
    let outputs = try TemporaryDirectory()
    let load = (0..<8).map { _ in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        return process
    }
    defer { load.forEach { $0.terminate() } }
    let total = 600
    let results = Results()
    let runner = makeRunner(in: directory, outputs: outputs)
    for _ in 0..<total {
        Task.detached { results.append(await runner.run("true", timeout: 120).exitCode) }
    }
    #expect(await eventually(timeout: 60) { results.all.count == total },
            "\(total - results.all.count) runs never returned")
    #expect(results.all.allSatisfy { $0 == 0 }, "\(Dictionary(grouping: results.all.map { $0.map(String.init) ?? "nil" }) { $0 }.mapValues(\.count))")
}
