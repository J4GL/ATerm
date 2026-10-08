/// A cell color: the palette default, one of the 256 indexed colors, or a direct RGB color.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public enum UnderlineStyle: UInt8, Hashable, Sendable {
    case none, single, double, curly, dotted, dashed
}

public struct AttributeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = AttributeFlags(rawValue: 1 << 0)
    public static let dim = AttributeFlags(rawValue: 1 << 1)
    public static let italic = AttributeFlags(rawValue: 1 << 2)
    public static let blink = AttributeFlags(rawValue: 1 << 3)
    public static let inverse = AttributeFlags(rawValue: 1 << 4)
    public static let hidden = AttributeFlags(rawValue: 1 << 5)
    public static let strikethrough = AttributeFlags(rawValue: 1 << 6)
    public static let overline = AttributeFlags(rawValue: 1 << 7)
}

/// Rendition of a cell, set by SGR. See SPEC/screen/contract.md.
public struct Attributes: Hashable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var underlineColor: TerminalColor
    public var flags: AttributeFlags
    public var underline: UnderlineStyle

    public init(foreground: TerminalColor = .default,
                background: TerminalColor = .default,
                underlineColor: TerminalColor = .default,
                flags: AttributeFlags = [],
                underline: UnderlineStyle = .none) {
        self.foreground = foreground
        self.background = background
        self.underlineColor = underlineColor
        self.flags = flags
        self.underline = underline
    }
}
