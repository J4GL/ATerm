import Testing
import ATermCore

@Test("SCREEN-PRINT-001 printing writes at the cursor and advances it")
func SCREEN_PRINT_001() {
    let terminal = Terminal(cols: 10, rows: 3)
    terminal.feed("abc")
    #expect(terminal.screenLines == ["abc", "", ""])
    #expect(terminal.cursor == P(0, 3))
    for col in 0..<3 {
        #expect(terminal.cell(0, col).width == 1)
        #expect(terminal.cell(0, col).attributes == Attributes())
    }
}

enum PrintingCases {
    static let autowrap: [TerminalCase] = [
        TerminalCase("wrap deferred then taken", cols: 5, rows: 3, steps: [
            feedStep("abcde") { t, _ in
                #expect(t.screenLines == ["abcde", "", ""])
                #expect(!t.line(0).isWrapped)
                #expect(t.cursor == P(0, 4))
            },
            feedStep("f") { t, _ in
                #expect(t.screenLines == ["abcde", "f", ""])
                #expect(t.line(0).isWrapped)
                #expect(t.cursor == P(1, 1))
            },
        ]),
        TerminalCase("CR cancels the pending wrap", cols: 5, rows: 3, "abcde\rX") { t, _ in
            #expect(t.screenLines == ["Xbcde", "", ""])
            #expect(t.cursor == P(0, 1))
        },
        TerminalCase("cursor movement cancels the pending wrap", cols: 5, rows: 3, "abcde⎋[DX") { t, _ in
            #expect(t.screenLines == ["abcXe", "", ""])
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("DECAWM off overwrites the last column", cols: 5, rows: 3, "⎋[?7labcdefg") { t, _ in
            #expect(t.screenLines == ["abcdg", "", ""])
            #expect(!t.line(0).isWrapped)
            #expect(t.cursor == P(0, 4))
        },
    ]

    static let wide: [TerminalCase] = [
        TerminalCase("wide character in the middle", cols: 6, rows: 2, "a中b") { t, _ in
            #expect(t.screenLines[0] == "a中b")
            #expect(t.cell(0, 1).width == 2)
            #expect(t.cell(0, 2).width == 0)
            #expect(t.cell(0, 3).scalar == "b")
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("wide character wraps at the last column", cols: 5, rows: 2, "abcd中") { t, _ in
            #expect(t.screenLines == ["abcd", "中"])
            #expect(t.line(0).isWrapped)
            #expect(t.cursor == P(1, 2))
        },
        TerminalCase("overwriting the trailing half", cols: 6, rows: 2, "中⎋[1;2Hx") { t, _ in
            #expect(t.cell(0, 0).scalar == " ")
            #expect(t.cell(0, 0).width == 1)
            #expect(t.cell(0, 1).scalar == "x")
            #expect(t.cell(0, 1).width == 1)
            #expect(t.screenLines[0] == " x")
        },
        TerminalCase("overwriting the leading half", cols: 6, rows: 2, "ab中⎋[1;3Hx") { t, _ in
            #expect(t.cell(0, 2).scalar == "x")
            #expect(t.cell(0, 3).scalar == " ")
            #expect(t.cell(0, 3).width == 1)
            #expect(t.screenLines[0] == "abx")
        },
    ]

    static let zeroWidth: [TerminalCase] = [
        TerminalCase("combining acute", cols: 6, rows: 2, "e\u{301}x") { t, _ in
            #expect(t.line(0).character(at: 0) == "e\u{301}")
            #expect(t.cell(0, 1).scalar == "x")
            #expect(t.cursor == P(0, 2))
        },
        TerminalCase("emoji ZWJ sequence", cols: 6, rows: 2, "👨\u{200D}👩z") { t, _ in
            #expect(t.line(0).character(at: 0).unicodeScalars.elementsEqual("👨\u{200D}👩".unicodeScalars))
            #expect(t.cell(0, 0).width == 2)
            #expect(t.cell(0, 2).scalar == "z")
            #expect(t.cursor == P(0, 3))
        },
        TerminalCase("mark after a pending wrap", cols: 5, rows: 2, "abcde\u{301}") { t, _ in
            #expect(t.line(0).character(at: 4) == "e\u{301}")
            #expect(t.screenLines[1] == "")
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("mark with nothing to join", cols: 6, rows: 2, "\u{301}a") { t, _ in
            #expect(t.screenLines[0] == "a")
            #expect(t.cursor == P(0, 1))
        },
        TerminalCase("mark on a padding cell is dropped", cols: 5, rows: 2, "abcde⎋7⎋[1;1Habcd中⎋8\u{301}") { t, _ in
            #expect(t.line(0).character(at: 4) == " ")
        },
        TerminalCase("graphemes are capped at 32 scalars", cols: 6, rows: 2,
                     "e" + String(repeating: "\u{301}", count: 40)) { t, _ in
            #expect(t.line(0).character(at: 0).unicodeScalars.count == 32)
        },
    ]

    static let insert: [TerminalCase] = [
        TerminalCase("insert then replace", cols: 8, rows: 2, steps: [
            feedStep("abcdef⎋[1;3H⎋[4hX") { t, _ in
                #expect(t.screenLines[0] == "abXcdef")
                #expect(t.cursor == P(0, 3))
            },
            feedStep("⎋[4lY") { t, _ in
                #expect(t.screenLines[0] == "abXYdef")
                #expect(t.cursor == P(0, 4))
            },
        ]),
        TerminalCase("inserted text pushes characters off the line", cols: 6, rows: 2, "abcdef⎋[1;1H⎋[4hXY") { t, _ in
            #expect(t.screenLines == ["XYabcd", ""])
        },
    ]

    static let charsets: [TerminalCase] = [
        TerminalCase("G0 line drawing", cols: 20, rows: 2, "⎋(0jklmnqtuvwx⎋(Bq") { t, _ in
            #expect(t.screenLines[0] == "┘┐┌└┼─├┤┴┬│q")
        },
        TerminalCase("G1 with SO and SI", cols: 20, rows: 2, "⎋)0\u{0E}x\u{0F}x") { t, _ in
            #expect(t.screenLines[0] == "│x")
        },
        TerminalCase("symbols", cols: 20, rows: 2, "⎋(0`afgy{|}~") { t, _ in
            #expect(t.screenLines[0] == "◆▒°±≤π≠£·")
        },
    ]

    static let rep: [TerminalCase] = [
        TerminalCase("repeat last character", cols: 10, rows: 2, "a⎋[3b") { t, _ in
            #expect(t.screenLines[0] == "aaaa")
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("nothing to repeat", cols: 10, rows: 2, "⎋[3b") { t, _ in
            #expect(t.screenLines[0] == "")
            #expect(t.cursor == P(0, 0))
        },
    ]
}

@Test("SCREEN-PRINT-008 overwriting text keeps the graphemes of untouched cells", arguments: [
    TerminalCase("combining mark before the run", cols: 10, rows: 2, "e\u{301}bc⎋[1;2Hxy") { t, _ in
        #expect(t.line(0).character(at: 0) == "e\u{301}")
        #expect(t.screenLines[0] == "e\u{301}xy")
    },
    TerminalCase("run starting on a trailing half", cols: 10, rows: 2, "中a⎋[1;2Hxy") { t, _ in
        #expect(t.screenLines[0] == " xy")
    },
])
func SCREEN_PRINT_008(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-002 autowrap is deferred until the next printable character", arguments: PrintingCases.autowrap)
func SCREEN_PRINT_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-003 wide characters occupy two cells", arguments: PrintingCases.wide)
func SCREEN_PRINT_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-004 zero-width characters join the previous cell", arguments: PrintingCases.zeroWidth)
func SCREEN_PRINT_004(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-005 insert mode shifts the rest of the line right", arguments: PrintingCases.insert)
func SCREEN_PRINT_005(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-006 DEC special graphics are mapped through G0 and G1", arguments: PrintingCases.charsets)
func SCREEN_PRINT_006(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-PRINT-007 REP repeats the last printed character", arguments: PrintingCases.rep)
func SCREEN_PRINT_007(_ testCase: TerminalCase) { testCase.run() }
