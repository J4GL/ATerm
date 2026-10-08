import CPTY
import Darwin
import Foundation

public struct PTYSize: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.cols = cols
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct PTYCommand: Sendable, Equatable {
    public var executable: String
    /// The argument vector, starting with argv[0].
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum PTYError: Error {
    case spawnFailed(Int32)
}

/// A program running in a pseudo-terminal. See SPEC/pty/pty.md.
///
/// All I/O state lives on a private serial queue; output chunks and the exit
/// status are delivered on `callbackQueue`. Reading pauses while too many
/// chunks wait to be consumed, which throttles a program flooding the terminal.
public final class PTYProcess: @unchecked Sendable {
    public let command: PTYCommand
    public private(set) var pid: pid_t = 0
    /// Set before `start()`.
    public var onOutput: (@Sendable ([UInt8]) -> Void)?
    /// Set before `start()`. Receives the exit code, or 128 + signal number.
    public var onExit: (@Sendable (Int32) -> Void)?

    private let callbackQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "ATerm.pty.io")
    private var size: PTYSize
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var running = true
    /// The master descriptor, -1 once closed. Readable from any thread.
    private var masterFD: Int32 {
        get { stateLock.withLock { descriptor } }
        set { stateLock.withLock { descriptor = newValue } }
    }

    /// False once the program has exited and been reaped: its pid may then belong to
    /// another process, so it is never inspected or signalled again.
    public var isRunning: Bool { stateLock.withLock { running } }

    // Owned by ioQueue.
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var readSuspended = false
    private var writeSourceActive = false
    private var pendingWrite: [UInt8] = []
    private var pendingWriteOffset = 0
    private var chunksInFlight = 0
    private var readerFinished = false
    private var exitStatus: Int32?
    private var exitDelivered = false
    private var ioClosed = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    private static let maxChunksInFlight = 4

    public init(command: PTYCommand, size: PTYSize, callbackQueue: DispatchQueue = .main) {
        self.command = command
        self.size = size
        self.callbackQueue = callbackQueue
    }

    // MARK: - Lifecycle

    public func start() throws {
        let argv = command.arguments.map { strdup($0) } + [nil]
        let envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        let childPID: pid_t = command.executable.withCString { path in
            withOptionalCString(command.workingDirectory) { cwd in
                aterm_pty_spawn(path, argv, envp, cwd,
                               UInt16(clamping: size.cols), UInt16(clamping: size.rows),
                               UInt16(clamping: size.pixelWidth), UInt16(clamping: size.pixelHeight), &master)
            }
        }
        guard childPID > 0 else { throw PTYError.spawnFailed(errno) }
        pid = childPID
        masterFD = master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        ioQueue.sync { startMonitoring() }
    }

    /// Hangs up: the shell receives SIGHUP (unless it already exited) and the descriptor is closed.
    public func terminate() {
        guard pid > 0 else { return }
        ioQueue.async {
            // Reaping happens on this queue too, so the pid cannot be recycled between the check and the kill.
            if self.exitStatus == nil { kill(self.pid, SIGHUP) }
            self.shutDownIO()
        }
    }

    // MARK: - Input

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        ioQueue.async {
            guard !self.ioClosed, !self.readerFinished else { return }
            self.pendingWrite.append(contentsOf: bytes)
            self.flushWrites()
        }
    }

    public func resize(_ size: PTYSize) {
        ioQueue.async {
            self.size = size
            guard self.masterFD >= 0 else { return }
            _ = aterm_pty_set_size(self.masterFD, UInt16(clamping: size.cols), UInt16(clamping: size.rows),
                                  UInt16(clamping: size.pixelWidth), UInt16(clamping: size.pixelHeight))
        }
    }

    // MARK: - Inspection

    private var foregroundProcessGroup: pid_t? {
        guard masterFD >= 0 else { return nil }
        let group = tcgetpgrp(masterFD)
        return group > 0 ? group : nil
    }

    /// Name of the process in the foreground of the terminal (the shell, or the job it runs).
    public var foregroundProcessName: String? {
        foregroundProcessGroup.flatMap(Self.processName)
    }

    /// True when the shell runs a foreground job.
    public var hasForegroundJob: Bool {
        guard let group = foregroundProcessGroup else { return false }
        return group != pid
    }

    /// The shell's current working directory.
    public var currentDirectory: String? {
        guard pid > 0, isRunning else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - I/O (ioQueue)

    private func startMonitoring() {
        // Sources capture self strongly: the process stays alive until its I/O is shut down.
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        read.setEventHandler { self.readAvailable() }
        read.setCancelHandler {
            let fd = self.masterFD
            self.masterFD = -1
            close(fd)
        }
        readSource = read
        read.resume()

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        process.setEventHandler { self.reapChild() }
        processSource = process
        process.resume()
        // The child may already have exited before the source was armed.
        reapChild(blocking: false)
    }

    private func readAvailable() {
        let count = readBuffer.withUnsafeMutableBytes { Darwin.read(masterFD, $0.baseAddress, $0.count) }
        if count > 0 {
            deliver(Array(readBuffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF, or EIO once every process holding the terminal has exited.
            finishReading()
        }
    }

    private func deliver(_ chunk: [UInt8]) {
        chunksInFlight += 1
        if chunksInFlight >= Self.maxChunksInFlight, !readSuspended, let readSource {
            readSource.suspend()
            readSuspended = true
        }
        let handler = onOutput
        callbackQueue.async {
            handler?(chunk)
            self.ioQueue.async { self.chunkConsumed() }
        }
    }

    private func chunkConsumed() {
        chunksInFlight -= 1
        if readSuspended, chunksInFlight < Self.maxChunksInFlight / 2, let readSource {
            readSuspended = false
            readSource.resume()
        }
        deliverExitIfFinished()
    }

    private func finishReading() {
        guard !readerFinished else { return }
        readerFinished = true
        shutDownIO()
        reapChild(blocking: false)
        deliverExitIfFinished()
    }

    private func flushWrites() {
        guard !ioClosed else { return }
        while pendingWriteOffset < pendingWrite.count {
            let written = pendingWrite.withUnsafeBytes { raw in
                Darwin.write(masterFD, raw.baseAddress! + pendingWriteOffset, raw.count - pendingWriteOffset)
            }
            if written > 0 {
                pendingWriteOffset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                armWriteSource()
                return
            } else {
                break  // The terminal is gone; drop the input.
            }
        }
        pendingWrite.removeAll(keepingCapacity: true)
        pendingWriteOffset = 0
        if writeSourceActive, let writeSource {
            writeSource.suspend()
            writeSourceActive = false
        }
    }

    private func armWriteSource() {
        guard !ioClosed else { return }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
            source.setEventHandler { self.flushWrites() }
            writeSource = source
            writeSourceActive = true
            source.resume()
        } else if !writeSourceActive, let writeSource {
            writeSourceActive = true
            writeSource.resume()
        }
    }

    /// Cancels the sources; the read source's cancel handler closes the descriptor.
    private func shutDownIO() {
        ioClosed = true
        if let writeSource {
            if !writeSourceActive { writeSource.resume() }
            writeSource.cancel()
            self.writeSource = nil
            writeSourceActive = false
        }
        if let readSource {
            if readSuspended { readSource.resume() }
            readSource.cancel()
            readSuspended = false
            self.readSource = nil
        }
        pendingWrite.removeAll()
        pendingWriteOffset = 0
    }

    private func reapChild(blocking: Bool = true) {
        guard exitStatus == nil, pid > 0 else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        guard result == pid else { return }
        exitStatus = Self.exitCode(fromWaitStatus: status)
        stateLock.withLock { running = false }
        processSource?.cancel()
        processSource = nil
        // A background process may keep the terminal open: do not wait for EOF forever.
        ioQueue.asyncAfter(deadline: .now() + 0.5) {
            if !self.readerFinished { self.finishReading() }
        }
        deliverExitIfFinished()
    }

    private func deliverExitIfFinished() {
        guard let status = exitStatus, readerFinished, chunksInFlight == 0, !exitDelivered else { return }
        exitDelivered = true
        let handler = onExit
        callbackQueue.async { handler?(status) }
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 { return (status >> 8) & 0xFF }
        return 128 + signal
    }
}

private func withOptionalCString<Result>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
