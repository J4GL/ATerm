# App — the tab strip

Each window shows its tabs in a `TabStripView` drawn in the title bar, as in
Chrome: to the right of the window buttons, always visible, with a + button
after the last tab. Every spec uses the e2e fixture of the
[App contract](contract.md); tabs are opened with ⌘T through the main menu.

## Geometry

In the strip's flipped coordinates, with `W` the strip width, `n` the number
of tabs and `S` = the zoom button's maxX in the strip + 12 (8 in full screen,
where the window buttons are hidden):

- tab `i` is the rectangle `(S + i × w, 8, w, 30)` with
  `w = min(240, (W − 8 − 28 − S) / n)`, its top corners rounded (radius 8);
- its × is the 16 × 16 square centered 13 points left of the tab's maxX,
  vertically centered in the tab;
- the + button is the 24 × 24 square at `(S + n × w + 4, 11)`.

## APP-TAB-003 — The tab strip sits in the title bar and lists the window's tabs

Implement: `TerminalWindowController` building its window (full-size content view, transparent title bar, hidden title, `tabbingMode = .disallowed`) with `TabStripView` on top and the tab views below, and `layoutTrafficLights()` centering the window buttons in the strip; `TabStripView.draw(_:)` and `TabStripView.tabRect(at:)`.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/TabStripTests.swift` · "APP-TAB-003 the tab strip sits in the title bar and lists the window's tabs"
- Given: a fixture window with, for each case, 1, 3 or 12 tabs (the last opened selected), the strip rendered into an sRGB bitmap
- When: the window has laid out
- Then: the window's style mask contains `.fullSizeContentView`, its title bar is transparent, its title hidden and its tabbing mode `.disallowed`; the strip spans the window's content width at the top with a height of 38; the selected tab's view spans the rest of the content view, directly below the strip; the close, minimize and zoom buttons' vertical centers are within 1 point of the strip's; `S` is greater than the zoom button's maxX; each tab rectangle and the + button follow the geometry above, the + button within the strip; the labels drawn are the tabs' titles; the pixel 6 points right of the selected tab's left edge at its vertical center matches the terminal background (30, 31, 38), the same pixel of every other tab and the strip pixel at (W − 4, 4) match the strip background (20, 21, 26)

## APP-TAB-004 — Clicking a tab selects it; ×, the middle button and + close and open tabs

Implement: `TabStripView.mouseDown(with:)` / `mouseUp(with:)` / `otherMouseUp(with:)` calling `TerminalWindowController.select(_:)`, `performCloseTab(_:)` (which asks before closing a tab one of whose panes runs a program, APP-WINDOW-006) and `newWindowForTab(_:)`.
Uses: [App contract](contract.md), [Tabs](tabs-fonts.md), [Windows](window.md)

Test: e2e · `Tests/ATermE2ETests/TabStripTests.swift` · "APP-TAB-004 clicking a tab selects it and the close middle and plus buttons close and open tabs"
- Given: a fixture window whose first tab ran `cd /tmp`, three tabs titled `A`, `B`, `C` by `printf '\033]2;X\007'`, `C` selected
- When: tab `A` is clicked
- Then: `A` is selected, its view is shown and its pane's view is the window's first responder, the views of `B` and `C` are hidden, the window title is `A`
- When: tab `B` is clicked with the middle button
- Then: the tabs are `A`, `C`, `A` still selected, `B` is closed and its shell process is gone within 3 seconds
- When: the × of tab `C` (at index 1) is clicked
- Then: the only tab is `A`, still selected
- When: the + button is clicked
- Then: there are two tabs, the new one selected and first responder, its shell's current directory `/private/tmp`

## APP-TAB-005 — Dragging a tab reorders the tabs

Implement: `TabStripView.mouseDown(with:)` / `mouseDragged(with:)` / `mouseUp(with:)` (the window server does not move the window from a tab, see APP-TAB-007 and `TabStripView.updateWindowMovability(at:)`): past 3 points the pressed tab follows the pointer horizontally (its center kept between `S` and `W`), is swapped with a neighbor as soon as its center passes the neighbor's center (`TerminalWindowController.moveTab(from:to:)`), and snaps to its slot on release.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/TabStripTests.swift` · "APP-TAB-005 dragging a tab reorders the tabs"
- Given: a fixture window with three tabs titled `A`, `B`, `C`, `C` selected
- When: the mouse goes down at the center of tab `A`
- Then: `A` is selected
- When: the mouse is dragged to the center of tab `C` plus a quarter of the tab width
- Then: the tabs are `B`, `C`, `A`, and the center of `A`'s rectangle is at the pointer's x
- When: the mouse goes up there
- Then: the tabs are `B`, `C`, `A`, `A` is selected and its rectangle is slot 2 of the geometry

- Given: a fixture window with three tabs titled `A`, `B`, `C`, `C` selected
- When: the mouse goes down at the center of tab `A`, is dragged 2 points right and goes up
- Then: the tabs are `A`, `B`, `C`, `A` is selected and its rectangle is slot 0

## APP-TAB-006 — Keyboard shortcuts select and close tabs

Implement: Window ▸ Show Previous Tab (⌘{, i.e. ⇧⌘[), Show Next Tab (⌘}, i.e. ⇧⌘]), Select Tab 1 … Select Tab 8 (⌘1…⌘8) and Select Last Tab (⌘9), and Shell ▸ Close (⌘W, which closes the active pane — here each tab's only one, so the tab), handled by `AppDelegate.selectPreviousTab(_:)`, `selectNextTab(_:)`, `selectTabByNumber(_:)` and `closePane(_:)` for the active window, calling `TerminalWindowController.selectPreviousTab()`, `selectNextTab()`, `selectTab(number:)` and `performClosePane(_:)`.
Uses: [App contract](contract.md), [Windows](window.md)

Test: e2e · `Tests/ATermE2ETests/TabStripTests.swift` · "APP-TAB-006 keyboard shortcuts select and close tabs"
- Given: a fixture window with four tabs titled `A`, `B`, `C`, `D`, `D` selected
- When: ⌘} is pressed
- Then: `A` is selected (the order wraps around)
- When: ⌘{ is pressed
- Then: `D` is selected
- When: ⌘2 is pressed
- Then: `B` is selected
- When: ⌘9 is pressed
- Then: `D` is selected (⌘9 is the last tab)
- When: ⌘W is pressed
- Then: the tabs are `A`, `B`, `C` and `C` is selected
- After each step, the selected tab's view is shown and its pane's view is the window's first responder, and the window title is the selected tab's title

## APP-TAB-007 — Only the empty part of the strip moves the window

Implement: `TabStripView.updateWindowMovability(at:)`, called from `mouseMoved(with:)`, `mouseEntered(with:)`, `mouseExited(with:)` and `mouseDown(with:)`: the window is movable (`NSWindow.isMovable`, which lets the window server drag it from the title bar area) only while the pointer is over the strip outside every tab and the + button, or outside the strip; a press on the empty part drags the window with `performDrag(with:)`, a double click zooms it.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/TabStripTests.swift` · "APP-TAB-007 only the empty part of the strip moves the window"
- Given: a fixture window with two tabs, the second selected
- When: the pointer moves over the body of tab 0
- Then: the window is not movable
- When: the pointer moves over the × of tab 1
- Then: the window is not movable
- When: the pointer moves over the + button
- Then: the window is not movable
- When: the pointer moves to (W − 4, 19), right of the + button
- Then: the window is movable
- When: the pointer leaves the strip
- Then: the window is movable
- When: the mouse goes down at the center of tab 1, without a prior move, then is dragged 20 points left
- Then: the window is not movable while the button is down, and the center of tab 1's rectangle follows the pointer
