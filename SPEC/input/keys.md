# Input — keyboard encoding

`KeyEncoder.encode(_:modifiers:modes:optionAsMeta:)` in
`Sources/ATermCore/Input/KeyEncoder.swift` turns a key press into the bytes
written to the PTY. Its caller is `TerminalView.keyDown(with:)` in the app,
which passes:

- `.character(text)` for text keys: the text already composed by the keyboard
  layout, dead keys and input methods (`é`, `|` from ⌥⇧L on AZERTY…). When
  Option acts as Meta, the text is `charactersIgnoringModifiers` instead. When
  Control is held, the text is `charactersIgnoringModifiers`.
- a named key (`.up`, `.enter`, `.function(5)`…) for everything else.

Modifiers are `shift`, `option`, `control`. xterm modifier parameter:
`1 + shift(1) + option(2) + control(4)`. `⎋` stands for ESC, `SS3` for `⎋O`.

## INPUT-KEY-001 — Text is sent as UTF-8

Implement: `KeyEncoder.encode` for `.character`, called by `TerminalView.keyDown(with:)` and `TerminalView.insertText(_:replacementRange:)`.

Test: unit · `Tests/ATermCoreTests/KeyEncoderTests.swift` · "INPUT-KEY-001 text is sent as UTF-8"
- Given: the keys `.character("a")`, `.character("é")`, `.character("€")`, `.character("ê")`, each without modifiers
- When: each is encoded in normal mode
- Then: the bytes are respectively `61`, `C3 A9`, `E2 82 AC`, `C3 AA`

- Given: `.character("|")` with modifiers option + shift (⌥⇧L on a French layout), Option not acting as Meta
- When: it is encoded
- Then: the bytes are `7C`

## INPUT-KEY-002 — Control combinations produce C0 control codes

Implement: control mapping in `KeyEncoder.encode`, called by `TerminalView.keyDown(with:)`.

Test: unit · `Tests/ATermCoreTests/KeyEncoderTests.swift` · "INPUT-KEY-002 control combinations produce C0 control codes"
- Given: control + `.character(c)` for c in `a`, `z`, `A`, space, `@`, `[`, `\`, `]`, `^`, `_`, `?`, `2`, `3`, `4`, `5`, `6`, `7`, `8`
- When: each is encoded
- Then: the bytes are respectively `01`, `1A`, `01`, `00`, `00`, `1B`, `1C`, `1D`, `1E`, `1F`, `7F`, `00`, `1B`, `1C`, `1D`, `1E`, `1F`, `7F`

- Given: control + option + `.character("a")` with Option acting as Meta
- When: it is encoded
- Then: the bytes are `1B 01`

- Given: control + `.character("é")` (no control code exists)
- When: it is encoded
- Then: the bytes are `C3 A9`

## INPUT-KEY-003 — Special keys follow the cursor key mode

Implement: named keys in `KeyEncoder.encode`, called by `TerminalView.keyDown(with:)`.

Test: unit · `Tests/ATermCoreTests/KeyEncoderTests.swift` · "INPUT-KEY-003 special keys follow the cursor key mode"
- Given: the keys up, down, right, left, home, end without modifiers
- When: each is encoded with application cursor keys off, then on
- Then: off gives `⎋[A`, `⎋[B`, `⎋[C`, `⎋[D`, `⎋[H`, `⎋[F`; on gives `SS3 A`, `SS3 B`, `SS3 C`, `SS3 D`, `SS3 H`, `SS3 F`

- Given: the keys page up, page down, insert, forward delete, enter, tab, backspace, escape without modifiers
- When: each is encoded
- Then: the bytes are respectively `⎋[5~`, `⎋[6~`, `⎋[2~`, `⎋[3~`, `0D`, `09`, `7F`, `1B`

- Given: enter with the new line mode (LNM) on
- When: it is encoded
- Then: the bytes are `0D 0A`

- Given: shift + tab
- When: it is encoded
- Then: the bytes are `⎋[Z`

- Given: the function keys F1 to F12 without modifiers
- When: each is encoded
- Then: the bytes are `SS3 P`, `SS3 Q`, `SS3 R`, `SS3 S`, `⎋[15~`, `⎋[17~`, `⎋[18~`, `⎋[19~`, `⎋[20~`, `⎋[21~`, `⎋[23~`, `⎋[24~`

## INPUT-KEY-004 — Modified special keys carry the xterm modifier parameter

Implement: modifier parameters in `KeyEncoder.encode`, called by `TerminalView.keyDown(with:)`.

Test: unit · `Tests/ATermCoreTests/KeyEncoderTests.swift` · "INPUT-KEY-004 modified special keys carry the xterm modifier parameter"
- Given: shift + up, option + shift + up, control + right, control + shift + home, shift + F5, control + page up, shift + F1
- When: each is encoded
- Then: the bytes are respectively `⎋[1;2A`, `⎋[1;4A`, `⎋[1;5C`, `⎋[1;6H`, `⎋[15;2~`, `⎋[5;5~`, `⎋[1;2P`

- Given: control + up with application cursor keys on
- When: it is encoded
- Then: the bytes are `⎋[1;5A`

- Given: control + backspace, and shift + enter
- When: each is encoded
- Then: the bytes are respectively `08` and `0D`

## INPUT-KEY-005 — Option moves by word, or acts as Meta when enabled

Implement: Option handling in `KeyEncoder.encode`, called by `TerminalView.keyDown(with:)`.

Test: unit · `Tests/ATermCoreTests/KeyEncoderTests.swift` · "INPUT-KEY-005 option moves by word or acts as Meta when enabled"
- Given: Option not acting as Meta, the keys option + left, option + right, option + backspace, option + `.character("π")`
- When: each is encoded
- Then: the bytes are respectively `⎋b`, `⎋f`, `⎋ 7F`, `CF 80`

- Given: Option acting as Meta, the keys option + `.character("x")`, option + shift + `.character("X")`, option + backspace, option + left
- When: each is encoded
- Then: the bytes are respectively `⎋x`, `⎋X`, `⎋ 7F`, `⎋b`
