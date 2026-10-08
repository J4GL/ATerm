# Screen — resizing and reflow

`Terminal.resize(cols:rows:)` in `Sources/ATermCore/Screen/`, called by the
app's terminal view whenever its grid size changes. The main screen (with its
scrollback) reflows soft-wrapped lines; the alternate screen is truncated or
padded. `⎋` stands for ESC; every case starts from a fresh terminal. "Rows
1..N" means the terminal was fed `1` CR LF `2` … CR LF `N`.

## SCREEN-RESIZE-001 — The alternate screen is truncated or padded without reflow

Implement: alternate-buffer resize in `Terminal.resize(cols:rows:)`, called by the terminal view.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenResizeTests.swift` · "SCREEN-RESIZE-001 the alternate screen is truncated or padded without reflow"
- Given: a 10×3 terminal fed `⎋[?1049habcdefghij⎋[2;1Hxy`
- When: it is resized to 5×2
- Then: the rows are `abcde`, `xy`, row 0 is not wrapped and the cursor is at (1, 2)
- When: it is resized to 12×4
- Then: the rows are `abcde`, `xy`, ``, `` and the cursor is at (1, 2)

- Given: a 10×3 terminal fed `⎋[?1049h⎋[3;9H`
- When: it is resized to 5×2
- Then: the cursor is at (1, 4)

- Given: a 6×2 terminal fed `⎋[?1049habcd👨` U+200D `👩`
- When: it is resized to 5×2
- Then: row 0 is `abcd` and `character(at: 4)` is a space

## SCREEN-RESIZE-002 — Main screen lines reflow when the width changes

Implement: reflow of scrollback and main screen in `Terminal.resize(cols:rows:)`, called by the terminal view.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenResizeTests.swift` · "SCREEN-RESIZE-002 main screen lines reflow when the width changes"
- Given: a 10×4 terminal fed `abcdefghijKLMNO` CR LF `$ `
- When: it is resized to 15×4
- Then: the rows are `abcdefghijKLMNO`, `$`, ``, ``, row 0 is not wrapped and the cursor is at (1, 2)
- When: it is resized to 5×4
- Then: the rows are `abcde`, `fghij`, `KLMNO`, `$`, rows 0 and 1 are wrapped, row 2 is not, and the cursor is at (3, 2)

- Given: a 10×4 terminal fed `abc` CR LF `def`
- When: it is resized to 20×4
- Then: the rows are `abc`, `def`, ``, `` and the cursor is at (1, 3)

- Given: a 6×3 terminal fed `abcd中ef`
- When: it is resized to 5×3
- Then: the rows are `abcd`, `中ef`, `` and row 0 is wrapped

- Given: a 5×3 terminal fed `abcd中` (the wide character wrapped)
- When: it is resized to 10×3
- Then: row 0 is `abcd中`

- Given: a 10×4 terminal fed `abc` CR LF `defgh⎋[1;8H` (cursor past the end of `abc`)
- When: it is resized to 5×4, then `X` is fed
- Then: the cursor had stayed on the `abc` line: the rows are `abc X`, `defgh`, ``, ``

## SCREEN-RESIZE-003 — Row changes keep the cursor line visible and move lines through scrollback

Implement: row adjustment in `Terminal.resize(cols:rows:)`, called by the terminal view.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenResizeTests.swift` · "SCREEN-RESIZE-003 row changes keep the cursor line visible and move lines through scrollback"
- Given: a 10×4 terminal showing rows 1..4
- When: it is resized to 10×2
- Then: the rows are `3`, `4`, the scrollback is [`1`, `2`] and the cursor is at (1, 1)
- When: it is resized to 10×4
- Then: the rows are `1`, `2`, `3`, `4`, the scrollback is empty and the cursor is at (3, 1)

- Given: a 10×4 terminal fed `1`
- When: it is resized to 10×2
- Then: the rows are `1`, ``, the scrollback is empty and the cursor is at (0, 1)

- Given: a 10×2 terminal fed `abcdefghij` CR LF `$ `
- When: it is resized to 5×2
- Then: the scrollback is [`abcde`], the rows are `fghij`, `$` and the cursor is at (1, 2)
- When: it is resized to 10×2
- Then: the scrollback is empty, the rows are `abcdefghij`, `$` and the cursor is at (1, 2)

## SCREEN-RESIZE-004 — Resizing resets the scroll region and extends the tab stops

Implement: scroll region and tab stop updates in `Terminal.resize(cols:rows:)`, called by the terminal view.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenResizeTests.swift` · "SCREEN-RESIZE-004 resizing resets the scroll region and extends the tab stops"
- Given: a 10×5 terminal fed `⎋[2;4r`
- When: it is resized to 10×8
- Then: the scroll region is rows 0…7

- Given: a 10×5 terminal
- When: it is resized to 20×5, then HT HT `X` is fed
- Then: cell 16 of row 0 holds `X`

## SCREEN-RESIZE-005 — Resizing on the alternate screen keeps the main screen's content

Implement: `Terminal.resize(cols:rows:)` reflowing the hidden main screen around the main cursor remembered when the alternate screen was entered, and moving saved cursors with the text.
Uses: [Screen model contract](contract.md)

Test: unit · `Tests/ATermCoreTests/ScreenResizeTests.swift` · "SCREEN-RESIZE-005 resizing on the alternate screen keeps the main screen's content"
- Given: a 10×6 terminal showing rows 1..6, fed `⎋[?1047h`
- When: it is resized to 10×3, then `⎋[?1047l` is fed
- Then: the rows are `4`, `5`, `6` and the scrollback is [`1`, `2`, `3`]

- Given: a 10×6 terminal showing rows 1..6, fed `⎋[?1049h⎋[!p`
- When: it is resized to 10×3, then `⎋[?1049l` is fed
- Then: the rows are `4`, `5`, `6` and the scrollback is [`1`, `2`, `3`]

- Given: a 10×12 terminal showing rows 1..12, fed `⎋7`, then resized to 10×3
- When: `⎋[?1047h` is fed, it is resized to 12×3, then `⎋[?1047l` is fed
- Then: the rows are `10`, `11`, `12` and the scrollback is [`1`, …, `9`]
