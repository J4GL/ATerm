/// Encodes mouse events for programs that enabled mouse tracking. See SPEC/input/mouse.md.
public enum MouseEncoder {
    public static func encode(_ event: MouseEvent, tracking: MouseTracking, encoding: MouseEncoding) -> [UInt8]? {
        let isWheel = event.button == .wheelUp || event.button == .wheelDown
        switch tracking {
        case .none:
            return nil
        case .x10:
            guard event.action == .press, !isWheel, event.button != .none else { return nil }
        case .normal:
            guard event.action != .motion else { return nil }
        case .buttonEvent:
            guard event.action != .motion || event.button != .none else { return nil }
        case .anyEvent:
            break
        }
        if isWheel && event.action == .release { return nil }

        var code: Int
        switch event.button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        }
        if event.action == .motion { code += 32 }
        if tracking != .x10 {
            if event.modifiers.contains(.shift) { code += 4 }
            if event.modifiers.contains(.option) { code += 8 }
            if event.modifiers.contains(.control) { code += 16 }
        }
        let x = event.col + 1
        let y = event.row + 1

        switch encoding {
        case .sgr:
            let final = event.action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(x);\(y)\(final)".utf8)
        case .legacy:
            if event.action == .release { code = (code & ~0b11) | 3 }
            guard 32 + x <= 255, 32 + y <= 255, 32 + code <= 255 else { return nil }
            return [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(32 + code), UInt8(32 + x), UInt8(32 + y)]
        }
    }
}
