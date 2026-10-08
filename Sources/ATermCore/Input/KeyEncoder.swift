/// Encodes key presses into PTY input. See SPEC/input/keys.md.
public enum KeyEncoder {
    private static let escape: UInt8 = 0x1B

    public static func encode(_ key: Key, modifiers: KeyModifiers = [], modes: TerminalModes = TerminalModes(),
                              optionAsMeta: Bool = false) -> [UInt8] {
        switch key {
        case .character(let text):
            return encodeText(text, modifiers: modifiers, optionAsMeta: optionAsMeta)
        case .enter:
            let newline: [UInt8] = modes.newLineMode ? [0x0D, 0x0A] : [0x0D]
            return optionAsMeta && modifiers.contains(.option) ? [escape] + newline : newline
        case .tab:
            return modifiers.contains(.shift) ? csi("Z") : [0x09]
        case .backspace:
            if modifiers.contains(.control) { return [0x08] }
            return modifiers.contains(.option) ? [escape, 0x7F] : [0x7F]
        case .escape:
            return optionAsMeta && modifiers.contains(.option) ? [escape, escape] : [escape]
        case .up:
            return cursorKey("A", modifiers: modifiers, modes: modes)
        case .down:
            return cursorKey("B", modifiers: modifiers, modes: modes)
        case .right:
            if modifiers == .option { return [escape, UInt8(ascii: "f")] }
            return cursorKey("C", modifiers: modifiers, modes: modes)
        case .left:
            if modifiers == .option { return [escape, UInt8(ascii: "b")] }
            return cursorKey("D", modifiers: modifiers, modes: modes)
        case .home:
            return cursorKey("H", modifiers: modifiers, modes: modes)
        case .end:
            return cursorKey("F", modifiers: modifiers, modes: modes)
        case .pageUp:
            return tildeKey(5, modifiers: modifiers)
        case .pageDown:
            return tildeKey(6, modifiers: modifiers)
        case .insert:
            return tildeKey(2, modifiers: modifiers)
        case .forwardDelete:
            return tildeKey(3, modifiers: modifiers)
        case .function(let number):
            return functionKey(number, modifiers: modifiers)
        }
    }

    /// xterm modifier parameter: 1 + shift(1) + option(2) + control(4).
    static func modifierParameter(_ modifiers: KeyModifiers) -> Int {
        1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.option) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
    }

    private static func encodeText(_ text: String, modifiers: KeyModifiers, optionAsMeta: Bool) -> [UInt8] {
        var bytes: [UInt8]
        if modifiers.contains(.control), let code = controlCode(for: text) {
            bytes = [code]
        } else {
            bytes = Array(text.utf8)
        }
        if optionAsMeta && modifiers.contains(.option) { bytes.insert(escape, at: 0) }
        return bytes
    }

    /// The C0 code xterm sends for Control plus this character, if any.
    private static func controlCode(for text: String) -> UInt8? {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - 0x60
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return value - 0x40
        case UInt8(ascii: " "), UInt8(ascii: "@"), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    private static func csi(_ body: String) -> [UInt8] {
        [escape, UInt8(ascii: "[")] + Array(body.utf8)
    }

    private static func cursorKey(_ final: Character, modifiers: KeyModifiers, modes: TerminalModes) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        if parameter > 1 { return csi("1;\(parameter)\(final)") }
        if modes.applicationCursorKeys { return [escape, UInt8(ascii: "O")] + Array(String(final).utf8) }
        return csi(String(final))
    }

    private static func tildeKey(_ code: Int, modifiers: KeyModifiers) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        return parameter > 1 ? csi("\(code);\(parameter)~") : csi("\(code)~")
    }

    private static let functionKeyCodes = [15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34]

    private static func functionKey(_ number: Int, modifiers: KeyModifiers) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        switch number {
        case 1...4:
            let final = ["P", "Q", "R", "S"][number - 1]
            return parameter > 1 ? csi("1;\(parameter)\(final)") : [escape, UInt8(ascii: "O")] + Array(final.utf8)
        case 5...20:
            return tildeKey(functionKeyCodes[number - 5], modifiers: modifiers)
        default:
            return []
        }
    }
}
