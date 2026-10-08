# App — split panes

A tab can be split into **panes**, each a `TerminalPane` with its own
`TerminalView`, `TerminalSession` (its own shell) and `AssistantController`.
One pane of each tab is **active**: while the tab is selected, its view (or
its assistant bar) holds the window's keyboard — typed keys, the Edit
commands, Clear Scrollback and the assistant act on it — and the tab's title,
shown by the strip and the window title, is its title. A new pane is active;
whichever pane's view becomes the window's first responder (a click in it, its
context menu, Window ▸ Select Pane …) becomes active. Shell ▸ Close (⌘W)
closes the active pane and a clean shell exit closes its pane
([Windows](window.md)); a tab closes with its last pane, a window with its
last tab.

Every spec uses the e2e fixture of the [App contract](contract.md); shortcuts
are delivered through the main menu. Layouts are written `A | B` (side by
side) and `A / B` (stacked), with parentheses for nested splits: in a new
window, ⌘D then ⇧⌘D give `A | (B / C)`.

## Geometry

The **tab area** is the window's content below the tab strip, covered by the
tab's view, a `PaneContainerView`. `W × H` is its size, `cw × ch` the cell
size; frames are `(x, y, width, height)` in the tab's view, y down from the
top of the area.

- **Tree.** A new tab has one pane covering the area. Panes form a binary
  tree (`PaneNode`): a split lays out its first child left of (side by side)
  or above (stacked) its second, a 1-point divider between them, and has a
  proportion `p`, 0 < p < 1. `TerminalTab.panes` lists the panes in tree
  order, first child before second.
- **Lengths.** A split `L` long along its axis (its width side by side, its
  height stacked) gives its first child `l = round(p × (L − 1))` points (to the
  nearest whole point, halves up), kept between the first child's minimum and
  `L − 1 −` the second child's when `L` is long enough for both; the divider
  covers `[l, l + 1)` and the second child gets the remaining `L − 1 − l`.
  Across the axis both children get the split's whole extent.
- **Minimums.** A pane keeps at least 2 columns × 1 row: `12 + 2 × cw` wide,
  `8 + ch` high. Along an axis, a split along it needs its children's
  minimums plus 1, a split across it the larger of its children's.
- **Grid.** A pane's terminal, and its PTY, have the whole cells that fit its
  frame inside the padding: `⌊(width − 12) / cw⌋` columns × `⌊(height − 8) / ch⌋`
  rows. The **area grid** is that of a single pane covering the whole area;
  the window resizes in whole cells of it ([App contract](contract.md)).
- **Changes.** Split Right / Split Down replace the active pane by a split of
  proportion 1/2, side by side / stacked, the active pane first and the new
  pane second; they are disabled, and do nothing, when the active pane is
  shorter along that axis than two minimum panes and a divider. Closing a
  pane replaces its split by its sibling, which takes the split's rectangle.
  Resizing the window and changing the font size lay the tree out again with
  the same proportions. Dragging a divider sets its split's proportion to
  `l / (L − 1)`, `l` being the first child's length at the press plus the
  pointer's move along the axis, rounded and kept between the minimums.
- **Weights.** Equalize Panes gives each split `p = w₁ / (w₁ + w₂)`, the weight
  of a subtree along the split's axis being 1 for a pane, the sum of its
  children's for a split along that axis and the larger of its children's for
  a split across it: `A | (B | C)` gets 1/3 then 1/2 (three equal columns),
  `A | (B / C)` 1/2 then 1/2.
- **Neighbor.** Select Pane Left makes active, among the panes entirely left of
  the active pane (their right edge at or before its left edge) that overlap
  it vertically, the nearest, then the one that overlaps it most, then the
  top-most; Select Pane Right, Above and Below likewise (Above and Below
  measure horizontal overlaps and end with the left-most). Without such a
  pane nothing happens: the selection does not wrap. When the active pane
  closes, the pane this rule selects from it toward its sibling becomes active.
- **Zoom.** While a tab is zoomed (`TerminalTab.isZoomed`), its active pane's
  view alone is shown, over the whole area, with the area grid; the other
  views are hidden and keep their frames, grids and processes. Select Pane
  uses the unzoomed layout. The zoom ends when Zoom Pane is chosen again, a
  pane is split or closed, another pane becomes active, or the panes are
  equalized.
- **Dividers.** A divider is drawn in (20, 21, 26), the strip background. A
  divider covering `[d, d + 1)` along its axis can be pressed from `d − 3` to
  `d + 4` over its whole extent: there `PaneContainerView.hitTest(_:)` returns
  the tab's view, which moves the divider while the button is down. The zone
  lies in the panes' padding, never over a cell. A zoomed tab has no divider.
- **Active frame.** In a tab with more than one pane, zoomed or not, the
  active pane has a 1-point frame along the inside of its bounds in the accent
  color, dark blue (29, 78, 216), in its padding, never over a cell. A tab with one pane has none. Panes are not dimmed, and
  no pane draws outside its frame.

## Menus

The Shell and Window menus, in order (─ is a separator). *Delegate* items
target `AppDelegate`, which acts on the active window, its selected tab and
that tab's active pane; the others go to the first responder. A shortcut is
the item's key equivalent and modifier mask, an uppercase letter counting as
⇧ (⌘{ and ⌘} are typed ⇧⌘[ and ⇧⌘]). AppKit may add its own items to the
Window menu. No ATerm item is hidden except View ▸ Bigger's ⌘= alternate.
Select Pane …, Zoom Pane and Equalize Panes are disabled in a tab with one
pane; Zoom Pane is checked while the active tab is zoomed.

Shell:

| Item | Shortcut | Action |
|---|---|---|
| New Window | ⌘N | `newWindow(_:)`, delegate |
| New Tab | ⌘T | `newTab(_:)`, delegate |
| ─ | | |
| Split Right | ⌘D | `splitRight(_:)`, delegate |
| Split Down | ⇧⌘D | `splitDown(_:)`, delegate |
| ─ | | |
| Ask… | | `askAssistant(_:)`, delegate |
| Stop Agent | ⌘. | `stopAgent(_:)`, delegate |
| ─ | | |
| Close | ⌘W | `closePane(_:)`, delegate |
| Close Window | ⇧⌘W | `performClose(_:)` |

Window:

| Item | Shortcut | Action |
|---|---|---|
| Minimize | ⌘M | `performMiniaturize(_:)` |
| Zoom | | `performZoom(_:)` |
| ─ | | |
| Show Previous Tab | ⌘{ | `selectPreviousTab(_:)`, delegate |
| Show Next Tab | ⌘} | `selectNextTab(_:)`, delegate |
| Select Tab 1 … Select Tab 8 | ⌘1 … ⌘8 | `selectTabByNumber(_:)`, delegate, tag 1 … 8 |
| Select Last Tab | ⌘9 | `selectTabByNumber(_:)`, delegate, tag 9 |
| ─ | | |
| Select Pane Left | ⌥⌘← | `selectPaneLeft(_:)`, delegate |
| Select Pane Right | ⌥⌘→ | `selectPaneRight(_:)`, delegate |
| Select Pane Above | ⌥⌘↑ | `selectPaneAbove(_:)`, delegate |
| Select Pane Below | ⌥⌘↓ | `selectPaneBelow(_:)`, delegate |
| Zoom Pane | ⇧⌘↩ | `togglePaneZoom(_:)`, delegate |
| Equalize Panes | ⌃⌘= | `equalizePanes(_:)`, delegate |
| ─ | | |
| Bring All to Front | | `arrangeInFront(_:)` |

## APP-SPLIT-001 — Split Right and Split Down divide the active pane and start a shell in its directory

Implement: `AppDelegate.splitRight(_:)` and `splitDown(_:)` (Shell ▸ Split Right ⌘D, Split Down ⇧⌘D) calling `TerminalWindowController.splitActivePane(_:)` for the active window: a new `TerminalPane` gets the grid of the frame it will have, starts its shell in the active pane's `TerminalSession.currentDirectory` (the agent's in an agent pane) with the active pane's font size and Option as Meta setting, and `TerminalTab.split(_:with:)` puts it in the active pane's place ([Geometry](#geometry)) and makes it active.
Uses: [App contract](contract.md), [PTY](../pty/pty.md), [Tabs and fonts](tabs-fonts.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-001 split right and split down divide the active pane and start a shell in its directory"
- Given: a fixture window where `cd /tmp` was run, ⌘+ pressed (font size 14) and View ▸ Use Option as Meta Key chosen, then `sleep 1; stty size` started in its pane A
- When: ⌘D is pressed, before the `sleep` ends
- Then: the window's content size is unchanged; the tab's panes are A and a new pane B, A's frame `(0, 0, l, H)` and B's `(l + 1, 0, W − 1 − l, H)` with `l = round((W − 1) / 2)`, each terminal with the grid of its frame; B is active, its view the window's first responder, its font size 14 and its Option as Meta setting on; B's shell is another process, in `/private/tmp`; `stty size` run in B prints B's rows and columns, and A prints its own once the `sleep` ends

- Given: the same
- When: ⇧⌘D is pressed, before the `sleep` ends
- Then: the same with the panes stacked: A's frame `(0, 0, W, l)`, B's `(0, l + 1, W, H − 1 − l)` with `l = round((H − 1) / 2)`

- Given: a fixture window at its minimum size, 20 × 5, split by ⇧⌘D: `A / B`, B active
- When: ⇧⌘D is pressed (B is shorter than two 1-row panes and a divider)
- Then: the Split Down item is disabled; the tab's panes are still A and B with the same frames, and B is still active

## APP-SPLIT-002 — Clicking a pane makes it the active pane: it gets the keys and names the tab

Implement: `TerminalView.mouseDown(with:)` and `TerminalView.menu(for:)` (its context menu) making the view first responder; `TerminalWindowController` observing its window's first responder (`TerminalWindow.makeFirstResponder(_:)`) and making the pane holding it the tab's active pane (`TerminalTab.activate(_:)`); `TerminalTab.title`, the active pane's title (`TerminalPane.updateTitle()`), shown by the strip and copied to the window title while the tab is selected, also when another pane becomes active; `TerminalWindowController.select(_:)` giving the keyboard to the selected tab's active pane.
Uses: [App contract](contract.md), [Windows](window.md), [Tab strip](tab-strip.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-002 clicking a pane makes it the active pane it gets the keys and names the tab"
- Given: a fixture window where `printf '\033]2;Left\007'` was run in its pane A
- When: ⌘D is pressed and `printf '\033]2;Right\007'` run in the new pane B
- Then: the tab title, its label in the strip and the window title are `Right`
- When: `sleep 0.5; printf '\033]2;Later\007'` is run in B, then cell (0, 0) of A is clicked
- Then: A is active and its view the window's first responder; the tab title, its label and the window title are `Left`, and still are once B's title is `Later`
- When: `echo typed-in-a` is typed and Return pressed
- Then: A's screen shows the line `typed-in-a`; B's screen does not contain `typed-in-a`
- When: B's context menu is asked for (`menu(for:)` with a right mouse down on its cell (0, 0))
- Then: B is active and first responder, and the three titles are `Later`
- When: ⌘T opens a second tab, then ⌘1 selects the first again
- Then: B is still its active pane and the window's first responder, and the window title is `Later`

## APP-SPLIT-003 — Select Pane Left, Right, Above and Below move to the adjacent pane

Implement: `AppDelegate.selectPaneLeft(_:)`, `selectPaneRight(_:)`, `selectPaneAbove(_:)` and `selectPaneBelow(_:)` (Window ▸ Select Pane Left ⌥⌘←, Select Pane Right ⌥⌘→, Select Pane Above ⌥⌘↑, Select Pane Below ⌥⌘↓) calling `TerminalWindowController.selectPane(_:)`, which makes the [neighbor](#geometry) in that direction (`TerminalTab.neighbor(toward:)`) active.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-003 select pane left right above and below move to the adjacent pane"
- Given: a fixture window split by ⌘D, ⌘D and ⇧⌘D: `A | (B | (C / D))` — A half the width, B and the column of C over D a quarter each — D active
- When / Then: each row's step is made in turn; the active pane, whose view is the window's first responder, is then the row's:

| Step | Active pane |
|---|---|
| ⌥⌘↓ | D (no pane below: no wrap) |
| ⌥⌘→ | D |
| ⌥⌘↑ | C |
| ⌥⌘← | B (the nearest; A is farther) |
| ⌥⌘← | A |
| ⌥⌘← | A |
| ⌥⌘→ | B |
| ⌥⌘→ | C (C and D touch B: C overlaps it no less and is the top-most) |
| the divider between C and D dragged 3 rows (`3 × ch`) up, then ⌥⌘← | B |
| ⌥⌘→ | D (it overlaps B most) |
| ⌥⌘↑ | C |
| ⌥⌘↑ | C |

## APP-SPLIT-004 — Dragging a divider resizes the panes on its sides, each keeping 2 columns and 1 row

Implement: `PaneContainerView.hitTest(_:)` returning itself in each divider's grab zone, and `PaneContainerView.mouseDown/mouseDragged/mouseUp(with:)` moving the pressed divider with the pointer (`TerminalTab.moveDivider(at:to:offset:)`, [Geometry](#geometry)), laying the panes out at each move; the tab's view never takes the keyboard.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-004 dragging a divider resizes the panes on its sides each keeping 2 columns and 1 row"
- Given: a fixture window split by ⌘D twice: `A | (B | C)`, C active; the divider between A and `B | C` covers `[d, d + 1)` with `d = round((W − 1) / 2)`
- When: the window hit-tests points at mid-height
- Then: it returns the tab's view at `x = d − 2.5` and `d + 3.5`, A's terminal view at `d − 3.5` and B's at `d + 4.5`
- When: the mouse goes down at `(d + 2.5, H / 2)` and is dragged `10 × cw` to the left
- Then: before the mouse goes up, A is `round(d − 10 × cw)` wide, `B | C` has the rest of the width divided by its own proportion 1/2, every terminal has the grid of its frame, and C is still active and first responder
- When: the mouse goes up, then the divider is dragged to `x = 0`
- Then: A is `12 + 2 × cw` wide and its terminal 2 columns wide
- When: the divider is dragged to `x = W`
- Then: B and C are each `12 + 2 × cw` wide with terminals 2 columns wide, and A is `W − 2 − 2 × (12 + 2 × cw)` wide

- Given: a fixture window split by ⇧⌘D twice: `A / (B / C)`
- When / Then: the same along the vertical axis (y for x, mid-width for mid-height, rows for columns), the first drag `5 × ch` up: at `y = 0`, A is `8 + ch` high with 1 row; at `y = H`, B and C are each `8 + ch` high with 1 row and A is `H − 2 − 2 × (8 + ch)` high

## APP-SPLIT-005 — Resizing the window keeps the panes' proportions

Implement: `PaneContainerView.resizeSubviews(withOldSize:)` laying the tab's tree out again (`TerminalTab.layoutPanes()`) from the splits' proportions when the tab area's size changes, each terminal and PTY resized to its pane.
Uses: [App contract](contract.md), [Windows](window.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-005 resizing the window keeps the panes' proportions"
- Given: a fixture window split by ⌘D then ⇧⌘D: `A | (B / C)`, the divider between A and `B / C` dragged `10 × cw` to the left: A is `l₀` wide and its split's proportion `p = l₀ / (W − 1)`
- When: the window's content size is set to the strip plus a 100 × 30 grid (`TerminalWindowController.contentSize(cols:rows:)`), the area becoming `W' × H'`
- Then: A's frame is `(0, 0, a, H')` with `a = round(p × (W' − 1))`; B's is `(a + 1, 0, W' − 1 − a, b)` and C's `(a + 1, b + 1, W' − 1 − a, H' − 1 − b)` with `b = round((H' − 1) / 2)`; every terminal has the grid of its frame
- When: the content size is set back to the strip plus an 80 × 24 grid
- Then: the three frames are those before the first resize

## APP-SPLIT-006 — Closing the active pane gives its space to its sibling

Implement: `AppDelegate.closePane(_:)` (Shell ▸ Close ⌘W) calling `TerminalWindowController.performClosePane(_:)` for the active pane — which asks first when its program runs ([Windows](window.md), APP-WINDOW-006) — then `closePane(_:)`: `TerminalTab.remove(_:)` hangs the pane's shell up, removes its view, replaces its split by its sibling and makes its [neighbor](#geometry) toward the sibling active; the tab closes with its last pane (`TerminalWindowController.closeTab(_:)`), the window with its last tab.
Uses: [App contract](contract.md), [Windows](window.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-006 closing the active pane gives its space to its sibling"
- Given: a fixture window split by ⌘D then ⇧⌘D: `A | (B / C)`, every pane showing the prompt, then cell (0, 0) of A clicked (A active)
- When: ⌘W is pressed
- Then: A is closed, its view out of the window and its shell process gone within 3 seconds; the tab's panes are B and C, stacked over the whole area: B's frame `(0, 0, W, l)`, C's `(0, l + 1, W, H − 1 − l)` with `l = round((H − 1) / 2)`, each terminal with the grid of its frame; B (the top-most of the panes that touched A) is active and its view the window's first responder
- When: ⌘W is pressed
- Then: B is closed and its shell process gone within 3 seconds; C's frame is the whole area and its terminal 80 × 24; C is active and first responder
- When: ⌘W is pressed
- Then: the tab and the window are closed

## APP-SPLIT-007 — Zoom Pane shows the active pane alone until the layout is restored

Implement: `AppDelegate.togglePaneZoom(_:)` (Window ▸ Zoom Pane ⇧⌘↩) calling `TerminalTab.toggleZoom()`, the item checked by `AppDelegate.validateMenuItem(_:)` while the active tab is zoomed and disabled in a tab with one pane; `TerminalTab.layoutPanes()` showing the zoomed pane alone, and `TerminalTab` ending the zoom ([Geometry](#geometry)).
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-007 zoom pane shows the active pane alone until the layout is restored"
- Given: a fixture window with one pane
- When: ⇧⌘↩ is pressed
- Then: the tab is not zoomed, the pane's frame is the whole area, and the Zoom Pane item is disabled
- When: ⌘D is pressed, `sleep 1; echo still-running` run in the new pane B, ⇧⌘D pressed (`A | (B / C)`, C active), then ⇧⌘↩
- Then: the tab is zoomed: C's frame is the whole area, its terminal 80 × 24, and it is still active and first responder; A's and B's views are hidden and their terminals keep their grids; the Zoom Pane item is checked; B's screen shows `still-running` once its `sleep` ends; `stty size` run in C prints `24 80`
- When: ⇧⌘↩ is pressed
- Then: the tab is not zoomed, every view is shown, the frames and grids are those before the zoom, and the item is not checked
- When / Then: before each row, ⇧⌘↩ is pressed if the tab is not zoomed; then the row's shortcut has this effect ("ended": the tab not zoomed, every view shown, the frames following the Geometry):

| Shortcut | Then |
|---|---|
| ⌥⌘→ (no pane right of C) | C is still zoomed and active |
| ⌥⌘↑ | ended; B is active |
| ⌃⌘= | ended; B is still active |
| ⌘D | ended; B is split: `A \| ((B \| E) / C)`, E active |
| ⌘W | ended; E is closed: `A \| (B / C)` with the frames of before the first zoom, B active |

## APP-SPLIT-008 — Equalize Panes shares the space equally between the panes

Implement: `AppDelegate.equalizePanes(_:)` (Window ▸ Equalize Panes ⌃⌘=) calling `TerminalTab.equalize()`, which gives every split the proportion of its children's [weights](#geometry).
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-008 equalize panes shares the space equally between the panes"
- Given: a fixture window split by ⌘D twice: `A | (B | C)`, A half the width, B and C a quarter each, C active
- When: ⌃⌘= is pressed
- Then: the outer split's proportion is 1/3 and the inner one's 1/2: A's frame is `(0, 0, a, H)` with `a = round((W − 1) / 3)`, B and C divide the rest by 1/2; the three widths differ by at most 1 point, every terminal has the grid of its frame, and C is still active
- When: ⇧⌘D is pressed (`A | (B | (C / D))`), the divider between A and B dragged `5 × cw` to the left, and ⌃⌘= pressed
- Then: the proportions are 1/3, 1/2 (`C / D`, a split across the axis, weighs 1) and 1/2: A, B and the column of C over D have the frames of the previous step, and C and D divide the column's height by 1/2

## APP-SPLIT-009 — The divider and a frame around the active pane show the layout

Implement: `PaneContainerView.draw(_:)` filling the dividers; the active pane's frame drawn by its `TerminalView` (`showsActiveFrame`, set by `TerminalTab.layoutPanes()`) when its tab has more than one pane; every pane drawing within its bounds ([Geometry](#geometry)).
Uses: [App contract](contract.md), [Rendering](rendering.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-009 the divider and a frame around the active pane show the layout"
- Given: a fixture window split by ⌘D: `A | B`, B active, both showing the prompt, the window reported key
- When: the tab's view is rendered
- Then: every pixel of the divider `(l, 0, 1, H)`, `l = round((W − 1) / 2)`, is (20, 21, 26); at the middle of each edge of B's frame and at its corners, the pixels of the 1-point band inside the edge are the accent color (29, 78, 216) and those 1 point further in the background (30, 31, 38); the same pixels of A are the background; B's cursor cell is filled with the cursor color and A's is an outline (APP-RENDER-003)
- When: A is clicked and the tab's view rendered
- Then: the frame is around A, not B, and the divider pixels are unchanged
- When: ⇧⌘↩ is pressed (A zoomed) and the tab's view rendered
- Then: the frame runs along the edges of the whole area, and the pixels where the divider was, inside the frame, are the background
- When: ⇧⌘↩ then ⌘W are pressed (B alone) and the tab's view rendered
- Then: there is no frame: the band along the area's edges is the background

## APP-SPLIT-010 — The assistant bar opens in the active pane and runs commands there

Implement: one `AssistantController` per `TerminalPane`, whose `AssistantBar` is installed in the pane's `TerminalView` and fed by that view's ⌘ hold; `AppDelegate.askAssistant(_:)` (Shell ▸ Ask…) opening the active pane's bar.
Uses: [Assistant](assistant.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-010 the assistant bar opens in the active pane and runs commands there"
- Given: a window of the assistant fixture split by ⌘D: `A | B`, B active, both showing the prompt, the window reported key; the router reply suggests `echo first-choice` (`First`)
- When: Shell ▸ Ask… is chosen
- Then: B's bar shows the request field, first responder, inside B's terminal view with its center within 0.5 point of that view's center; A's bar is hidden; B is still the active pane
- When: Esc is pressed, cell (0, 0) of A clicked, and ⌘ held and released (0.6 s)
- Then: A's bar shows the request field, inside A's view with its center within 0.5 point of that view's center; B's bar is hidden
- When: `say it` is typed and Return pressed, then Return pressed on the first suggestion
- Then: A's screen shows `$ echo first-choice` followed by the line `first-choice`; B's screen does not contain `first-choice`

## APP-SPLIT-011 — The Shell and Window menus show every command with its shortcut

Implement: `MainMenu.shellMenu(target:)` and `windowMenu(target:)` building the items of [Menus](#menus); `AppDelegate.validateMenuItem(_:)` enabling the pane items and checking Zoom Pane.
Uses: [App contract](contract.md), [Tab strip](tab-strip.md)

Test: e2e · `Tests/ATermE2ETests/SplitTests.swift` · "APP-SPLIT-011 the shell and window menus show every command with its shortcut"
- Given: a fixture window with one pane
- When: the main menu is read and the Window menu validated (`NSMenu.update()`)
- Then: the Shell menu's items are exactly those of its table, in order; the Window menu has the items of its table in that order, a separator between consecutive groups and none inside a group; each item has its title, shortcut, action, tag and target; no item targeting the app delegate is hidden except View ▸ Bigger's ⌘= alternate; Select Pane Left, Right, Above, Below, Zoom Pane and Equalize Panes are disabled
- When: ⌘D is pressed and the Window menu validated again
- Then: those six items are enabled
