# App — clearing, dropping files and opening links

Every spec uses the e2e fixture of the [App contract](contract.md).

## APP-EDIT-001 — Clear Scrollback keeps only the current line

Implement: `TerminalView.clearScrollback(_:)` using `Terminal.clearScrollbackKeepingCursorLine()`, reached from Edit ▸ Clear Scrollback (⌘K) through `AppDelegate.clearScrollback(_:)` for the active window's active pane.
Uses: [App contract](contract.md), [Screen model contract](../screen/contract.md)

Test: e2e · `Tests/ATermE2ETests/EditTests.swift` · "APP-EDIT-001 clear scrollback keeps only the current line"
- Given: a fixture window where `seq 1 50` was run and the prompt is shown
- When: ⌘K is pressed
- Then: the scrollback is empty, row 0 reads `$`, the other rows are empty and the cursor is on row 0
- When: `echo after` is run
- Then: row 1 reads `after`

## APP-EDIT-002 — Dropping files inserts their shell-escaped paths

Implement: `TerminalView` as a dragging destination for file URLs (`performDragOperation(_:)`), sending the paths like a paste.
Uses: [App contract](contract.md), [Paste](../input/paste-focus.md)

Test: e2e · `Tests/ATermE2ETests/EditTests.swift` · "APP-EDIT-002 dropping files inserts their shell-escaped paths"
- Given: a fixture window showing the prompt
- When: the files `/tmp/a b.txt` and `/tmp/c'd` are dropped on the view
- Then: the prompt row reads `$ /tmp/a\ b.txt /tmp/c\'d` (every character other than letters, digits and `_-.,/:@+%=` is escaped with a backslash; paths are separated and followed by a space)

## APP-EDIT-003 — ⌘-click opens the link under the pointer

Implement: ⌘-click handling in `TerminalView.mouseDown(with:)` using `LinkDetector` on the clicked line, opening through `AppConfiguration.openURL`.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/EditTests.swift` · "APP-EDIT-003 command-click opens the link under the pointer"
- Given: a fixture window where `echo see https://example.com/x?y=1. now` was run (output row R), with a URL opener that records URLs
- When: a ⌘-click happens on cell (R, 10)
- Then: the recorded URLs are exactly `https://example.com/x?y=1` (trailing punctuation excluded) and the view has no selection
- When: a ⌘-click happens on cell (R, 1)
- Then: no other URL was recorded

## APP-EDIT-004 — Clicking the view after dropping a file at the zsh prompt removes the highlight of its path

Implement: `TerminalView.mouseDown(with:)` telling the shell's integration about the click (`TerminalSession.sendClick()`) when no program captures the mouse.
Uses: [App contract](contract.md), [zsh fixture](suggestions.md), [zsh integration](../pty/shell-integration.md)

Test: e2e · `Tests/ATermE2ETests/EditTests.swift` · "APP-EDIT-004 clicking the view after dropping a file at the zsh prompt removes the highlight of its path"
- Given: a window of the zsh fixture showing the prompt on row R
- When: the file `/tmp/a b.txt` is dropped on the view
- Then: row R reads `$ /tmp/a\ b.txt` and the cells of columns 2 to 15 are inverse (zsh highlights pasted text)
- When: a click happens on cell (R + 3, 30)
- Then: row R reads `$ /tmp/a\ b.txt`, no cell of columns 2 to 15 is inverse, the cursor is at (R, 16) and the view has no selection
