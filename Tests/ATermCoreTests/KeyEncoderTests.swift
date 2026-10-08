import Testing
import ATermCore

struct KeyCase: CustomTestStringConvertible, Sendable {
    let name: String
    let key: Key
    var modifiers: KeyModifiers = []
    var applicationCursorKeys = false
    var newLineMode = false
    var optionAsMeta = false
    /// Expected bytes, `⎋` standing for ESC.
    let expected: String

    var testDescription: String { name }

    func run() {
        var modes = TerminalModes()
        modes.applicationCursorKeys = applicationCursorKeys
        modes.newLineMode = newLineMode
        let encoded = KeyEncoder.encode(key, modifiers: modifiers, modes: modes, optionAsMeta: optionAsMeta)
        #expect(encoded == bytes(expected), "\(name)")
    }
}

enum KeyCases {
    static let text: [KeyCase] = [
        KeyCase(name: "a", key: .character("a"), expected: "a"),
        KeyCase(name: "é", key: .character("é"), expected: "é"),
        KeyCase(name: "€", key: .character("€"), expected: "€"),
        KeyCase(name: "ê", key: .character("ê"), expected: "ê"),
        KeyCase(name: "option-shift composed |", key: .character("|"), modifiers: [.option, .shift], expected: "|"),
    ]

    static let control: [KeyCase] = {
        let pairs: [(String, String)] = [
            ("a", "\u{01}"), ("z", "\u{1A}"), ("A", "\u{01}"), (" ", "\u{00}"), ("@", "\u{00}"),
            ("[", "\u{1B}"), ("\\", "\u{1C}"), ("]", "\u{1D}"), ("^", "\u{1E}"), ("_", "\u{1F}"),
            ("?", "\u{7F}"), ("2", "\u{00}"), ("3", "\u{1B}"), ("4", "\u{1C}"), ("5", "\u{1D}"),
            ("6", "\u{1E}"), ("7", "\u{1F}"), ("8", "\u{7F}"),
        ]
        return pairs.map { KeyCase(name: "control \($0.0.debugDescription)", key: .character($0.0), modifiers: .control, expected: $0.1) } + [
            KeyCase(name: "control option a as meta", key: .character("a"), modifiers: [.control, .option], optionAsMeta: true, expected: "⎋\u{01}"),
            KeyCase(name: "control é has no code", key: .character("é"), modifiers: .control, expected: "é"),
        ]
    }()

    static let special: [KeyCase] = {
        let cursorKeys: [(String, Key, String, String)] = [
            ("up", .up, "⎋[A", "⎋OA"), ("down", .down, "⎋[B", "⎋OB"), ("right", .right, "⎋[C", "⎋OC"),
            ("left", .left, "⎋[D", "⎋OD"), ("home", .home, "⎋[H", "⎋OH"), ("end", .end, "⎋[F", "⎋OF"),
        ]
        var cases: [KeyCase] = []
        for (name, key, normal, application) in cursorKeys {
            cases.append(KeyCase(name: "\(name) normal", key: key, expected: normal))
            cases.append(KeyCase(name: "\(name) application", key: key, applicationCursorKeys: true, expected: application))
        }
        let others: [(String, Key, String)] = [
            ("page up", .pageUp, "⎋[5~"), ("page down", .pageDown, "⎋[6~"), ("insert", .insert, "⎋[2~"),
            ("forward delete", .forwardDelete, "⎋[3~"), ("enter", .enter, "\r"), ("tab", .tab, "\t"),
            ("backspace", .backspace, "\u{7F}"), ("escape", .escape, "⎋"),
        ]
        cases += others.map { KeyCase(name: $0.0, key: $0.1, expected: $0.2) }
        cases.append(KeyCase(name: "enter with LNM", key: .enter, newLineMode: true, expected: "\r\n"))
        cases.append(KeyCase(name: "shift tab", key: .tab, modifiers: .shift, expected: "⎋[Z"))
        let functionKeys = ["⎋OP", "⎋OQ", "⎋OR", "⎋OS", "⎋[15~", "⎋[17~", "⎋[18~", "⎋[19~", "⎋[20~", "⎋[21~", "⎋[23~", "⎋[24~"]
        for (index, expected) in functionKeys.enumerated() {
            cases.append(KeyCase(name: "F\(index + 1)", key: .function(index + 1), expected: expected))
        }
        return cases
    }()

    static let modified: [KeyCase] = [
        KeyCase(name: "shift up", key: .up, modifiers: .shift, expected: "⎋[1;2A"),
        KeyCase(name: "option shift up", key: .up, modifiers: [.option, .shift], expected: "⎋[1;4A"),
        KeyCase(name: "control right", key: .right, modifiers: .control, expected: "⎋[1;5C"),
        KeyCase(name: "control shift home", key: .home, modifiers: [.control, .shift], expected: "⎋[1;6H"),
        KeyCase(name: "shift F5", key: .function(5), modifiers: .shift, expected: "⎋[15;2~"),
        KeyCase(name: "control page up", key: .pageUp, modifiers: .control, expected: "⎋[5;5~"),
        KeyCase(name: "shift F1", key: .function(1), modifiers: .shift, expected: "⎋[1;2P"),
        KeyCase(name: "control up in application mode", key: .up, modifiers: .control, applicationCursorKeys: true, expected: "⎋[1;5A"),
        KeyCase(name: "control backspace", key: .backspace, modifiers: .control, expected: "\u{08}"),
        KeyCase(name: "shift enter", key: .enter, modifiers: .shift, expected: "\r"),
    ]

    static let option: [KeyCase] = [
        KeyCase(name: "option left", key: .left, modifiers: .option, expected: "⎋b"),
        KeyCase(name: "option right", key: .right, modifiers: .option, expected: "⎋f"),
        KeyCase(name: "option backspace", key: .backspace, modifiers: .option, expected: "⎋\u{7F}"),
        KeyCase(name: "option composed π", key: .character("π"), modifiers: .option, expected: "π"),
        KeyCase(name: "meta x", key: .character("x"), modifiers: .option, optionAsMeta: true, expected: "⎋x"),
        KeyCase(name: "meta shift X", key: .character("X"), modifiers: [.option, .shift], optionAsMeta: true, expected: "⎋X"),
        KeyCase(name: "meta backspace", key: .backspace, modifiers: .option, optionAsMeta: true, expected: "⎋\u{7F}"),
        KeyCase(name: "meta left", key: .left, modifiers: .option, optionAsMeta: true, expected: "⎋b"),
    ]
}

@Test("INPUT-KEY-001 text is sent as UTF-8", arguments: KeyCases.text)
func INPUT_KEY_001(_ testCase: KeyCase) { testCase.run() }

@Test("INPUT-KEY-002 control combinations produce C0 control codes", arguments: KeyCases.control)
func INPUT_KEY_002(_ testCase: KeyCase) { testCase.run() }

@Test("INPUT-KEY-003 special keys follow the cursor key mode", arguments: KeyCases.special)
func INPUT_KEY_003(_ testCase: KeyCase) { testCase.run() }

@Test("INPUT-KEY-004 modified special keys carry the xterm modifier parameter", arguments: KeyCases.modified)
func INPUT_KEY_004(_ testCase: KeyCase) { testCase.run() }

@Test("INPUT-KEY-005 option moves by word or acts as Meta when enabled", arguments: KeyCases.option)
func INPUT_KEY_005(_ testCase: KeyCase) { testCase.run() }
