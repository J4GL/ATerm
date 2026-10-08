import Testing
import ATermCore

enum CursorCases {
    static func at(_ name: String, _ input: String, _ expected: Position) -> TerminalCase {
        TerminalCase(name, input) { t, _ in #expect(t.cursor == expected) }
    }

    static func cellHolds(_ name: String, _ input: String, _ row: Int, _ col: Int, _ scalar: Unicode.Scalar) -> TerminalCase {
        TerminalCase(name, input) { t, _ in #expect(t.cell(row, col).scalar == scalar) }
    }

    static let absolute: [TerminalCase] = [
        at("CUP", "⎋[5;10H", P(4, 9)),
        at("CUP home", "⎋[5;5H⎋[H", P(0, 0)),
        at("CUP clamped", "⎋[99;999H", P(23, 79)),
        at("CUP zero params", "⎋[0;0H", P(0, 0)),
        at("CHA", "⎋[5;10H⎋[3G", P(4, 2)),
        at("HPA", "⎋[5;10H⎋[20`", P(4, 19)),
        at("VPA", "⎋[5;10H⎋[7d", P(6, 9)),
        at("HVP", "⎋[2;3f", P(1, 2)),
    ]

    static let relative: [TerminalCase] = [
        TerminalCase("relative moves", cols: 80, rows: 24, steps: [
            feedStep("⎋[6;6H⎋[A") { t, _ in #expect(t.cursor == P(4, 5)) },
            feedStep("⎋[3B") { t, _ in #expect(t.cursor == P(7, 5)) },
            feedStep("⎋[2C") { t, _ in #expect(t.cursor == P(7, 7)) },
            feedStep("⎋[10D") { t, _ in #expect(t.cursor == P(7, 0)) },
            feedStep("⎋[2E") { t, _ in #expect(t.cursor == P(9, 0)) },
            feedStep("⎋[F") { t, _ in #expect(t.cursor == P(8, 0)) },
            feedStep("⎋[0A") { t, _ in #expect(t.cursor == P(7, 0)) },
            feedStep("⎋[3a⎋[2e") { t, _ in #expect(t.cursor == P(9, 3)) },
            feedStep("⎋[99A⎋[999C") { t, _ in #expect(t.cursor == P(0, 79)) },
            feedStep("⎋[99B⎋[999D") { t, _ in #expect(t.cursor == P(23, 0)) },
        ]),
    ]

    static let controls: [TerminalCase] = [
        TerminalCase("BS", "abc\u{08}\u{08}X") { t, _ in
            #expect(t.screenLines[0] == "aXc")
            #expect(t.cursor == P(0, 2))
        },
        at("BS at column 0", "\u{08}", P(0, 0)),
        TerminalCase("CR", "abc\rX") { t, _ in
            #expect(t.screenLines[0] == "Xbc")
            #expect(t.cursor == P(0, 1))
        },
        TerminalCase("LF keeps the column", "ab\ncd") { t, _ in
            #expect(t.screenLines[0] == "ab")
            #expect(t.screenLines[1] == "  cd")
            #expect(t.cursor == P(1, 4))
        },
        TerminalCase("LNM makes LF a new line", "⎋[20hab\ncd") { t, _ in
            #expect(t.screenLines[1] == "cd")
            #expect(t.cursor == P(1, 2))
        },
        TerminalCase("VT and FF act as LF", "ab\u{0B}c\u{0C}d") { t, _ in
            #expect(t.screenLines[1] == "  c")
            #expect(t.screenLines[2] == "   d")
            #expect(t.cursor == P(2, 4))
        },
        TerminalCase("HT", "a\tb") { t, _ in
            #expect(t.screenLines[0] == "a       b")
            #expect(t.cursor == P(0, 9))
        },
        cellHolds("HT stops at the last column", "⎋[1;79H\t\tX", 0, 79, "X"),
    ]

    static let tabs: [TerminalCase] = [
        cellHolds("HTS", "⎋[1;5H⎋H⎋[1;1H\tX", 0, 4, "X"),
        cellHolds("TBC current", "⎋[1;9H⎋[g⎋[1;1H\tX", 0, 16, "X"),
        cellHolds("TBC all", "⎋[3g\tX", 0, 79, "X"),
        cellHolds("CBT", "⎋[1;20H⎋[ZX", 0, 16, "X"),
        cellHolds("CHT", "⎋[2IX", 0, 16, "X"),
    ]

    static let save: [TerminalCase] = [
        TerminalCase("DECSC and DECRC", "⎋[3;4H⎋[1;31m⎋7⎋[10;10H⎋[0m⎋8X") { t, _ in
            let cell = t.cell(2, 3)
            #expect(cell.scalar == "X")
            #expect(cell.attributes.flags == [.bold])
            #expect(cell.attributes.foreground == .indexed(1))
        },
        cellHolds("SCOSC and SCORC", "⎋[3;4H⎋[s⎋[10;10H⎋[uX", 2, 3, "X"),
        TerminalCase("charset is restored", "⎋(0⎋7⎋(B⎋8q") { t, _ in
            #expect(t.screenLines[0] == "─")
        },
        TerminalCase("restore without save", "⎋[1;31m⎋[5;5H⎋8X") { t, _ in
            #expect(t.cell(0, 0).scalar == "X")
            #expect(t.cell(0, 0).attributes == Attributes())
        },
    ]

    static let origin: [TerminalCase] = [
        cellHolds("home is the region top", "⎋[5;10r⎋[?6h⎋[HX", 4, 0, "X"),
        cellHolds("rows clamp to the region bottom", "⎋[5;10r⎋[?6h⎋[99;1HX", 9, 0, "X"),
        TerminalCase("DSR reports relative position", "⎋[5;10r⎋[?6h⎋[2;3H⎋[6n") { _, d in
            #expect(d.sentText == "⎋[2;3R")
        },
        cellHolds("resetting DECOM homes to the screen", "⎋[5;10r⎋[?6h⎋[?6lX", 0, 0, "X"),
    ]

    static let visibility: [TerminalCase] = [
        TerminalCase("defaults", "") { t, _ in
            #expect(t.cursorVisible)
            #expect(t.cursorShape == .block)
            #expect(!t.cursorBlinks)
        },
        TerminalCase("DECTCEM", cols: 80, rows: 24, steps: [
            feedStep("⎋[?25l") { t, _ in #expect(!t.cursorVisible) },
            feedStep("⎋[?25h") { t, _ in #expect(t.cursorVisible) },
        ]),
        TerminalCase("DECSCUSR", cols: 80, rows: 24, steps: [
            (1, CursorShape.block, true), (2, .block, false), (3, .underline, true), (4, .underline, false),
            (5, .bar, true), (6, .bar, false), (0, .block, false),
        ].map { (ps: Int, shape: CursorShape, blinks: Bool) in
            feedStep("⎋[\(ps) q") { t, _ in
                #expect(t.cursorShape == shape, "DECSCUSR \(ps)")
                #expect(t.cursorBlinks == blinks, "DECSCUSR \(ps)")
            }
        }),
        TerminalCase("blink mode", cols: 80, rows: 24, steps: [
            feedStep("⎋[?12h") { t, _ in #expect(t.cursorBlinks) },
            feedStep("⎋[?12l") { t, _ in #expect(!t.cursorBlinks) },
        ]),
    ]
}

@Test("SCREEN-CURSOR-001 absolute positioning is 1-based and clamped", arguments: CursorCases.absolute)
func SCREEN_CURSOR_001(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-002 relative movement defaults to one and stops at the edges", arguments: CursorCases.relative)
func SCREEN_CURSOR_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-003 BS CR LF VT FF and HT move the cursor", arguments: CursorCases.controls)
func SCREEN_CURSOR_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-004 tab stops can be set and cleared", arguments: CursorCases.tabs)
func SCREEN_CURSOR_004(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-005 saving the cursor restores position attributes and charset", arguments: CursorCases.save)
func SCREEN_CURSOR_005(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-006 origin mode confines addressing to the scroll region", arguments: CursorCases.origin)
func SCREEN_CURSOR_006(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-CURSOR-007 cursor visibility and shape follow DECTCEM and DECSCUSR", arguments: CursorCases.visibility)
func SCREEN_CURSOR_007(_ testCase: TerminalCase) { testCase.run() }
