# App — tabs, windows and font size

Menu commands handled by `AppDelegate` for the active tab. Every spec uses
the e2e fixture of the [App contract](contract.md); shortcuts are delivered
through the main menu.

## APP-TAB-001 — New Tab opens a tab in the same window, in the current directory

Implement: `AppDelegate.newTab(_:)` (Shell ▸ New Tab, ⌘T) and `TerminalWindowController.newWindowForTab(_:)` (the + button), calling `TerminalWindowController.addTab(workingDirectory:agentLaunch:)` of the active tab's window, which appends the tab, selects it and starts the shell in `TerminalSession.currentDirectory` of the active pane (its shell's directory, or the agent's in an agent tab).
Uses: [App contract](contract.md), [PTY](../pty/pty.md), [Assistant](assistant.md), [Tab strip](tab-strip.md)

Test: e2e · `Tests/ATermE2ETests/TabsFontsTests.swift` · "APP-TAB-001 new tab opens a tab in the same window in the current directory"
- Given: a fixture window where `cd /tmp` was run
- When: ⌘T is pressed
- Then: there is one window with two tabs, the new one last, selected and its view the window's first responder; the two tabs have different shell processes, and the new shell's current directory is `/private/tmp`

- Given: an agent tab of the assistant fixture ([Assistant](assistant.md)) whose agent ran the call `bash` `mkdir -p sub && cd sub` and finished
- When: ⌘T is pressed with the agent tab active
- Then: a third tab opens in the same window and its shell's current directory is `T/sub`

## APP-TAB-002 — New Window opens a separate window in the home directory

Implement: `AppDelegate.newWindow(_:)` (Shell ▸ New Window, ⌘N).
Uses: [App contract](contract.md), [PTY](../pty/pty.md)

Test: e2e · `Tests/ATermE2ETests/TabsFontsTests.swift` · "APP-TAB-002 new window opens a separate window in the home directory"
- Given: a fixture window where `cd /tmp` was run
- When: ⌘N is pressed
- Then: there are two windows with one tab each, and the new shell's current directory is the home directory

## APP-FONT-001 — Font size changes keep the grid of the tab area

Implement: `AppDelegate.makeTextBigger(_:)`, `makeTextSmaller(_:)`, `makeTextStandardSize(_:)` (View ▸ Bigger ⌘+, Smaller ⌘-, Default Size ⌘0) calling `TerminalWindowController.setFontSize(_:)`, which changes the font size of every pane of every tab of the window. Any change of the cell size — a font size change or a move to a display of another scale (`viewDidChangeBackingProperties`) — goes through `TerminalWindowController.cellSizeDidChange(_:)`, which resizes the window to keep the area grid ([Split panes](splits.md#geometry); the terminal's grid in a tab with one pane); split panes keep their proportions.
Uses: [App contract](contract.md), [Split panes](splits.md)

Test: e2e · `Tests/ATermE2ETests/TabsFontsTests.swift` · "APP-FONT-001 font size changes keep the grid of the tab area"
- Given: a fixture window at the default font size 13 with a second tab opened by ⌘T, the first tab selected again
- When: ⌘+ is pressed
- Then: the font size of both tabs is 14, the cell size and the window's content size grew (each larger in width or height, smaller in neither) and both terminals are still 80 × 24
- When: ⌘- is pressed twice
- Then: the font size of both tabs is 12 and both terminals are still 80 × 24
- When: ⌘0 is pressed
- Then: the font size of both tabs is 13 and both terminals are still 80 × 24

- Given: a fixture window split by ⌘D: `A | B`
- When: ⌘+ is pressed
- Then: the font size of A and B is 14; the window's content size is the strip plus an 80 × 24 grid at the new cell size (`TerminalWindowController.contentSize(cols:rows:)`); A's frame is `(0, 0, l, H)` and B's `(l + 1, 0, W − 1 − l, H)` with `l = round((W − 1) / 2)` in the new area, each terminal with the grid of its frame
