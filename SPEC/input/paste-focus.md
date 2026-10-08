# Input — paste and focus reports

`PasteEncoder.encode(_:bracketed:)` and `FocusEncoder.encode(focused:modes:)`
in `Sources/ATermCore/Input/`. Their callers are `TerminalView.paste(_:)`
and the view's focus handling in the app. `⎋` is ESC.

## INPUT-PASTE-001 — Pasted text uses CR line endings and brackets when requested

Implement: `PasteEncoder.encode(_:bracketed:)`, called by `TerminalView.paste(_:)` with `modes.bracketedPaste`.

Test: unit · `Tests/ATermCoreTests/PasteFocusEncoderTests.swift` · "INPUT-PASTE-001 pasted text uses CR line endings and brackets when requested"
- Given: the text `a` LF `b` CR LF `c`, bracketed paste off
- When: it is encoded
- Then: the bytes are `a` CR `b` CR `c`

- Given: the text `a` LF `b`, bracketed paste on
- When: it is encoded
- Then: the bytes are `⎋[200~a` CR `b⎋[201~`

- Given: the text `x⎋[201~y`, bracketed paste on (an attempt to end the paste early)
- When: it is encoded
- Then: the bytes are `⎋[200~xy⎋[201~`

- Given: the text `x⎋[20⎋[201~1~y`, bracketed paste on (an end marker hidden around another one)
- When: it is encoded
- Then: the bytes are `⎋[200~xy⎋[201~`

## INPUT-FOCUS-001 — Focus changes are reported only when requested

Implement: `FocusEncoder.encode(focused:modes:)`, called by `TerminalView` when it gains or loses keyboard focus.

Test: unit · `Tests/ATermCoreTests/PasteFocusEncoderTests.swift` · "INPUT-FOCUS-001 focus changes are reported only when requested"
- Given: focus reporting on
- When: focus in, then focus out are encoded
- Then: the bytes are `⎋[I`, then `⎋[O`

- Given: focus reporting off
- When: focus in is encoded
- Then: nothing is produced
