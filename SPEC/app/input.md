# App — keyboard, input methods, paste, mouse and focus

How `TerminalView` turns user input into PTY input. Every spec uses the e2e
fixture of the [App contract](contract.md). Most run `cat -v`, which prints
control characters in caret notation (`^[` for ESC), then press Return so the
line is echoed.

## APP-INPUT-001 — Special keys and modifiers reach programs encoded

Implement: `TerminalView.keyDown(with:)` using `KeyEncoder`.
Uses: [App contract](contract.md), [Keyboard encoding](../input/keys.md)

Test: e2e · `Tests/ATermE2ETests/InputTests.swift` · "APP-INPUT-001 special keys and modifiers reach programs encoded"
- Given: a fixture window running `cat -v`
- When: the key events Up, Option+Left, Control+A, F5 and Return are sent to the window
- Then: a row reads `^[[A^[b^A^[[15~`

- Given: a fixture window running `cat -v`
- When: Control + the keypad Clear key (a function key with no terminal encoding), `x` and Return are sent
- Then: a row reads `x` (nothing was sent for the unmapped key)

## APP-INPUT-002 — Composed text from dead keys and input methods is sent once committed

Implement: `NSTextInputClient` conformance of `TerminalView` (`setMarkedText`, `insertText`), driven by `interpretKeyEvents` in `keyDown(with:)`.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/InputTests.swift` · "APP-INPUT-002 composed text from dead keys and input methods is sent once committed"
- Given: a fixture window showing the prompt after `echo ` was typed
- When: the input system sets the marked text `^`
- Then: the view has marked text, the bottom band of the cursor cell has foreground-colored pixels (the marked text underline) and after 300 ms the screen still reads `$ echo`
- When: the input system inserts `ê` and Return is pressed
- Then: the view has no marked text and the output row reads `ê`

## APP-INPUT-003 — Paste sends the pasteboard text, bracketed when requested

Implement: `TerminalView.paste(_:)` (Edit ▸ Paste, ⌘V) using `PasteEncoder`.
Uses: [App contract](contract.md), [Paste](../input/paste-focus.md)

Test: e2e · `Tests/ATermE2ETests/InputTests.swift` · "APP-INPUT-003 paste sends the pasteboard text bracketed when requested"
- Given: a fixture window running `printf '\033[?2004h'; cat -v`, and the pasteboard holding `a` LF `b`
- When: the view pastes, then Return is pressed
- Then: rows read `^[[200~a` and `b^[[201~`

## APP-INPUT-004 — Mouse clicks are reported to programs that ask, unless Shift is held

Implement: `TerminalView.mouseDown/mouseUp(with:)` using `MouseEncoder`.
Uses: [App contract](contract.md), [Mouse](../input/mouse.md)

Test: e2e · `Tests/ATermE2ETests/InputTests.swift` · "APP-INPUT-004 mouse clicks are reported to programs that ask unless shift is held"
- Given: a fixture window running `printf '\033[?1000h\033[?1006h'; cat -v`
- When: a left click (down and up) happens on cell (5, 10), then Return is pressed
- Then: a row reads `^[[<0;11;6M^[[<0;11;6m`

- Given: the same program
- When: a Shift + left click happens on cell (5, 10), then Return is pressed
- Then: no row contains `^[[<`

- Given: a fixture window where `echo alpha; echo delta` was run (output rows A and D), then `printf '\033[?1000h'; cat` is running, and a Shift + drag selected cells (A, 0) to (A, 4)
- When: a plain click happens on cell (A, 0), then a Shift + drag goes from (D, 0) to (D, 4), and the view copies
- Then: the pasteboard holds `delta` (a Shift + drag starts a new selection while the program captures the mouse)

## APP-INPUT-005 — Focus changes are reported to programs that ask

Implement: focus tracking of `TerminalView` using `FocusEncoder`.
Uses: [App contract](contract.md), [Focus](../input/paste-focus.md)

Test: e2e · `Tests/ATermE2ETests/InputTests.swift` · "APP-INPUT-005 focus changes are reported to programs that ask"
- Given: a fixture window running `printf '\033[?1004h'; cat -v`, its window reported key
- When: the window is reported not key, then key again, then Return is pressed
- Then: a row reads `^[[O^[[I`
