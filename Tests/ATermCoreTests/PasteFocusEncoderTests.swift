import Testing
import ATermCore

struct PasteCase: CustomTestStringConvertible, Sendable {
    let name: String
    let text: String
    let bracketed: Bool
    let expected: String

    var testDescription: String { name }
}

@Test("INPUT-PASTE-001 pasted text uses CR line endings and brackets when requested", arguments: [
    PasteCase(name: "line endings become CR", text: "a\nb\r\nc", bracketed: false, expected: "a\rb\rc"),
    PasteCase(name: "bracketed", text: "a\nb", bracketed: true, expected: "⎋[200~a\rb⎋[201~"),
    PasteCase(name: "embedded end marker is removed", text: "x\u{1B}[201~y", bracketed: true, expected: "⎋[200~xy⎋[201~"),
    PasteCase(name: "end marker hidden around another one", text: "x\u{1B}[20\u{1B}[201~1~y", bracketed: true,
              expected: "⎋[200~xy⎋[201~"),
])
func INPUT_PASTE_001(_ testCase: PasteCase) {
    #expect(PasteEncoder.encode(testCase.text, bracketed: testCase.bracketed) == bytes(testCase.expected))
}

struct FocusCase: CustomTestStringConvertible, Sendable {
    let name: String
    let reporting: Bool
    let focused: Bool
    let expected: [UInt8]?

    var testDescription: String { name }
}

@Test("INPUT-FOCUS-001 focus changes are reported only when requested", arguments: [
    FocusCase(name: "focus in", reporting: true, focused: true, expected: bytes("⎋[I")),
    FocusCase(name: "focus out", reporting: true, focused: false, expected: bytes("⎋[O")),
    FocusCase(name: "reporting off", reporting: false, focused: true, expected: nil),
])
func INPUT_FOCUS_001(_ testCase: FocusCase) {
    var modes = TerminalModes()
    modes.focusReporting = testCase.reporting
    #expect(FocusEncoder.encode(focused: testCase.focused, modes: modes) == testCase.expected)
}
