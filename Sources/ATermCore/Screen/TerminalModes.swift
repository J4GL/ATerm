public enum MouseTracking: Sendable {
    case none
    /// DECSET 9: button presses only.
    case x10
    /// DECSET 1000: presses, releases and wheel.
    case normal
    /// DECSET 1002: also motion while a button is held.
    case buttonEvent
    /// DECSET 1003: all motion.
    case anyEvent
}

public enum MouseEncoding: Sendable {
    /// `CSI M Cb Cx Cy` with values offset by 32.
    case legacy
    /// DECSET 1006: `CSI < b ; x ; y M/m`.
    case sgr
}

public enum CursorShape: Sendable {
    case block, underline, bar
}

/// Mode flags that change how the terminal interprets output and encodes input.
public struct TerminalModes: Equatable, Sendable {
    public var applicationCursorKeys = false
    public var applicationKeypad = false
    public var reverseVideo = false
    public var originMode = false
    public var autoWrap = true
    public var cursorVisible = true
    public var insertMode = false
    public var newLineMode = false
    public var bracketedPaste = false
    public var focusReporting = false
    public var alternateScroll = true
    public var synchronizedOutput = false
    public var mouseTracking: MouseTracking = .none
    public var mouseEncoding: MouseEncoding = .legacy

    public init() {}
}
