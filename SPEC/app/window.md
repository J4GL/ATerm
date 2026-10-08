# App — terminal windows

Window and session lifecycle. Every spec uses the e2e fixture of the
[App contract](contract.md).

## APP-WINDOW-001 — Launching the app opens a window running the user's login shell

Implement: `AppDelegate.applicationDidFinishLaunching(_:)` opening a `TerminalWindowController` whose `TerminalSession` runs `LoginShell.command(...)`, reached from `ATermMain.run()`.
Uses: [App contract](contract.md), [PTY](../pty/pty.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-001 launching the app opens a window running the user's login shell"
- Given: the fixture configuration without a shell override (the user's login shell), `SHELL` pointing to an executable shell
- When: the app finishes launching
- Then: exactly one terminal window exists, its terminal is 80 × 24, its view is the window's first responder, the window uses the dark appearance, and the command line of its shell process (`ps -o args=`) starts with `-` followed by the shell's name

## APP-WINDOW-002 — Typed keys run commands whose output is drawn

Implement: `TerminalView.keyDown(with:)` → `TerminalSession.send(_:)` → PTY, and PTY output → `Terminal.feed(_:)` → `TerminalView.draw(_:)`.
Uses: [App contract](contract.md), [Keyboard encoding](../input/keys.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-002 typed keys run commands whose output is drawn"
- Given: a fixture window showing the prompt `$ `
- When: the key events for `echo hello` and Return are sent to the window
- Then: the row after the command line reads `hello`, and in the rendered view every cell of `hello` has pixels differing from the background while the cell after it has none

## APP-WINDOW-003 — The tab title follows OSC titles, else the foreground program

Implement: `TerminalPane.updateTitle()` from its `TerminalSession` (title changes and foreground process polling); a tab's title is its active pane's ([Split panes](splits.md)), shown by the tab strip and copied to the window title while the tab is selected.
Uses: [App contract](contract.md), [Reports](../screen/reports.md), [Tab strip](tab-strip.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-003 the tab title follows OSC titles else the foreground program"
- Given: a fixture window showing the prompt
- When: nothing has set a title
- Then: the tab title, its label in the tab strip and the window title are `bash`
- When: `printf '\033]2;Build\007'` is run
- Then: the tab title, its label and the window title are `Build`
- When: `printf '\033]2;\007'` is run
- Then: the tab title, its label and the window title are `bash` again

## APP-WINDOW-004 — Resizing the window resizes the terminal and the PTY

Implement: `TerminalView.setFrameSize(_:)` → `TerminalSession.resize(cols:rows:)` → `Terminal.resize` and `PTYProcess.resize`; the window resizes in whole cells (`contentResizeIncrements`).
Uses: [App contract](contract.md), [Resize](../screen/resize.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-004 resizing the window resizes the terminal and the PTY"
- Given: a fixture window showing the prompt
- When: its content size is set to the tab strip height plus the size of a 100 × 30 grid (`TerminalWindowController.contentSize(cols:rows:)`), then `stty size` is run
- Then: the terminal is 100 × 30, the window's content resize increments equal the cell size, and the output reads `30 100`

## APP-WINDOW-005 — A clean shell exit closes its pane, an error keeps it open

Implement: `TerminalSession` exit handling observed by `TerminalPane`: a clean exit closes the pane with `TerminalWindowController.closePane(_:)` (its sibling takes its space, [Split panes](splits.md)), the tab closes with its last pane (`TerminalWindowController.closeTab(_:)`), the window with its last tab; another status shows a message.
Uses: [App contract](contract.md), [PTY](../pty/pty.md), [Split panes](splits.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-005 a clean shell exit closes its pane an error keeps it open"
- Given: a fixture window showing the prompt
- When: `exit` is run
- Then: within 3 seconds the tab and the window are closed and the app delegate has no terminal window left

- Given: a fixture window with a second tab opened by ⌘T, both showing the prompt, the second selected
- When: `exit` is run in the second tab
- Then: within 3 seconds the second tab is closed, the window is still open with the first tab selected, its view shown and first responder

- Given: a fixture window showing the prompt
- When: `exit 3` is run
- Then: within 3 seconds the screen shows `[Process exited with code 3]`, the tab and the window are still open, and later key events do not change the screen

- Given: a fixture window split by ⌘D: `A | B`, B active, both showing the prompt
- When: `exit` is run in B
- Then: within 3 seconds B is closed; A's frame is the whole tab area, A is active and its view the window's first responder; the tab and the window are still open

- Given: the same, where `sleep 1; exit` was run in B, then A clicked
- When: the `sleep` ends
- Then: within 3 seconds B is closed; A's frame is the whole tab area and A is still active and first responder

## APP-WINDOW-006 — Closing a pane, a tab or a window with a running program asks for confirmation

Implement: `TerminalWindowController.windowShouldClose(_:)` (the window's close button, Shell ▸ Close Window ⇧⌘W), `performCloseTab(_:)` (the tab's ×, its middle click) and `performClosePane(_:)` (Shell ▸ Close ⌘W through `AppDelegate.closePane(_:)`), using `TerminalSession.hasRunningJob` (the shell's foreground job, or a running agent in an agent tab) of every pane that would close, and `runningProgramName` to name them as P, in tab then pane order, joined by `, `. Terminate closes, Cancel closes nothing:

| Closing | Message | Information |
|---|---|---|
| the active pane, its tab having other panes (⌘W) | Do you want to terminate running processes in this pane? | Closing this pane will terminate P. |
| a tab (×, middle click, ⌘W on its only pane) | Do you want to terminate running processes in this tab? | Closing this tab will terminate P. |
| a window (close button, ⇧⌘W) | Do you want to terminate running processes in this window? | Closing this window will terminate P. |

Uses: [App contract](contract.md), [PTY](../pty/pty.md), [Assistant](assistant.md), [Split panes](splits.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-006 closing a pane a tab or a window with a running program asks for confirmation"
- Given: a fixture window whose shell is idle at the prompt
- When: the window is asked to close (`performClose`)
- Then: it closes without showing a sheet

- Given: a fixture window whose first tab runs `sleep 30` and whose second tab, opened by ⌘T and selected, is idle
- When: the window is asked to close
- Then: a sheet asks to terminate `sleep` and the window and both tabs stay open
- When: the sheet's Terminate button is clicked
- Then: the window and both tabs close and the first shell process is gone within 3 seconds

- Given: a fixture window whose first tab, selected, runs `sleep 30` and whose second tab is idle
- When: ⌘W is pressed
- Then: a sheet asks to terminate `sleep` and both tabs stay open
- When: the sheet's Terminate button is clicked
- Then: only the first tab closes, the window stays open with the second tab selected, and the first shell process is gone within 3 seconds

- Given: an agent tab of the assistant fixture ([Assistant](assistant.md)) whose agent runs the call `bash` `sleep 30`
- When: ⌘W is pressed with the agent tab selected, once its screen shows `$ sleep 30`
- Then: a sheet asks to terminate the agent and the agent tab stays open
- When: the sheet's Terminate button is clicked
- Then: the agent tab closes, the window stays open with the shell tab, and no process of the command's group is left within 3 seconds

- Given: a fixture window split by ⌘D: `A | B`, B active and running `sleep 30`
- When: ⌘W is pressed
- Then: a sheet says `Do you want to terminate running processes in this pane?` and `Closing this pane will terminate sleep.`, and both panes stay open
- When: the sheet's Terminate button is clicked
- Then: only B closes and its shell process is gone within 3 seconds; A has the whole tab area and is active

- Given: a fixture window where `sleep 30` runs in its pane A, then split by ⌘D: `A | B`, B active and idle
- When: the window is asked to close
- Then: a sheet says `Do you want to terminate running processes in this window?` and `Closing this window will terminate sleep.`
- When: the sheet's Cancel button is clicked
- Then: the sheet is gone and the window, its tab and both panes are still open
- When: the × of the tab is clicked
- Then: a sheet says `Do you want to terminate running processes in this tab?` and `Closing this tab will terminate sleep.`
- When: the sheet's Terminate button is clicked
- Then: the tab and the window close, and both shell processes are gone within 3 seconds

## APP-WINDOW-007 — The Dock menu opens a new window

Implement: `AppDelegate.applicationDockMenu(_:)` returning a menu whose `New Window` item calls `AppDelegate.newWindow(_:)`.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-007 the dock menu opens a new window"
- Given: a fixture window showing the prompt
- When: the `New Window` item of the app delegate's Dock menu is chosen
- Then: two terminal windows exist, the new one is the active window, and its shell shows the prompt

- Given: a fixture window showing the prompt, then closed (no terminal window left)
- When: the `New Window` item of the Dock menu is chosen
- Then: exactly one terminal window exists and its shell shows the prompt

## APP-WINDOW-008 — Quitting asks first when a program runs in any pane, then hangs up every shell

Implement: `AppDelegate.applicationShouldTerminate(_:)` checking `TerminalSession.hasRunningJob` of every pane of every tab and asking with an alert run through `AppConfiguration.runAlert`; `AppDelegate.applicationWillTerminate(_:)` stopping every agent and hanging up the shell of every pane.
Uses: [App contract](contract.md), [Split panes](splits.md)

Test: e2e · `Tests/ATermE2ETests/WindowTests.swift` · "APP-WINDOW-008 quitting asks first when a program runs in any pane then hangs up every shell"
- Given: a fixture window whose shell is idle at the prompt
- When: the app is asked whether it should terminate
- Then: it answers `.terminateNow` and no alert was run

- Given: a fixture window where `sleep 30` runs in its pane A, then split by ⌘D: `A | B`, B active and idle, and a second tab opened by ⌘T, idle
- When: the app is asked whether it should terminate, the alert answered Cancel
- Then: one alert was run, with the message `Quit ATerm?`, the information `A program is still running in one tab.` and the buttons Quit and Cancel, and the app answers `.terminateCancel`
- When: it is asked again, the alert answered Quit
- Then: the app answers `.terminateNow`
- When: the app will terminate (`applicationWillTerminate`)
- Then: the shell processes of A, B and the second tab are gone within 3 seconds
