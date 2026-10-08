# Screen — scrolling and scrollback

Scrolling of `Terminal` (`Sources/ATermCore/Screen/`), reached through
`Terminal.feed(_:)`. `⎋` stands for ESC; every case starts from a fresh
terminal. "Rows 1..N" means the terminal was fed `1` CR LF `2` … CR LF `N`.

## SCREEN-SCROLL-001 — A line feed at the bottom scrolls the top line into scrollback

Implement: index/scroll-up in `Terminal` and the scrollback store, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenScrollingTests.swift` · "SCREEN-SCROLL-001 a line feed at the bottom scrolls the top line into scrollback"
- Given: a 10×3 terminal
- When: rows 1..4 are fed
- Then: the rows are `2`, `3`, `4`, the scrollback is [`1`] and the cursor is at (2, 1)

## SCREEN-SCROLL-002 — Scrollback keeps at most the configured number of lines

Implement: scrollback limit in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenScrollingTests.swift` · "SCREEN-SCROLL-002 scrollback keeps at most the configured number of lines"
- Given: a 10×2 terminal with a scrollback limit of 3
- When: rows 1..8 are fed
- Then: the scrollback is [`4`, `5`, `6`], the rows are `7`, `8` and `linesDropped` is 3

## SCREEN-SCROLL-003 — A scroll region scrolls only its own lines

Implement: DECSTBM (`CSI Pt ; Pb r`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenScrollingTests.swift` · "SCREEN-SCROLL-003 a scroll region scrolls only its own lines"
- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2;4r` is fed
- Then: the scroll region is rows 1…3 and the cursor is at (0, 0)
- When: `⎋[4;1H` LF is fed
- Then: the rows are `1`, `3`, `4`, ``, `5` and the scrollback is empty

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[1;3r⎋[3;1H` LF is fed
- Then: the rows are `2`, `3`, ``, `4`, `5` and the scrollback is [`1`]

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[3;3r` is fed (empty region)
- Then: the scroll region is rows 0…4

## SCREEN-SCROLL-004 — RI, IND and NEL move the cursor and scroll at the margins

Implement: RI (`ESC M`), IND (`ESC D`) and NEL (`ESC E`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenScrollingTests.swift` · "SCREEN-SCROLL-004 RI IND and NEL move the cursor and scroll at the margins"
- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[1;1H⎋M` is fed
- Then: the rows are ``, `1`, `2`, `3`, `4` and the cursor is at (0, 0)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[3;3H⎋M` is fed
- Then: the rows are `1`, `2`, `3`, `4`, `5` and the cursor is at (1, 2)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[5;3H⎋D` is fed
- Then: the rows are `2`, `3`, `4`, `5`, ``, the scrollback is [`1`] and the cursor is at (4, 2)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2;3H⎋E` is fed
- Then: the cursor is at (2, 0)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2;4r⎋[2;1H⎋M` is fed
- Then: the rows are `1`, ``, `2`, `3`, `5`

## SCREEN-SCROLL-005 — SU and SD scroll the region by n lines

Implement: SU (`CSI Ps S`) and SD (`CSI Ps T`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenScrollingTests.swift` · "SCREEN-SCROLL-005 SU and SD scroll the region by n lines"
- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2S` is fed
- Then: the rows are `3`, `4`, `5`, ``, ``, the scrollback is [`1`, `2`] and the cursor is at (4, 1)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2T` is fed
- Then: the rows are ``, ``, `1`, `2`, `3` and the cursor is at (4, 1)

- Given: a 10×5 terminal showing rows 1..5
- When: `⎋[2;4r⎋[S` is fed
- Then: the rows are `1`, `3`, `4`, ``, `5` and the scrollback is empty
