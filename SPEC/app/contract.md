# App contract — windows, sessions and the e2e fixture

Shared by the app specs. Code lives in `Sources/ATermApp/`; the executable
`Sources/ATerm/main.swift` calls `ATermMain.run()`, which installs
`AppDelegate` and runs the application.

## Structure

- `AppDelegate` builds the main menu, opens the first window when the app has
  finished launching, and handles the application-level menu actions (the
  Shell and Window commands of [Split panes › Menus](splits.md#menus), and
  View ▸ Bigger ⌘+, Smaller ⌘-, Default Size ⌘0) for the active window, i.e.
  the window that last became key (or was last opened), its selected tab and
  that tab's active pane. It also provides the Dock menu (New Window) and
  opens the Settings window (ATerm ▸ Settings… ⌘,, see
  [Settings](settings.md)).
- `TerminalWindowController` owns one window, its `TabStripView` and its tabs
  (see [Tab strip](tab-strip.md)). Windows do not use native macOS tabs
  (`tabbingMode = .disallowed`).
- `TerminalTab` owns its panes — `TerminalPane`s laid out as a tree of splits
  by its view, a `PaneContainerView` ([Split panes](splits.md)) — and its
  active pane; `window` is the window of its controller. A tab's `session`,
  `terminalView`, `assistant`, `agentTab` and title are its active pane's.
  Every tab of a window has its view in the window, stacked below the tab
  strip; only the selected tab's view is shown, and its active pane's
  terminal view is the window's first responder.
- `TerminalPane` owns one `TerminalView`, one `TerminalSession` and one
  `AssistantController`.
- `TerminalSession` owns the `Terminal` model and the `PTYProcess` running the
  shell, started with ATerm's zsh integration when it is zsh (see
  [Suggestions](suggestions.md)). Program output is fed to the terminal on the
  main queue.
- `TerminalView` draws the terminal and turns keyboard, mouse, scroll and
  pasteboard input into PTY input.
- `AssistantController` (one per pane) owns the pane's `AssistantBar`
  and turns a request into suggested commands or an agent tab; `AgentTab`
  runs the agent of an agent tab, whose `TerminalSession` has no process
  (see [Assistant](assistant.md)). `TerminalSession.currentDirectory`,
  `hasRunningJob` and `runningProgramName` describe either the shell or the
  agent.

## Layout

- The tab strip covers the top 38 points of the window, title bar included
  (full-size content view, transparent title bar, hidden title); the tab views
  fill the rest, the tab area, where a tab's panes are laid out
  ([Split panes](splits.md)). The window's content size is the strip height
  plus the tab area's size, that of one terminal view showing the area grid:
  it resizes in whole cells and never below 20 × 5.
- The grid is inset by a padding of 6 points horizontally and 4 points
  vertically. The cell size comes from the font: the advance of `M` and the
  line height (ascent + descent + leading), both rounded up to whole device
  pixels. A new window is 80 × 24 cells.
- Cell (row, col) covers the rectangle starting at
  `(6 + col × cellWidth, 4 + row × cellHeight)` in its terminal view's flipped
  coordinates.

## Theme

The default palette of the [Screen model contract](../screen/contract.md)
gives the default foreground, background, cursor and indexed colors. Terminal
windows use the dark appearance (`NSAppearance.Name.darkAqua`) so their title
bar and window buttons match the dark palette whatever the system appearance.
The tab strip's background is (20, 21, 26); the selected tab is filled with
the terminal background (30, 31, 38) so it joins the terminal below, a hovered
tab with (38, 39, 48); the selected tab's title is (230, 230, 235), the others'
(150, 150, 160). Dividers between panes are (20, 21, 26); the active pane of
a tab with several panes has a one-point frame in the accent color, dark blue
(29, 78, 216) ([Split panes](splits.md)). Selected
cells have the background (59, 74, 106). A focused block cursor is a cell
filled with the cursor color, text under it drawn in the background color; an
unfocused block cursor is a one-point outline in the cursor color. Focused
means: the view is its window's first responder and the window is key.

## E2E fixture

E2E tests run the real app classes in-process through `AppHarness`
(`Tests/ATermE2ETests/Support/AppHarness.swift`):

- `AppDelegate` is created with a configuration and receives
  `applicationDidFinishLaunching`, as when the app starts. The harness lists
  the tabs of every window (`AppDelegate.tabs`, in window order then strip
  order) and the panes of a tab (`TerminalTab.panes`, in tree order).
- The configuration keeps windows off screen (the test process is never the
  active application, so its windows never become key; focus changes are
  simulated by posting `NSWindow.didBecomeKeyNotification` /
  `didResignKeyNotification`, which AppKit posts for real windows), uses a
  private pasteboard and private user defaults (a suite unique to the
  harness, removed by `shutDown()`), records the windows run modally
  (`runModal`, `stopModal`) instead of running a modal loop (APP-SETTINGS-007
  runs the real loop, alone in `Tests/ATermModalTests`), records the
  alerts run modally (`runAlert`) and answers them with the response the
  test gives, disables cursor blinking and runs
  `/bin/bash --noprofile --norc` with `PS1='$ '` unless a spec says otherwise.
- Key events are `NSEvent`s dispatched with `NSWindow.sendEvent(_:)`; menu
  shortcuts go through `NSApp.mainMenu.performKeyEquivalent(with:)`, with the
  characters and modifiers AppKit reports (an arrow key also has
  `.numericPad` and `.function`); mouse and scroll events are delivered to the
  view's `mouseDown/Dragged/Up` and `scrollWheel` handlers, which AppKit calls
  for real events; clicks and drags in the tab strip are delivered to the
  `TabStripView` handlers the same way. A press in the tab area goes to the
  view the window's content view returns from `hitTest(_:)` (a pane's
  `TerminalView`, or the tab's `PaneContainerView` near a divider), which then
  receives the drags and the release, as AppKit does.
- Rendered pixels come from `cacheDisplay(in:to:)` into an sRGB bitmap; colors
  match when every channel is within 3 of the expected value.
- Assistant specs extend this fixture with a fake OpenRouter endpoint, an
  in-memory key store and a temporary working directory (the **assistant
  fixture**, see [Assistant](assistant.md)); `shutDown()` also stops the
  agents.
