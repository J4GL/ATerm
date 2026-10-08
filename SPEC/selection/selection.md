# Selection

`Selection` and the `Terminal` selection helpers in
`Sources/ATermCore/Selection/Selection.swift`. The app's `TerminalView`
creates selections from mouse drags, double and triple clicks, highlights the
covered cells and copies `Terminal.text(in:)` to the pasteboard.

A selection has an anchor and a head — absolute line index and column, see the
[Screen model contract](../screen/contract.md) — and a granularity
(`character`, `word`, `line`). It covers the cells from its start to its end
inclusive, in reading order, whatever the drag direction. Extracted text
skips the trailing halves of wide characters, trims trailing spaces of each
line, joins soft-wrapped lines without a newline and separates the others
with `\n`.

## SELECT-001 — Character selection extracts the covered text in reading order

Implement: `Terminal.text(in:)` for character granularity, called by `TerminalView.copy(_:)`.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-001 character selection extracts the covered text in reading order"
- Given: a 20×3 terminal fed `hello world` CR LF `second line`
- When: the text of the selection from (line 0, col 2) to (line 1, col 3) is taken
- Then: it is `llo world\nseco`

- Given: the same terminal
- When: the text of the selection from (line 1, col 3) to (line 0, col 2) is taken (dragged backwards)
- Then: it is `llo world\nseco`

- Given: the same terminal
- When: the text of the selection from (line 0, col 0) to (line 0, col 4) is taken
- Then: it is `hello`

## SELECT-002 — Soft-wrapped lines are joined and trailing spaces trimmed

Implement: line joining in `Terminal.text(in:)`, called by `TerminalView.copy(_:)`.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-002 soft-wrapped lines are joined and trailing spaces trimmed"
- Given: a 5×3 terminal fed `abcdefgh`
- When: the text of the selection from (0, 0) to (1, 4) is taken
- Then: it is `abcdefgh`

- Given: a 10×2 terminal fed `ab   ` CR LF `cd`
- When: the text of the selection from (0, 0) to (1, 9) is taken
- Then: it is `ab\ncd`

- Given: a 5×3 terminal fed `abcd中` (the wide character wrapped, leaving the last column of row 0 empty)
- When: the text of the selection from (0, 0) to (1, 4) is taken
- Then: it is `abcd中`

## SELECT-003 — Word selection expands to the surrounding word

Implement: word granularity in `Terminal.selectionRange(_:)`, used by `TerminalView` on double click.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-003 word selection expands to the surrounding word"
- Given: a 30×2 terminal fed `ls -la /usr/local/bin | foo`
- When: word selections anchored at columns 12, 25, 4 and 22 of line 0 are taken
- Then: their texts are respectively `/usr/local/bin`, `foo`, `-la` and `|` (letters, digits and `_-./~+` are word characters; a click on any other character selects that character only)

- Given: the same terminal
- When: the word selection anchored at column 4 with its head at column 12 is taken
- Then: its text is `-la /usr/local/bin`

- Given: a 10×2 terminal fed `hello` CR LF `2` CR LF `3` (`hello` is in the scrollback)
- When: the word selection anchored at (line 0, col 8), past the end of `hello`, is taken
- Then: its text is empty

## SELECT-004 — Line selection covers whole logical lines

Implement: line granularity in `Terminal.selectionRange(_:)`, used by `TerminalView` on triple click.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-004 line selection covers whole logical lines"
- Given: a 5×3 terminal fed `abcdefgh` CR LF `xy`
- When: the line selection anchored at (1, 0) is taken (the wrapped continuation)
- Then: its text is `abcdefgh`
- When: its head is moved to (2, 0)
- Then: its text is `abcdefgh\nxy`

## SELECT-005 — Wide characters and graphemes are extracted once

Implement: cell iteration in `Terminal.text(in:)`, called by `TerminalView.copy(_:)`.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-005 wide characters and graphemes are extracted once"
- Given: a 10×2 terminal fed `a中b` then `e` U+0301
- When: the text of the selection from (0, 0) to (0, 4) is taken
- Then: it is `a中be\u{301}`

- Given: the same terminal
- When: the text of the selection from (0, 2) to (0, 3) is taken (starting on the trailing half)
- Then: it is `中b`

## SELECT-006 — Selections follow their text as it scrolls into the scrollback

Implement: absolute line addressing in `Terminal.text(in:)`, called by `TerminalView.copy(_:)`.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-006 selections follow their text as it scrolls into the scrollback"
- Given: a 10×2 terminal fed rows `1` to `4` (scrollback `1`, `2`)
- When: the text of the selection from (line 1, col 0) to (line 2, col 9) is taken
- Then: it is `2\n3`
- When: CR LF `5` is fed and the text of the same selection is taken again
- Then: it is `2\n3`

## SELECT-007 — Select all covers the scrollback and the screen

Implement: `Terminal.selectAll()`, called by `TerminalView.selectAll(_:)`.
Uses: [Screen model contract](../screen/contract.md)

Test: unit · `Tests/ATermCoreTests/SelectionTests.swift` · "SELECT-007 select all covers the scrollback and the screen"
- Given: a 10×4 terminal fed rows `1` to `6` then `⎋[3;1H` (scrollback `1`, `2`; screen `3`…`6`)
- When: the text of `selectAll()` is taken
- Then: it is `1\n2\n3\n4\n5\n6`

- Given: a 10×4 terminal fed `only`
- When: the text of `selectAll()` is taken
- Then: it is `only`
