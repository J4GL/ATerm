import Testing
import ATermCore

enum ScrollingCases {
    static let region: [TerminalCase] = [
        TerminalCase("region in the middle", cols: 10, rows: 5, steps: [
            feedStep(numberedRows(5) + "⎋[2;4r") { t, _ in
                #expect(t.scrollRegion == 1...3)
                #expect(t.cursor == P(0, 0))
            },
            feedStep("⎋[4;1H\n") { t, _ in
                #expect(t.screenLines == ["1", "3", "4", "", "5"])
                #expect(t.scrollbackLines == [])
            },
        ]),
        TerminalCase("region at the top feeds the scrollback", cols: 10, rows: 5, numberedRows(5) + "⎋[1;3r⎋[3;1H\n") { t, _ in
            #expect(t.screenLines == ["2", "3", "", "4", "5"])
            #expect(t.scrollbackLines == ["1"])
        },
        TerminalCase("empty region is ignored", cols: 10, rows: 5, numberedRows(5) + "⎋[3;3r") { t, _ in
            #expect(t.scrollRegion == 0...4)
        },
    ]

    static let index: [TerminalCase] = [
        TerminalCase("RI at the top scrolls down", cols: 10, rows: 5, numberedRows(5) + "⎋[1;1H⎋M") { t, _ in
            #expect(t.screenLines == ["", "1", "2", "3", "4"])
            #expect(t.cursor == P(0, 0))
        },
        TerminalCase("RI elsewhere moves up", cols: 10, rows: 5, numberedRows(5) + "⎋[3;3H⎋M") { t, _ in
            #expect(t.screenLines == ["1", "2", "3", "4", "5"])
            #expect(t.cursor == P(1, 2))
        },
        TerminalCase("IND at the bottom scrolls up", cols: 10, rows: 5, numberedRows(5) + "⎋[5;3H⎋D") { t, _ in
            #expect(t.screenLines == ["2", "3", "4", "5", ""])
            #expect(t.scrollbackLines == ["1"])
            #expect(t.cursor == P(4, 2))
        },
        TerminalCase("NEL", cols: 10, rows: 5, numberedRows(5) + "⎋[2;3H⎋E") { t, _ in
            #expect(t.cursor == P(2, 0))
        },
        TerminalCase("RI at the region top", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4r⎋[2;1H⎋M") { t, _ in
            #expect(t.screenLines == ["1", "", "2", "3", "5"])
        },
    ]

    static let suSd: [TerminalCase] = [
        TerminalCase("SU 2", cols: 10, rows: 5, numberedRows(5) + "⎋[2S") { t, _ in
            #expect(t.screenLines == ["3", "4", "5", "", ""])
            #expect(t.scrollbackLines == ["1", "2"])
            #expect(t.cursor == P(4, 1))
        },
        TerminalCase("SD 2", cols: 10, rows: 5, numberedRows(5) + "⎋[2T") { t, _ in
            #expect(t.screenLines == ["", "", "1", "2", "3"])
            #expect(t.cursor == P(4, 1))
        },
        TerminalCase("SU inside a region", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4r⎋[S") { t, _ in
            #expect(t.screenLines == ["1", "3", "4", "", "5"])
            #expect(t.scrollbackLines == [])
        },
    ]
}

@Test("SCREEN-SCROLL-001 a line feed at the bottom scrolls the top line into scrollback")
func SCREEN_SCROLL_001() {
    let terminal = Terminal(cols: 10, rows: 3)
    terminal.feed(numberedRows(4))
    #expect(terminal.screenLines == ["2", "3", "4"])
    #expect(terminal.scrollbackLines == ["1"])
    #expect(terminal.cursor == P(2, 1))
}

@Test("SCREEN-SCROLL-002 scrollback keeps at most the configured number of lines")
func SCREEN_SCROLL_002() {
    let terminal = Terminal(cols: 10, rows: 2, scrollbackLimit: 3)
    terminal.feed(numberedRows(8))
    #expect(terminal.scrollbackLines == ["4", "5", "6"])
    #expect(terminal.screenLines == ["7", "8"])
    #expect(terminal.linesDropped == 3)
}

@Test("SCREEN-SCROLL-003 a scroll region scrolls only its own lines", arguments: ScrollingCases.region)
func SCREEN_SCROLL_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-SCROLL-004 RI IND and NEL move the cursor and scroll at the margins", arguments: ScrollingCases.index)
func SCREEN_SCROLL_004(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-SCROLL-005 SU and SD scroll the region by n lines", arguments: ScrollingCases.suSd)
func SCREEN_SCROLL_005(_ testCase: TerminalCase) { testCase.run() }
