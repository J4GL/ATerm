import Testing
import ATermCore

enum ReportCases {
    static func sends(_ name: String, _ input: String, _ expected: String) -> TerminalCase {
        TerminalCase(name, input) { _, d in #expect(d.sentText == expected) }
    }

    static let deviceAttributes: [TerminalCase] = [
        sends("DA1", "⎋[c", "⎋[?62;22c"),
        sends("DA1 with 0", "⎋[0c", "⎋[?62;22c"),
        sends("DECID", "⎋Z", "⎋[?62;22c"),
        sends("DA2", "⎋[>c", "⎋[>1;10;0c"),
        sends("DA3 is ignored", "⎋[=c", ""),
    ]

    static let status: [TerminalCase] = [
        sends("DSR 5", "⎋[5n", "⎋[0n"),
        sends("DSR 6", "⎋[3;7H⎋[6n", "⎋[3;7R"),
        sends("DECXCPR", "⎋[3;7H⎋[?6n", "⎋[?3;7R"),
    ]

    static let titles: [TerminalCase] = [
        TerminalCase("OSC 0", "⎋]0;Hello\u{07}") { t, d in
            #expect(t.title == "Hello")
            #expect(d.titleChanges == 1)
        },
        TerminalCase("OSC 2 with ST", "⎋]2;Wörld⎋\\") { t, _ in
            #expect(t.title == "Wörld")
        },
        TerminalCase("OSC 1 only sets the icon name", "⎋]1;icon\u{07}") { t, d in
            #expect(t.title == "")
            #expect(d.titleChanges == 0)
        },
        TerminalCase("title stack", "⎋]2;A\u{07}⎋[22;0t⎋]2;B\u{07}⎋[23;0t") { t, _ in
            #expect(t.title == "A")
        },
    ]

    static let colors: [TerminalCase] = [
        sends("OSC 11 query", "⎋]11;?\u{07}", "⎋]11;rgb:1e1e/1f1f/2626\u{07}"),
        sends("OSC 10 query with ST", "⎋]10;?⎋\\", "⎋]10;rgb:d9d9/dbdb/e3e3⎋\\"),
        sends("OSC 12 query", "⎋]12;?\u{07}", "⎋]12;rgb:f2f2/c5c5/7272\u{07}"),
        sends("OSC 4 query", "⎋]4;1;?\u{07}", "⎋]4;1;rgb:e5e5/6464/6a6a\u{07}"),
        TerminalCase("OSC 4 set and 104 reset", cols: 80, rows: 24, steps: [
            feedStep("⎋]4;1;rgb:ff/00/80\u{07}") { t, d in
                #expect(t.palette.colors[1] == RGB(255, 0, 128))
                #expect(d.paletteChanges == 1)
            },
            feedStep("⎋]104;1\u{07}") { t, _ in #expect(t.palette.colors[1] == RGB(229, 100, 106)) },
        ]),
        TerminalCase("OSC 11 set and 111 reset", cols: 80, rows: 24, steps: [
            feedStep("⎋]11;#102030\u{07}") { t, _ in #expect(t.palette.background == RGB(16, 32, 48)) },
            feedStep("⎋]111\u{07}") { t, _ in #expect(t.palette.background == RGB(30, 31, 38)) },
        ]),
        TerminalCase("OSC 4 pairs and 104 reset all", cols: 80, rows: 24, steps: [
            feedStep("⎋]4;2;#010203;3;#040506\u{07}") { t, _ in
                #expect(t.palette.colors[2] == RGB(1, 2, 3))
                #expect(t.palette.colors[3] == RGB(4, 5, 6))
            },
            feedStep("⎋]104\u{07}") { t, _ in
                #expect(t.palette.colors[2] == RGB(140, 203, 126))
                #expect(t.palette.colors[3] == RGB(232, 194, 122))
            },
        ]),
    ]

    static let workingDirectory: [TerminalCase] = [
        TerminalCase("file URL with host", "⎋]7;file://host/Users/me/My%20Dir\u{07}") { t, d in
            #expect(t.workingDirectory == "/Users/me/My Dir")
            #expect(d.workingDirectoryChanges == 1)
        },
        TerminalCase("file URL without host", "⎋]7;file:///tmp⎋\\") { t, _ in
            #expect(t.workingDirectory == "/tmp")
        },
        TerminalCase("not a URL", "⎋]7;not a url\u{07}") { t, d in
            #expect(t.workingDirectory == nil)
            #expect(d.workingDirectoryChanges == 0)
        },
    ]

    static let completionRequests: [TerminalCase] = [
        TerminalCase("ST terminated", "⎋]6973;n1;git pu⎋\\") { t, d in
            #expect(d.completionRequests == [CompletionRequest(nonce: "n1", line: "git pu")])
            #expect(t.cursor == P(0, 0))
            #expect(t.screenLines[0] == "")
        },
        TerminalCase("UTF-8 and semicolons", "⎋]6973;n1;écho a; b\u{07}") { _, d in
            #expect(d.completionRequests == [CompletionRequest(nonce: "n1", line: "écho a; b")])
        },
        TerminalCase("empty line", "⎋]6973;n1;\u{07}") { _, d in
            #expect(d.completionRequests == [CompletionRequest(nonce: "n1", line: "")])
        },
        TerminalCase("no line", "⎋]6973;n1\u{07}") { _, d in
            #expect(d.completionRequests.isEmpty)
        },
    ]

    static let modeRequests: [TerminalCase] = [
        sends("set private mode", "⎋[?2004h⎋[?2004$p", "⎋[?2004;1$y"),
        sends("reset private mode", "⎋[?2004$p", "⎋[?2004;2$y"),
        sends("unknown private mode", "⎋[?9999$p", "⎋[?9999;0$y"),
        sends("ANSI mode", "⎋[4$p", "⎋[4;2$y"),
    ]
}

@Test("SCREEN-REPORT-001 device attribute requests are answered", arguments: ReportCases.deviceAttributes)
func SCREEN_REPORT_001(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-002 status reports give the terminal state and cursor position", arguments: ReportCases.status)
func SCREEN_REPORT_002(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-003 OSC 0 and 2 set the title which can be pushed and popped", arguments: ReportCases.titles)
func SCREEN_REPORT_003(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-004 colors can be queried and changed with OSC 4 10 11 and 12", arguments: ReportCases.colors)
func SCREEN_REPORT_004(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-005 OSC 7 reports the working directory", arguments: ReportCases.workingDirectory)
func SCREEN_REPORT_005(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-006 BEL rings the bell")
func SCREEN_REPORT_006() {
    let terminal = Terminal(cols: 80, rows: 24)
    let delegate = RecordingDelegate()
    terminal.delegate = delegate
    terminal.feed("a\u{07}b\u{07}")
    #expect(delegate.bells == 2)
    #expect(terminal.screenLines[0] == "ab")
}

@Test("SCREEN-REPORT-007 DECRQM reports whether a mode is set", arguments: ReportCases.modeRequests)
func SCREEN_REPORT_007(_ testCase: TerminalCase) { testCase.run() }

@Test("SCREEN-REPORT-008 XTWINOPS 18 reports the text area size in characters")
func SCREEN_REPORT_008() {
    let terminal = Terminal(cols: 80, rows: 24)
    let delegate = RecordingDelegate()
    terminal.delegate = delegate
    terminal.feed("⎋[18t")
    #expect(delegate.sentText == "⎋[8;24;80t")
}

@Test("SCREEN-REPORT-009 OSC 6973 passes a completion request to the delegate", arguments: ReportCases.completionRequests)
func SCREEN_REPORT_009(_ testCase: TerminalCase) { testCase.run() }
