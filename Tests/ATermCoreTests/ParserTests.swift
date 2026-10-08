import Testing
import ATermCore

/// One parser case: input chunks fed in order and the expected recorded actions.
struct ParserCase: CustomTestStringConvertible, Sendable {
    let name: String
    let chunks: [[UInt8]]
    let expected: [RecordingHandler.Action]

    init(_ name: String, _ input: [UInt8], _ expected: [RecordingHandler.Action]) {
        self.init(name, chunks: [input], expected)
    }

    init(_ name: String, chunks: [[UInt8]], _ expected: [RecordingHandler.Action]) {
        self.name = name
        self.chunks = chunks
        self.expected = expected
    }

    var testDescription: String { name }

    func run() -> [RecordingHandler.Action] {
        var parser = VTParser()
        let handler = RecordingHandler()
        for chunk in chunks {
            parser.feed(chunk, handler: handler)
        }
        return handler.actions
    }
}

extension RecordingHandler.Action: @unchecked Sendable {}

private let sample = Array("aé€😀z".utf8)

@Test("PARSER-001 text is emitted as print actions whatever the chunking", arguments: [
    ParserCase("single call", sample, [.print("aé€😀z")]),
    ParserCase("one byte per call", chunks: sample.map { [$0] }, [.print("aé€😀z")]),
    // 😀 starts at offset 1 + 2 + 3 = 6; split after its second byte.
    ParserCase("split inside 😀", chunks: [Array(sample[0..<8]), Array(sample[8...])], [.print("aé€😀z")]),
])
func PARSER_001(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-002 malformed UTF-8 is replaced by U+FFFD", arguments: [
    ParserCase("lead byte then ASCII", [0xC3, 0x28], [.print("\u{FFFD}(")]),
    ParserCase("invalid byte", [0xFF, 0x41], [.print("\u{FFFD}A")]),
    ParserCase("overlong encoding", [0xC0, 0xAF], [.print("\u{FFFD}\u{FFFD}")]),
    ParserCase("encoded surrogate", [0xED, 0xA0, 0x80], [.print("\u{FFFD}\u{FFFD}\u{FFFD}")]),
    ParserCase("truncated then CSI", [0xE2, 0x82, 0x1B, 0x5B, 0x41], [.print("\u{FFFD}"), .csi(CSISequence([], "A"))]),
])
func PARSER_002(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-003 C0 controls are executed even inside a CSI sequence", arguments: [
    ParserCase("controls in ground state", bytes("a\u{07}b\u{08}\t\n\u{0B}\u{0C}\r\u{0E}\u{0F}"), [
        .print("a"), .execute(0x07), .print("b"), .execute(0x08), .execute(0x09), .execute(0x0A),
        .execute(0x0B), .execute(0x0C), .execute(0x0D), .execute(0x0E), .execute(0x0F),
    ]),
    ParserCase("LF inside CSI", bytes("⎋[2\nA"), [.execute(0x0A), .csi(CSISequence([[2]], "A"))]),
    ParserCase("DEL is ignored", bytes("a\u{7F}b"), [.print("ab")]),
])
func PARSER_003(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-004 CSI sequences carry parameters sub-parameters private marker and intermediates", arguments: [
    ParserCase("two params", bytes("⎋[1;2H"), [.csi(CSISequence([[1], [2]], "H"))]),
    ParserCase("no params", bytes("⎋[H"), [.csi(CSISequence([], "H"))]),
    ParserCase("omitted first param", bytes("⎋[;5H"), [.csi(CSISequence([[0], [5]], "H"))]),
    ParserCase("private marker ?", bytes("⎋[?25h"), [.csi(CSISequence([[25]], "h", private: "?"))]),
    ParserCase("private marker >", bytes("⎋[>c"), [.csi(CSISequence([], "c", private: ">"))]),
    ParserCase("colon truecolor", bytes("⎋[38:2::255:128:0m"), [.csi(CSISequence([[38, 2, 0, 255, 128, 0]], "m"))]),
    ParserCase("mixed sub-params", bytes("⎋[4:3;58:5:196m"), [.csi(CSISequence([[4, 3], [58, 5, 196]], "m"))]),
    ParserCase("space intermediate", bytes("⎋[2 q"), [.csi(CSISequence([[2]], "q", intermediates: " "))]),
    ParserCase("private and intermediate", bytes("⎋[?2004$p"), [.csi(CSISequence([[2004]], "p", private: "?", intermediates: "$"))]),
    ParserCase("misplaced private marker", bytes("⎋[1?2hX"), [.print("X")]),
])
func PARSER_004(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-005 ESC sequences dispatch with their intermediates", arguments: [
    ParserCase("DECSC", bytes("⎋7"), [.esc(intermediates: "", final: "7")]),
    ParserCase("designate G0", bytes("⎋(0"), [.esc(intermediates: "(", final: "0")]),
    ParserCase("DECALN", bytes("⎋#8"), [.esc(intermediates: "#", final: "8")]),
    ParserCase("ESC restarts", bytes("⎋⎋[A"), [.csi(CSISequence([], "A"))]),
    ParserCase("lone ST", bytes("⎋\\"), []),
])
func PARSER_005(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-006 OSC strings are dispatched with their terminator", arguments: [
    ParserCase("BEL terminator", bytes("⎋]0;title\u{07}"), [.osc("0;title", .bel)]),
    ParserCase("ST terminator with UTF-8", bytes("⎋]2;héllo⎋\\"), [.osc("2;héllo", .st)]),
    ParserCase("hyperlink around text", bytes("⎋]8;;http://x.y⎋\\link⎋]8;;⎋\\"), [
        .osc("8;;http://x.y", .st), .print("link"), .osc("8;;", .st),
    ]),
    ParserCase("CAN aborts", bytes("⎋]0;abc\u{18}d"), [.print("d")]),
    ParserCase("oversized payload is discarded",
               bytes("⎋]0;") + [UInt8](repeating: UInt8(ascii: "x"), count: 70_000) + bytes("\u{07}z"),
               [.print("z")]),
])
func PARSER_006(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-007 DCS strings are dispatched and SOS PM APC strings are swallowed", arguments: [
    ParserCase("XTGETTCAP", bytes("⎋P+q544e⎋\\X"), [
        .dcs(DCSSequence([], "q", intermediates: "+", data: "544e")), .print("X"),
    ]),
    ParserCase("DECRQSS with param", bytes("⎋P1$r0m⎋\\"), [
        .dcs(DCSSequence([[1]], "r", intermediates: "$", data: "0m")),
    ]),
    ParserCase("APC", bytes("⎋_Gi=1;AAAA⎋\\Y"), [.print("Y")]),
    ParserCase("PM", bytes("⎋^secret⎋\\Z"), [.print("Z")]),
    ParserCase("SOS", bytes("⎋Xsos⎋\\W"), [.print("W")]),
])
func PARSER_007(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}

@Test("PARSER-008 oversized parameters are clamped", arguments: [
    ParserCase("huge value", bytes("⎋[99999999999999999999A"), [.csi(CSISequence([[65535]], "A"))]),
    ParserCase("forty params",
               bytes("⎋[" + (1...40).map(String.init).joined(separator: ";") + "m"),
               [.csi(CSISequence((1...32).map { [$0] }, "m"))]),
    ParserCase("eighteen sub-params",
               bytes("⎋[" + (1...18).map(String.init).joined(separator: ":") + "m"),
               [.csi(CSISequence([Array(1...16)], "m"))]),
])
func PARSER_008(_ testCase: ParserCase) {
    #expect(testCase.run() == testCase.expected)
}
