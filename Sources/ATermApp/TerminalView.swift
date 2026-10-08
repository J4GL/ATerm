import AppKit
import ATermCore

/// Draws a terminal and turns user input into PTY input. See SPEC/app.
@MainActor
final class TerminalView: NSView {
    static let padding = NSSize(width: 6, height: 4)
    static let selectionColor = RGB(59, 74, 106)
    /// The accent color: the frame of a tab's active pane. See SPEC/app/splits.md.
    static let accentColor = RGB(29, 78, 216)

    let session: TerminalSession
    var terminal: Terminal { session.terminal }
    var pasteboard: NSPasteboard
    let openURL: @MainActor (URL) -> Void
    var optionAsMeta: Bool
    let allowsBlinking: Bool
    let fontName: String?
    private(set) var fontSize: CGFloat
    private(set) var fonts: FontSet
    var cellSize: NSSize { fonts.cellSize }
    /// Called when the cell size changes (font size or screen scale).
    var onCellSizeChange: (() -> Void)?

    /// What the ⌘ hold detector needs: ⌘ alone pressed or released, and any other input.
    enum HoldInput {
        case commandDown(TimeInterval), commandUp(TimeInterval), other
    }

    /// Fed with the input that matters to the ⌘ hold. See SPEC/input/hold.md.
    var onHoldInput: ((HoldInput) -> Void)?
    /// Called when the view's size changed (overlays follow it).
    var onSizeChange: (() -> Void)?
    /// The 1-point frame of the active pane of a tab with several panes. See SPEC/app/splits.md.
    var showsActiveFrame = false {
        didSet { if showsActiveFrame != oldValue { needsDisplay = true } }
    }

    // Viewport: how many lines the view is scrolled back into the scrollback.
    var scrollOffset = 0
    private var anchoredFirstLine = 0
    var scrollAccumulator: CGFloat = 0

    // Selection and mouse state.
    var selection: Selection?
    var pendingSelectionAnchor: SelectionPoint?
    var reportingMouseButton: MouseButton?
    var lastReportedMouseCell: (row: Int, col: Int)?

    // Text input state.
    var markedText: NSAttributedString?
    var inputHandledByTextSystem = false

    // Focus and cursor blinking.
    private var isWindowKey = false
    private var isFirstResponder = false
    private var reportedFocus: Bool?
    private var blinkTimer: Timer?
    var blinkVisible = true

    // Rendering caches.
    var glyphCache: [GlyphKey: GlyphEntry] = [:]
    var colorCache: [RGB: CGColor] = [:]

    private var synchronizedRedrawPending = false

    init(session: TerminalSession, configuration: AppConfiguration) {
        self.session = session
        pasteboard = configuration.pasteboard
        openURL = configuration.openURL
        optionAsMeta = configuration.optionAsMeta
        allowsBlinking = configuration.cursorBlinks
        fontName = configuration.fontName
        fontSize = configuration.fontSize
        fonts = FontSet(name: configuration.fontName, size: configuration.fontSize,
                        scale: NSScreen.main?.backingScaleFactor ?? 2)
        super.init(frame: NSRect(origin: .zero, size: .zero))
        // Panes sit side by side: what a view draws stays in its frame.
        clipsToBounds = true
        anchoredFirstLine = session.terminal.firstScreenLineIndex
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalView is created in code")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Geometry

    /// The rectangle of cell (row, col) in view coordinates. See SPEC/app/contract.md.
    func cellRect(row: Int, col: Int) -> NSRect {
        NSRect(x: Self.padding.width + CGFloat(col) * cellSize.width,
               y: Self.padding.height + CGFloat(row) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// The view size showing a grid of `cols` × `rows` cells.
    func contentSize(cols: Int, rows: Int) -> NSSize {
        Self.contentSize(cols: cols, rows: rows, cellSize: cellSize)
    }

    /// The size of a view showing a grid of `cols` × `rows` cells of `cellSize`.
    static func contentSize(cols: Int, rows: Int, cellSize: NSSize) -> NSSize {
        NSSize(width: padding.width * 2 + CGFloat(cols) * cellSize.width,
               height: padding.height * 2 + CGFloat(rows) * cellSize.height)
    }

    func gridSize(for size: NSSize) -> (cols: Int, rows: Int) {
        Self.gridSize(for: size, cellSize: cellSize)
    }

    /// The whole cells of `cellSize` that fit a view of `size` inside the padding, at least 2 × 1.
    static func gridSize(for size: NSSize, cellSize: NSSize) -> (cols: Int, rows: Int) {
        let cols = Int((size.width - padding.width * 2) / cellSize.width + 0.001)
        let rows = Int((size.height - padding.height * 2) / cellSize.height + 0.001)
        return (max(2, cols), max(1, rows))
    }

    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
        onSizeChange?()
    }

    /// Resizes the terminal to the grid that fits the view.
    func updateGridSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let (cols, rows) = gridSize(for: bounds.size)
        guard cols != terminal.cols || rows != terminal.rows else { return }
        session.resize(cols: cols, rows: rows, cellSize: cellSize)
        selection = nil
        scrollOffset = 0
        anchoredFirstLine = terminal.firstScreenLineIndex
        needsDisplay = true
    }

    /// Moving to a display of another scale can change the cell size.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if rebuildFonts() { onCellSizeChange?() }
    }

    /// Changes the font size; `onCellSizeChange` lets the window keep the grid.
    func setFontSize(_ size: CGFloat) {
        fontSize = size
        if rebuildFonts() { onCellSizeChange?() }
    }

    /// Returns true when the cell size changed.
    @discardableResult
    private func rebuildFonts() -> Bool {
        let previous = cellSize
        fonts = FontSet(name: fontName, size: fontSize, scale: backingScale)
        glyphCache.removeAll()
        needsDisplay = true
        return previous != cellSize
    }

    // MARK: - Viewport

    /// Lines scrolled back, limited to the scrollback of the main screen.
    var effectiveScrollOffset: Int {
        terminal.isAlternateScreenActive ? 0 : min(scrollOffset, terminal.scrollbackCount)
    }

    /// Absolute index of the line drawn on row 0.
    var firstDisplayedLineIndex: Int {
        terminal.firstScreenLineIndex - effectiveScrollOffset
    }

    /// The line drawn on a row of the view.
    func displayedLine(_ row: Int) -> Line {
        terminal.line(absolute: firstDisplayedLineIndex + row) ?? Line(cols: terminal.cols)
    }

    /// Moves the viewport by whole screens (positive: toward older lines).
    func scrollByPages(_ pages: Int) {
        let offset = min(max(0, scrollOffset + pages * terminal.rows), terminal.scrollbackCount)
        guard offset != scrollOffset else { return }
        scrollOffset = offset
        needsDisplay = true
    }

    func scrollToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        needsDisplay = true
    }

    /// Called after the program changed the terminal.
    func terminalDidChange() {
        let first = terminal.firstScreenLineIndex
        if scrollOffset > 0 {
            scrollOffset = min(max(0, scrollOffset + first - anchoredFirstLine), terminal.scrollbackCount)
        }
        anchoredFirstLine = first
        blinkVisible = true
        updateBlinkTimer()
        if terminal.modes.synchronizedOutput {
            // The program is batching an update: draw when it is done, or after a short delay.
            if !synchronizedRedrawPending {
                synchronizedRedrawPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.synchronizedRedrawPending = false
                        self?.needsDisplay = true
                    }
                }
            }
        } else {
            needsDisplay = true
        }
    }

    // MARK: - Focus

    /// The view is its window's first responder and the window is key.
    var isFocused: Bool { isWindowKey && isFirstResponder }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        isWindowKey = window.isKeyWindow
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        // A window on a display of another scale can change the cell size the view was made with.
        if rebuildFonts() { onCellSizeChange?() }
        focusChanged()
    }

    @objc private func windowKeyStatusChanged(_ notification: Notification) {
        isWindowKey = notification.name == NSWindow.didBecomeKeyNotification
        focusChanged()
    }

    override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        focusChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        focusChanged()
        return true
    }

    private func focusChanged() {
        let focused = isFocused
        if !focused { onHoldInput?(.other) }
        guard focused != reportedFocus else { return }
        let hadFocusState = reportedFocus != nil
        reportedFocus = focused
        if hadFocusState, let report = FocusEncoder.encode(focused: focused, modes: terminal.modes) {
            session.send(report)
        }
        blinkVisible = true
        updateBlinkTimer()
        needsDisplay = true
    }

    // MARK: - Cursor blinking

    func updateBlinkTimer() {
        let shouldBlink = allowsBlinking && terminal.cursorBlinks && isFocused
        if shouldBlink, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkVisible.toggle()
                    self.setNeedsDisplay(self.cursorRect())
                }
            }
        } else if !shouldBlink, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            blinkVisible = true
        }
    }

    /// The rectangle covered by the cursor (two cells on a wide character).
    func cursorRect() -> NSRect {
        let position = terminal.cursorPosition
        let line = terminal.line(position.row)
        var col = position.col
        if col > 0, col < line.cells.count, line.cells[col].width == 0 { col -= 1 }
        var rect = cellRect(row: position.row, col: col)
        if col < line.cells.count, line.cells[col].width == 2 { rect.size.width *= 2 }
        return rect
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        let text = terminal.text(in: selection)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        sendInput(PasteEncoder.encode(text, bracketed: terminal.modes.bracketedPaste))
    }

    override func selectAll(_ sender: Any?) {
        selection = terminal.selectAll()
        needsDisplay = true
    }

    /// Edit ▸ Clear Scrollback: only the current line stays, at the top. See SPEC/app/edit.md.
    @objc func clearScrollback(_ sender: Any?) {
        terminal.clearScrollbackKeepingCursorLine()
        selection = nil
        scrollOffset = 0
        anchoredFirstLine = terminal.firstScreenLineIndex
        needsDisplay = true
    }

    // MARK: - Links

    /// The URL covering a cell, looked for in the whole logical line around it.
    func link(at point: SelectionPoint) -> URL? {
        var first = point.line
        while let previous = terminal.line(absolute: first - 1), previous.isWrapped { first -= 1 }
        var last = point.line
        while let current = terminal.line(absolute: last), current.isWrapped, terminal.line(absolute: last + 1) != nil {
            last += 1
        }
        var text = ""
        var target: Int?
        for index in first...last {
            guard let line = terminal.line(absolute: index) else { continue }
            var leadingOffset = text.utf16.count
            for col in 0..<line.cells.count {
                if line.cells[col].width != 0 { leadingOffset = text.utf16.count }
                if index == point.line && col == point.col { target = leadingOffset }
                if line.cells[col].width != 0 { text += line.character(at: col) }
            }
        }
        guard let target else { return nil }
        return LinkDetector.link(in: text, atUTF16Offset: target)
    }

    // MARK: - Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    /// Dropped files are typed as shell-escaped paths, dropped text as a paste. See SPEC/app/edit.md.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let text: String
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            text = urls.map { Self.shellEscaped($0.path) }.joined(separator: " ") + " "
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            text = string
        } else {
            return false
        }
        sendInput(PasteEncoder.encode(text, bracketed: terminal.modes.bracketedPaste))
        return true
    }

    /// Escapes every character other than letters, digits and `_-.,/:@+%=` with a backslash.
    static func shellEscaped(_ path: String) -> String {
        let safe = Set("_-.,/:@+%=".unicodeScalars)
        var escaped = ""
        for scalar in path.unicodeScalars {
            let properties = scalar.properties
            if !(properties.isAlphabetic || properties.numericType == .decimal || safe.contains(scalar)) {
                escaped.unicodeScalars.append("\\")
            }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }

    /// Sends user input to the program and brings the view back to the live screen.
    func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        scrollToBottom()
        blinkVisible = true
        session.send(bytes)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // The menu's commands go to the first responder: the pane clicked, made active.
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }
}

extension TerminalView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): selection != nil
        case #selector(paste(_:)): pasteboard.string(forType: .string) != nil
        default: true
        }
    }
}
