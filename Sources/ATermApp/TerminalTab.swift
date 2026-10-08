import AppKit
import ATermCore

/// One tab of a terminal window: its panes, laid out by its view, and the active one, whose session, view,
/// assistant and title are the tab's. See SPEC/app/contract.md and SPEC/app/splits.md.
@MainActor
final class TerminalTab {
    /// The panes and the dividers between them, below the tab strip.
    let view = PaneContainerView()
    private(set) var root: PaneNode
    /// The pane holding the keyboard while the tab is selected.
    private(set) var activePane: TerminalPane
    weak var windowController: TerminalWindowController?
    private(set) var isClosed = false
    /// The active pane alone fills the tab, the others hidden. See SPEC/app/splits.md.
    private(set) var isZoomed = false

    init(pane: TerminalPane) {
        root = .pane(pane)
        activePane = pane
        pane.tab = self
        view.tab = self
        view.addSubview(pane.terminalView)
    }

    /// The active pane's.
    var session: TerminalSession { activePane.session }
    /// The active pane's.
    var terminalView: TerminalView { activePane.terminalView }
    /// The active pane's.
    var assistant: AssistantController { activePane.assistant }
    /// The active pane's.
    var agentTab: AgentTab? { activePane.agentTab }
    /// The active pane's.
    var title: String { activePane.title }

    var window: NSWindow? { windowController?.window }
    /// In tree order: left to right, top to bottom.
    var panes: [TerminalPane] { root.panes }

    /// Starts the shell, or the agent of an agent tab.
    func start() throws {
        try activePane.start()
    }

    func paneTitleDidChange(_ pane: TerminalPane) {
        guard pane === activePane else { return }
        windowController?.tabTitleDidChange(self)
    }

    /// Makes `pane`, one of the tab's, the active pane: its title becomes the tab's.
    func activate(_ pane: TerminalPane) {
        guard pane !== activePane, panes.contains(where: { $0 === pane }) else { return }
        activePane = pane
        isZoomed = false
        layoutPanes()
        windowController?.tabTitleDidChange(self)
    }

    /// The pane next to the active one toward `direction`, in the layout without zoom. See SPEC/app/splits.md.
    func neighbor(toward direction: PaneDirection) -> TerminalPane? {
        PaneNode.neighbor(of: activePane, toward: direction, in: currentLayout.frames)
    }

    // MARK: - Splitting

    /// The frame of a pane splitting the active pane along `axis`; nil when the active pane is too short for two
    /// panes and a divider.
    func frameForSplit(_ axis: PaneAxis) -> NSRect? {
        let minimum = minimumPaneSize
        guard let frame = currentLayout.frames.first(where: { $0.pane === activePane })?.frame else { return nil }
        let length = axis == .horizontal ? frame.width : frame.height
        let leaf = axis == .horizontal ? minimum.width : minimum.height
        guard length >= leaf * 2 + PaneNode.dividerThickness else { return nil }
        return PaneNode.divide(frame, axis, ratio: 0.5, minimums: (leaf, leaf)).second
    }

    /// Puts `pane`, started, beside (`horizontal`) or below (`vertical`) the active pane, which keeps the first
    /// half; `pane` becomes active.
    func split(_ axis: PaneAxis, with pane: TerminalPane) {
        view.cancelDrag()
        isZoomed = false
        root = root.splitting(activePane, axis, with: pane)
        pane.tab = self
        view.addSubview(pane.terminalView)
        activePane = pane
        layoutPanes()
        windowController?.tabTitleDidChange(self)
    }

    /// Closes `pane`, one of several panes: its sibling takes its space and, when it was active, the pane next to
    /// it toward the sibling becomes active.
    func remove(_ pane: TerminalPane) {
        guard panes.count > 1, let remaining = root.removing(pane) else { return }
        view.cancelDrag()
        isZoomed = false
        if pane === activePane {
            let frames = currentLayout.frames
            activePane = root.directionToSibling(of: pane)
                .flatMap { PaneNode.neighbor(of: pane, toward: $0, in: frames) } ?? remaining.panes[0]
        }
        root = remaining
        pane.close()
        pane.terminalView.removeFromSuperview()
        pane.tab = nil
        layoutPanes()
        windowController?.tabTitleDidChange(self)
    }

    /// Gives every split the proportion of its children's weights. See SPEC/app/splits.md.
    func equalize() {
        view.cancelDrag()
        isZoomed = false
        root = root.equalized()
        layoutPanes()
    }

    /// Shows the active pane alone over the tab, or the layout again; a tab with one pane has nothing to zoom.
    func toggleZoom() {
        guard isZoomed || panes.count > 1 else { return }
        view.cancelDrag()
        isZoomed.toggle()
        layoutPanes()
    }

    // MARK: - Dividers

    /// Moves the divider of the split at `path` to follow the pointer at `point`, pressed `offset` points into
    /// it along the split's axis; each side keeps its minimum.
    func moveDivider(at path: [Bool], to point: NSPoint, offset: CGFloat) {
        let minimum = minimumPaneSize
        guard let divider = currentLayout.dividers.first(where: { $0.path == path }),
              case .split(let axis, _, let first, let second)? = root.node(at: path[...])
        else { return }
        let split = divider.splitFrame
        let horizontal = axis == .horizontal
        let available = (horizontal ? split.width : split.height) - PaneNode.dividerThickness
        guard available > 0 else { return }
        var length = ((horizontal ? point.x - split.minX : point.y - split.minY) - offset).rounded()
        let minimums = (first.minimumLength(axis, minimum), second.minimumLength(axis, minimum))
        if available >= minimums.0 + minimums.1 {
            length = min(max(length, minimums.0), available - minimums.1)
        }
        length = min(max(length, 0), available)
        root = root.settingRatio(length / available, at: path[...])
        layoutPanes()
    }

    // MARK: - Layout

    /// A pane's smallest size: 2 columns × 1 row.
    private var minimumPaneSize: NSSize {
        activePane.terminalView.contentSize(cols: 2, rows: 1)
    }

    /// The layout of the tree over the tab's view, without zoom.
    private var currentLayout: PaneNode.Layout {
        root.layout(in: view.bounds, minimum: minimumPaneSize)
    }

    /// Lays the panes out over the tab's view; zoomed, the active pane covers it and the others, hidden, keep
    /// their frames (and their terminals their grids).
    func layoutPanes() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if isZoomed {
            for pane in panes where pane !== activePane { pane.terminalView.isHidden = true }
            if activePane.terminalView.frame != bounds { activePane.terminalView.frame = bounds }
            activePane.terminalView.isHidden = false
            view.dividers = []
        } else {
            let layout = currentLayout
            for (pane, frame) in layout.frames {
                if pane.terminalView.frame != frame { pane.terminalView.frame = frame }
                pane.terminalView.isHidden = false
            }
            view.dividers = layout.dividers
        }
        let framed = panes.count > 1
        for pane in panes { pane.terminalView.showsActiveFrame = framed && pane === activePane }
    }

    // MARK: - Close

    /// Stops the agents and hangs up the shells.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for pane in panes { pane.close() }
    }
}

/// A tab's view: its panes, side by side or stacked, and the 1-point dividers between them, which the mouse drags.
/// See SPEC/app/splits.md.
@MainActor
final class PaneContainerView: NSView {
    /// How far beyond each side of a divider a press grabs it.
    static let grabDistance: CGFloat = 3

    weak var tab: TerminalTab?
    var dividers: [PaneNode.Divider] = [] {
        didSet {
            guard dividers != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The pressed divider's path, and how far into the divider it was pressed along its axis.
    private var drag: (path: [Bool], offset: CGFloat)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Synchronous, like the window's content: a resized window has resized terminals.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        tab?.layoutPanes()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !dividers.isEmpty else { return }
        TabStripView.background.nsColor.setFill()
        for divider in dividers {
            divider.frame.intersection(dirtyRect).fill()
        }
    }

    // MARK: - Dragging dividers

    private func grabRect(_ divider: PaneNode.Divider) -> NSRect {
        divider.axis == .horizontal
            ? divider.frame.insetBy(dx: -Self.grabDistance, dy: 0)
            : divider.frame.insetBy(dx: 0, dy: -Self.grabDistance)
    }

    private func divider(at point: NSPoint) -> PaneNode.Divider? {
        dividers.first { grabRect($0).contains(point) }
    }

    /// Near a divider a press is the tab view's, over the panes' padding; a hidden tab takes none.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if divider(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        for divider in dividers {
            addCursorRect(grabRect(divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = divider(at: point) else { return }
        drag = (divider.path, divider.axis == .horizontal ? point.x - divider.frame.minX : point.y - divider.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        tab?.moveDivider(at: drag.path, to: convert(event.locationInWindow, from: nil), offset: drag.offset)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    /// Forgets the pressed divider, which a change of the tree may have removed.
    func cancelDrag() {
        drag = nil
    }
}
