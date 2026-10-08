import AppKit
import ATermCore

/// Mouse selection, mouse reporting and the scroll wheel. See SPEC/app/input.md and SPEC/app/scroll-selection.md.
extension TerminalView {
    /// The cell under a mouse event, clamped to the grid.
    func gridPosition(for event: NSEvent) -> (row: Int, col: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(floor((point.x - Self.padding.width) / cellSize.width))
        let row = Int(floor((point.y - Self.padding.height) / cellSize.height))
        return (min(max(0, row), terminal.rows - 1), min(max(0, col), terminal.cols - 1))
    }

    func selectionPoint(for event: NSEvent) -> SelectionPoint {
        let (row, col) = gridPosition(for: event)
        return SelectionPoint(line: firstDisplayedLineIndex + row, col: col)
    }

    /// The program asked for mouse events and Shift does not override it.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        terminal.modes.mouseTracking != .none && !event.modifierFlags.contains(.shift)
    }

    private func report(_ button: MouseButton, _ action: MouseAction, _ event: NSEvent) {
        let (row, col) = gridPosition(for: event)
        if action == .motion {
            if let last = lastReportedMouseCell, last == (row, col) { return }
        }
        lastReportedMouseCell = (row, col)
        let mouseEvent = MouseEvent(button: button, action: action, row: row, col: col,
                                    modifiers: Self.keyModifiers(event.modifierFlags))
        if let bytes = MouseEncoder.encode(mouseEvent, tracking: terminal.modes.mouseTracking,
                                           encoding: terminal.modes.mouseEncoding) {
            session.send(bytes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onHoldInput?(.other)
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command) {
            // ⌘-click opens the link under the pointer.
            if let url = link(at: selectionPoint(for: event)) { openURL(url) }
            return
        }
        if reportsMouse(event) {
            reportingMouseButton = .left
            report(.left, .press, event)
            if selection != nil {
                selection = nil
                needsDisplay = true
            }
            return
        }
        // zsh highlights pasted text until the next key; a click in the terminal drops the highlight too.
        session.sendClick()
        let point = selectionPoint(for: event)
        pendingSelectionAnchor = nil
        switch event.clickCount {
        case 2:
            selection = Selection(anchor: point, granularity: .word)
        case 3...:
            selection = Selection(anchor: point, granularity: .line)
        default:
            // Shift extends the selection, unless it is bypassing a program that captures the mouse.
            if event.modifierFlags.contains(.shift), terminal.modes.mouseTracking == .none, var extended = selection {
                extended.head = point
                selection = extended
            } else {
                selection = nil
                pendingSelectionAnchor = point
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = reportingMouseButton {
            report(button, .motion, event)
            return
        }
        autoscrollIfNeeded(event)
        let point = selectionPoint(for: event)
        if let anchor = pendingSelectionAnchor {
            if anchor != point {
                selection = Selection(anchor: anchor, head: point)
                pendingSelectionAnchor = nil
            }
        } else if var extended = selection {
            extended.head = point
            selection = extended
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        if let button = reportingMouseButton {
            reportingMouseButton = nil
            report(button, .release, event)
            return
        }
        pendingSelectionAnchor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onHoldInput?(.other)
        if reportsMouse(event) {
            reportingMouseButton = .right
            report(.right, .press, event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportingMouseButton == .right {
            reportingMouseButton = nil
            report(.right, .release, event)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        onHoldInput?(.other)
        guard reportsMouse(event) else { return }
        reportingMouseButton = .middle
        report(.middle, .press, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard reportingMouseButton == .middle else { return }
        reportingMouseButton = nil
        report(.middle, .release, event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if let button = reportingMouseButton { report(button, .motion, event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if let button = reportingMouseButton { report(button, .motion, event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if terminal.modes.mouseTracking == .anyEvent && !event.modifierFlags.contains(.shift) {
            report(.none, .motion, event)
        }
    }

    /// Scrolls the viewport while a selection is dragged above or below the view.
    private func autoscrollIfNeeded(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 {
            scrollOffset = min(scrollOffset + 1, terminal.isAlternateScreenActive ? 0 : terminal.scrollbackCount)
        } else if point.y > bounds.height {
            scrollOffset = max(0, scrollOffset - 1)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onHoldInput?(.other)
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta /= cellSize.height }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)

        if reportsMouse(event) {
            for _ in 0..<abs(lines) { report(lines > 0 ? .wheelUp : .wheelDown, .press, event) }
        } else if terminal.isAlternateScreenActive {
            guard terminal.modes.alternateScroll else { return }
            let key: Key = lines > 0 ? .up : .down
            let bytes = KeyEncoder.encode(key, modes: terminal.modes)
            for _ in 0..<abs(lines) { session.send(bytes) }
        } else {
            let offset = min(max(0, scrollOffset + lines), terminal.scrollbackCount)
            if offset != scrollOffset {
                scrollOffset = offset
                needsDisplay = true
            }
        }
    }
}
