import Testing
import ATermCore

enum ResizeCases {
    static let alternate: [TerminalCase] = [
        TerminalCase("truncate then pad", cols: 10, rows: 3, steps: [
            feedStep("⎋[?1049habcdefghij⎋[2;1Hxy") { _, _ in },
            resizeStep(cols: 5, rows: 2) { t, _ in
                #expect(t.screenLines == ["abcde", "xy"])
                #expect(!t.line(0).isWrapped)
                #expect(t.cursor == P(1, 2))
            },
            resizeStep(cols: 12, rows: 4) { t, _ in
                #expect(t.screenLines == ["abcde", "xy", "", ""])
                #expect(t.cursor == P(1, 2))
            },
        ]),
        TerminalCase("cursor is clamped", cols: 10, rows: 3, steps: [
            feedStep("⎋[?1049h⎋[3;9H") { _, _ in },
            resizeStep(cols: 5, rows: 2) { t, _ in #expect(t.cursor == P(1, 4)) },
        ]),
        TerminalCase("a cut wide character leaves no grapheme", cols: 6, rows: 2, steps: [
            feedStep("⎋[?1049habcd👨\u{200D}👩") { _, _ in },
            resizeStep(cols: 5, rows: 2) { t, _ in
                #expect(t.screenLines[0] == "abcd")
                #expect(t.line(0).character(at: 4) == " ")
            },
        ]),
    ]

    static let reflow: [TerminalCase] = [
        TerminalCase("wider then narrower", cols: 10, rows: 4, steps: [
            feedStep("abcdefghijKLMNO\r\n$ ") { _, _ in },
            resizeStep(cols: 15, rows: 4) { t, _ in
                #expect(t.screenLines == ["abcdefghijKLMNO", "$", "", ""])
                #expect(!t.line(0).isWrapped)
                #expect(t.cursor == P(1, 2))
            },
            resizeStep(cols: 5, rows: 4) { t, _ in
                #expect(t.screenLines == ["abcde", "fghij", "KLMNO", "$"])
                #expect(t.line(0).isWrapped && t.line(1).isWrapped && !t.line(2).isWrapped)
                #expect(t.cursor == P(3, 2))
            },
        ]),
        TerminalCase("hard line breaks are kept", cols: 10, rows: 4, steps: [
            feedStep("abc\r\ndef") { _, _ in },
            resizeStep(cols: 20, rows: 4) { t, _ in
                #expect(t.screenLines == ["abc", "def", "", ""])
                #expect(t.cursor == P(1, 3))
            },
        ]),
        TerminalCase("wide characters move to the next line", cols: 6, rows: 3, steps: [
            feedStep("abcd中ef") { _, _ in },
            resizeStep(cols: 5, rows: 3) { t, _ in
                #expect(t.screenLines == ["abcd", "中ef", ""])
                #expect(t.line(0).isWrapped)
            },
        ]),
        TerminalCase("wrap padding is not reflowed as a space", cols: 5, rows: 3, steps: [
            feedStep("abcd中") { _, _ in },
            resizeStep(cols: 10, rows: 3) { t, _ in #expect(t.screenLines[0] == "abcd中") },
        ]),
        TerminalCase("cursor past the end of a line stays on it", cols: 10, rows: 4, steps: [
            feedStep("abc\r\ndefgh⎋[1;8H") { _, _ in },
            resizeStep(cols: 5, rows: 4) { _, _ in },
            feedStep("X") { t, _ in #expect(t.screenLines == ["abc X", "defgh", "", ""]) },
        ]),
    ]

    static let rowChanges: [TerminalCase] = [
        TerminalCase("shrink then grow", cols: 10, rows: 4, steps: [
            feedStep(numberedRows(4)) { _, _ in },
            resizeStep(cols: 10, rows: 2) { t, _ in
                #expect(t.screenLines == ["3", "4"])
                #expect(t.scrollbackLines == ["1", "2"])
                #expect(t.cursor == P(1, 1))
            },
            resizeStep(cols: 10, rows: 4) { t, _ in
                #expect(t.screenLines == ["1", "2", "3", "4"])
                #expect(t.scrollbackLines == [])
                #expect(t.cursor == P(3, 1))
            },
        ]),
        TerminalCase("empty rows below the cursor are dropped first", cols: 10, rows: 4, steps: [
            feedStep("1") { _, _ in },
            resizeStep(cols: 10, rows: 2) { t, _ in
                #expect(t.screenLines == ["1", ""])
                #expect(t.scrollbackLines == [])
                #expect(t.cursor == P(0, 1))
            },
        ]),
        TerminalCase("reflow through the scrollback", cols: 10, rows: 2, steps: [
            feedStep("abcdefghij\r\n$ ") { _, _ in },
            resizeStep(cols: 5, rows: 2) { t, _ in
                #expect(t.scrollbackLines == ["abcde"])
                #expect(t.screenLines == ["fghij", "$"])
                #expect(t.cursor == P(1, 2))
            },
            resizeStep(cols: 10, rows: 2) { t, _ in
                #expect(t.scrollbackLines == [])
                #expect(t.screenLines == ["abcdefghij", "$"])
                #expect(t.cursor == P(1, 2))
            },
        ]),
    ]

    static let regionAndTabs: [TerminalCase] = [
        TerminalCase("scroll region is reset", cols: 10, rows: 5, steps: [
            feedStep("⎋[2;4r") { _, _ in },
            resizeStep(cols: 10, rows: 8) { t, _ in #expect(t.scrollRegion == 0...7) },
        ]),
        TerminalCase("tab stops are extended", cols: 10, rows: 5, steps: [
            resizeStep(cols: 20, rows: 5) { _, _ in },
            feedStep("\t\tX") { t, _ in #expect(t.cell(0, 16).scalar == "X") },
        ]),
    ]
}

enum AlternateResizeCases {
    static let cases: [TerminalCase] = [
        TerminalCase("1047 without a saved cursor", cols: 10, rows: 6, steps: [
            feedStep(numberedRows(6) + "⎋[?1047h") { _, _ in },
            resizeStep(cols: 10, rows: 3) { _, _ in },
            feedStep("⎋[?1047l") { t, _ in
                #expect(t.screenLines == ["4", "5", "6"])
                #expect(t.scrollbackLines == ["1", "2", "3"])
            },
        ]),
        TerminalCase("1049 after DECSTR", cols: 10, rows: 6, steps: [
            feedStep(numberedRows(6) + "⎋[?1049h⎋[!p") { _, _ in },
            resizeStep(cols: 10, rows: 3) { _, _ in },
            feedStep("⎋[?1049l") { t, _ in
                #expect(t.screenLines == ["4", "5", "6"])
                #expect(t.scrollbackLines == ["1", "2", "3"])
            },
        ]),
        TerminalCase("saved cursor from before a resize", cols: 10, rows: 12, steps: [
            feedStep(numberedRows(12) + "⎋7") { _, _ in },
            resizeStep(cols: 10, rows: 3) { _, _ in },
            feedStep("⎋[?1047h") { _, _ in },
            resizeStep(cols: 12, rows: 3) { _, _ in },
            feedStep("⎋[?1047l") { t, _ in
                #expect(t.screenLines == ["10", "11", "12"])
                #expect(t.scrollbackLines == (1...9).map(String.init))
            },
        ]),
    ]
}

@Test("SCREEN-RESIZE-005 resizing on the alternate screen keeps the main screen's content",
      arguments: AlternateResizeCases.cases)
func SCREEN_RESIZE_005(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-RESIZE-001 the alternate screen is truncated or padded without reflow", arguments: ResizeCases.alternate)
func SCREEN_RESIZE_001(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-RESIZE-002 main screen lines reflow when the width changes", arguments: ResizeCases.reflow)
func SCREEN_RESIZE_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-RESIZE-003 row changes keep the cursor line visible and move lines through scrollback", arguments: ResizeCases.rowChanges)
func SCREEN_RESIZE_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-RESIZE-004 resizing resets the scroll region and extends the tab stops", arguments: ResizeCases.regionAndTabs)
func SCREEN_RESIZE_004(_ testCase: TerminalCase) { testCase.run() }
