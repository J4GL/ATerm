/// Receives what the terminal produces besides the screen. See SPEC/screen/contract.md.
public protocol TerminalDelegate: AnyObject {
    /// Reply bytes for the host (device attributes, reports, color queries).
    func terminal(_ terminal: Terminal, send bytes: [UInt8])
    func terminalTitleDidChange(_ terminal: Terminal)
    func terminalBell(_ terminal: Terminal)
    func terminalWorkingDirectoryDidChange(_ terminal: Terminal)
    func terminalPaletteDidChange(_ terminal: Terminal)
    /// A completion request of ATerm's zsh integration (OSC 6973); an empty line withdraws the pending one.
    func terminal(_ terminal: Terminal, didRequestCompletionOf line: String, nonce: String)
}

public extension TerminalDelegate {
    func terminal(_ terminal: Terminal, send bytes: [UInt8]) {}
    func terminalTitleDidChange(_ terminal: Terminal) {}
    func terminalBell(_ terminal: Terminal) {}
    func terminalWorkingDirectoryDidChange(_ terminal: Terminal) {}
    func terminalPaletteDidChange(_ terminal: Terminal) {}
    func terminal(_ terminal: Terminal, didRequestCompletionOf line: String, nonce: String) {}
}
