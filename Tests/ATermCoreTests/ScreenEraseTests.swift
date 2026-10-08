import Testing
import ATermCore

enum EraseCases {
    static let filled = "aaaaaaaaaabbbbbbbbbbcccccccccc⎋[2;5H"

    static let ed: [TerminalCase] = [
        TerminalCase("ED 0 erases below", cols: 10, rows: 3, filled + "⎋[J") { t, _ in
            #expect(t.screenLines == ["aaaaaaaaaa", "bbbb", ""])
            #expect(t.cursor == P(1, 4))
        },
        TerminalCase("ED 1 erases above through the cursor", cols: 10, rows: 3, filled + "⎋[1J") { t, _ in
            #expect(t.screenLines == ["", "     bbbbb", "cccccccccc"])
            #expect(t.cursor == P(1, 4))
        },
        TerminalCase("ED 2 erases everything", cols: 10, rows: 3, filled + "⎋[2J") { t, _ in
            #expect(t.screenLines == ["", "", ""])
            #expect(t.cursor == P(1, 4))
        },
        TerminalCase("ED 3 clears the scrollback", cols: 10, rows: 3, numberedRows(5) + "⎋[3J") { t, _ in
            #expect(t.scrollbackLines == [])
            #expect(t.linesDropped == 2)
            #expect(t.screenLines == ["3", "4", "5"])
        },
    ]

    static let el: [TerminalCase] = [
        TerminalCase("EL 0", cols: 10, rows: 2, "abcdefghij⎋[1;5H⎋[K") { t, _ in
            #expect(t.screenLines[0] == "abcd")
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("EL 1", cols: 10, rows: 2, "abcdefghij⎋[1;5H⎋[1K") { t, _ in
            #expect(t.screenLines[0] == "     fghij")
            #expect(t.cursor == P(0, 4))
        },
        TerminalCase("EL 2", cols: 10, rows: 2, "abcdefghij⎋[1;5H⎋[2K") { t, _ in
            #expect(t.screenLines[0] == "")
            #expect(t.cursor == P(0, 4))
        },
    ]

    static let ech: [TerminalCase] = [
        TerminalCase("ECH 3", cols: 10, rows: 2, "abcdefghij⎋[1;3H⎋[3X") { t, _ in
            #expect(t.screenLines[0] == "ab   fghij")
            #expect(t.cursor == P(0, 2))
        },
        TerminalCase("ECH past the end", cols: 10, rows: 2, "abcdefghij⎋[1;3H⎋[99X") { t, _ in
            #expect(t.screenLines[0] == "ab")
            #expect(t.cursor == P(0, 2))
        },
    ]

    static let ichDch: [TerminalCase] = [
        TerminalCase("ICH 2", cols: 10, rows: 2, "abcdefghij⎋[1;3H⎋[2@") { t, _ in
            #expect(t.screenLines[0] == "ab  cdefgh")
            #expect(t.cursor == P(0, 2))
        },
        TerminalCase("DCH 2", cols: 10, rows: 2, "abcdefghij⎋[1;3H⎋[2P") { t, _ in
            #expect(t.screenLines[0] == "abefghij")
            #expect(t.cursor == P(0, 2))
        },
        TerminalCase("DCH past the end", cols: 10, rows: 2, "abcdefghij⎋[1;3H⎋[99P") { t, _ in
            #expect(t.screenLines[0] == "ab")
            #expect(t.cursor == P(0, 2))
        },
        TerminalCase("DCH cutting a wide character", cols: 10, rows: 2, steps: [
            feedStep("ab中cd⎋[1;2H⎋[2P") { t, _ in
                #expect(t.screenLines[0] == "a cd")
                #expect(t.cell(0, 1).scalar == " " && t.cell(0, 1).width == 1)
            },
            feedStep("X") { t, _ in #expect(t.screenLines[0] == "aXcd") },
        ]),
        TerminalCase("insert mode on a trailing half", cols: 10, rows: 2, "x中y⎋[1;3H⎋[4hab") { t, _ in
            #expect(t.screenLines[0] == "x ab y")
            #expect(t.line(0).cells.allSatisfy { $0.width != 0 })
        },
        TerminalCase("ICH pushing an emoji off the line", cols: 5, rows: 2, "abc👨\u{200D}👩⎋[1;1H⎋[@") { t, _ in
            #expect(t.screenLines[0] == " abc")
            #expect(t.line(0).character(at: 4) == " ")
        },
    ]

    static let ilDl: [TerminalCase] = [
        TerminalCase("IL", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4H⎋[L") { t, _ in
            #expect(t.screenLines == ["1", "", "2", "3", "4"])
            #expect(t.cursor == P(1, 0))
        },
        TerminalCase("DL 2", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4H⎋[2M") { t, _ in
            #expect(t.screenLines == ["1", "4", "5", "", ""])
            #expect(t.cursor == P(1, 0))
        },
        TerminalCase("IL inside a region", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4r⎋[2;4H⎋[L") { t, _ in
            #expect(t.screenLines == ["1", "", "2", "3", "5"])
        },
        TerminalCase("IL outside the region is ignored", cols: 10, rows: 5, numberedRows(5) + "⎋[2;4r⎋[5;1H⎋[L") { t, _ in
            #expect(t.screenLines == ["1", "2", "3", "4", "5"])
        },
    ]

    static let bce: [TerminalCase] = [
        TerminalCase("EL keeps only the background", cols: 10, rows: 2, "⎋[1;41mabc⎋[2K") { t, _ in
            #expect(t.screenLines[0] == "")
            for cell in t.line(0).cells {
                #expect(cell.attributes == Attributes(background: .indexed(1)))
            }
        },
        TerminalCase("ED uses the background", cols: 10, rows: 2, "⎋[44m⎋[2J") { t, _ in
            for row in 0..<2 {
                for cell in t.line(row).cells { #expect(cell.attributes.background == .indexed(4)) }
            }
        },
        TerminalCase("ICH uses the background", cols: 10, rows: 2, "abc⎋[45m⎋[1;1H⎋[2@") { t, _ in
            #expect(t.cell(0, 0).attributes.background == .indexed(5))
            #expect(t.cell(0, 1).attributes.background == .indexed(5))
            #expect(t.screenLines[0] == "  abc")
        },
        TerminalCase("scrolling uses the background", cols: 10, rows: 2, "⎋[46m\n\n") { t, _ in
            for cell in t.line(1).cells { #expect(cell.attributes.background == .indexed(6)) }
        },
    ]
}

@Test("SCREEN-ERASE-001 ED erases part of the display", arguments: EraseCases.ed)
func SCREEN_ERASE_001(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-ERASE-002 EL erases part of the line", arguments: EraseCases.el)
func SCREEN_ERASE_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-ERASE-003 ECH erases characters without moving the cursor", arguments: EraseCases.ech)
func SCREEN_ERASE_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-ERASE-004 ICH and DCH insert and delete characters in the line", arguments: EraseCases.ichDch)
func SCREEN_ERASE_004(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-ERASE-005 IL and DL insert and delete lines inside the scroll region", arguments: EraseCases.ilDl)
func SCREEN_ERASE_005(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-ERASE-006 blank cells take the current background color only", arguments: EraseCases.bce)
func SCREEN_ERASE_006(_ testCase: TerminalCase) { testCase.run() }
