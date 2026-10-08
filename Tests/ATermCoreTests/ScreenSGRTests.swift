import Testing
import ATermCore

/// Feeds `⎋[<params>mX` (optionally with a suffix before `X`) and checks X's attributes.
struct SGRCase: CustomTestStringConvertible, Sendable {
    let params: String
    var suffix = ""
    let expected: Attributes

    var testDescription: String { "SGR \(params)\(suffix.isEmpty ? "" : " then \(suffix)")" }

    func run() {
        let terminal = Terminal(cols: 10, rows: 2)
        terminal.feed("⎋[\(params)m\(suffix)X")
        #expect(terminal.cell(0, 0).scalar == "X")
        #expect(terminal.cell(0, 0).attributes == expected)
    }
}

enum SGRCases {
    static func flags(_ params: String, _ flags: AttributeFlags) -> SGRCase {
        SGRCase(params: params, expected: Attributes(flags: flags))
    }

    static func underline(_ params: String, _ style: UnderlineStyle) -> SGRCase {
        SGRCase(params: params, expected: Attributes(underline: style))
    }

    static func plain(_ params: String, suffix: String = "") -> SGRCase {
        SGRCase(params: params, suffix: suffix, expected: Attributes())
    }

    static let attributes: [SGRCase] = [
        flags("1", .bold), flags("2", .dim), flags("3", .italic), flags("5", .blink),
        flags("7", .inverse), flags("8", .hidden), flags("9", .strikethrough), flags("53", .overline),
        underline("4", .single), underline("21", .double), underline("4:3", .curly),
        underline("4:4", .dotted), underline("4:5", .dashed), underline("4;4:0", .none),
        plain("1;2;22"), plain("3;23"), plain("4;24"), plain("5;25"), plain("7;27"),
        plain("8;28"), plain("9;29"), plain("53;55"),
        plain("1;3;4;7;31;42;0"), plain("1;4", suffix: "⎋[m"),
    ]

    static func fg(_ params: String, _ color: TerminalColor) -> SGRCase {
        SGRCase(params: params, expected: Attributes(foreground: color))
    }

    static func bg(_ params: String, _ color: TerminalColor) -> SGRCase {
        SGRCase(params: params, expected: Attributes(background: color))
    }

    static func ul(_ params: String, _ color: TerminalColor) -> SGRCase {
        SGRCase(params: params, expected: Attributes(underlineColor: color))
    }

    static let colors: [SGRCase] = [
        fg("31", .indexed(1)), fg("91", .indexed(9)), fg("38;5;208", .indexed(208)), fg("38:5:208", .indexed(208)),
        fg("38;2;10;20;30", .rgb(10, 20, 30)), fg("38:2::10:20:30", .rgb(10, 20, 30)),
        fg("38:2:10:20:30", .rgb(10, 20, 30)),
        bg("47", .indexed(7)), bg("107", .indexed(15)), bg("48;5;17", .indexed(17)), bg("48;2;1;2;3", .rgb(1, 2, 3)),
        ul("58:5:196", .indexed(196)), ul("58;2;1;2;3", .rgb(1, 2, 3)), ul("58;5;196;59", .default),
        plain("31;39"), plain("41;49"),
        SGRCase(params: "38;5;1;4", expected: Attributes(foreground: .indexed(1), underline: .single)),
        plain("38;5"), plain("38;2;300;0;0"),
    ]
}

@Test("SCREEN-SGR-001 SGR sets and resets text attributes", arguments: SGRCases.attributes)
func SCREEN_SGR_001(_ testCase: SGRCase) { testCase.run() }

@Test("SCREEN-SGR-002 SGR selects indexed and direct colors", arguments: SGRCases.colors)
func SCREEN_SGR_002(_ testCase: SGRCase) { testCase.run() }
