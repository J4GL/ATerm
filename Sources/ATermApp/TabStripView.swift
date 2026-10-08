import AppKit
import ATermCore

/// The window's tabs, drawn in the title bar as in Chrome: click to select, × or the middle button to close,
/// + to open, drag to reorder. See SPEC/app/tab-strip.md.
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 38
    static let background = RGB(20, 21, 26)
    static let hoverFill = RGB(38, 39, 48)
    static let selectedTitle = RGB(230, 230, 235)
    static let title = RGB(150, 150, 160)
    static let separator = RGB(60, 62, 72)

    private static let tabTop: CGFloat = 8
    private static let tabHeight: CGFloat = 30
    private static let maxTabWidth: CGFloat = 240
    private static let trailingSpace: CGFloat = 8 + 28
    private static let dragThreshold: CGFloat = 3

    weak var controller: TerminalWindowController?

    /// A tab pressed with the left button, dragged once it moved past the threshold.
    private struct Drag {
        let tab: TerminalTab
        let downX: CGFloat
        /// Pointer x minus the tab's center when the mouse went down.
        let grabOffset: CGFloat
        var center: CGFloat?
    }

    private enum Pressed {
        case tab(Drag), close(TerminalTab), newTab, none
    }

    private var pressed: Pressed = .none
    private var middlePressed: TerminalTab?
    private var hoverPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                                .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("TabStripView is created in code")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var tabs: [TerminalTab] { controller?.tabs ?? [] }

    /// The titles drawn, in order.
    var labels: [String] { tabs.map(\.title) }

    /// The model changed (tabs, order, selection or titles).
    func tabsDidChange() {
        needsDisplay = true
        removeAllToolTips()
        for index in tabs.indices { addToolTip(tabRect(at: index), owner: self, userData: nil) }
    }

    // MARK: - Geometry

    /// Where the first tab starts: right of the window buttons, or at the edge in full screen.
    private var tabsStart: CGFloat {
        guard let window, !window.styleMask.contains(.fullScreen),
              let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview
        else { return 8 }
        return convert(zoom.frame, from: superview).maxX + 12
    }

    private var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return Self.maxTabWidth }
        return max(0, min(Self.maxTabWidth, (bounds.width - Self.trailingSpace - tabsStart) / CGFloat(tabs.count)))
    }

    private func slotRect(at index: Int) -> NSRect {
        NSRect(x: tabsStart + CGFloat(index) * tabWidth, y: Self.tabTop, width: tabWidth, height: Self.tabHeight)
    }

    /// The rectangle of tab `index`; a dragged tab follows the pointer.
    func tabRect(at index: Int) -> NSRect {
        var rect = slotRect(at: index)
        if case .tab(let drag) = pressed, let center = drag.center, tabs.indices.contains(index),
           tabs[index] === drag.tab {
            rect.origin.x = center - rect.width / 2
        }
        return rect
    }

    func closeButtonRect(at index: Int) -> NSRect {
        let tab = tabRect(at: index)
        return NSRect(x: tab.maxX - 13 - 8, y: tab.midY - 8, width: 16, height: 16)
    }

    var newTabButtonRect: NSRect {
        NSRect(x: tabsStart + CGFloat(tabs.count) * tabWidth + 4, y: 11, width: 24, height: 24)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        tabs.indices.first { tabRect(at: $0).contains(point) }
    }

    /// The × of a tab is shown, and clickable, only when the tab is wide enough.
    private func showsCloseButton(at index: Int) -> Bool {
        tabRect(at: index).width >= 40
    }

    // MARK: - Mouse

    /// In the title bar area the window server drags the window before the view sees the drag: the window is
    /// movable only while the pointer is over the empty part of the strip (or outside it).
    func updateWindowMovability(at point: NSPoint?) {
        guard let window else { return }
        let movable = point.map { tabIndex(at: $0) == nil && !newTabButtonRect.contains($0) } ?? true
        if window.isMovable != movable { window.isMovable = movable }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateWindowMovability(at: point)
        if let index = tabIndex(at: point) {
            let tab = tabs[index]
            if showsCloseButton(at: index), closeButtonRect(at: index).contains(point) {
                pressed = .close(tab)
                return
            }
            controller?.select(tab)
            pressed = .tab(Drag(tab: tab, downX: point.x, grabOffset: point.x - tabRect(at: index).midX))
        } else if newTabButtonRect.contains(point) {
            pressed = .newTab
        } else {
            pressed = .none
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .tab(var drag) = pressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        guard drag.center != nil || abs(point.x - drag.downX) > Self.dragThreshold else { return }
        let center = min(max(point.x - drag.grabOffset, tabsStart), bounds.width)
        drag.center = center
        pressed = .tab(drag)
        guard let controller, var index = tabs.firstIndex(where: { $0 === drag.tab }) else { return }
        while index + 1 < tabs.count, center > slotRect(at: index + 1).midX {
            controller.moveTab(from: index, to: index + 1)
            index += 1
        }
        while index > 0, center < slotRect(at: index - 1).midX {
            controller.moveTab(from: index, to: index - 1)
            index -= 1
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        let released = pressed
        pressed = .none
        switch released {
        case .close(let tab):
            if let index = tabs.firstIndex(where: { $0 === tab }), closeButtonRect(at: index).contains(point) {
                controller?.performCloseTab(tab)
            }
        case .newTab:
            if newTabButtonRect.contains(point) { controller?.newWindowForTab(nil) }
        case .tab, .none:
            break
        }
        tabsDidChange()
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        middlePressed = tabIndex(at: point).map { tabs[$0] }
    }

    override func otherMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { middlePressed = nil }
        guard let tab = middlePressed, let index = tabIndex(at: point), tabs[index] === tab else { return }
        controller?.performCloseTab(tab)
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateWindowMovability(at: hoverPoint)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        updateWindowMovability(at: nil)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.background.nsColor.setFill()
        bounds.fill()
        let tabs = self.tabs
        let selected = controller?.selectedTab
        let hovered = hoverPoint.flatMap { tabIndex(at: $0) }

        // Separators between two tabs that are neither selected nor hovered.
        Self.separator.nsColor.setFill()
        for index in tabs.indices.dropLast() {
            let quiet = { (i: Int) in tabs[i] !== selected && i != hovered }
            guard quiet(index), quiet(index + 1) else { continue }
            let rect = slotRect(at: index)
            NSRect(x: rect.maxX - 0.5, y: rect.minY + 8, width: 1, height: rect.height - 16).fill()
        }

        // The selected tab is drawn last, so that a dragged tab passes over its neighbors.
        let order = tabs.indices.filter { tabs[$0] !== selected } + tabs.indices.filter { tabs[$0] === selected }
        for index in order {
            drawTab(at: index, selected: tabs[index] === selected, hovered: index == hovered)
        }
        drawNewTabButton()
    }

    private func drawTab(at index: Int, selected: Bool, hovered: Bool) {
        let rect = tabRect(at: index)
        if selected {
            selectedBackground.nsColor.setFill()
            topRoundedPath(rect).fill()
        } else if hovered {
            Self.hoverFill.nsColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 3), xRadius: 8, yRadius: 8).fill()
        }
        let showsClose = (selected || hovered) && showsCloseButton(at: index)
        let close = closeButtonRect(at: index)
        let titleColor = selected ? Self.selectedTitle : Self.title
        let titleMaxX = showsClose ? close.minX - 4 : rect.maxX - 12
        drawTitle(tabs[index].title, in: NSRect(x: rect.minX + 12, y: rect.minY, width: max(0, titleMaxX - rect.minX - 12),
                                                height: rect.height), color: titleColor)
        if showsClose {
            if let hoverPoint, close.contains(hoverPoint) {
                Self.separator.nsColor.setFill()
                NSBezierPath(ovalIn: close).fill()
            }
            let cross = NSBezierPath()
            let inset = close.insetBy(dx: 4.5, dy: 4.5)
            cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            cross.lineWidth = 1.25
            titleColor.nsColor.setStroke()
            cross.stroke()
        }
    }

    /// The terminal background, so that the selected tab joins the terminal below it.
    private var selectedBackground: RGB {
        controller?.selectedTab?.session.terminal.palette.background ?? Palette.default.background
    }

    private func drawTitle(_ title: String, in rect: NSRect, color: RGB) {
        guard rect.width > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.nsColor,
                                                         .paragraphStyle: paragraph]
        let height = ceil(font.ascender - font.descender)
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (title as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: attributes)
    }

    private func drawNewTabButton() {
        let rect = newTabButtonRect
        if let hoverPoint, rect.contains(hoverPoint) {
            Self.hoverFill.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        let plus = NSBezierPath()
        let inset = rect.insetBy(dx: 7, dy: 7)
        plus.move(to: NSPoint(x: inset.midX, y: inset.minY))
        plus.line(to: NSPoint(x: inset.midX, y: inset.maxY))
        plus.move(to: NSPoint(x: inset.minX, y: inset.midY))
        plus.line(to: NSPoint(x: inset.maxX, y: inset.midY))
        plus.lineWidth = 1.5
        Self.title.nsColor.setStroke()
        plus.stroke()
    }

    /// A rectangle whose top corners are rounded (the view is flipped: the top is minY).
    private func topRoundedPath(_ rect: NSRect, radius: CGFloat = 8) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                       startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }
}

extension TabStripView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        tabIndex(at: point).map { tabs[$0].title } ?? ""
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
