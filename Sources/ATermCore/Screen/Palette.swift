public struct RGB: Hashable, Sendable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var description: String { "RGB(\(r), \(g), \(b))" }
}

/// Default colors and the 256 indexed colors. See SPEC/screen/contract.md.
public struct Palette: Hashable, Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// 256 entries.
    public var colors: [RGB]

    public init(foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB]) {
        precondition(ansi.count == 16)
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        var colors = ansi
        for r in levels { for g in levels { for b in levels { colors.append(RGB(r, g, b)) } } }
        for i in 0..<24 {
            let v = UInt8(8 + 10 * i)
            colors.append(RGB(v, v, v))
        }
        self.colors = colors
    }

    public static let `default` = Palette(
        foreground: RGB(217, 219, 227),
        background: RGB(30, 31, 38),
        cursor: RGB(242, 197, 114),
        ansi: [
            RGB(42, 43, 51), RGB(229, 100, 106), RGB(140, 203, 126), RGB(232, 194, 122),
            RGB(108, 164, 236), RGB(201, 138, 224), RGB(94, 196, 207), RGB(205, 208, 216),
            RGB(95, 98, 112), RGB(255, 138, 143), RGB(174, 229, 158), RGB(247, 220, 155),
            RGB(149, 193, 250), RGB(227, 177, 242), RGB(146, 227, 234), RGB(244, 245, 248),
        ])

    /// Resolves a cell color, using `fallback` for `.default`.
    public func resolve(_ color: TerminalColor, fallback: RGB) -> RGB {
        switch color {
        case .default: fallback
        case .indexed(let index): colors[Int(index)]
        case .rgb(let r, let g, let b): RGB(r, g, b)
        }
    }
}
