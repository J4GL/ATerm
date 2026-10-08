import Testing
import ATermCore

enum ModeCases {
    static let alternate: [TerminalCase] = [
        TerminalCase("1049", cols: 10, rows: 3, steps: [
            feedStep("main⎋[2;3H⎋[?1049h") { t, _ in
                #expect(t.isAlternateScreenActive)
                #expect(t.screenLines == ["", "", ""])
                #expect(t.cursor == P(1, 2))
            },
            feedStep("alt\n\n\n\n") { t, _ in
                #expect(t.screenLines[0] == "")
                #expect(t.scrollbackLines == [])
            },
            feedStep("⎋[?1049l") { t, _ in
                #expect(!t.isAlternateScreenActive)
                #expect(t.screenLines == ["main", "", ""])
                #expect(t.cursor == P(1, 2))
            },
            feedStep("⎋[?1049h") { t, _ in
                #expect(t.screenLines == ["", "", ""])
            },
        ]),
        TerminalCase("1047", cols: 10, rows: 3, steps: [
            feedStep("main⎋[?1047hxyz⎋[?1047l") { t, _ in
                #expect(!t.isAlternateScreenActive)
                #expect(t.screenLines[0] == "main")
                #expect(t.cursor == P(0, 7))
            },
            feedStep("⎋[?1047h") { t, _ in
                #expect(t.screenLines == ["", "", ""])
            },
        ]),
        TerminalCase("47", cols: 10, rows: 3, "main⎋[?47h⎋[1;1Halt⎋[?47l") { t, _ in
            #expect(!t.isAlternateScreenActive)
            #expect(t.screenLines[0] == "main")
            #expect(t.cursor == P(0, 3))
        },
    ]

    typealias Flag = WritableKeyPath<TerminalModes, Bool>

    static func toggle(_ set: String, _ reset: String, _ flag: Flag, _ name: String, startsOn: Bool = false) -> TerminalCase {
        TerminalCase("\(name)", cols: 80, rows: 24, steps: [
            feedStep(set) { t, _ in #expect(t.modes[keyPath: flag] == !startsOn, "\(name) after \(set)") },
            feedStep(reset) { t, _ in #expect(t.modes[keyPath: flag] == startsOn, "\(name) after \(reset)") },
        ])
    }

    static func tracking(_ set: String, _ expected: MouseTracking) -> TerminalCase {
        TerminalCase("tracking \(set)", cols: 80, rows: 24, steps: [
            feedStep(set) { t, _ in #expect(t.modes.mouseTracking == expected) },
            feedStep("⎋[?1000l") { t, _ in #expect(t.modes.mouseTracking == MouseTracking.none) },
        ])
    }

    static let flags: [TerminalCase] = [
        TerminalCase("defaults", "") { t, _ in
            let m = t.modes
            #expect(m.autoWrap && m.cursorVisible && m.alternateScroll)
            #expect(!m.applicationCursorKeys && !m.applicationKeypad && !m.reverseVideo && !m.originMode)
            #expect(!m.insertMode && !m.newLineMode && !m.bracketedPaste && !m.focusReporting)
            #expect(!m.synchronizedOutput)
            #expect(m.mouseTracking == MouseTracking.none)
            #expect(m.mouseEncoding == .legacy)
        },
        toggle("⎋[?1h", "⎋[?1l", \.applicationCursorKeys, "applicationCursorKeys"),
        toggle("⎋[?5h", "⎋[?5l", \.reverseVideo, "reverseVideo"),
        toggle("⎋[?6h", "⎋[?6l", \.originMode, "originMode"),
        toggle("⎋[?2004h", "⎋[?2004l", \.bracketedPaste, "bracketedPaste"),
        toggle("⎋[?1004h", "⎋[?1004l", \.focusReporting, "focusReporting"),
        toggle("⎋[?2026h", "⎋[?2026l", \.synchronizedOutput, "synchronizedOutput"),
        toggle("⎋[4h", "⎋[4l", \.insertMode, "insertMode"),
        toggle("⎋[20h", "⎋[20l", \.newLineMode, "newLineMode"),
        toggle("⎋=", "⎋>", \.applicationKeypad, "applicationKeypad"),
        toggle("⎋[?7l", "⎋[?7h", \.autoWrap, "autoWrap", startsOn: true),
        toggle("⎋[?25l", "⎋[?25h", \.cursorVisible, "cursorVisible", startsOn: true),
        toggle("⎋[?1007l", "⎋[?1007h", \.alternateScroll, "alternateScroll", startsOn: true),
        tracking("⎋[?9h", .x10),
        tracking("⎋[?1000h", .normal),
        tracking("⎋[?1002h", .buttonEvent),
        tracking("⎋[?1003h", .anyEvent),
        TerminalCase("SGR encoding", cols: 80, rows: 24, steps: [
            feedStep("⎋[?1000;1006h") { t, _ in
                #expect(t.modes.mouseTracking == .normal)
                #expect(t.modes.mouseEncoding == .sgr)
            },
            feedStep("⎋[?1006l") { t, _ in #expect(t.modes.mouseEncoding == .legacy) },
        ]),
    ]

    static let resets: [TerminalCase] = [
        TerminalCase("RIS", cols: 10, rows: 3, numberedRows(4) + "⎋]2;T\u{07}⎋[1;31m⎋[?1h⎋[2;3r⎋(0⎋cq") { t, _ in
            #expect(t.screenLines == ["q", "", ""])
            #expect(t.cell(0, 0).attributes == Attributes())
            #expect(t.cursor == P(0, 1))
            #expect(t.scrollRegion == 0...2)
            #expect(!t.modes.applicationCursorKeys)
            #expect(t.title == "")
            #expect(t.scrollbackLines == ["1"])
        },
        TerminalCase("DECSTR", cols: 10, rows: 3, "abc⎋[1;31m⎋[?7l⎋[4h⎋[?6h⎋[?25l⎋[2;3r⎋[2;2H⎋[!pX") { t, _ in
            #expect(t.screenLines[0] == "abc")
            #expect(t.modes.autoWrap && t.modes.cursorVisible)
            #expect(!t.modes.insertMode && !t.modes.originMode)
            #expect(t.scrollRegion == 0...2)
            #expect(t.cell(2, 1).scalar == "X")
            #expect(t.cell(2, 1).attributes == Attributes())
        },
    ]
}

@Test("SCREEN-MODE-001 the alternate screen preserves the main screen", arguments: ModeCases.alternate)
func SCREEN_MODE_001(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-MODE-002 mode sequences toggle the terminal mode flags", arguments: ModeCases.flags)
func SCREEN_MODE_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-MODE-003 RIS and DECSTR reset the terminal state", arguments: ModeCases.resets)
func SCREEN_MODE_003(_ testCase: TerminalCase) { testCase.run() }
