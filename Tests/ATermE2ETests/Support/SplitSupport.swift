import AppKit
import Testing
@testable import ATermApp
import ATermCore

/// The first child's length of a split `length` long with proportion `p`: `round(p × (L − 1))`.
/// See SPEC/app/splits.md.
func splitLength(_ p: CGFloat, of length: CGFloat) -> CGFloat {
    (p * (length - 1)).rounded()
}

/// A menu item's shortcut as the menu shows it: ⌃⌥⇧⌘ then the key, an uppercase letter counting as ⇧, the arrow
/// and Return keys as ↑↓←→ and ↩. Empty without a key equivalent.
@MainActor
func displayedShortcut(_ item: NSMenuItem) -> String {
    let key = item.keyEquivalent
    guard let character = key.first else { return "" }
    var flags = item.keyEquivalentModifierMask
    if key.count == 1, character.isLetter, character.isUppercase { flags.insert(.shift) }
    var text = ""
    if flags.contains(.control) { text += "⌃" }
    if flags.contains(.option) { text += "⌥" }
    if flags.contains(.shift) { text += "⇧" }
    if flags.contains(.command) { text += "⌘" }
    let names = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩"]
    return text + (names[key] ?? key.uppercased())
}

/// Split panes: their shortcuts, their geometry and the pixels of the tab area. See SPEC/app/splits.md.
extension AppHarness {
    enum SplitDirection {
        case right, down
    }

    /// ⌘D or ⇧⌘D through the main menu; the new pane once it shows the prompt, nil when no pane was added.
    func split(_ direction: SplitDirection, in tab: TerminalTab? = nil) async -> TerminalPane? {
        let tab = tab ?? controller
        let count = tab.panes.count
        switch direction {
        case .right: shortcut("d")
        case .down: shortcut("D", modifiers: [.command, .shift])
        }
        guard tab.panes.count == count + 1 else { return nil }
        let pane = tab.activePane
        _ = await waitForPrompt(pane)
        return pane
    }

    /// A menu shortcut on a named key, with the flags AppKit adds to an arrow key.
    @discardableResult
    func shortcut(_ key: Key, modifiers: NSEvent.ModifierFlags) -> Bool {
        var flags = modifiers
        if [Key.up, .down, .left, .right].contains(key) { flags.formUnion([.numericPad, .function]) }
        let event = keyEvent(characters: key.characters, keyCode: key.keyCode, modifiers: flags,
                             window: controllers.last?.window)
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// Window ▸ Select Pane …: ⌥⌘ and an arrow.
    @discardableResult
    func selectPane(_ arrow: Key) -> Bool {
        shortcut(arrow, modifiers: [.command, .option])
    }

    /// Window ▸ Zoom Pane: ⇧⌘↩.
    @discardableResult
    func toggleZoom() -> Bool {
        shortcut(.returnKey, modifiers: [.command, .shift])
    }

    /// Window ▸ Equalize Panes: ⌃⌘=.
    @discardableResult
    func equalize() -> Bool {
        shortcut("=", modifiers: [.command, .control])
    }

    // MARK: - Geometry

    /// The size of the tab area: the bounds of the tab's view.
    func areaSize(_ tab: TerminalTab? = nil) -> NSSize {
        (tab ?? controller).view.bounds.size
    }

    /// The frame of `pane` in its tab's view, y down from the top of the area.
    func frame(of pane: TerminalPane) -> NSRect {
        pane.terminalView.frame
    }

    /// The whole cells that fit the frame of `pane` inside the padding: ⌊(w − 12) / cw⌋ × ⌊(h − 8) / ch⌋.
    func gridOfFrame(_ pane: TerminalPane) -> (cols: Int, rows: Int) {
        let frame = frame(of: pane)
        let cell = pane.terminalView.cellSize
        return (Int((frame.width - 12) / cell.width + 0.001), Int((frame.height - 8) / cell.height + 0.001))
    }

    /// The terminal of `pane` has the grid of its frame.
    func hasGridOfFrame(_ pane: TerminalPane) -> Bool {
        let grid = gridOfFrame(pane)
        return pane.session.terminal.cols == grid.cols && pane.session.terminal.rows == grid.rows
    }

    // MARK: - Mouse in the tab area

    /// The view AppKit sends a press at `point` of the tab area to: the hit test of the window's content view.
    func hitView(at point: NSPoint, in tab: TerminalTab? = nil) -> NSView? {
        let area = (tab ?? controller).view
        guard let content = area.window?.contentView else { return nil }
        let inWindow = area.convert(point, to: nil)
        return content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
    }

    /// A press at `point` of the tab area, delivered to the view AppKit sends it to.
    func pressArea(at point: NSPoint, in tab: TerminalTab? = nil) -> AreaPress? {
        let tab = tab ?? controller
        guard let view = hitView(at: point, in: tab) else { return nil }
        let press = AreaPress(view: view, area: tab.view)
        view.mouseDown(with: press.event(.leftMouseDown, at: point))
        return press
    }

    /// A press at `start`, a drag to `end` and the release there.
    func dragInArea(from start: NSPoint, to end: NSPoint, in tab: TerminalTab? = nil) {
        guard let press = pressArea(at: start, in: tab) else { return }
        press.drag(to: end)
        press.release(at: end)
    }

    // MARK: - Pixels

    /// The tab's view — its panes, its dividers and the active frame — rendered into an sRGB bitmap.
    func renderArea(_ tab: TerminalTab? = nil) -> RenderedArea {
        let (rep, scale) = snapshot((tab ?? controller).view)
        return RenderedArea(rep: rep, scale: scale)
    }

    // MARK: - Menus

    /// A menu of the main menu, by title.
    func menu(_ title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == title }?.submenu
    }

    /// An item of a menu of the main menu, by titles.
    func menuItem(_ title: String, in menuTitle: String) -> NSMenuItem? {
        menu(menuTitle)?.items.first { $0.title == title }
    }
}

/// A press in the tab area: the view that got the mouse down gets the drags and the release, as with AppKit.
@MainActor
struct AreaPress {
    let view: NSView
    let area: PaneContainerView

    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: area.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: area.window!.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func drag(to point: NSPoint) {
        view.mouseDragged(with: event(.leftMouseDragged, at: point))
    }

    func release(at point: NSPoint) {
        view.mouseUp(with: event(.leftMouseUp, at: point))
    }
}

/// A rendered snapshot of a tab's view, sampled in its coordinates (y down from the top of the area).
@MainActor
struct RenderedArea {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    /// Every device pixel of `rect`.
    func pixels(in rect: NSRect) -> [RGB] {
        let x0 = max(0, Int((rect.minX * scale).rounded())), x1 = min(rep.pixelsWide, Int((rect.maxX * scale).rounded()))
        let y0 = max(0, Int((rect.minY * scale).rounded())), y1 = min(rep.pixelsHigh, Int((rect.maxY * scale).rounded()))
        var result: [RGB] = []
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                result.append(rep.rgb(x: x, y: y))
            }
        }
        return result
    }

    /// The pixels of the 1-point band `inset` points inside `frame`, at the middle of each edge and at each corner.
    func edges(of frame: NSRect, inset: CGFloat = 0) -> [RGB] {
        let band = frame.insetBy(dx: inset, dy: inset)
        let midX = band.midX.rounded(.down), midY = band.midY.rounded(.down)
        let squares = [
            NSPoint(x: midX, y: band.minY), NSPoint(x: midX, y: band.maxY - 1),
            NSPoint(x: band.minX, y: midY), NSPoint(x: band.maxX - 1, y: midY),
            NSPoint(x: band.minX, y: band.minY), NSPoint(x: band.maxX - 1, y: band.minY),
            NSPoint(x: band.minX, y: band.maxY - 1), NSPoint(x: band.maxX - 1, y: band.maxY - 1),
        ]
        return squares.flatMap { pixels(in: NSRect(origin: $0, size: NSSize(width: 1, height: 1))) }
    }
}
