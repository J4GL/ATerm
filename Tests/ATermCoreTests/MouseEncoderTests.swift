import Testing
import ATermCore

struct MouseCase: CustomTestStringConvertible, Sendable {
    let name: String
    let button: MouseButton
    let action: MouseAction
    var modifiers: KeyModifiers = []
    var row = 2
    var col = 4
    let tracking: MouseTracking
    var encoding: MouseEncoding = .sgr
    /// Expected bytes (`⎋` is ESC), or nil when nothing must be produced.
    let expected: [UInt8]?

    var testDescription: String { name }

    func run() {
        let event = MouseEvent(button: button, action: action, row: row, col: col, modifiers: modifiers)
        #expect(MouseEncoder.encode(event, tracking: tracking, encoding: encoding) == expected, "\(name)")
    }
}

enum MouseCases {
    static let sgr: [MouseCase] = [
        MouseCase(name: "left press", button: .left, action: .press, tracking: .normal, expected: bytes("⎋[<0;5;3M")),
        MouseCase(name: "left release", button: .left, action: .release, tracking: .normal, expected: bytes("⎋[<0;5;3m")),
        MouseCase(name: "middle press", button: .middle, action: .press, tracking: .normal, expected: bytes("⎋[<1;5;3M")),
        MouseCase(name: "right press", button: .right, action: .press, tracking: .normal, expected: bytes("⎋[<2;5;3M")),
        MouseCase(name: "wheel up", button: .wheelUp, action: .press, tracking: .normal, expected: bytes("⎋[<64;5;3M")),
        MouseCase(name: "wheel down", button: .wheelDown, action: .press, tracking: .normal, expected: bytes("⎋[<65;5;3M")),
        MouseCase(name: "control left press", button: .left, action: .press, modifiers: .control, tracking: .normal,
                  expected: bytes("⎋[<16;5;3M")),
        MouseCase(name: "shift option left press", button: .left, action: .press, modifiers: [.shift, .option],
                  tracking: .normal, expected: bytes("⎋[<12;5;3M")),
        MouseCase(name: "drag with left held", button: .left, action: .motion, tracking: .buttonEvent,
                  expected: bytes("⎋[<32;5;3M")),
        MouseCase(name: "motion without button", button: .none, action: .motion, tracking: .anyEvent,
                  expected: bytes("⎋[<35;5;3M")),
    ]

    static let legacy: [MouseCase] = [
        MouseCase(name: "left press", button: .left, action: .press, tracking: .normal, encoding: .legacy,
                  expected: bytes("⎋[M") + [0x20, 0x25, 0x23]),
        MouseCase(name: "left release", button: .left, action: .release, tracking: .normal, encoding: .legacy,
                  expected: bytes("⎋[M") + [0x23, 0x25, 0x23]),
        MouseCase(name: "wheel up", button: .wheelUp, action: .press, tracking: .normal, encoding: .legacy,
                  expected: bytes("⎋[M") + [0x60, 0x25, 0x23]),
        MouseCase(name: "column 223 is out of reach", button: .left, action: .press, row: 0, col: 223,
                  tracking: .normal, encoding: .legacy, expected: nil),
    ]

    static let filtering: [MouseCase] = [
        MouseCase(name: "tracking off", button: .left, action: .press, tracking: .none, expected: nil),
        MouseCase(name: "x10 press drops modifiers", button: .left, action: .press, modifiers: .control, row: 0, col: 0,
                  tracking: .x10, encoding: .legacy, expected: bytes("⎋[M") + [0x20, 0x21, 0x21]),
        MouseCase(name: "x10 release", button: .left, action: .release, row: 0, col: 0, tracking: .x10,
                  encoding: .legacy, expected: nil),
        MouseCase(name: "x10 wheel", button: .wheelUp, action: .press, row: 0, col: 0, tracking: .x10,
                  encoding: .legacy, expected: nil),
        MouseCase(name: "normal ignores drags", button: .left, action: .motion, tracking: .normal, expected: nil),
        MouseCase(name: "button event ignores bare motion", button: .none, action: .motion, tracking: .buttonEvent,
                  expected: nil),
    ]
}

@Test("INPUT-MOUSE-001 SGR encoding reports buttons wheel modifiers and motion", arguments: MouseCases.sgr)
func INPUT_MOUSE_001(_ testCase: MouseCase) { testCase.run() }

@Test("INPUT-MOUSE-002 legacy encoding offsets values by 32 and cannot reach far cells", arguments: MouseCases.legacy)
func INPUT_MOUSE_002(_ testCase: MouseCase) { testCase.run() }

@Test("INPUT-MOUSE-003 the tracking mode decides which events are reported", arguments: MouseCases.filtering)
func INPUT_MOUSE_003(_ testCase: MouseCase) { testCase.run() }
