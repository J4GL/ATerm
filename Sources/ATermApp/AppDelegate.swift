import AppKit
import ATermCore

/// Opens terminal windows and handles the application menu commands. See SPEC/app/contract.md.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var configuration: AppConfiguration
    private(set) var windowControllers: [TerminalWindowController] = []
    /// The window that last became key, or was last opened.
    private(set) weak var activeController: TerminalWindowController?
    /// Every tab of every window, in window order then strip order.
    var tabs: [TerminalTab] { windowControllers.flatMap(\.tabs) }
    /// Every pane of every tab.
    var panes: [TerminalPane] { tabs.flatMap(\.panes) }
    /// The selected tab of the active window.
    private var activeTab: TerminalTab? { activeController?.selectedTab }
    let assistantServices: AssistantServices
    private(set) var settingsController: SettingsWindowController?

    public init(configuration: AppConfiguration) {
        self.configuration = configuration
        assistantServices = AssistantServices(appConfiguration: configuration)
    }

    // MARK: - Application lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        // Resolving the login shell's environment can take seconds: start before the first request.
        let loginEnvironment = configuration.assistant.loginEnvironment
        Task.detached { _ = await loginEnvironment() }
        openWindow(workingDirectory: nil)
        if configuration.presentsWindows {
            NSApp.activate()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(workingDirectory: nil) }
        return true
    }

    /// The Dock icon's menu. See SPEC/app/window.md.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = tabs.filter { $0.panes.contains { $0.session.hasRunningJob } }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit ATerm?"
        alert.informativeText = busy.count == 1
            ? "A program is still running in one tab."
            : "Programs are still running in \(busy.count) tabs."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return configuration.runAlert(alert) == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        for pane in panes {
            pane.agentTab?.terminateNow()
            pane.session.terminate()
        }
    }

    // MARK: - Windows

    /// Opens a terminal window with one tab.
    @discardableResult
    func openWindow(workingDirectory: String?) -> TerminalWindowController? {
        let controller = TerminalWindowController(configuration: configuration, services: assistantServices)
        controller.appDelegate = self
        guard let window = controller.window else { return nil }
        do {
            try controller.addTab(workingDirectory: workingDirectory)
        } catch {
            showStartError(error)
            return nil
        }
        if let previous = activeController?.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 22, y: previous.frame.maxY - 22))
        } else {
            window.center()
        }
        windowControllers.append(controller)
        activeController = controller
        if configuration.presentsWindows {
            controller.showWindow(nil)
        }
        controller.layoutTrafficLights()
        return controller
    }

    /// Opens a tab in the window of `tab` (the active tab by default), in its current directory.
    func openTab(nextTo tab: TerminalTab?) {
        let source = tab ?? activeTab
        guard let controller = source?.windowController ?? activeController else {
            openWindow(workingDirectory: source?.session.currentDirectory)
            return
        }
        do {
            try controller.addTab(workingDirectory: source?.session.currentDirectory)
        } catch {
            showStartError(error)
        }
    }

    /// Opens an agent tab in the window of `pane`. See SPEC/app/assistant.md.
    func openAgentTab(from pane: TerminalPane, launch: AgentLaunch) {
        do {
            try pane.tab?.windowController?.addTab(workingDirectory: nil, agentLaunch: launch)
        } catch {
            showStartError(error)
        }
    }

    private func showStartError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The shell could not be started."
        alert.informativeText = "\(error)"
        alert.runModal()
    }

    func windowControllerDidClose(_ controller: TerminalWindowController) {
        windowControllers.removeAll { $0 === controller }
        if activeController === controller { activeController = windowControllers.last }
    }

    func windowControllerDidBecomeActive(_ controller: TerminalWindowController) {
        activeController = controller
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        openWindow(workingDirectory: nil)
    }

    @objc func newTab(_ sender: Any?) {
        openTab(nextTo: nil)
    }

    /// Shell ▸ Split Right (⌘D). See SPEC/app/splits.md.
    @objc func splitRight(_ sender: Any?) {
        split(.horizontal)
    }

    /// Shell ▸ Split Down (⇧⌘D).
    @objc func splitDown(_ sender: Any?) {
        split(.vertical)
    }

    private func split(_ axis: PaneAxis) {
        do {
            try activeController?.splitActivePane(axis)
        } catch {
            showStartError(error)
        }
    }

    /// Window ▸ Select Pane Left (⌥⌘←).
    @objc func selectPaneLeft(_ sender: Any?) {
        activeController?.selectPane(.left)
    }

    /// Window ▸ Select Pane Right (⌥⌘→).
    @objc func selectPaneRight(_ sender: Any?) {
        activeController?.selectPane(.right)
    }

    /// Window ▸ Select Pane Above (⌥⌘↑).
    @objc func selectPaneAbove(_ sender: Any?) {
        activeController?.selectPane(.up)
    }

    /// Window ▸ Select Pane Below (⌥⌘↓).
    @objc func selectPaneBelow(_ sender: Any?) {
        activeController?.selectPane(.down)
    }

    /// Window ▸ Zoom Pane (⇧⌘↩).
    @objc func togglePaneZoom(_ sender: Any?) {
        activeTab?.toggleZoom()
    }

    /// Window ▸ Equalize Panes (⌃⌘=).
    @objc func equalizePanes(_ sender: Any?) {
        activeTab?.equalize()
    }

    /// Shell ▸ Close (⌘W): the active pane, its tab with its last pane.
    @objc func closePane(_ sender: Any?) {
        guard let controller = activeController, let tab = controller.selectedTab else { return }
        controller.performClosePane(tab.activePane)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activeController?.selectNextTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activeController?.selectPreviousTab()
    }

    /// ⌘1…⌘9: the menu item's tag is the number.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        activeController?.selectTab(number: item.tag)
    }

    @objc func makeTextBigger(_ sender: Any?) {
        guard let controller = activeController, let tab = activeTab else { return }
        controller.setFontSize(tab.terminalView.fontSize + 1)
    }

    @objc func makeTextSmaller(_ sender: Any?) {
        guard let controller = activeController, let tab = activeTab else { return }
        controller.setFontSize(tab.terminalView.fontSize - 1)
    }

    @objc func makeTextStandardSize(_ sender: Any?) {
        activeController?.setFontSize(configuration.fontSize)
    }

    @objc func clearScrollback(_ sender: Any?) {
        activeTab?.terminalView.clearScrollback(sender)
    }

    @objc func askAssistant(_ sender: Any?) {
        activeTab?.assistant.open()
    }

    @objc func stopAgent(_ sender: Any?) {
        activeTab?.agentTab?.stop()
    }

    /// ATerm ▸ Settings… (⌘,): one app-modal window, until Save, Cancel or its close button.
    /// See SPEC/app/settings.md.
    @objc func showSettings(_ sender: Any?) {
        if let window = settingsController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(services: assistantServices, defaults: configuration.defaults,
                                                  stopModal: configuration.stopModal)
        controller.onClose = { [weak self] in self?.settingsController = nil }
        settingsController = controller
        controller.prepareToShow()
        if let window = controller.window { configuration.runModal(window) }
    }

    @objc func toggleOptionAsMeta(_ sender: Any?) {
        configuration.optionAsMeta.toggle()
        configuration.defaults.set(configuration.optionAsMeta, forKey: "OptionAsMeta")
        for pane in panes { pane.terminalView.optionAsMeta = configuration.optionAsMeta }
    }
}

extension AppDelegate: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleOptionAsMeta(_:)):
            menuItem.state = configuration.optionAsMeta ? .on : .off
            return true
        case #selector(makeTextBigger(_:)), #selector(makeTextSmaller(_:)), #selector(makeTextStandardSize(_:)),
             #selector(clearScrollback(_:)), #selector(askAssistant(_:)),
             #selector(closePane(_:)), #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return activeTab != nil
        case #selector(selectTabByNumber(_:)):
            // ⌘9 is the last tab; ⌘1…⌘8 need that many tabs.
            let count = activeController?.tabs.count ?? 0
            return count > 0 && (menuItem.tag >= 9 || menuItem.tag <= count)
        case #selector(selectPaneLeft(_:)), #selector(selectPaneRight(_:)), #selector(selectPaneAbove(_:)),
             #selector(selectPaneBelow(_:)), #selector(equalizePanes(_:)):
            return (activeTab?.panes.count ?? 0) > 1
        case #selector(togglePaneZoom(_:)):
            menuItem.state = activeTab?.isZoomed == true ? .on : .off
            return (activeTab?.panes.count ?? 0) > 1
        case #selector(splitRight(_:)):
            return activeTab?.frameForSplit(.horizontal) != nil
        case #selector(splitDown(_:)):
            return activeTab?.frameForSplit(.vertical) != nil
        case #selector(stopAgent(_:)):
            return activeTab?.agentTab?.isRunning == true
        default:
            return true
        }
    }
}

/// Entry point of the executable.
public enum ATermMain {
    @MainActor public static func run() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate(configuration: .standard())
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
