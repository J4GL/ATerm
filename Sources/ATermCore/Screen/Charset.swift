/// Character sets that can be designated into G0/G1.
enum Charset: Sendable {
    case ascii
    case decSpecialGraphics
    case british

    init?(designator: UInt8) {
        switch designator {
        case UInt8(ascii: "B"): self = .ascii
        case UInt8(ascii: "0"): self = .decSpecialGraphics
        case UInt8(ascii: "A"): self = .british
        default: return nil
        }
    }

    func map(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch self {
        case .ascii:
            return scalar
        case .british:
            return scalar == "#" ? "£" : scalar
        case .decSpecialGraphics:
            guard scalar.value >= 0x5F, scalar.value <= 0x7E else { return scalar }
            return Self.decGraphics[Int(scalar.value - 0x5F)]
        }
    }

    // 0x5F through 0x7E.
    private static let decGraphics: [Unicode.Scalar] = [
        " ", "◆", "▒", "␉", "␌", "␍", "␊", "°", "±", "␤", "␋", "┘", "┐", "┌", "└", "┼",
        "⎺", "⎻", "─", "⎼", "⎽", "├", "┤", "┴", "┬", "│", "≤", "≥", "π", "≠", "£", "·",
    ]
}

/// G0/G1 designations and which one is invoked into GL (SO/SI).
struct CharsetState: Sendable {
    var g0: Charset = .ascii
    var g1: Charset = .ascii
    var useG1 = false

    var active: Charset { useG1 ? g1 : g0 }
}
