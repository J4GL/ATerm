# App — rendering

What `TerminalView.draw(_:)` puts on screen. Every spec uses the e2e fixture
of the [App contract](contract.md) and runs a `printf` command at the prompt;
"the output row" is the row after the command line. Pixel checks use the
rendered view in sRGB with a tolerance of 3 per channel.

## APP-RENDER-001 — Cell backgrounds use the palette, direct colors and inverse video

Implement: background pass of `TerminalView.draw(_:)`.
Uses: [App contract](contract.md), [Screen model contract](../screen/contract.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-001 cell backgrounds use the palette direct colors and inverse video"
- Given: a fixture window showing the prompt
- When: `printf '\033[41m  \033[44m  \033[48;2;10;200;30m  \033[7m  \033[0m\n'` is run
- Then: the centers of output cells 0–1 are (229, 100, 106), cells 2–3 (108, 164, 236), cells 4–5 (10, 200, 30), cells 6–7 (217, 219, 227) and cell 9 (30, 31, 38)

## APP-RENDER-002 — Glyphs use their foreground color, dimmed when faint

Implement: text pass of `TerminalView.draw(_:)`.
Uses: [App contract](contract.md), [Screen model contract](../screen/contract.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-002 glyphs use their foreground color dimmed when faint"
- Given: a fixture window showing the prompt
- When: `printf '\033[32m█\033[0m \033[2;32m█\033[0m\n'` is run (full blocks)
- Then: the center of output cell 0 is (140, 203, 126) and the center of cell 2 is halfway between it and the background, (85, 117, 82)

## APP-RENDER-003 — The cursor is a filled block when focused, an outline otherwise, and can be hidden

Implement: cursor pass of `TerminalView.draw(_:)` and focus tracking of `TerminalView`.
Uses: [App contract](contract.md), [Cursor](../screen/cursor.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-003 the cursor is a filled block when focused an outline otherwise and can be hidden"
- Given: a fixture window showing the prompt, its window reported key
- When: the view is rendered
- Then: the center of the cursor cell is the cursor color (242, 197, 114)
- When: the window is reported not key
- Then: the top-left pixel of the cursor cell is the cursor color and its center is the background (30, 31, 38)
- When: `printf '\033[?25l'` is run
- Then: the top-left pixel of the cursor cell is the background

## APP-RENDER-004 — Wide characters and emoji are drawn across two cells

Implement: glyph placement and font fallback in `TerminalView.draw(_:)`.
Uses: [App contract](contract.md), [Printing](../screen/printing.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-004 wide characters and emoji are drawn across two cells"
- Given: a fixture window showing the prompt
- When: `printf '中\n'` is run
- Then: output cells 0 and 1 both contain pixels differing from the background and cell 2 contains none

- Given: a fixture window showing the prompt
- When: `printf '😀\n'` is run
- Then: output cells 0 and 1 both contain pixels differing from the background, some of them not gray, and cell 2 contains none

## APP-RENDER-005 — Underline and strikethrough are drawn in the foreground color

Implement: decoration pass of `TerminalView.draw(_:)`.
Uses: [App contract](contract.md), [SGR](../screen/sgr.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-005 underline and strikethrough are drawn in the foreground color"
- Given: a fixture window showing the prompt
- When: `printf '\033[4;31m \033[0m \033[9;31m \033[0m\n'` is run (decorated spaces)
- Then: output cell 0 has pixels of (229, 100, 106) in its bottom quarter and none in its top half; cell 2 has pixels of (229, 100, 106) in its middle band and none in its top quarter or bottom quarter

## APP-RENDER-006 — Box-drawing lines and block elements fill their cells exactly

Implement: procedural drawing of U+2500–U+259F in `TerminalView.draw(_:)` (`BoxDrawing.swift`), instead of font glyphs that leave gaps between rows.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/RenderingTests.swift` · "APP-RENDER-006 box-drawing lines and block elements fill their cells exactly"
- Given: a fixture window showing the prompt
- When: `printf '│\n│\n█▀┼\n'` is run
- Then: on the two `│` output rows, the pixels at the horizontal center of cell 0 are the foreground color (217, 219, 227) on the top and the bottom pixel row of the cell; every pixel of the `█` cell is the foreground color; the top half of the `▀` cell is the foreground color and its bottom half the background; the `┼` cell has foreground pixels at the middle of all four edges
