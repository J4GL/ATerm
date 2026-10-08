/// A key press as seen by the encoder. See SPEC/input/keys.md.
public enum Key: Hashable, Sendable {
    /// Text produced by the key (already composed by the keyboard layout or input method).
    case character(String)
    case enter, tab, backspace, escape
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, forwardDelete
    /// F1…F20.
    case function(Int)
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
}

public enum MouseButton: Sendable {
    case left, middle, right, wheelUp, wheelDown, none
}

public enum MouseAction: Sendable {
    case press, release, motion
}

public struct MouseEvent: Sendable {
    public var button: MouseButton
    public var action: MouseAction
    public var row: Int
    public var col: Int
    public var modifiers: KeyModifiers

    public init(button: MouseButton, action: MouseAction, row: Int, col: Int, modifiers: KeyModifiers = []) {
        self.button = button
        self.action = action
        self.row = row
        self.col = col
        self.modifiers = modifiers
    }
}
