# App — scrollback and selection

Viewport scrolling and mouse selection in `TerminalView`. Every spec uses the
e2e fixture of the [App contract](contract.md). `TerminalView.displayedLine(_:)`
is the line drawn on a given row.

## APP-SCROLL-001 — The wheel scrolls through the scrollback; typing returns to the bottom

Implement: `TerminalView.scrollWheel(with:)` and viewport anchoring on new output.
Uses: [App contract](contract.md), [Scrolling](../screen/scrolling.md)

Test: e2e · `Tests/ATermE2ETests/ScrollSelectionTests.swift` · "APP-SCROLL-001 the wheel scrolls through the scrollback typing returns to the bottom"
- Given: a fixture window where `seq 1 100; sleep 1; echo tick` was started, and `100` is displayed
- When: the wheel scrolls up by 5 lines
- Then: displayed row 0 is the line 5 lines above the first screen line, and the rendered row 0 differs from before
- When: `tick` is printed by the program
- Then: the displayed rows are unchanged
- When: the key `x` is pressed
- Then: the displayed rows are the screen rows again

## APP-SCROLL-002 — In the alternate screen the wheel sends cursor keys

Implement: alternate scroll in `TerminalView.scrollWheel(with:)`.
Uses: [App contract](contract.md), [Modes](../screen/modes.md)

Test: e2e · `Tests/ATermE2ETests/ScrollSelectionTests.swift` · "APP-SCROLL-002 in the alternate screen the wheel sends cursor keys"
- Given: a fixture window running `printf '\033[?1049h'; cat -v`
- When: the wheel scrolls up by 3 lines, then Return is pressed
- Then: a row reads `^[[A^[[A^[[A`

## APP-SELECT-001 — Dragging selects text, highlighted, and Copy puts it on the pasteboard

Implement: `TerminalView.mouseDown/mouseDragged/mouseUp(with:)` selection, highlight in `draw(_:)`, `TerminalView.copy(_:)` (Edit ▸ Copy, ⌘C).
Uses: [App contract](contract.md), [Selection](../selection/selection.md)

Test: e2e · `Tests/ATermE2ETests/ScrollSelectionTests.swift` · "APP-SELECT-001 dragging selects text highlighted and copy puts it on the pasteboard"
- Given: a fixture window where `echo hello world` was run (output row R)
- When: the mouse goes down on cell (R, 0), is dragged to cell (R, 4) and goes up
- Then: the top-left pixels of cells (R, 0) to (R, 4) are the selection color (59, 74, 106) and that of cell (R, 6) is the background
- When: the view copies
- Then: the pasteboard holds `hello`

## APP-SELECT-002 — Double click selects a word, triple click a line

Implement: click counts in `TerminalView.mouseDown(with:)`.
Uses: [App contract](contract.md), [Selection](../selection/selection.md)

Test: e2e · `Tests/ATermE2ETests/ScrollSelectionTests.swift` · "APP-SELECT-002 double click selects a word triple click a line"
- Given: a fixture window where `echo hello world` was run (output row R)
- When: a double click happens on cell (R, 8), then the view copies
- Then: the pasteboard holds `world`
- When: a triple click happens on cell (R, 2), then the view copies
- Then: the pasteboard holds `hello world`

## APP-SCROLL-003 — Page Up and Page Down scroll the scrollback on the main screen

Implement: page keys in `TerminalView.keyDown(with:)`: they move the viewport by one screen on the main screen; with Shift, or on the alternate screen, they go to the program.
Uses: [App contract](contract.md), [Keyboard encoding](../input/keys.md)

Test: e2e · `Tests/ATermE2ETests/ScrollSelectionTests.swift` · "APP-SCROLL-003 page up and page down scroll the scrollback on the main screen"
- Given: a fixture window where `seq 1 100` was run and the prompt is shown
- When: Page Up is pressed
- Then: displayed row 0 is the line one screen (24 lines) above the first screen line
- When: Page Down is pressed
- Then: the displayed rows are the screen rows again

- Given: a fixture window running `cat -v` on the main screen
- When: Shift + Page Up, then Return are pressed
- Then: a row reads `^[[5;2~`

- Given: a fixture window running `printf '\033[?1049h'; cat -v`
- When: Page Up, then Return are pressed
- Then: a row reads `^[[5~`
