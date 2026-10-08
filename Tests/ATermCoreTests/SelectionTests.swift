import Testing
import ATermCore

func SP(_ line: Int, _ col: Int) -> SelectionPoint { SelectionPoint(line: line, col: col) }

struct SelectionCase: CustomTestStringConvertible, @unchecked Sendable {
    let name: String
    let cols: Int
    let rows: Int
    let input: String
    let selection: Selection
    let expected: String

    var testDescription: String { name }

    func run() {
        let terminal = Terminal(cols: cols, rows: rows)
        terminal.feed(input)
        #expect(terminal.text(in: selection) == expected, "\(name)")
    }
}

enum SelectionCases {
    static let hello = "hello world\r\nsecond line"

    static let character: [SelectionCase] = [
        SelectionCase(name: "across two lines", cols: 20, rows: 3, input: hello,
                      selection: Selection(anchor: SP(0, 2), head: SP(1, 3)), expected: "llo world\nseco"),
        SelectionCase(name: "dragged backwards", cols: 20, rows: 3, input: hello,
                      selection: Selection(anchor: SP(1, 3), head: SP(0, 2)), expected: "llo world\nseco"),
        SelectionCase(name: "one word", cols: 20, rows: 3, input: hello,
                      selection: Selection(anchor: SP(0, 0), head: SP(0, 4)), expected: "hello"),
    ]

    static let wrapping: [SelectionCase] = [
        SelectionCase(name: "soft wrap is joined", cols: 5, rows: 3, input: "abcdefgh",
                      selection: Selection(anchor: SP(0, 0), head: SP(1, 4)), expected: "abcdefgh"),
        SelectionCase(name: "trailing spaces are trimmed", cols: 10, rows: 2, input: "ab   \r\ncd",
                      selection: Selection(anchor: SP(0, 0), head: SP(1, 9)), expected: "ab\ncd"),
        SelectionCase(name: "wrap padding of a wide character is skipped", cols: 5, rows: 3, input: "abcd中",
                      selection: Selection(anchor: SP(0, 0), head: SP(1, 4)), expected: "abcd中"),
    ]

    static let command = "ls -la /usr/local/bin | foo"

    static let words: [SelectionCase] = [
        SelectionCase(name: "path", cols: 30, rows: 2, input: command,
                      selection: Selection(anchor: SP(0, 12), granularity: .word), expected: "/usr/local/bin"),
        SelectionCase(name: "last word", cols: 30, rows: 2, input: command,
                      selection: Selection(anchor: SP(0, 25), granularity: .word), expected: "foo"),
        SelectionCase(name: "option", cols: 30, rows: 2, input: command,
                      selection: Selection(anchor: SP(0, 4), granularity: .word), expected: "-la"),
        SelectionCase(name: "non-word character", cols: 30, rows: 2, input: command,
                      selection: Selection(anchor: SP(0, 22), granularity: .word), expected: "|"),
        SelectionCase(name: "extended by words", cols: 30, rows: 2, input: command,
                      selection: Selection(anchor: SP(0, 4), head: SP(0, 12), granularity: .word),
                      expected: "-la /usr/local/bin"),
        SelectionCase(name: "past the end of a scrollback line", cols: 10, rows: 2, input: "hello\r\n2\r\n3",
                      selection: Selection(anchor: SP(0, 8), granularity: .word), expected: ""),
    ]

    static let lines: [SelectionCase] = [
        SelectionCase(name: "wrapped continuation selects the logical line", cols: 5, rows: 3, input: "abcdefgh\r\nxy",
                      selection: Selection(anchor: SP(1, 0), granularity: .line), expected: "abcdefgh"),
        SelectionCase(name: "extended to the next line", cols: 5, rows: 3, input: "abcdefgh\r\nxy",
                      selection: Selection(anchor: SP(1, 0), head: SP(2, 0), granularity: .line),
                      expected: "abcdefgh\nxy"),
    ]

    static let wide: [SelectionCase] = [
        SelectionCase(name: "wide and combining", cols: 10, rows: 2, input: "a中be\u{301}",
                      selection: Selection(anchor: SP(0, 0), head: SP(0, 4)), expected: "a中be\u{301}"),
        SelectionCase(name: "starting on a trailing half", cols: 10, rows: 2, input: "a中be\u{301}",
                      selection: Selection(anchor: SP(0, 2), head: SP(0, 3)), expected: "中b"),
    ]
}

@Test("SELECT-001 character selection extracts the covered text in reading order", arguments: SelectionCases.character)
func SELECT_001(_ testCase: SelectionCase) { testCase.run() }

@Test("SELECT-002 soft-wrapped lines are joined and trailing spaces trimmed", arguments: SelectionCases.wrapping)
func SELECT_002(_ testCase: SelectionCase) { testCase.run() }

@Test("SELECT-003 word selection expands to the surrounding word", arguments: SelectionCases.words)
func SELECT_003(_ testCase: SelectionCase) { testCase.run() }

@Test("SELECT-004 line selection covers whole logical lines", arguments: SelectionCases.lines)
func SELECT_004(_ testCase: SelectionCase) { testCase.run() }

@Test("SELECT-005 wide characters and graphemes are extracted once", arguments: SelectionCases.wide)
func SELECT_005(_ testCase: SelectionCase) { testCase.run() }

@Test("SELECT-006 selections follow their text as it scrolls into the scrollback")
func SELECT_006() {
    let terminal = Terminal(cols: 10, rows: 2)
    terminal.feed(numberedRows(4))
    let selection = Selection(anchor: SP(1, 0), head: SP(2, 9))
    #expect(terminal.text(in: selection) == "2\n3")
    terminal.feed("\r\n5")
    #expect(terminal.text(in: selection) == "2\n3")
}

@Test("SELECT-007 select all covers the scrollback and the screen", arguments: [
    SelectionCase(name: "scrollback and screen", cols: 10, rows: 4, input: numberedRows(6) + "⎋[3;1H",
                  selection: Selection(anchor: SP(0, 0)), expected: "1\n2\n3\n4\n5\n6"),
    SelectionCase(name: "single line", cols: 10, rows: 4, input: "only",
                  selection: Selection(anchor: SP(0, 0)), expected: "only"),
])
func SELECT_007(_ testCase: SelectionCase) {
    let terminal = Terminal(cols: testCase.cols, rows: testCase.rows)
    terminal.feed(testCase.input)
    #expect(terminal.text(in: terminal.selectAll()) == testCase.expected)
}
