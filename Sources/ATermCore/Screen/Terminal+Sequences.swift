/// CSI and ESC sequences: movement, editing, modes, SGR, reports. See SPEC/screen.
extension Terminal {
    // MARK: - CSI

    func handleCSI(_ csi: CSISequence) {
        let final = csi.final
        let marker = csi.privateMarker
        let intermediates = csi.intermediates

        if !intermediates.isEmpty {
            handleCSIWithIntermediates(csi)
            return
        }

        switch (marker, final) {
        case (nil, UInt8(ascii: "@")): insertBlankCells(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "A")): cursorUp(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "B")), (nil, UInt8(ascii: "e")): cursorDown(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "C")), (nil, UInt8(ascii: "a")): cursorForward(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "D")): cursorBackward(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "E")):
            cursorDown(csi.param(0, default: 1))
            cursor.col = 0
        case (nil, UInt8(ascii: "F")):
            cursorUp(csi.param(0, default: 1))
            cursor.col = 0
        case (nil, UInt8(ascii: "G")), (nil, UInt8(ascii: "`")):
            moveCursor(row: cursor.row, col: csi.param(0, default: 1) - 1)
        case (nil, UInt8(ascii: "H")), (nil, UInt8(ascii: "f")):
            moveCursorAddressed(row: csi.param(0, default: 1) - 1, col: csi.param(1, default: 1) - 1)
        case (nil, UInt8(ascii: "I")): tabForward(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "J")), (UInt8(ascii: "?"), UInt8(ascii: "J")): eraseInDisplay(csi.rawParam(0, default: 0))
        case (nil, UInt8(ascii: "K")), (UInt8(ascii: "?"), UInt8(ascii: "K")): eraseInLine(csi.rawParam(0, default: 0))
        case (nil, UInt8(ascii: "L")): insertLines(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "M")): deleteLines(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "P")): deleteCells(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "S")): scrollUp(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "T")) where csi.count <= 1: scrollDown(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "X")): eraseCharacters(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "Z")): tabBackward(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "b")): repeatLastCharacter(csi.param(0, default: 1))
        case (nil, UInt8(ascii: "c")):
            if csi.rawParam(0, default: 0) == 0 { send("\u{1B}[?62;22c") }
        case (UInt8(ascii: ">"), UInt8(ascii: "c")):
            if csi.rawParam(0, default: 0) == 0 { send("\u{1B}[>1;10;0c") }
        case (nil, UInt8(ascii: "d")): setAddressedRow(csi.param(0, default: 1) - 1)
        case (nil, UInt8(ascii: "g")): clearTabStops(csi.rawParam(0, default: 0))
        case (nil, UInt8(ascii: "h")): setANSIModes(csi, on: true)
        case (nil, UInt8(ascii: "l")): setANSIModes(csi, on: false)
        case (UInt8(ascii: "?"), UInt8(ascii: "h")): setPrivateModes(csi, on: true)
        case (UInt8(ascii: "?"), UInt8(ascii: "l")): setPrivateModes(csi, on: false)
        case (nil, UInt8(ascii: "m")): applySGR(csi)
        case (nil, UInt8(ascii: "n")): deviceStatusReport(csi.rawParam(0, default: 0), decFormat: false)
        case (UInt8(ascii: "?"), UInt8(ascii: "n")): deviceStatusReport(csi.rawParam(0, default: 0), decFormat: true)
        case (nil, UInt8(ascii: "r")): setScrollRegion(top: csi.param(0, default: 1), bottom: csi.param(1, default: rows))
        case (nil, UInt8(ascii: "s")) where csi.count == 0: saveCursor()
        case (nil, UInt8(ascii: "u")): restoreCursor()
        case (nil, UInt8(ascii: "t")): windowOperation(csi)
        default:
            break
        }
    }

    private func handleCSIWithIntermediates(_ csi: CSISequence) {
        switch (csi.privateMarker, csi.intermediates, csi.final) {
        case (nil, [UInt8(ascii: " ")], UInt8(ascii: "q")):
            setCursorStyle(csi.rawParam(0, default: 0))
        case (nil, [UInt8(ascii: "!")], UInt8(ascii: "p")):
            softReset()
        case (UInt8(ascii: "?"), [UInt8(ascii: "$")], UInt8(ascii: "p")):
            let mode = csi.rawParam(0, default: 0)
            send("\u{1B}[?\(mode);\(privateModeState(mode))$y")
        case (nil, [UInt8(ascii: "$")], UInt8(ascii: "p")):
            let mode = csi.rawParam(0, default: 0)
            send("\u{1B}[\(mode);\(ansiModeState(mode))$y")
        default:
            break
        }
    }

    // MARK: - ESC

    func handleESC(intermediates: [UInt8], final: UInt8) {
        switch intermediates.first {
        case nil:
            switch final {
            case UInt8(ascii: "7"): saveCursor()
            case UInt8(ascii: "8"): restoreCursor()
            case UInt8(ascii: "D"): index()
            case UInt8(ascii: "E"):
                index()
                cursor.col = 0
            case UInt8(ascii: "H"): tabStops[cursor.col] = true
            case UInt8(ascii: "M"): reverseIndex()
            case UInt8(ascii: "Z"): send("\u{1B}[?62;22c")
            case UInt8(ascii: "c"): fullReset()
            case UInt8(ascii: "="): modes.applicationKeypad = true
            case UInt8(ascii: ">"): modes.applicationKeypad = false
            default: break
            }
        case UInt8(ascii: "("):
            if let charset = Charset(designator: final) { cursor.charsets.g0 = charset }
        case UInt8(ascii: ")"):
            if let charset = Charset(designator: final) { cursor.charsets.g1 = charset }
        case UInt8(ascii: "#"):
            if final == UInt8(ascii: "8") { screenAlignmentTest() }
        default:
            break
        }
    }

    // MARK: - Tabs, margins, cursor state

    func clearTabStops(_ mode: Int) {
        switch mode {
        case 0: tabStops[cursor.col] = false
        case 3: tabStops = Array(repeating: false, count: cols)
        default: break
        }
    }

    func setScrollRegion(top: Int, bottom: Int) {
        let top = top - 1
        let bottom = min(bottom, rows) - 1
        guard top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        moveCursorAddressed(row: 0, col: 0)
    }

    func saveCursor() {
        let saved = SavedCursor(cursor: cursor, originMode: modes.originMode)
        if isAlternateScreenActive {
            savedCursorAlternate = saved
        } else {
            savedCursorMain = saved
        }
    }

    func restoreCursor() {
        let saved = isAlternateScreenActive ? savedCursorAlternate : savedCursorMain
        if let saved {
            cursor = saved.cursor
            modes.originMode = saved.originMode
            cursor.row = min(cursor.row, rows - 1)
            cursor.col = min(cursor.col, cols - 1)
        } else {
            cursor = Cursor()
            modes.originMode = false
        }
    }

    func setCursorStyle(_ style: Int) {
        switch style {
        case 0: (cursorShape, cursorBlinks) = (.block, false)
        case 1: (cursorShape, cursorBlinks) = (.block, true)
        case 2: (cursorShape, cursorBlinks) = (.block, false)
        case 3: (cursorShape, cursorBlinks) = (.underline, true)
        case 4: (cursorShape, cursorBlinks) = (.underline, false)
        case 5: (cursorShape, cursorBlinks) = (.bar, true)
        case 6: (cursorShape, cursorBlinks) = (.bar, false)
        default: break
        }
    }

    // MARK: - Modes

    func setANSIModes(_ csi: CSISequence, on: Bool) {
        for index in 0..<csi.count {
            switch csi.rawParam(index, default: 0) {
            case 4: modes.insertMode = on
            case 20: modes.newLineMode = on
            default: break
            }
        }
    }

    func setPrivateModes(_ csi: CSISequence, on: Bool) {
        for index in 0..<csi.count {
            setPrivateMode(csi.rawParam(index, default: 0), on: on)
        }
    }

    func setPrivateMode(_ mode: Int, on: Bool) {
        switch mode {
        case 1: modes.applicationCursorKeys = on
        case 5: modes.reverseVideo = on
        case 6:
            modes.originMode = on
            moveCursorAddressed(row: 0, col: 0)
        case 7:
            modes.autoWrap = on
            if !on { cursor.pendingWrap = false }
        case 9: modes.mouseTracking = on ? .x10 : .none
        case 12: cursorBlinks = on
        case 25: modes.cursorVisible = on
        case 47:
            on ? enterAlternateScreen(saveCursor: false, clear: false) : exitAlternateScreen(restoreCursor: false, clear: false)
        case 1047:
            on ? enterAlternateScreen(saveCursor: false, clear: false) : exitAlternateScreen(restoreCursor: false, clear: true)
        case 1049:
            on ? enterAlternateScreen(saveCursor: true, clear: true) : exitAlternateScreen(restoreCursor: true, clear: false)
        case 1048:
            on ? saveCursor() : restoreCursor()
        case 1000: modes.mouseTracking = on ? .normal : .none
        case 1002: modes.mouseTracking = on ? .buttonEvent : .none
        case 1003: modes.mouseTracking = on ? .anyEvent : .none
        case 1004: modes.focusReporting = on
        case 1006: modes.mouseEncoding = on ? .sgr : .legacy
        case 1007: modes.alternateScroll = on
        case 2004: modes.bracketedPaste = on
        case 2026: modes.synchronizedOutput = on
        default: break
        }
    }

    /// DECRQM value: 1 set, 2 reset, 0 unknown.
    func privateModeState(_ mode: Int) -> Int {
        let state: Bool
        switch mode {
        case 1: state = modes.applicationCursorKeys
        case 5: state = modes.reverseVideo
        case 6: state = modes.originMode
        case 7: state = modes.autoWrap
        case 9: state = modes.mouseTracking == .x10
        case 12: state = cursorBlinks
        case 25: state = modes.cursorVisible
        case 47, 1047, 1049: state = isAlternateScreenActive
        case 1000: state = modes.mouseTracking == .normal
        case 1002: state = modes.mouseTracking == .buttonEvent
        case 1003: state = modes.mouseTracking == .anyEvent
        case 1004: state = modes.focusReporting
        case 1006: state = modes.mouseEncoding == .sgr
        case 1007: state = modes.alternateScroll
        case 2004: state = modes.bracketedPaste
        case 2026: state = modes.synchronizedOutput
        default: return 0
        }
        return state ? 1 : 2
    }

    func ansiModeState(_ mode: Int) -> Int {
        switch mode {
        case 4: modes.insertMode ? 1 : 2
        case 20: modes.newLineMode ? 1 : 2
        default: 0
        }
    }

    // MARK: - Alternate screen

    func enterAlternateScreen(saveCursor save: Bool, clear: Bool) {
        if save { saveCursor() }
        if !isAlternateScreenActive {
            mainCursorWhileAlternate = cursor
            swap(&screen, &inactiveScreen)
            isAlternateScreenActive = true
        }
        if clear {
            let blank = Line(cols: cols)
            for row in 0..<rows { screen[row] = blank }
        }
        cursor.pendingWrap = false
    }

    func exitAlternateScreen(restoreCursor restore: Bool, clear: Bool) {
        if isAlternateScreenActive {
            if clear {
                let blank = Line(cols: cols)
                for row in 0..<rows { screen[row] = blank }
            }
            swap(&screen, &inactiveScreen)
            isAlternateScreenActive = false
            mainCursorWhileAlternate = nil
        }
        if restore { restoreCursor() }
        cursor.pendingWrap = false
    }

    // MARK: - Resets

    /// RIS: everything back to defaults except the scrollback.
    func fullReset() {
        if isAlternateScreenActive {
            swap(&screen, &inactiveScreen)
            isAlternateScreenActive = false
        }
        mainCursorWhileAlternate = nil
        screen = Array(repeating: Line(cols: cols), count: rows)
        inactiveScreen = Array(repeating: Line(cols: cols), count: rows)
        cursor = Cursor()
        savedCursorMain = nil
        savedCursorAlternate = nil
        modes = TerminalModes()
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Terminal.defaultTabStops(cols: cols)
        cursorShape = .block
        cursorBlinks = false
        lastPrintedScalar = nil
        titleStack = []
        if !title.isEmpty {
            title = ""
            delegate?.terminalTitleDidChange(self)
        }
        if palette != defaultPalette {
            palette = defaultPalette
            delegate?.terminalPaletteDidChange(self)
        }
    }

    /// DECSTR: resets modes and rendition, keeps the screen and the cursor position.
    func softReset() {
        modes.insertMode = false
        modes.originMode = false
        modes.autoWrap = true
        modes.cursorVisible = true
        modes.applicationCursorKeys = false
        modes.applicationKeypad = false
        scrollTop = 0
        scrollBottom = rows - 1
        cursor.attributes = Attributes()
        cursor.charsets = CharsetState()
        cursor.pendingWrap = false
        savedCursorMain = nil
        savedCursorAlternate = nil
    }

    // MARK: - Reports

    func deviceStatusReport(_ request: Int, decFormat: Bool) {
        switch request {
        case 5 where !decFormat:
            send("\u{1B}[0n")
        case 6:
            let row = modes.originMode ? cursor.row - scrollTop : cursor.row
            send("\u{1B}[\(decFormat ? "?" : "")\(row + 1);\(cursor.col + 1)R")
        default:
            break
        }
    }

    func windowOperation(_ csi: CSISequence) {
        switch csi.rawParam(0, default: 0) {
        case 18:
            send("\u{1B}[8;\(rows);\(cols)t")
        case 22:
            if titleStack.count < 16 { titleStack.append(title) }
        case 23:
            if let previous = titleStack.popLast(), previous != title {
                title = previous
                delegate?.terminalTitleDidChange(self)
            }
        default:
            break
        }
    }

    // MARK: - SGR

    func applySGR(_ csi: CSISequence) {
        if csi.count == 0 {
            cursor.attributes = Attributes()
            return
        }
        var attributes = cursor.attributes
        var index = 0
        while index < csi.count {
            let group = csi.group(index)
            let code = group.first ?? 0
            switch code {
            case 0: attributes = Attributes()
            case 1: attributes.flags.insert(.bold)
            case 2: attributes.flags.insert(.dim)
            case 3: attributes.flags.insert(.italic)
            case 4:
                if group.count > 1 {
                    attributes.underline = UnderlineStyle(rawValue: UInt8(min(group[group.startIndex + 1], 5))) ?? .single
                } else {
                    attributes.underline = .single
                }
            case 5, 6: attributes.flags.insert(.blink)
            case 7: attributes.flags.insert(.inverse)
            case 8: attributes.flags.insert(.hidden)
            case 9: attributes.flags.insert(.strikethrough)
            case 21: attributes.underline = .double
            case 22: attributes.flags.subtract([.bold, .dim])
            case 23: attributes.flags.remove(.italic)
            case 24: attributes.underline = .none
            case 25: attributes.flags.remove(.blink)
            case 27: attributes.flags.remove(.inverse)
            case 28: attributes.flags.remove(.hidden)
            case 29: attributes.flags.remove(.strikethrough)
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 39: attributes.foreground = .default
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 49: attributes.background = .default
            case 53: attributes.flags.insert(.overline)
            case 55: attributes.flags.remove(.overline)
            case 59: attributes.underlineColor = .default
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let (color, consumed) = extendedColor(csi, at: index)
                index += consumed
                if let color {
                    switch code {
                    case 38: attributes.foreground = color
                    case 48: attributes.background = color
                    default: attributes.underlineColor = color
                    }
                }
            default:
                break
            }
            index += 1
        }
        cursor.attributes = attributes
    }

    /// Parses the color following 38/48/58. Returns the color (nil if invalid) and
    /// how many extra `;`-separated parameters it consumed.
    private func extendedColor(_ csi: CSISequence, at index: Int) -> (TerminalColor?, Int) {
        let group = csi.group(index)
        if group.count > 1 {
            // Colon form: 38:5:n, 38:2:r:g:b or 38:2:colorspace:r:g:b.
            let base = group.startIndex
            switch group[base + 1] {
            case 5 where group.count >= 3:
                return (indexedColor(group[base + 2]), 0)
            case 2 where group.count >= 5:
                let first = group.count >= 6 ? base + 3 : base + 2
                return (rgbColor(group[first], group[first + 1], group[first + 2]), 0)
            default:
                return (nil, 0)
            }
        }
        // Semicolon form: 38;5;n or 38;2;r;g;b.
        let remaining = csi.count - index - 1
        guard remaining >= 1 else { return (nil, 0) }
        switch csi.rawParam(index + 1, default: 0) {
        case 5:
            guard remaining >= 2 else { return (nil, remaining) }
            return (indexedColor(csi.rawParam(index + 2, default: 0)), 2)
        case 2:
            guard remaining >= 4 else { return (nil, remaining) }
            return (rgbColor(csi.rawParam(index + 2, default: 0), csi.rawParam(index + 3, default: 0),
                             csi.rawParam(index + 4, default: 0)), 4)
        default:
            return (nil, 1)
        }
    }

    private func indexedColor(_ value: Int) -> TerminalColor? {
        (0...255).contains(value) ? .indexed(UInt8(value)) : nil
    }

    private func rgbColor(_ r: Int, _ g: Int, _ b: Int) -> TerminalColor? {
        guard (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }
        return .rgb(UInt8(r), UInt8(g), UInt8(b))
    }
}
