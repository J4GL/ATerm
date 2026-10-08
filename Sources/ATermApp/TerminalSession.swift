import AppKit
import ATermCore

/// What an agent tab tells its session.
@MainActor
protocol AgentSessionOwner: AnyObject {
    var isRunning: Bool { get }
    var currentDirectory: String { get }
    /// Input typed in the tab (the agent tab is read-only: it decides what keys do).
    func receiveInput(_ bytes: [UInt8])
}

/// One terminal: the model and the shell process feeding it, or, in an agent tab, the model the agent writes
/// to. See SPEC/app/contract.md.
@MainActor
final class TerminalSession {
    let terminal: Terminal
    /// The shell; nil in an agent tab.
    let process: PTYProcess?
    /// Name of the program started in the terminal, used when nothing else names it.
    let programName: String
    private(set) var hasExited = false
    /// The agent tab this session shows.
    weak var agentOwner: AgentSessionOwner?
    /// ATerm's suggestions in a zsh shell. See SPEC/app/suggestions.md.
    private let integration: ShellIntegration?

    var onScreenChange: (() -> Void)?
    var onTitleChange: (() -> Void)?
    var onBell: (() -> Void)?
    var onExit: ((Int32) -> Void)?
    /// A completion request of the shell's integration; an empty line withdraws the pending one.
    var onCompletionRequest: ((String) -> Void)?

    init(configuration: AppConfiguration, cols: Int, rows: Int, workingDirectory: String?) {
        terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: configuration.scrollbackLines,
                            palette: configuration.palette)
        let base = ProcessInfo.processInfo.environment
        var environment = ShellEnvironment.make(base: base, localeIdentifier: Locale.current.identifier)
        environment.merge(configuration.environment) { $1 }
        let executable: String
        let arguments: [String]
        if let shell = configuration.shell {
            (executable, arguments) = (shell.executable, shell.arguments)
        } else {
            (executable, arguments) = LoginShell.command(environment: base, accountShell: LoginShell.accountShell())
        }
        integration = configuration.autosuggestions
            ? ShellIntegration.install(for: executable, environment: &environment,
                                       directory: configuration.shellIntegrationDirectory)
            : nil
        let directory = Self.usableDirectory(workingDirectory) ?? NSHomeDirectory()
        environment["PWD"] = directory
        process = PTYProcess(command: PTYCommand(executable: executable, arguments: arguments,
                                                 environment: environment, workingDirectory: directory),
                             size: PTYSize(cols: cols, rows: rows))
        programName = (executable as NSString).lastPathComponent
        terminal.delegate = self
    }

    /// A session without process, written to by an agent tab.
    init(agentConfiguration configuration: AppConfiguration, cols: Int, rows: Int) {
        terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: configuration.scrollbackLines,
                            palette: configuration.palette)
        process = nil
        integration = nil
        programName = "Agent"
        terminal.delegate = self
    }

    private static func usableDirectory(_ path: String?) -> String? {
        var isDirectory: ObjCBool = false
        guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return path
    }

    func start() throws {
        guard let process else { return }
        process.onOutput = { [weak self] bytes in
            MainActor.assumeIsolated { self?.receive(bytes) }
        }
        process.onExit = { [weak self] status in
            MainActor.assumeIsolated { self?.exited(status) }
        }
        try process.start()
    }

    /// Input from the user (keys, paste, mouse and focus reports): to the shell, or to the agent tab.
    func send(_ bytes: [UInt8]) {
        guard !hasExited, !bytes.isEmpty else { return }
        if let process {
            process.write(bytes)
        } else {
            agentOwner?.receiveInput(bytes)
        }
    }

    /// Writes text straight to the terminal, as program output.
    func display(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        terminal.feed(bytes)
        onScreenChange?()
    }

    func resize(cols: Int, rows: Int, cellSize: NSSize) {
        terminal.resize(cols: cols, rows: rows)
        process?.resize(PTYSize(cols: cols, rows: rows,
                                pixelWidth: Int(CGFloat(cols) * cellSize.width),
                                pixelHeight: Int(CGFloat(rows) * cellSize.height)))
        onScreenChange?()
    }

    /// The title set by the program, else the name of the program in the foreground.
    var displayTitle: String {
        if !terminal.title.isEmpty { return terminal.title }
        return process?.foregroundProcessName ?? programName
    }

    /// The shell's working directory, or the agent's.
    var currentDirectory: String? {
        if let process { return process.currentDirectory }
        return agentOwner?.currentDirectory
    }

    /// A program runs in the shell's foreground, or the agent is working.
    var hasRunningJob: Bool {
        if let process { return !hasExited && process.hasForegroundJob }
        return agentOwner?.isRunning ?? false
    }

    /// What closing the session would terminate.
    var runningProgramName: String? {
        process == nil ? "the agent" : process?.foregroundProcessName
    }

    /// Hangs up the shell.
    func terminate() {
        process?.terminate()
        integration?.remove()
    }

    /// Hands the model's completion of the line being typed to the shell's integration.
    func sendCompletion(_ line: String) {
        integration?.send(line)
    }

    /// Tells the shell's integration the user clicked in the terminal.
    func sendClick() {
        integration?.sendClick()
    }

    /// Shows a line of text below the output, as a terminal message.
    func showMessage(_ message: String) {
        display(Array("\r\n\(message)\r\n".utf8))
    }

    private func receive(_ bytes: [UInt8]) {
        guard !hasExited else { return }
        terminal.feed(bytes)
        onScreenChange?()
    }

    private func exited(_ status: Int32) {
        hasExited = true
        integration?.remove()
        onExit?(status)
    }
}

extension TerminalSession: @preconcurrency TerminalDelegate {
    func terminal(_ terminal: Terminal, send bytes: [UInt8]) {
        // Replies to queries go to the shell; in an agent tab nobody asked, so they are dropped.
        guard !hasExited, let process, !bytes.isEmpty else { return }
        process.write(bytes)
    }

    func terminalTitleDidChange(_ terminal: Terminal) {
        onTitleChange?()
    }

    func terminalBell(_ terminal: Terminal) {
        onBell?()
    }

    func terminalPaletteDidChange(_ terminal: Terminal) {
        onScreenChange?()
    }

    func terminal(_ terminal: Terminal, didRequestCompletionOf line: String, nonce: String) {
        // Only the shell knows the nonce: a program printing the sequence cannot ask in its name.
        guard let integration, nonce == integration.nonce else { return }
        onCompletionRequest?(line)
    }
}
