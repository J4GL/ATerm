import AppKit
import ATermCore

/// One terminal window: its tab strip in the title bar and its tabs. See SPEC/app/window.md and
/// SPEC/app/tab-strip.md.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let initialGrid = (cols: 80, rows: 24)

    let tabStrip = TabStripView()
    private(set) var tabs: [TerminalTab] = []
    private(set) weak var selectedTab: TerminalTab?
    private let configuration: AppConfiguration
    private let services: AssistantServices
    weak var appDelegate: AppDelegate?
    private(set) var isClosed = false
    /// Set while every pane changes its font size, so that the window is resized once.
    private var isChangingFontSize = false
    /// The cell size of the window's terminals, which the window is sized in.
    private(set) var cellSize = NSSize.zero

    init(configuration: AppConfiguration, services: AssistantServices) {
        self.configuration = configuration
        self.services = services
        let container = WindowContentView(tabStrip: tabStrip)
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        let background = configuration.palette.background
        window.backgroundColor = NSColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255,
                                         blue: CGFloat(background.b) / 255, alpha: 1)
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        window.onFirstResponderChange = { [weak self] in self?.firstResponderDidChange() }
        tabStrip.controller = self
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code")
    }

    // MARK: - Tabs

    /// Opens a tab after the last one, selects it and starts its shell (or its agent).
    @discardableResult
    func addTab(workingDirectory: String?, agentLaunch: AgentLaunch? = nil) throws -> TerminalTab {
        guard let window, let container = window.contentView as? WindowContentView else {
            throw CocoaError(.featureUnsupported)
        }
        let grid = tabs.isEmpty ? Self.initialGrid : tabAreaGrid
        let pane = makePane(cols: grid.cols, rows: grid.rows, workingDirectory: workingDirectory,
                            agentLaunch: agentLaunch)
        if tabs.isEmpty {
            cellSize = pane.terminalView.cellSize
            window.contentResizeIncrements = cellSize
            window.setContentSize(contentSize(cols: grid.cols, rows: grid.rows))
        }
        let tab = TerminalTab(pane: pane)
        tab.windowController = self
        tab.view.isHidden = true
        container.addTabView(tab.view)
        do {
            try tab.start()
        } catch {
            tab.view.removeFromSuperview()
            tab.close()
            throw error
        }
        tabs.append(tab)
        if tabs.count == 1 { updateSizeConstraints() }
        container.layoutTabViews()
        select(tab)
        layoutTrafficLights()
        return tab
    }

    /// Splits the selected tab's active pane along `axis`: a new shell in its directory, beside or below it, at
    /// the grid of the frame it gets. See SPEC/app/splits.md.
    func splitActivePane(_ axis: PaneAxis) throws {
        guard let tab = selectedTab, let frame = tab.frameForSplit(axis) else { return }
        let source = tab.activePane
        let grid = TerminalView.gridSize(for: frame.size, cellSize: source.terminalView.cellSize)
        let pane = makePane(cols: grid.cols, rows: grid.rows, workingDirectory: source.session.currentDirectory)
        do {
            try pane.start()
        } catch {
            pane.close()
            throw error
        }
        tab.split(axis, with: pane)
        window?.makeFirstResponder(pane.terminalView)
    }

    /// Makes the pane next to the active one toward `direction` active; nothing without one.
    func selectPane(_ direction: PaneDirection) {
        guard let tab = selectedTab, let pane = tab.neighbor(toward: direction) else { return }
        tab.activate(pane)
        window?.makeFirstResponder(pane.terminalView)
    }

    /// A pane with the font size and the Option as Meta setting of the active pane.
    private func makePane(cols: Int, rows: Int, workingDirectory: String?,
                          agentLaunch: AgentLaunch? = nil) -> TerminalPane {
        let pane = TerminalPane(configuration: configuration, cols: cols, rows: rows,
                                workingDirectory: workingDirectory, services: services, agentLaunch: agentLaunch)
        let view = pane.terminalView
        if let source = selectedTab?.terminalView {
            if source.fontSize != view.fontSize { view.setFontSize(source.fontSize) }
            view.optionAsMeta = source.optionAsMeta
        }
        view.onCellSizeChange = { [weak self, weak view] in
            guard let self, let view else { return }
            self.cellSizeDidChange(view)
        }
        return pane
    }

    /// Shows `tab` and gives it the keyboard.
    func select(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let previous = selectedTab
        selectedTab = tab
        for other in tabs where other !== tab { other.view.isHidden = true }
        tab.view.isHidden = false
        if previous !== tab || window?.firstResponder !== tab.terminalView {
            window?.makeFirstResponder(tab.terminalView)
        }
        window?.title = tab.title
        tabStrip.tabsDidChange()
    }

    func selectNextTab() {
        selectTab(offset: 1)
    }

    func selectPreviousTab() {
        selectTab(offset: -1)
    }

    private func selectTab(offset: Int) {
        guard let selectedTab, let index = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// ⌘1…⌘8 select that tab, ⌘9 the last one.
    func selectTab(number: Int) {
        guard !tabs.isEmpty, number >= 1 else { return }
        if number >= 9 {
            select(tabs[tabs.count - 1])
        } else if number <= tabs.count {
            select(tabs[number - 1])
        }
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination) else { return }
        tabs.insert(tabs.remove(at: source), at: destination)
        tabStrip.tabsDidChange()
    }

    /// The pane whose view holds the keyboard — its terminal view or its assistant bar — becomes active.
    private func firstResponderDidChange() {
        guard !isClosed, let tab = selectedTab, let responder = window?.firstResponder as? NSView,
              let pane = tab.panes.first(where: { responder.isDescendant(of: $0.terminalView) })
        else { return }
        tab.activate(pane)
    }

    func tabTitleDidChange(_ tab: TerminalTab) {
        if tab === selectedTab { window?.title = tab.title }
        tabStrip.tabsDidChange()
    }

    /// Closes `tab` after asking when a program runs in one of its panes.
    func performCloseTab(_ tab: TerminalTab) {
        let programs = Self.runningPrograms(in: tab.panes)
        guard !programs.isEmpty else {
            closeTab(tab)
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        confirmTermination(message: "Do you want to terminate running processes in this tab?",
                           information: "Closing this tab will terminate \(programs.joined(separator: ", ")).",
                           window: window) { [weak self] in
            self?.closeTab(tab)
        }
    }

    /// Closes `tab`; the window closes with its last tab.
    func closeTab(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else {
            window?.close()
            return
        }
        tabs.remove(at: index)
        tab.close()
        tab.view.removeFromSuperview()
        if selectedTab === tab || selectedTab == nil {
            select(tabs[min(index, tabs.count - 1)])
        } else {
            tabStrip.tabsDidChange()
        }
    }

    /// Closes `pane` after asking when a program runs in it; a tab's only pane closes the tab.
    func performClosePane(_ pane: TerminalPane) {
        guard let tab = pane.tab else { return }
        guard tab.panes.count > 1 else {
            performCloseTab(tab)
            return
        }
        let programs = Self.runningPrograms(in: [pane])
        guard !programs.isEmpty else {
            closePane(pane)
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        confirmTermination(message: "Do you want to terminate running processes in this pane?",
                           information: "Closing this pane will terminate \(programs.joined(separator: ", ")).",
                           window: window) { [weak self] in
            self?.closePane(pane)
        }
    }

    /// Closes `pane`; its tab closes with its last pane. See SPEC/app/splits.md.
    func closePane(_ pane: TerminalPane) {
        guard !pane.isClosed, let tab = pane.tab, tabs.contains(where: { $0 === tab }) else { return }
        guard tab.panes.count > 1 else {
            closeTab(tab)
            return
        }
        let wasActive = tab.activePane === pane
        tab.remove(pane)
        if wasActive, tab === selectedTab { window?.makeFirstResponder(tab.terminalView) }
    }

    /// The programs running in `panes`, as a confirmation names them.
    private static func runningPrograms(in panes: [TerminalPane]) -> [String] {
        panes.filter { $0.session.hasRunningJob }.map { $0.session.runningProgramName ?? "a program" }
    }

    // MARK: - Size and fonts

    /// The window's content size showing a grid of `cols` × `rows` cells below the tab strip.
    func contentSize(cols: Int, rows: Int) -> NSSize {
        let size = TerminalView.contentSize(cols: cols, rows: rows, cellSize: cellSize)
        return NSSize(width: size.width, height: size.height + TabStripView.height)
    }

    /// The window resizes in whole cells and never below 20 × 5.
    func updateSizeConstraints() {
        guard let window else { return }
        window.contentResizeIncrements = cellSize
        window.contentMinSize = contentSize(cols: 20, rows: 5)
    }

    /// The grid of one terminal covering the tab area. See SPEC/app/splits.md.
    private var tabAreaGrid: (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0,
              let container = window?.contentView as? WindowContentView
        else { return Self.initialGrid }
        return TerminalView.gridSize(for: container.tabAreaFrame.size, cellSize: cellSize)
    }

    /// Changes the font size of every pane; the grid of the tab area is kept.
    func setFontSize(_ size: CGFloat) {
        guard let selectedTab else { return }
        let grid = tabAreaGrid
        isChangingFontSize = true
        for pane in tabs.flatMap(\.panes) { pane.terminalView.setFontSize(min(max(size, 6), 72)) }
        isChangingFontSize = false
        resize(keeping: grid, cellSize: selectedTab.terminalView.cellSize)
    }

    /// The cell size of `view` changed (font size or display scale): the first view to change resizes the window
    /// to keep the grid of the tab area; the others, whose cell size is then the window's, only update their grid.
    func cellSizeDidChange(_ view: TerminalView) {
        guard !isChangingFontSize else { return }
        guard view.cellSize != cellSize else {
            view.updateGridSize()
            return
        }
        resize(keeping: tabAreaGrid, cellSize: view.cellSize)
    }

    private func resize(keeping grid: (cols: Int, rows: Int), cellSize: NSSize) {
        guard let window else { return }
        self.cellSize = cellSize
        updateSizeConstraints()
        window.setContentSize(contentSize(cols: grid.cols, rows: grid.rows))
        for pane in tabs.flatMap(\.panes) { pane.terminalView.updateGridSize() }
    }

    // MARK: - Window buttons

    /// Centers the close, minimize and zoom buttons vertically in the tab strip.
    func layoutTrafficLights() {
        guard let window else { return }
        let middle = tabStrip.convert(NSPoint(x: 0, y: tabStrip.bounds.midY), to: nil).y
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let superview = button.superview else { continue }
            let target = superview.convert(NSPoint(x: 0, y: middle), from: nil).y
            let y = (target - button.frame.height / 2).rounded()
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
        tabStrip.needsDisplay = true
    }

    func windowDidResize(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        tabStrip.tabsDidChange()
    }

    // MARK: - Close

    private func confirmTermination(message: String, information: String, window: NSWindow,
                                    terminate: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { terminate() }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let programs = Self.runningPrograms(in: tabs.flatMap(\.panes))
        guard !programs.isEmpty else { return true }
        confirmTermination(message: "Do you want to terminate running processes in this window?",
                           information: "Closing this window will terminate \(programs.joined(separator: ", ")).",
                           window: sender) { [weak self] in
            self?.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        for tab in tabs { tab.close() }
        appDelegate?.windowControllerDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appDelegate?.windowControllerDidBecomeActive(self)
    }

    /// The + button of the tab strip.
    @objc override func newWindowForTab(_ sender: Any?) {
        appDelegate?.openTab(nextTo: selectedTab)
    }
}

/// Tells its controller when its first responder changes, so that the pane holding the keyboard is the active one.
@MainActor
private final class TerminalWindow: NSWindow {
    var onFirstResponderChange: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChange?() }
        return accepted
    }
}

/// The window's content: the tab strip on top, the tabs' views stacked below it, over the tab area.
@MainActor
private final class WindowContentView: NSView {
    let tabStrip: TabStripView

    init(tabStrip: TabStripView) {
        self.tabStrip = tabStrip
        super.init(frame: .zero)
        addSubview(tabStrip)
    }

    required init?(coder: NSCoder) {
        fatalError("WindowContentView is created in code")
    }

    override var isFlipped: Bool { true }

    func addTabView(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: tabStrip)
        view.frame = tabAreaFrame
    }

    var tabAreaFrame: NSRect {
        NSRect(x: 0, y: TabStripView.height, width: bounds.width, height: max(0, bounds.height - TabStripView.height))
    }

    func layoutTabViews() {
        tabStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabStripView.height)
        let frame = tabAreaFrame
        for view in subviews where view !== tabStrip && view.frame != frame {
            view.frame = frame
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutTabViews()
    }
}
