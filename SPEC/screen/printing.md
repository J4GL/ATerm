# Screen — printing text

`Terminal.print(_:)` / `Terminal.printASCII(_:)` in
`Sources/ATermCore/Screen/Terminal.swift`, reached through
`Terminal.feed(_:)`. In the specs `⎋` stands for ESC and every case starts from
a fresh terminal.

## SCREEN-PRINT-001 — Printing writes at the cursor and advances it

Implement: printing in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-001 printing writes at the cursor and advances it"
- Given: a 10×3 terminal
- When: `abc` is fed
- Then: row 0 is `abc`, rows 1–2 are empty, the cursor is at (0, 3) and cells 0–2 have width 1 and default attributes

## SCREEN-PRINT-002 — Autowrap is deferred until the next printable character

Implement: pending-wrap state and DECAWM (`CSI ? 7 h/l`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-002 autowrap is deferred until the next printable character"
- Given: a 5×3 terminal
- When: `abcde` is fed
- Then: row 0 is `abcde`, row 0 is not wrapped and the cursor is at (0, 4)
- When: `f` is fed
- Then: row 0 is `abcde` and wrapped, row 1 is `f` and the cursor is at (1, 1)

- Given: a 5×3 terminal
- When: `abcde` CR `X` is fed
- Then: row 0 is `Xbcde`, row 1 is empty and the cursor is at (0, 1)

- Given: a 5×3 terminal
- When: `abcde⎋[DX` is fed
- Then: row 0 is `abcXe`, row 1 is empty and the cursor is at (0, 4)

- Given: a 5×3 terminal
- When: `⎋[?7labcdefg` is fed
- Then: row 0 is `abcdg` and not wrapped, row 1 is empty and the cursor is at (0, 4)

## SCREEN-PRINT-003 — Wide characters occupy two cells

Implement: wide-character placement in `Terminal` using `CharacterWidth`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-003 wide characters occupy two cells"
- Given: a 6×2 terminal
- When: `a中b` is fed
- Then: row 0 is `a中b`, cell 1 has width 2, cell 2 has width 0, cell 3 holds `b` and the cursor is at (0, 4)

- Given: a 5×2 terminal
- When: `abcd中` is fed
- Then: row 0 is `abcd` and wrapped, row 1 is `中` and the cursor is at (1, 2)

- Given: a 6×2 terminal
- When: `中⎋[1;2Hx` is fed (overwrite the trailing half)
- Then: cell 0 is a blank of width 1, cell 1 holds `x` with width 1 and row 0 is ` x`

- Given: a 6×2 terminal
- When: `ab中⎋[1;3Hx` is fed (overwrite the leading half)
- Then: cell 2 holds `x`, cell 3 is a blank of width 1 and row 0 is `abx`

## SCREEN-PRINT-004 — Zero-width characters join the previous cell

Implement: grapheme joining in `Terminal` using `CharacterWidth`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-004 zero-width characters join the previous cell"
- Given: a 6×2 terminal
- When: `e` U+0301 `x` is fed
- Then: `character(at: 0)` of row 0 is `e\u{301}`, cell 1 holds `x` and the cursor is at (0, 2)

- Given: a 6×2 terminal
- When: `👨` U+200D `👩` `z` is fed
- Then: `character(at: 0)` of row 0 is `👨‍👩`, cell 0 has width 2, cell 2 holds `z` and the cursor is at (0, 3)

- Given: a 5×2 terminal
- When: `abcde` U+0301 is fed (mark after a pending wrap)
- Then: `character(at: 4)` of row 0 is `e\u{301}`, row 1 is empty and the cursor is at (0, 4)

- Given: a 6×2 terminal
- When: U+0301 `a` is fed (nothing to join)
- Then: row 0 is `a` and the cursor is at (0, 1)

- Given: a 5×2 terminal fed `abcde⎋7⎋[1;1Habcd中⎋8` (the restored cursor waits to wrap on a padding cell)
- When: U+0301 is fed
- Then: `character(at: 4)` of row 0 is a space (a mark never joins a padding cell)

- Given: a 6×2 terminal
- When: `e` followed by 40 × U+0301 is fed
- Then: `character(at: 0)` of row 0 has 32 scalars (a grapheme keeps at most 32; further marks are dropped)

## SCREEN-PRINT-005 — Insert mode shifts the rest of the line right

Implement: IRM (`CSI 4 h/l`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-005 insert mode shifts the rest of the line right"
- Given: an 8×2 terminal showing `abcdef`
- When: `⎋[1;3H⎋[4hX` is fed
- Then: row 0 is `abXcdef` and the cursor is at (0, 3)
- When: `⎋[4lY` is fed
- Then: row 0 is `abXYdef` and the cursor is at (0, 4)

- Given: a 6×2 terminal showing `abcdef`
- When: `⎋[1;1H⎋[4hXY` is fed
- Then: row 0 is `XYabcd` and row 1 is empty

## SCREEN-PRINT-006 — DEC special graphics are mapped through G0 and G1

Implement: charset designation (`ESC ( F`, `ESC ) F`) and SO/SI in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-006 DEC special graphics are mapped through G0 and G1"
- Given: a 20×2 terminal
- When: `⎋(0jklmnqtuvwx⎋(Bq` is fed
- Then: row 0 is `┘┐┌└┼─├┤┴┬│q`

- Given: a 20×2 terminal
- When: `⎋)0` SO `x` SI `x` is fed
- Then: row 0 is `│x`

- Given: a 20×2 terminal
- When: `⎋(0` + `` `afgy{|}~ `` is fed
- Then: row 0 is `◆▒°±≤π≠£·`

## SCREEN-PRINT-007 — REP repeats the last printed character

Implement: REP (`CSI Ps b`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-007 REP repeats the last printed character"
- Given: a 10×2 terminal
- When: `a⎋[3b` is fed
- Then: row 0 is `aaaa` and the cursor is at (0, 4)

- Given: a 10×2 terminal
- When: `⎋[3b` is fed (nothing printed yet)
- Then: row 0 is empty and the cursor is at (0, 0)

## SCREEN-PRINT-008 — Overwriting text keeps the graphemes of untouched cells

Implement: the ASCII fast path of `Terminal.printASCII(_:)`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenPrintingTests.swift` · "SCREEN-PRINT-008 overwriting text keeps the graphemes of untouched cells"
- Given: a 10×2 terminal fed `e` U+0301 `bc`
- When: `⎋[1;2Hxy` is fed
- Then: `character(at: 0)` of row 0 is `e\u{301}` and row 0 reads `e\u{301}xy`

- Given: a 10×2 terminal fed `中a`
- When: `⎋[1;2Hxy` is fed (overwriting the trailing half)
- Then: row 0 reads ` xy`
