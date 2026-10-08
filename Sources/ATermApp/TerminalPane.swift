import AppKit
import ATermCore

/// One pane of a tab: its view, its session and its assistant. See SPEC/app/contract.md and SPEC/app/splits.md.
@MainActor
final class TerminalPane {
    let session: TerminalSession
    let terminalView: TerminalView
    let assistant: AssistantController
    /// Set in an agent tab.
    private(set) var agentTab: AgentTab?
    /// The tab showing the pane, until the pane leaves it.
    weak var tab: TerminalTab?
    private(set) var isClosed = false
    private(set) var title: String
    private var titleTimer: Timer?

    init(configuration: AppConfiguration, cols: Int, rows: Int, workingDirectory: String?,
         services: AssistantServices, agentLaunch: AgentLaunch? = nil) {
        session = agentLaunch == nil
            ? TerminalSession(configuration: configuration, cols: cols, rows: rows, workingDirectory: workingDirectory)
            : TerminalSession(agentConfiguration: configuration, cols: cols, rows: rows)
        terminalView = TerminalView(session: session, configuration: configuration)
        assistant = AssistantController(services: services)
        title = session.programName
        assistant.attach(to: self)
        if let agentLaunch {
            let agentTab = AgentTab(pane: self, session: session, services: services, launch: agentLaunch)
            self.agentTab = agentTab
            session.agentOwner = agentTab
        }
        session.onScreenChange = { [weak self] in self?.terminalView.terminalDidChange() }
        session.onTitleChange = { [weak self] in self?.updateTitle() }
        session.onBell = { [weak self] in self?.ringBell() }
        session.onExit = { [weak self] status in self?.shellExited(status) }
        session.onCompletionRequest = { [weak self] line in self?.assistant.requestCompletion(of: line) }
    }

    var window: NSWindow? { tab?.window }

    /// Starts the shell, or the agent of an agent tab.
    func start() throws {
        if let agentTab {
            agentTab.start()
            updateTitle()
            return
        }
        try session.start()
        updateTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
    }

    // MARK: - Title and bell

    func updateTitle() {
        guard !session.hasExited else { return }
        let title = session.displayTitle
        guard title != self.title else { return }
        self.title = title
        tab?.paneTitleDidChange(self)
    }

    private func ringBell() {
        NSSound.beep()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: - Exit and close

    private func shellExited(_ status: Int32) {
        stopTitleTimer()
        // Hanging up a closed pane's shell ends it too.
        guard !isClosed else { return }
        if status == 0 {
            tab?.windowController?.closePane(self)
        } else {
            session.showMessage("[Process exited with code \(status)]")
        }
    }

    /// Stops the agent and hangs up the shell.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        stopTitleTimer()
        agentTab?.close()
        session.terminate()
    }

    private func stopTitleTimer() {
        titleTimer?.invalidate()
        titleTimer = nil
    }
}
