import Foundation
import Testing
import ATermCore

/// Thread-safe record of what a `PTYProcess` delivered.
final class PTYRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var statuses: [Int32] = []
    private var outputBeforeExit: String?

    func append(_ chunk: [UInt8]) { lock.withLock { bytes += chunk } }

    func exited(_ status: Int32) {
        lock.withLock {
            statuses.append(status)
            outputBeforeExit = String(decoding: bytes, as: UTF8.self)
        }
    }

    var output: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var exitStatuses: [Int32] { lock.withLock { statuses } }
    var outputAtExit: String? { lock.withLock { outputBeforeExit } }
}

let testEnvironment = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": NSHomeDirectory(),
    "LANG": "en_US.UTF-8",
    "TERM": "xterm-256color",
    "BASH_SILENCE_DEPRECATION_WARNING": "1",
]

func startPTY(_ arguments: [String], environment: [String: String] = [:],
              size: PTYSize = PTYSize(cols: 80, rows: 24)) throws -> (PTYProcess, PTYRecorder) {
    let recorder = PTYRecorder()
    let command = PTYCommand(executable: arguments[0], arguments: arguments,
                             environment: testEnvironment.merging(environment) { $1 })
    let process = PTYProcess(command: command, size: size, callbackQueue: DispatchQueue(label: "pty-test"))
    process.onOutput = { recorder.append($0) }
    process.onExit = { recorder.exited($0) }
    try process.start()
    return (process, recorder)
}

/// Polls `condition` until it holds or `timeout` seconds elapse.
func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

struct PTYCase: CustomTestStringConvertible, Sendable {
    let name: String
    let arguments: [String]
    let expectedOutput: String
    var expectedStatus: Int32?

    var testDescription: String { name }
}

@Test("PTY-001 a program runs in a pseudo-terminal of the requested size", arguments: [
    PTYCase(name: "stty size", arguments: ["/bin/stty", "size"], expectedOutput: "24 80", expectedStatus: 0),
    PTYCase(name: "stdin and stdout are terminals",
            arguments: ["/bin/sh", "-c", "test -t 0 && test -t 1 && echo tty"], expectedOutput: "tty"),
])
func PTY_001(_ testCase: PTYCase) async throws {
    let (_, recorder) = try startPTY(testCase.arguments)
    #expect(await eventually { !recorder.exitStatuses.isEmpty })
    #expect(recorder.output.contains(testCase.expectedOutput))
    if let status = testCase.expectedStatus {
        #expect(recorder.exitStatuses == [status])
    }
}

@Test("PTY-002 written input reaches the program")
func PTY_002() async throws {
    let (process, recorder) = try startPTY(["/bin/cat"])
    process.write(Array("ping\n".utf8))
    #expect(await eventually { recorder.output.contains("ping\r\nping\r\n") })
    process.write([0x04])
    #expect(await eventually { recorder.exitStatuses == [0] })
}

@Test("PTY-003 resizing updates the size and signals the program")
func PTY_003() async throws {
    let (process, recorder) = try startPTY(
        ["/bin/sh", "-c", "trap \"stty size\" WINCH; echo ready; while :; do sleep 0.05; done"])
    defer { process.terminate() }
    #expect(await eventually { recorder.output.contains("ready") })
    process.resize(PTYSize(cols: 100, rows: 40))
    #expect(await eventually { recorder.output.contains("40 100") })
}

@Test("PTY-004 the exit status is reported once after the remaining output", arguments: [
    PTYCase(name: "exit code", arguments: ["/bin/sh", "-c", "echo bye; exit 3"], expectedOutput: "bye", expectedStatus: 3),
    PTYCase(name: "killed by a signal", arguments: ["/bin/sh", "-c", "kill -9 $$"], expectedOutput: "", expectedStatus: 137),
])
func PTY_004(_ testCase: PTYCase) async throws {
    let (process, recorder) = try startPTY(testCase.arguments)
    #expect(await eventually { !recorder.exitStatuses.isEmpty })
    try await Task.sleep(nanoseconds: 300_000_000)  // a second exit notification would arrive by now
    #expect(recorder.exitStatuses == [testCase.expectedStatus!])
    if !testCase.expectedOutput.isEmpty {
        #expect(recorder.outputAtExit?.contains(testCase.expectedOutput) == true)
    }
    #expect(!process.isRunning)
    #expect(process.currentDirectory == nil)
}

@Test("PTY-009 the line discipline edits UTF-8 input and uses the usual control characters")
func PTY_009() async throws {
    let (_, settings) = try startPTY(["/bin/stty", "-a"])
    #expect(await eventually { !settings.exitStatuses.isEmpty })
    let output = settings.output
    for expected in [" iutf8", " icanon", " echo ", "erase = ^?", "intr = ^C", "susp = ^Z"] {
        #expect(output.contains(expected), "\(expected)")
    }
    #expect(!output.contains("-iutf8"))

    let (process, reader) = try startPTY(["/bin/sh", "-c", "read line; printf %s \"$line\" | od -An -tx1"])
    process.write(Array("é".utf8) + [0x7F] + Array("a\n".utf8))
    #expect(await eventually { !reader.exitStatuses.isEmpty })
    #expect(reader.output.contains(" 61"))
    #expect(!reader.output.contains("c3"))
}

@Test("PTY-005 the program starts with default signals and no inherited descriptors")
func PTY_005() async throws {
    signal(SIGPIPE, SIG_IGN)
    let descriptor = open("/dev/null", O_RDONLY)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    let script = "yes | head -n 1; test -e /dev/fd/\(descriptor) && echo leaked || echo clean"
    let (_, recorder) = try startPTY(["/bin/sh", "-c", script])
    #expect(await eventually { !recorder.exitStatuses.isEmpty })
    let output = recorder.output
    #expect(output.contains("y\r\n"))
    #expect(output.contains("clean"))
    #expect(!output.contains("Broken pipe"))
}

@Test("PTY-008 process inspection reports the foreground job and the working directory")
func PTY_008() async throws {
    let (process, recorder) = try startPTY(["/bin/bash", "--noprofile", "--norc", "-i"], environment: ["PS1": "$ "])
    defer { process.terminate() }
    #expect(await eventually { recorder.output.hasSuffix("$ ") })
    #expect(process.foregroundProcessName == "bash")
    #expect(!process.hasForegroundJob)

    let promptCount = recorder.output.components(separatedBy: "$ ").count
    process.write(Array("cd /tmp\n".utf8))
    #expect(await eventually { recorder.output.components(separatedBy: "$ ").count > promptCount })
    #expect(process.currentDirectory == "/private/tmp")

    process.write(Array("sleep 5\n".utf8))
    #expect(await eventually(timeout: 2) { process.foregroundProcessName == "sleep" && process.hasForegroundJob })
}
