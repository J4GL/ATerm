# Screen — erasing and editing

Erase and edit operations of `Terminal` (`Sources/ATermCore/Screen/`),
reached through `Terminal.feed(_:)`. `⎋` stands for ESC; every case starts from
a fresh terminal. "Rows 1..5" means the terminal was fed `1` CR LF `2` CR LF
`3` CR LF `4` CR LF `5`.

## SCREEN-ERASE-001 — ED erases part of the display

Implement: ED (`CSI Ps J`, also `CSI ? Ps J`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-001 ED erases part of the display"
- Given: a 10×3 terminal fed `aaaaaaaaaabbbbbbbbbbcccccccccc⎋[2;5H`
- When: `⎋[J` is fed
- Then: the rows are `aaaaaaaaaa`, `bbbb`, `` and the cursor is at (1, 4)

- Given: the same terminal
- When: `⎋[1J` is fed
- Then: the rows are ``, `     bbbbb`, `cccccccccc` and the cursor is at (1, 4)

- Given: the same terminal
- When: `⎋[2J` is fed
- Then: every row is empty and the cursor is at (1, 4)

- Given: a 10×3 terminal showing rows 1..5 (scrollback `1`, `2`)
- When: `⎋[3J` is fed
- Then: the scrollback is empty, `linesDropped` is 2 and the rows are `3`, `4`, `5`

## SCREEN-ERASE-002 — EL erases part of the line

Implement: EL (`CSI Ps K`, also `CSI ? Ps K`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-002 EL erases part of the line"
- Given: a 10×2 terminal fed `abcdefghij⎋[1;5H`
- When: `⎋[K` is fed
- Then: row 0 is `abcd` and the cursor is at (0, 4)

- Given: the same terminal
- When: `⎋[1K` is fed
- Then: row 0 is `     fghij` and the cursor is at (0, 4)

- Given: the same terminal
- When: `⎋[2K` is fed
- Then: row 0 is empty and the cursor is at (0, 4)

## SCREEN-ERASE-003 — ECH erases characters without moving the cursor

Implement: ECH (`CSI Ps X`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-003 ECH erases characters without moving the cursor"
- Given: a 10×2 terminal fed `abcdefghij⎋[1;3H`
- When: `⎋[3X` is fed
- Then: row 0 is `ab   fghij` and the cursor is at (0, 2)

- Given: the same terminal
- When: `⎋[99X` is fed
- Then: row 0 is `ab` and the cursor is at (0, 2)

## SCREEN-ERASE-004 — ICH and DCH insert and delete characters in the line

Implement: ICH (`CSI Ps @`) and DCH (`CSI Ps P`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-004 ICH and DCH insert and delete characters in the line"
- Given: a 10×2 terminal fed `abcdefghij⎋[1;3H`
- When: `⎋[2@` is fed
- Then: row 0 is `ab  cdefgh` and the cursor is at (0, 2)

- Given: the same terminal
- When: `⎋[2P` is fed
- Then: row 0 is `abefghij` and the cursor is at (0, 2)

- Given: the same terminal
- When: `⎋[99P` is fed
- Then: row 0 is `ab` and the cursor is at (0, 2)

- Given: a 10×2 terminal fed `ab中cd⎋[1;2H`
- When: `⎋[2P` is fed (deleting `b` and the leading half of `中`)
- Then: row 0 is `a cd` and cell 1 is a blank of width 1
- When: `X` is fed
- Then: row 0 is `aXcd`

- Given: a 10×2 terminal fed `x中y⎋[1;3H⎋[4h` (cursor on the trailing half, insert mode)
- When: `ab` is fed
- Then: row 0 is `x ab y` and no cell of the row has width 0

- Given: a 5×2 terminal fed `abc👨` U+200D `👩⎋[1;1H`
- When: `⎋[@` is fed (the emoji is pushed off the line)
- Then: row 0 is ` abc` and `character(at: 4)` is a space

## SCREEN-ERASE-005 — IL and DL insert and delete lines inside the scroll region

Implement: IL (`CSI Ps L`) and DL (`CSI Ps M`) in `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-005 IL and DL insert and delete lines inside the scroll region"
- Given: a 10×5 terminal showing rows 1..5, fed `⎋[2;4H`
- When: `⎋[L` is fed
- Then: the rows are `1`, ``, `2`, `3`, `4` and the cursor is at (1, 0)

- Given: a 10×5 terminal showing rows 1..5, fed `⎋[2;4H`
- When: `⎋[2M` is fed
- Then: the rows are `1`, `4`, `5`, ``, `` and the cursor is at (1, 0)

- Given: a 10×5 terminal showing rows 1..5, fed `⎋[2;4r⎋[2;4H`
- When: `⎋[L` is fed
- Then: the rows are `1`, ``, `2`, `3`, `5`

- Given: a 10×5 terminal showing rows 1..5, fed `⎋[2;4r⎋[5;1H`
- When: `⎋[L` is fed
- Then: the rows are `1`, `2`, `3`, `4`, `5`

## SCREEN-ERASE-006 — Blank cells take the current background color only

Implement: background color erase in every blanking operation of `Terminal`, called by `Terminal.feed(_:)`.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenEraseTests.swift` · "SCREEN-ERASE-006 blank cells take the current background color only"
- Given: a 10×2 terminal
- When: `⎋[1;41mabc⎋[2K` is fed
- Then: row 0 is empty and all its cells have background `.indexed(1)`, default foreground and no flags

- Given: a 10×2 terminal
- When: `⎋[44m⎋[2J` is fed
- Then: every cell of both rows has background `.indexed(4)`

- Given: a 10×2 terminal
- When: `abc⎋[45m⎋[1;1H⎋[2@` is fed
- Then: cells 0–1 of row 0 have background `.indexed(5)` and row 0 is `  abc`

- Given: a 10×2 terminal
- When: `⎋[46m` LF LF is fed (scrolls one line)
- Then: every cell of row 1 has background `.indexed(6)`
