# Screen — cursor movement

Cursor handling of `Terminal` (`Sources/ATermCore/Screen/`), reached through
`Terminal.feed(_:)`. `⎋` stands for ESC; every case starts from a fresh
terminal; positions are `(row, col)`, 0-based.

## SCREEN-CURSOR-001 — Absolute positioning is 1-based and clamped to the screen

Implement: CUP (`H`), HVP (`f`), CHA (`G`), HPA (`` ` ``) and VPA (`d`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-001 absolute positioning is 1-based and clamped"
- Given: an 80×24 terminal
- When: `⎋[5;10H` is fed
- Then: the cursor is at (4, 9)

- Given: an 80×24 terminal
- When: `⎋[5;5H⎋[H` is fed
- Then: the cursor is at (0, 0)

- Given: an 80×24 terminal
- When: `⎋[99;999H` is fed
- Then: the cursor is at (23, 79)

- Given: an 80×24 terminal
- When: `⎋[0;0H` is fed
- Then: the cursor is at (0, 0)

- Given: an 80×24 terminal
- When: `⎋[5;10H⎋[3G` is fed
- Then: the cursor is at (4, 2)

- Given: an 80×24 terminal
- When: `⎋[5;10H⎋[20`` ` `` is fed
- Then: the cursor is at (4, 19)

- Given: an 80×24 terminal
- When: `⎋[5;10H⎋[7d` is fed
- Then: the cursor is at (6, 9)

- Given: an 80×24 terminal
- When: `⎋[2;3f` is fed
- Then: the cursor is at (1, 2)

## SCREEN-CURSOR-002 — Relative movement defaults to one and stops at the edges

Implement: CUU (`A`), CUD (`B`), CUF (`C`), CUB (`D`), CNL (`E`), CPL (`F`), HPR (`a`) and VPR (`e`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-002 relative movement defaults to one and stops at the edges"
- Given: an 80×24 terminal with the cursor at (5, 5) (`⎋[6;6H`)
- When: `⎋[A` is fed
- Then: the cursor is at (4, 5)
- When: `⎋[3B` is fed
- Then: the cursor is at (7, 5)
- When: `⎋[2C` is fed
- Then: the cursor is at (7, 7)
- When: `⎋[10D` is fed
- Then: the cursor is at (7, 0)
- When: `⎋[2E` is fed
- Then: the cursor is at (9, 0)
- When: `⎋[F` is fed
- Then: the cursor is at (8, 0)
- When: `⎋[0A` is fed
- Then: the cursor is at (7, 0)
- When: `⎋[3a⎋[2e` is fed
- Then: the cursor is at (9, 3)
- When: `⎋[99A⎋[999C` is fed
- Then: the cursor is at (0, 79)
- When: `⎋[99B⎋[999D` is fed
- Then: the cursor is at (23, 0)

## SCREEN-CURSOR-003 — BS, CR, LF, VT, FF and HT move the cursor

Implement: C0 execution in `Terminal` and LNM (`CSI 20 h/l`), called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-003 BS CR LF VT FF and HT move the cursor"
- Given: an 80×24 terminal
- When: `abc` BS BS `X` is fed
- Then: row 0 is `aXc` and the cursor is at (0, 2)

- Given: an 80×24 terminal
- When: BS is fed
- Then: the cursor is at (0, 0)

- Given: an 80×24 terminal
- When: `abc` CR `X` is fed
- Then: row 0 is `Xbc` and the cursor is at (0, 1)

- Given: an 80×24 terminal
- When: `ab` LF `cd` is fed
- Then: row 0 is `ab`, row 1 is `  cd` and the cursor is at (1, 4)

- Given: an 80×24 terminal
- When: `⎋[20hab` LF `cd` is fed
- Then: row 1 is `cd` and the cursor is at (1, 2)

- Given: an 80×24 terminal
- When: `ab` VT `c` FF `d` is fed
- Then: row 1 is `  c`, row 2 is `   d` and the cursor is at (2, 4)

- Given: an 80×24 terminal
- When: `a` HT `b` is fed
- Then: row 0 is `a       b` and the cursor is at (0, 9)

- Given: an 80×24 terminal
- When: `⎋[1;79H` HT HT `X` is fed
- Then: cell 79 of row 0 holds `X`

## SCREEN-CURSOR-004 — Tab stops can be set and cleared

Implement: HTS (`ESC H`), TBC (`CSI g`), CHT (`CSI I`) and CBT (`CSI Z`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-004 tab stops can be set and cleared"
- Given: an 80×24 terminal
- When: `⎋[1;5H⎋H⎋[1;1H` HT `X` is fed
- Then: cell 4 of row 0 holds `X`

- Given: an 80×24 terminal
- When: `⎋[1;9H⎋[g⎋[1;1H` HT `X` is fed
- Then: cell 16 of row 0 holds `X`

- Given: an 80×24 terminal
- When: `⎋[3g` HT `X` is fed
- Then: cell 79 of row 0 holds `X`

- Given: an 80×24 terminal
- When: `⎋[1;20H⎋[ZX` is fed
- Then: cell 16 of row 0 holds `X`

- Given: an 80×24 terminal
- When: `⎋[2IX` is fed
- Then: cell 16 of row 0 holds `X`

## SCREEN-CURSOR-005 — Saving the cursor restores position, attributes and charset

Implement: DECSC/DECRC (`ESC 7`, `ESC 8`) and SCOSC/SCORC (`CSI s`, `CSI u`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-005 saving the cursor restores position attributes and charset"
- Given: an 80×24 terminal
- When: `⎋[3;4H⎋[1;31m⎋7⎋[10;10H⎋[0m⎋8X` is fed
- Then: cell (2, 3) holds `X` with the bold flag and foreground `.indexed(1)`

- Given: an 80×24 terminal
- When: `⎋[3;4H⎋[s⎋[10;10H⎋[uX` is fed
- Then: cell (2, 3) holds `X`

- Given: an 80×24 terminal
- When: `⎋(0⎋7⎋(B⎋8q` is fed
- Then: row 0 is `─`

- Given: an 80×24 terminal
- When: `⎋[1;31m⎋[5;5H⎋8X` is fed (restore without save)
- Then: cell (0, 0) holds `X` with default attributes

## SCREEN-CURSOR-006 — Origin mode confines addressing to the scroll region

Implement: DECOM (`CSI ? 6 h/l`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-006 origin mode confines addressing to the scroll region"
- Given: an 80×24 terminal
- When: `⎋[5;10r⎋[?6h⎋[HX` is fed
- Then: cell (4, 0) holds `X`

- Given: an 80×24 terminal
- When: `⎋[5;10r⎋[?6h⎋[99;1HX` is fed
- Then: cell (9, 0) holds `X`

- Given: an 80×24 terminal
- When: `⎋[5;10r⎋[?6h⎋[2;3H⎋[6n` is fed
- Then: the terminal sends `⎋[2;3R`

- Given: an 80×24 terminal
- When: `⎋[5;10r⎋[?6h⎋[?6lX` is fed
- Then: cell (0, 0) holds `X`

## SCREEN-CURSOR-007 — Cursor visibility and shape follow DECTCEM and DECSCUSR

Implement: DECTCEM (`CSI ? 25 h/l`), cursor blink (`CSI ? 12 h/l`) and DECSCUSR (`CSI Ps SP q`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenCursorTests.swift` · "SCREEN-CURSOR-007 cursor visibility and shape follow DECTCEM and DECSCUSR"
- Given: an 80×24 terminal
- When: nothing is fed
- Then: the cursor is visible, its shape is `block` and it does not blink

- Given: an 80×24 terminal
- When: `⎋[?25l` is fed
- Then: the cursor is hidden
- When: `⎋[?25h` is fed
- Then: the cursor is visible

- Given: an 80×24 terminal
- When: each of `⎋[1 q`, `⎋[2 q`, `⎋[3 q`, `⎋[4 q`, `⎋[5 q`, `⎋[6 q`, `⎋[0 q` is fed in turn
- Then: after each one the shape and blink are respectively block/blinking, block/steady, underline/blinking, underline/steady, bar/blinking, bar/steady, block/steady

- Given: an 80×24 terminal
- When: `⎋[?12h` is fed
- Then: the cursor blinks
- When: `⎋[?12l` is fed
- Then: the cursor does not blink
