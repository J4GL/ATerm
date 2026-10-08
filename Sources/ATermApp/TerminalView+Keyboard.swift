import AppKit
import ATermCore

/// Keyboard input and input methods. See SPEC/app/input.md and SPEC/input/keys.md.
extension TerminalView {
    override func keyDown(with event: NSEvent) {
        onHoldInput?(.other)
        let flags = event.modifierFlags
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        if hasMarkedText() {
            // An input method is composing: it decides what every key does.
            interpretThroughTextSystem(event)
            return
        }
        let modifiers = Self.keyModifiers(flags)
        if let key = Self.namedKey(for: event), key == .pageUp || key == .pageDown, modifiers.isEmpty,
           !terminal.isAlternateScreenActive {
            // On the main screen the page keys scroll the scrollback, as in Terminal.
            scrollByPages(key == .pageUp ? 1 : -1)
            return
        }
        if let key = Self.namedKey(for: event) {
            var keyModifiers = modifiers
            if event.specialKey == .backTab { keyModifiers.insert(.shift) }
            sendInput(KeyEncoder.encode(key, modifiers: keyModifiers, modes: terminal.modes, optionAsMeta: optionAsMeta))
            return
        }
        if flags.contains(.control) || (optionAsMeta && flags.contains(.option)) {
            let text = event.charactersIgnoringModifiers ?? ""
            // A function key without terminal encoding sends nothing.
            guard !Self.isFunctionKeyText(text) else { return }
            sendInput(KeyEncoder.encode(.character(text), modifiers: modifiers, modes: terminal.modes,
                                        optionAsMeta: optionAsMeta))
            return
        }
        interpretThroughTextSystem(event)
    }

    /// ⌘ pressed or released alone drives the assistant's ⌘ hold; Caps Lock does not count.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            onHoldInput?(.commandDown(event.timestamp))
        } else if flags.isEmpty {
            onHoldInput?(.commandUp(event.timestamp))
        } else {
            onHoldInput?(.other)
        }
        super.flagsChanged(with: event)
    }

    /// Key equivalents (⌘C…) reach the views before the menu: they cancel a ⌘ hold.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onHoldInput?(.other)
        return super.performKeyEquivalent(with: event)
    }

    /// Lets the input system compose text (dead keys, input methods); falls back to the event's characters.
    private func interpretThroughTextSystem(_ event: NSEvent) {
        inputHandledByTextSystem = false
        interpretKeyEvents([event])
        guard !inputHandledByTextSystem, !hasMarkedText(), let characters = event.characters, !characters.isEmpty,
              !Self.isFunctionKeyText(characters)
        else { return }
        sendText(characters)
    }

    /// AppKit reports function keys as characters of the private range U+F700–U+F8FF.
    static func isFunctionKeyText(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
    }

    func sendText(_ text: String) {
        sendInput(KeyEncoder.encode(.character(text), modes: terminal.modes))
    }

    static func keyModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// Keys encoded by name rather than by the text they produce.
    static func namedKey(for event: NSEvent) -> Key? {
        if event.keyCode == 53 { return .escape }
        if let special = event.specialKey {
            switch special {
            case .upArrow: return .up
            case .downArrow: return .down
            case .leftArrow: return .left
            case .rightArrow: return .right
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .deleteForward: return .forwardDelete
            case .delete, .backspace: return .backspace
            case .carriageReturn, .enter, .newline: return .enter
            case .tab, .backTab: return .tab
            case .help, .insert: return .insert
            default:
                let value = special.rawValue
                if value >= NSF1FunctionKey && value <= NSF20FunctionKey {
                    return .function(value - NSF1FunctionKey + 1)
                }
            }
        }
        switch event.keyCode {
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 117: return .forwardDelete
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }

    override func doCommand(by selector: Selector) {
        inputHandledByTextSystem = true
        let key: Key?
        var modifiers: KeyModifiers = []
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)): key = .enter
        case #selector(insertTab(_:)): key = .tab
        case #selector(insertBacktab(_:)):
            key = .tab
            modifiers = .shift
        case #selector(deleteBackward(_:)): key = .backspace
        case #selector(deleteForward(_:)): key = .forwardDelete
        case #selector(cancelOperation(_:)): key = .escape
        case #selector(moveUp(_:)): key = .up
        case #selector(moveDown(_:)): key = .down
        case #selector(moveLeft(_:)): key = .left
        case #selector(moveRight(_:)): key = .right
        default: key = nil
        }
        if let key {
            sendInput(KeyEncoder.encode(key, modifiers: modifiers, modes: terminal.modes, optionAsMeta: optionAsMeta))
        }
    }
}

extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        inputHandledByTextSystem = true
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = nil
        if !text.isEmpty { sendText(text) }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputHandledByTextSystem = true
        let text: NSAttributedString
        if let attributed = string as? NSAttributedString {
            text = attributed
        } else {
            text = NSAttributedString(string: string as? String ?? "")
        }
        markedText = text.length > 0 ? text : nil
        needsDisplay = true
    }

    func unmarkText() {
        if let text = markedText?.string, !text.isEmpty { sendText(text) }
        markedText = nil
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        NSRange(location: markedText?.length ?? 0, length: 0)
    }

    func markedRange() -> NSRange {
        guard let markedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func hasMarkedText() -> Bool {
        markedText != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle]
    }

    /// Where the input method shows its candidates: at the cursor, in screen coordinates.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = convert(cursorRect(), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
