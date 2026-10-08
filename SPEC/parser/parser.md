# Parser

`VTParser.feed(_:handler:)` in `Sources/ATermCore/Parser/VTParser.swift` is
called by `Terminal.feed(_:)` for every chunk read from the PTY. In the tests a
recording handler merges consecutive `print`/`printASCII` actions into a single
`print(text)` action.

## PARSER-001 — Text is emitted as print actions whatever the chunking

Implement: `VTParser.feed(_:handler:)` ground state and UTF-8 decoder, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-001 text is emitted as print actions whatever the chunking"
- Given: the UTF-8 bytes of `aé€😀z` (1 + 2 + 3 + 4 + 1 bytes)
- When: they are fed in a single call
- Then: the recorded actions are exactly `[print("aé€😀z")]`

- Given: the same bytes
- When: they are fed one byte per call
- Then: the recorded actions are exactly `[print("aé€😀z")]`

- Given: the same bytes
- When: they are fed in two calls split after the second byte of `😀`
- Then: the recorded actions are exactly `[print("aé€😀z")]`

## PARSER-002 — Malformed UTF-8 is replaced by U+FFFD

Implement: UTF-8 error handling in `VTParser`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-002 malformed UTF-8 is replaced by U+FFFD"
- Given: bytes `C3 28` (lead byte followed by ASCII)
- When: they are fed
- Then: the actions are `[print("\u{FFFD}(")]`

- Given: bytes `FF 41` (invalid byte)
- When: they are fed
- Then: the actions are `[print("\u{FFFD}A")]`

- Given: bytes `C0 AF` (overlong encoding)
- When: they are fed
- Then: the actions are `[print("\u{FFFD}\u{FFFD}")]`

- Given: bytes `ED A0 80` (encoded UTF-16 surrogate)
- When: they are fed
- Then: the actions are `[print("\u{FFFD}\u{FFFD}\u{FFFD}")]`

- Given: bytes `E2 82 1B 5B 41` (truncated sequence followed by `ESC [ A`)
- When: they are fed
- Then: the actions are `[print("\u{FFFD}"), csi(params: [], final: A)]`

## PARSER-003 — C0 controls are executed, even inside a CSI sequence

Implement: C0 handling in every `VTParser` state, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-003 C0 controls are executed even inside a CSI sequence"
- Given: the bytes of `a` BEL `b` BS HT LF VT FF CR SO SI
- When: they are fed
- Then: the actions are `[print("a"), execute(07), print("b"), execute(08), execute(09), execute(0A), execute(0B), execute(0C), execute(0D), execute(0E), execute(0F)]`

- Given: the bytes of `ESC [ 2` LF `A`
- When: they are fed
- Then: the actions are `[execute(0A), csi(params: [[2]], final: A)]`

- Given: the bytes of `a` DEL `b`
- When: they are fed
- Then: the actions are `[print("ab")]`

## PARSER-004 — CSI sequences carry parameters, sub-parameters, private marker and intermediates

Implement: CSI states of `VTParser` and `CSISequence`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-004 CSI sequences carry parameters sub-parameters private marker and intermediates"
- Given: `ESC[1;2H`
- When: it is fed
- Then: the actions are `[csi(params: [[1], [2]], final: H)]`

- Given: `ESC[H`
- When: it is fed
- Then: the actions are `[csi(params: [], final: H)]`

- Given: `ESC[;5H`
- When: it is fed
- Then: the actions are `[csi(params: [[0], [5]], final: H)]`

- Given: `ESC[?25h`
- When: it is fed
- Then: the actions are `[csi(private: ?, params: [[25]], final: h)]`

- Given: `ESC[>c`
- When: it is fed
- Then: the actions are `[csi(private: >, params: [], final: c)]`

- Given: `ESC[38:2::255:128:0m`
- When: it is fed
- Then: the actions are `[csi(params: [[38, 2, 0, 255, 128, 0]], final: m)]`

- Given: `ESC[4:3;58:5:196m`
- When: it is fed
- Then: the actions are `[csi(params: [[4, 3], [58, 5, 196]], final: m)]`

- Given: `ESC[2 q`
- When: it is fed
- Then: the actions are `[csi(params: [[2]], intermediates: " ", final: q)]`

- Given: `ESC[?2004$p`
- When: it is fed
- Then: the actions are `[csi(private: ?, params: [[2004]], intermediates: "$", final: p)]`

- Given: `ESC[1?2hX` (private marker after a parameter)
- When: it is fed
- Then: the actions are `[print("X")]`

## PARSER-005 — ESC sequences dispatch with their intermediates

Implement: escape states of `VTParser`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-005 ESC sequences dispatch with their intermediates"
- Given: `ESC7`
- When: it is fed
- Then: the actions are `[esc(intermediates: "", final: 7)]`

- Given: `ESC(0`
- When: it is fed
- Then: the actions are `[esc(intermediates: "(", final: 0)]`

- Given: `ESC#8`
- When: it is fed
- Then: the actions are `[esc(intermediates: "#", final: 8)]`

- Given: `ESC ESC [A` (an ESC interrupted by another ESC)
- When: it is fed
- Then: the actions are `[csi(params: [], final: A)]`

- Given: `ESC\` (a lone string terminator)
- When: it is fed
- Then: no action is recorded

## PARSER-006 — OSC strings are dispatched with their terminator

Implement: OSC string state of `VTParser`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-006 OSC strings are dispatched with their terminator"
- Given: `ESC]0;title` BEL
- When: it is fed
- Then: the actions are `[osc("0;title", .bel)]`

- Given: `ESC]2;héllo ESC\` (UTF-8 payload, ST terminator)
- When: it is fed
- Then: the actions are `[osc("2;héllo", .st)]`

- Given: `ESC]8;;http://x.y ESC\` `link` `ESC]8;; ESC\`
- When: it is fed
- Then: the actions are `[osc("8;;http://x.y", .st), print("link"), osc("8;;", .st)]`

- Given: `ESC]0;abc` CAN `d`
- When: it is fed
- Then: the actions are `[print("d")]`

- Given: `ESC]0;` followed by 70 000 `x` bytes, BEL, then `z`
- When: it is fed
- Then: the actions are `[print("z")]`

## PARSER-007 — DCS strings are dispatched, SOS/PM/APC strings are swallowed

Implement: DCS and SOS/PM/APC states of `VTParser`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-007 DCS strings are dispatched and SOS PM APC strings are swallowed"
- Given: `ESCP+q544e ESC\` then `X`
- When: it is fed
- Then: the actions are `[dcs(params: [], intermediates: "+", final: q, data: "544e"), print("X")]`

- Given: `ESCP1$r0m ESC\`
- When: it is fed
- Then: the actions are `[dcs(params: [[1]], intermediates: "$", final: r, data: "0m")]`

- Given: `ESC_Gi=1;AAAA ESC\` then `Y` (APC)
- When: it is fed
- Then: the actions are `[print("Y")]`

- Given: `ESC^secret ESC\` then `Z` (PM)
- When: it is fed
- Then: the actions are `[print("Z")]`

- Given: `ESCXsos ESC\` then `W` (SOS)
- When: it is fed
- Then: the actions are `[print("W")]`

## PARSER-008 — Oversized parameters are clamped instead of overflowing

Implement: parameter accumulation limits in `VTParser`, called by `Terminal.feed(_:)`.
Uses: [Parser action contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ParserTests.swift` · "PARSER-008 oversized parameters are clamped"
- Given: `ESC[99999999999999999999A`
- When: it is fed
- Then: the actions are `[csi(params: [[65535]], final: A)]`

- Given: `ESC[` followed by the numbers 1 to 40 separated by `;`, then `m`
- When: it is fed
- Then: one CSI is recorded whose params are `[[1], [2], …, [32]]`

- Given: `ESC[1:2:3:4:5:6:7:8:9:10:11:12:13:14:15:16:17:18m`
- When: it is fed
- Then: one CSI is recorded whose params are `[[1, 2, …, 16]]`
