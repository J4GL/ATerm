# Screen — modes, alternate screen and resets

Mode handling of `Terminal` (`Sources/ATermCore/Screen/`), reached through
`Terminal.feed(_:)`. `⎋` stands for ESC; every case starts from a fresh
terminal. Mode flags are read from `Terminal.modes`.

## SCREEN-MODE-001 — The alternate screen preserves the main screen

Implement: DECSET/DECRST 1049, 1047 and 47 in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenModeTests.swift` · "SCREEN-MODE-001 the alternate screen preserves the main screen"
- Given: a 10×3 terminal fed `main⎋[2;3H`
- When: `⎋[?1049h` is fed
- Then: the alternate screen is active, every row is empty and the cursor is at (1, 2)
- When: `alt` LF LF LF LF is fed
- Then: row 0 is empty and the scrollback is empty
- When: `⎋[?1049l` is fed
- Then: the alternate screen is inactive, the rows are `main`, ``, `` and the cursor is at (1, 2)
- When: `⎋[?1049h` is fed again
- Then: every row is empty

- Given: a 10×3 terminal fed `main`
- When: `⎋[?1047hxyz⎋[?1047l` is fed
- Then: the alternate screen is inactive, row 0 is `main` and the cursor is at (0, 7)
- When: `⎋[?1047h` is fed
- Then: every row is empty

- Given: a 10×3 terminal fed `main`
- When: `⎋[?47h⎋[1;1Halt⎋[?47l` is fed
- Then: the alternate screen is inactive, row 0 is `main` and the cursor is at (0, 3)

## SCREEN-MODE-002 — Mode sequences toggle the terminal mode flags

Implement: SM/RM (`CSI Pm h/l`), DECSET/DECRST (`CSI ? Pm h/l`), DECKPAM/DECKPNM (`ESC =`, `ESC >`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenModeTests.swift` · "SCREEN-MODE-002 mode sequences toggle the terminal mode flags"
- Given: a fresh terminal
- When: nothing is fed
- Then: `autoWrap`, `cursorVisible` and `alternateScroll` are on; `applicationCursorKeys`, `applicationKeypad`, `reverseVideo`, `originMode`, `insertMode`, `newLineMode`, `bracketedPaste`, `focusReporting` and `synchronizedOutput` are off; `mouseTracking` is `.none` and `mouseEncoding` is `.legacy`

- Given: the pairs (`⎋[?1h`, `applicationCursorKeys`), (`⎋[?5h`, `reverseVideo`), (`⎋[?6h`, `originMode`), (`⎋[?2004h`, `bracketedPaste`), (`⎋[?1004h`, `focusReporting`), (`⎋[?2026h`, `synchronizedOutput`), (`⎋[4h`, `insertMode`), (`⎋[20h`, `newLineMode`), (`⎋=`, `applicationKeypad`)
- When: each set sequence is fed, then the same sequence with `l` (`⎋>` for the keypad)
- Then: the flag is on after the first and off after the second

- Given: the pairs (`⎋[?7l`, `autoWrap`), (`⎋[?25l`, `cursorVisible`), (`⎋[?1007l`, `alternateScroll`)
- When: each reset sequence is fed, then the same sequence with `h`
- Then: the flag is off after the first and on after the second

- Given: the sequences `⎋[?9h`, `⎋[?1000h`, `⎋[?1002h`, `⎋[?1003h`
- When: each is fed in its own case, then `⎋[?1000l`
- Then: `mouseTracking` is respectively `.x10`, `.normal`, `.buttonEvent`, `.anyEvent`, and `.none` after the reset

- Given: a fresh terminal
- When: `⎋[?1000;1006h` is fed
- Then: `mouseTracking` is `.normal` and `mouseEncoding` is `.sgr`
- When: `⎋[?1006l` is fed
- Then: `mouseEncoding` is `.legacy`

## SCREEN-MODE-003 — RIS and DECSTR reset the terminal state

Implement: RIS (`ESC c`) and DECSTR (`CSI ! p`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenModeTests.swift` · "SCREEN-MODE-003 RIS and DECSTR reset the terminal state"
- Given: a 10×3 terminal fed rows 1..4 then `⎋]2;T\u{07}⎋[1;31m⎋[?1h⎋[2;3r⎋(0`
- When: `⎋cq` is fed
- Then: row 0 is `q` with default attributes, rows 1–2 are empty, the cursor is at (0, 1), the scroll region is rows 0…2, `applicationCursorKeys` is off, the title is empty and the scrollback is still [`1`]

- Given: a 10×3 terminal fed `abc⎋[1;31m⎋[?7l⎋[4h⎋[?6h⎋[?25l⎋[2;3r⎋[2;2H`
- When: `⎋[!pX` is fed
- Then: row 0 is `abc`, `autoWrap` and `cursorVisible` are on, `insertMode` and `originMode` are off, the scroll region is rows 0…2 and `X` has default attributes at (2, 1), where the cursor was
