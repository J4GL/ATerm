# Parser action contract

Shared contract between `VTParser` (`Sources/ATermCore/Parser/VTParser.swift`)
and its handlers (`VTParserHandler`; `Terminal` is the production handler).
The parser interprets nothing: it only turns bytes into the actions below, in
stream order. Parser state survives across `feed` calls, so a sequence split
between two chunks produces the same actions as the unsplit stream.

## Actions

| Action | Payload | Emitted for |
|---|---|---|
| `print(scalar)` | one Unicode scalar | text in ground state: U+0020–U+007E, decoded UTF-8, or U+FFFD for malformed UTF-8 |
| `printASCII(bytes)` | a run of bytes 0x20–0x7E | optimisation, equivalent to one `print` per byte, in order |
| `execute(byte)` | a C0 control 0x00–0x1F other than ESC | outside strings, including in the middle of an ESC or CSI sequence (the sequence then continues) |
| `csiDispatch(CSISequence)` | see below | a complete, valid CSI sequence |
| `escDispatch(intermediates, final)` | bytes 0x20–0x2F, final 0x30–0x7E | a complete ESC sequence, except the CSI/OSC/DCS/SOS/PM/APC introducers and ST (`ESC \`) |
| `oscDispatch(payload, terminator)` | raw payload bytes, `.bel` or `.st` | an OSC string ended by BEL or by ESC |
| `dcsDispatch(DCSSequence)` | params, private marker, intermediates, final, data | a DCS string ended by ESC |

DEL (0x7F) is ignored everywhere except inside string payloads.

## CSISequence

- `params: [[Int]]` — one entry per `;`-separated parameter, each listing its
  `:`-separated sub-parameters. An omitted value is `0`. `CSI m` has no
  entries; `CSI ;m` has two `[0]` entries; `CSI 38:2::1:2:3m` has one entry
  `[38, 2, 0, 1, 2, 3]`.
- `privateMarker: UInt8?` — `<`, `=`, `>` or `?` when it is the first byte
  after `CSI`. Such a byte anywhere else invalidates the sequence.
- `intermediates: [UInt8]` — bytes 0x20–0x2F between the parameters and the final byte.
- `final: UInt8` — 0x40–0x7E.

`DCSSequence` has the same fields plus `data: [UInt8]`, the bytes between the
final byte and the terminator.

## Limits and aborts

- At most 32 parameters and 16 sub-parameters per parameter; extra ones are
  dropped. Values are clamped to 65 535.
- OSC and DCS payloads longer than 65 536 bytes are discarded without dispatch.
- CAN (0x18) and SUB (0x1A) cancel any sequence or string in progress without
  dispatching it; outside strings they are also executed.
- ESC always starts a new escape sequence; inside an OSC string it first
  dispatches the string with terminator `.st`.
- Bytes 0x80–0xFF are UTF-8 text in ground state and payload inside OSC/DCS
  strings; they are ignored inside ESC and CSI sequences. 8-bit C1 controls
  are not recognised.
