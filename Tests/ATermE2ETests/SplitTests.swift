import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

/// The frame of the active pane. See SPEC/app/splits.md.
private let accentColor = RGB(29, 78, 216)

extension E2E {
    @Suite @MainActor struct Splits {
        enum SplitCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case right, down, tooSmall = "too small"
            var testDescription: String { rawValue }
        }

        @Test("APP-SPLIT-001 split right and split down divide the active pane and start a shell in its directory",
              arguments: SplitCase.allCases)
        func APP_SPLIT_001(splitCase: SplitCase) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let windowController = try #require(tab.windowController)
            let window = try #require(tab.window)

            if splitCase == .tooSmall {
                window.setContentSize(windowController.contentSize(cols: 20, rows: 5))
                let b = try #require(await harness.split(.down))
                let frames = tab.panes.map(harness.frame(of:))
                let item = try #require(harness.menuItem("Split Down", in: "Shell"))
                item.menu?.update()
                #expect(!item.isEnabled)
                harness.shortcut("D", modifiers: [.command, .shift])
                #expect(tab.panes.elementsEqual([a, b], by: ===))
                #expect(tab.panes.map(harness.frame(of:)) == frames)
                #expect(tab.activePane === b)
                return
            }

            await harness.run("cd /tmp")
            #expect(await harness.eventually { a.session.currentDirectory == "/private/tmp" })
            #expect(harness.shortcut("+"))
            #expect(harness.chooseMenuItem("Use Option as Meta Key"))
            let contentSize = try #require(window.contentView).bounds.size
            await harness.run("sleep 1; stty size")
            let b = try #require(await harness.split(splitCase == .right ? .right : .down))

            #expect(try #require(window.contentView).bounds.size == contentSize)
            #expect(tab.panes.elementsEqual([a, b], by: ===))
            let area = harness.areaSize(tab)
            if splitCase == .right {
                let l = splitLength(0.5, of: area.width)
                #expect(harness.frame(of: a) == NSRect(x: 0, y: 0, width: l, height: area.height))
                #expect(harness.frame(of: b) == NSRect(x: l + 1, y: 0, width: area.width - 1 - l, height: area.height))
            } else {
                let l = splitLength(0.5, of: area.height)
                #expect(harness.frame(of: a) == NSRect(x: 0, y: 0, width: area.width, height: l))
                #expect(harness.frame(of: b) == NSRect(x: 0, y: l + 1, width: area.width, height: area.height - 1 - l))
            }
            #expect(harness.hasGridOfFrame(a) && harness.hasGridOfFrame(b),
                    "\(harness.gridOfFrame(a)) \(harness.gridOfFrame(b))")
            #expect(tab.activePane === b && window.firstResponder === b.terminalView)
            #expect(b.terminalView.fontSize == 14 && b.terminalView.optionAsMeta)
            #expect(b.session.process!.pid != a.session.process!.pid)
            #expect(await harness.eventually { b.session.currentDirectory == "/private/tmp" })

            await harness.run("stty size", in: b)
            let bSize = "\(b.session.terminal.rows) \(b.session.terminal.cols)"
            #expect(await harness.eventually { harness.screenContains(bSize, in: b) }, "\(harness.screenLines(b))")
            let aSize = "\(a.session.terminal.rows) \(a.session.terminal.cols)"
            #expect(await harness.eventually(timeout: 3) { harness.screenContains(aSize, in: a) },
                    "\(harness.screenLines(a))")
        }

        @Test("APP-SPLIT-002 clicking a pane makes it the active pane it gets the keys and names the tab")
        func APP_SPLIT_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let window = try #require(tab.window)
            let strip = try #require(tab.windowController).tabStrip
            func shows(_ title: String) -> Bool {
                tab.title == title && strip.labels == [title] && window.title == title
            }

            await harness.run("printf '\\033]2;Left\\007'")
            #expect(await harness.eventually { a.title == "Left" })
            let b = try #require(await harness.split(.right))
            await harness.run("printf '\\033]2;Right\\007'", in: b)
            #expect(await harness.eventually { shows("Right") }, "\(tab.title)")

            await harness.run("sleep 0.5; printf '\\033]2;Later\\007'", in: b)
            harness.click(row: 0, col: 0, in: a)
            #expect(tab.activePane === a && window.firstResponder === a.terminalView)
            #expect(shows("Left"), "\(tab.title)")
            #expect(await harness.eventually { b.title == "Later" })
            #expect(shows("Left"), "\(tab.title)")

            await harness.run("echo typed-in-a", in: a)
            #expect(await harness.eventually { harness.row("typed-in-a", in: a) != nil }, "\(harness.screenLines(a))")
            #expect(!harness.screenContains("typed-in-a", in: b))

            _ = b.terminalView.menu(for: harness.mouseEvent(.rightMouseDown, row: 0, col: 0, in: b))
            #expect(tab.activePane === b && window.firstResponder === b.terminalView)
            #expect(shows("Later"), "\(tab.title)")

            #expect(harness.shortcut("t"))
            #expect(harness.shortcut("1"))
            #expect(tab.windowController?.selectedTab === tab)
            #expect(tab.activePane === b && window.firstResponder === b.terminalView)
            #expect(window.title == "Later")
        }

        @Test("APP-SPLIT-003 select pane left right above and below move to the adjacent pane")
        func APP_SPLIT_003() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let window = try #require(tab.window)
            let b = try #require(await harness.split(.right))
            let c = try #require(await harness.split(.right))
            let d = try #require(await harness.split(.down))
            #expect(tab.panes.elementsEqual([a, b, c, d], by: ===))
            let names = [ObjectIdentifier(a): "A", ObjectIdentifier(b): "B", ObjectIdentifier(c): "C",
                         ObjectIdentifier(d): "D"]

            func step(_ arrow: AppHarness.Key, _ expected: TerminalPane, _ row: Int) {
                harness.selectPane(arrow)
                #expect(tab.activePane === expected && window.firstResponder === expected.terminalView,
                        "row \(row): \(names[ObjectIdentifier(tab.activePane)] ?? "?")")
            }
            step(.down, d, 1)
            step(.right, d, 2)
            step(.up, c, 3)
            step(.left, b, 4)
            step(.left, a, 5)
            step(.left, a, 6)
            step(.right, b, 7)
            step(.right, c, 8)
            let fc = harness.frame(of: c)
            let ch = c.terminalView.cellSize.height
            harness.dragInArea(from: NSPoint(x: fc.midX, y: fc.maxY + 0.5),
                               to: NSPoint(x: fc.midX, y: fc.maxY + 0.5 - 3 * ch))
            #expect(harness.frame(of: d).height > harness.frame(of: c).height)
            #expect(tab.activePane === c)
            step(.left, b, 9)
            step(.right, d, 10)
            step(.up, c, 11)
            step(.up, c, 12)
        }

        enum Axis: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case sideBySide = "side by side", stacked
            var testDescription: String { rawValue }
        }

        @Test("APP-SPLIT-004 dragging a divider resizes the panes on its sides each keeping 2 columns and 1 row",
              arguments: Axis.allCases)
        func APP_SPLIT_004(axis: Axis) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let window = try #require(tab.window)
            let horizontal = axis == .sideBySide
            let b = try #require(await harness.split(horizontal ? .right : .down))
            let c = try #require(await harness.split(horizontal ? .right : .down))
            let area = harness.areaSize(tab)
            let cell = a.terminalView.cellSize
            let length = horizontal ? area.width : area.height
            let minimum = horizontal ? 12 + 2 * cell.width : 8 + cell.height
            let fewest = horizontal ? 2 : 1
            func len(_ pane: TerminalPane) -> CGFloat {
                horizontal ? harness.frame(of: pane).width : harness.frame(of: pane).height
            }
            func point(_ value: CGFloat) -> NSPoint {
                horizontal ? NSPoint(x: value, y: area.height / 2) : NSPoint(x: area.width / 2, y: value)
            }
            func cells(_ pane: TerminalPane) -> Int {
                horizontal ? pane.session.terminal.cols : pane.session.terminal.rows
            }
            let d = splitLength(0.5, of: length)

            #expect(harness.hitView(at: point(d - 2.5)) === tab.view)
            #expect(harness.hitView(at: point(d + 3.5)) === tab.view)
            #expect(harness.hitView(at: point(d - 3.5)) === a.terminalView)
            #expect(harness.hitView(at: point(d + 4.5)) === b.terminalView)

            let move = horizontal ? 10 * cell.width : 5 * cell.height
            let press = try #require(harness.pressArea(at: point(d + 2.5)))
            press.drag(to: point(d + 2.5 - move))
            #expect(len(a) == (d - move).rounded())
            let rest = length - 1 - len(a)
            #expect(len(b) == splitLength(0.5, of: rest) && len(c) == rest - 1 - len(b))
            #expect([a, b, c].allSatisfy(harness.hasGridOfFrame))
            #expect(tab.activePane === c && window.firstResponder === c.terminalView)
            press.release(at: point(d + 2.5 - move))

            harness.dragInArea(from: point(len(a) + 0.5), to: point(0))
            #expect(len(a) == minimum && cells(a) == fewest, "\(len(a)) \(cells(a))")
            harness.dragInArea(from: point(len(a) + 0.5), to: point(length))
            #expect(len(b) == minimum && len(c) == minimum, "\(len(b)) \(len(c))")
            #expect(cells(b) == fewest && cells(c) == fewest)
            #expect(len(a) == length - 2 - 2 * minimum)
        }

        @Test("APP-SPLIT-005 resizing the window keeps the panes' proportions")
        func APP_SPLIT_005() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let windowController = try #require(tab.windowController)
            let window = try #require(tab.window)
            let b = try #require(await harness.split(.right))
            let c = try #require(await harness.split(.down))
            let cell = a.terminalView.cellSize
            let area = harness.areaSize(tab)
            let d = splitLength(0.5, of: area.width)
            harness.dragInArea(from: NSPoint(x: d + 0.5, y: area.height / 2),
                               to: NSPoint(x: d + 0.5 - 10 * cell.width, y: area.height / 2))
            let l0 = harness.frame(of: a).width
            #expect(l0 == (d - 10 * cell.width).rounded())
            let p = l0 / (area.width - 1)
            let before = [a, b, c].map(harness.frame(of:))

            window.setContentSize(windowController.contentSize(cols: 100, rows: 30))
            let resized = harness.areaSize(tab)
            let w = splitLength(p, of: resized.width)
            let h = splitLength(0.5, of: resized.height)
            #expect(harness.frame(of: a) == NSRect(x: 0, y: 0, width: w, height: resized.height))
            #expect(harness.frame(of: b) == NSRect(x: w + 1, y: 0, width: resized.width - 1 - w, height: h))
            #expect(harness.frame(of: c) == NSRect(x: w + 1, y: h + 1, width: resized.width - 1 - w,
                                                   height: resized.height - 1 - h))
            #expect([a, b, c].allSatisfy(harness.hasGridOfFrame))

            window.setContentSize(windowController.contentSize(cols: 80, rows: 24))
            #expect([a, b, c].map(harness.frame(of:)) == before)
        }

        @Test("APP-SPLIT-007 zoom pane shows the active pane alone until the layout is restored")
        func APP_SPLIT_007() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let window = try #require(tab.window)
            let zoomItem = try #require(harness.menuItem("Zoom Pane", in: "Window"))
            let area = NSRect(origin: .zero, size: harness.areaSize(tab))

            harness.toggleZoom()
            zoomItem.menu?.update()
            #expect(!tab.isZoomed && harness.frame(of: a) == area && !zoomItem.isEnabled)

            let b = try #require(await harness.split(.right))
            await harness.run("sleep 1; echo still-running", in: b)
            let c = try #require(await harness.split(.down))
            let panes = [a, b, c]
            let frames = panes.map(harness.frame(of:))
            func grids() -> [[Int]] { panes.map { [$0.session.terminal.cols, $0.session.terminal.rows] } }
            let before = grids()
            func restored() -> Bool {
                !tab.isZoomed && tab.panes.allSatisfy { !$0.terminalView.isHiddenOrHasHiddenAncestor }
            }

            #expect(harness.toggleZoom())
            zoomItem.menu?.update()
            #expect(tab.isZoomed && harness.frame(of: c) == area)
            #expect(c.session.terminal.cols == 80 && c.session.terminal.rows == 24)
            #expect(tab.activePane === c && window.firstResponder === c.terminalView)
            #expect(a.terminalView.isHiddenOrHasHiddenAncestor && b.terminalView.isHiddenOrHasHiddenAncestor)
            #expect(Array(grids().prefix(2)) == Array(before.prefix(2)))
            #expect(zoomItem.state == .on)
            #expect(await harness.eventually(timeout: 3) { harness.screenContains("still-running", in: b) })
            await harness.run("stty size", in: c)
            #expect(await harness.eventually { harness.screenContains("24 80", in: c) }, "\(harness.screenLines(c))")

            #expect(harness.toggleZoom())
            zoomItem.menu?.update()
            #expect(restored())
            #expect(panes.map(harness.frame(of:)) == frames)
            #expect(grids() == before)
            #expect(zoomItem.state == .off)

            func ensureZoomed() {
                if !tab.isZoomed { harness.toggleZoom() }
            }
            ensureZoomed()
            harness.selectPane(.right)
            #expect(tab.isZoomed && tab.activePane === c, "⌥⌘→")
            ensureZoomed()
            harness.selectPane(.up)
            #expect(restored() && tab.activePane === b, "⌥⌘↑")
            ensureZoomed()
            harness.equalize()
            #expect(restored() && tab.activePane === b, "⌃⌘=")
            ensureZoomed()
            let e = try #require(await harness.split(.right))
            #expect(restored() && tab.panes.elementsEqual([a, b, e, c], by: ===) && tab.activePane === e, "⌘D")
            ensureZoomed()
            #expect(harness.shortcut("w"))
            #expect(await harness.eventually(timeout: 3) { e.isClosed })
            #expect(restored() && tab.panes.elementsEqual([a, b, c], by: ===) && tab.activePane === b, "⌘W")
            #expect(panes.map(harness.frame(of:)) == frames)
        }

        @Test("APP-SPLIT-008 equalize panes shares the space equally between the panes")
        func APP_SPLIT_008() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let b = try #require(await harness.split(.right))
            let c = try #require(await harness.split(.right))
            let area = harness.areaSize(tab)

            #expect(harness.equalize())
            let first = splitLength(1.0 / 3, of: area.width)
            let rest = area.width - 1 - first
            let second = splitLength(0.5, of: rest)
            #expect(harness.frame(of: a) == NSRect(x: 0, y: 0, width: first, height: area.height))
            #expect(harness.frame(of: b) == NSRect(x: first + 1, y: 0, width: second, height: area.height))
            #expect(harness.frame(of: c) == NSRect(x: first + 2 + second, y: 0, width: rest - 1 - second,
                                                   height: area.height))
            let widths = [a, b, c].map { harness.frame(of: $0).width }
            #expect(widths.max()! - widths.min()! <= 1, "\(widths)")
            #expect([a, b, c].allSatisfy(harness.hasGridOfFrame))
            #expect(tab.activePane === c)
            let columns = [a, b, c].map(harness.frame(of:))

            let d = try #require(await harness.split(.down))
            let cell = a.terminalView.cellSize
            harness.dragInArea(from: NSPoint(x: first + 0.5, y: area.height / 2),
                               to: NSPoint(x: first + 0.5 - 5 * cell.width, y: area.height / 2))
            #expect(harness.frame(of: a).width < columns[0].width)
            #expect(harness.equalize())
            #expect(harness.frame(of: a) == columns[0] && harness.frame(of: b) == columns[1])
            let column = columns[2]
            let top = splitLength(0.5, of: area.height)
            #expect(harness.frame(of: c) == NSRect(x: column.minX, y: 0, width: column.width, height: top))
            #expect(harness.frame(of: d) == NSRect(x: column.minX, y: top + 1, width: column.width,
                                                   height: area.height - 1 - top))
        }

        @Test("APP-SPLIT-009 the divider and a frame around the active pane show the layout")
        func APP_SPLIT_009() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let b = try #require(await harness.split(.right))
            harness.reportKey(true)
            let area = NSRect(origin: .zero, size: harness.areaSize(tab))
            let l = splitLength(0.5, of: area.width)
            let divider = NSRect(x: l, y: 0, width: 1, height: area.height)

            func expectFrame(on active: TerminalPane, off other: TerminalPane, _ step: String) {
                let rendered = harness.renderArea(tab)
                #expect(rendered.pixels(in: divider).allSatisfy { $0.matches(TabStripView.background) }, "\(step)")
                let on = rendered.edges(of: harness.frame(of: active))
                #expect(on.allSatisfy { $0.matches(accentColor) }, "\(step) \(on)")
                #expect(rendered.edges(of: harness.frame(of: active), inset: 1).allSatisfy { $0.matches(backgroundColor) },
                        "\(step)")
                #expect(rendered.edges(of: harness.frame(of: other)).allSatisfy { $0.matches(backgroundColor) },
                        "\(step)")
            }

            expectFrame(on: b, off: a, "B active")
            let cursorB = b.session.terminal.cursorPosition
            #expect(harness.render(b).cellCenter(row: cursorB.row, col: cursorB.col).matches(cursorColor))
            let cursorA = a.session.terminal.cursorPosition
            let renderedA = harness.render(a)
            #expect(renderedA.cellCorner(row: cursorA.row, col: cursorA.col).matches(cursorColor))
            #expect(renderedA.cellCenter(row: cursorA.row, col: cursorA.col).matches(backgroundColor))

            harness.click(row: 0, col: 0, in: a)
            expectFrame(on: a, off: b, "A clicked")

            #expect(harness.toggleZoom())
            var rendered = harness.renderArea(tab)
            #expect(rendered.edges(of: area).allSatisfy { $0.matches(accentColor) })
            #expect(rendered.pixels(in: divider.insetBy(dx: 0, dy: 1)).allSatisfy { $0.matches(backgroundColor) })

            #expect(harness.toggleZoom())
            #expect(harness.shortcut("w"))
            #expect(await harness.eventually(timeout: 3) { tab.panes.count == 1 })
            rendered = harness.renderArea(tab)
            #expect(rendered.edges(of: area).allSatisfy { $0.matches(backgroundColor) })
        }

        @Test("APP-SPLIT-010 the assistant bar opens in the active pane and runs commands there")
        func APP_SPLIT_010() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let b = try #require(await harness.split(.right))
            harness.reportKey(true)
            fake.queue(.commands([("echo first-choice", "First")]))
            func centered(_ pane: TerminalPane) -> Bool {
                let bar = pane.assistant.bar
                let view = pane.terminalView
                return bar.superview === view && abs(bar.frame.midX - view.bounds.midX) <= 0.5
                    && abs(bar.frame.midY - view.bounds.midY) <= 0.5
            }

            #expect(harness.chooseMenuItem("Ask…"))
            #expect(b.assistant.bar.mode == .prompt && b.assistant.bar.fieldHasFocus)
            #expect(centered(b), "\(b.assistant.bar.frame) in \(b.terminalView.bounds)")
            #expect(a.assistant.bar.mode == .hidden)
            #expect(tab.activePane === b)

            harness.press(.escape, in: b)
            harness.click(row: 0, col: 0, in: a)
            #expect(await harness.openBar(in: a))
            #expect(a.assistant.bar.mode == .prompt && centered(a))
            #expect(b.assistant.bar.mode == .hidden)

            harness.submit("say it", in: a)
            #expect(await harness.eventually { a.assistant.bar.mode == .suggestions })
            harness.press(.returnKey, in: a)
            #expect(await harness.eventually { harness.showsInOrder(["$ echo first-choice", "first-choice"], in: a) },
                    "\(harness.screenLines(a))")
            #expect(!harness.screenContains("first-choice", in: b))
        }

        /// A menu item as SPEC/app/splits.md lists it.
        struct ListedItem {
            let title: String
            let shortcut: String
            let action: String
            let delegate: Bool
            var tag = 0
        }

        @Test("APP-SPLIT-011 the shell and window menus show every command with its shortcut")
        func APP_SPLIT_011() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let delegate = harness.delegate
            func check(_ item: NSMenuItem, _ expected: ListedItem) {
                #expect(item.title == expected.title)
                #expect(displayedShortcut(item) == expected.shortcut, "\(expected.title): \(displayedShortcut(item))")
                #expect(item.action.map(NSStringFromSelector) == expected.action, "\(expected.title)")
                #expect((item.target === delegate) == expected.delegate, "\(expected.title)")
                #expect(!item.isHidden, "\(expected.title)")
                #expect(item.tag == expected.tag, "\(expected.title)")
            }

            let shell = try #require(harness.menu("Shell"))
            let shellItems: [ListedItem?] = [
                ListedItem(title: "New Window", shortcut: "⌘N", action: "newWindow:", delegate: true),
                ListedItem(title: "New Tab", shortcut: "⌘T", action: "newTab:", delegate: true),
                nil,
                ListedItem(title: "Split Right", shortcut: "⌘D", action: "splitRight:", delegate: true),
                ListedItem(title: "Split Down", shortcut: "⇧⌘D", action: "splitDown:", delegate: true),
                nil,
                ListedItem(title: "Ask…", shortcut: "", action: "askAssistant:", delegate: true),
                ListedItem(title: "Stop Agent", shortcut: "⌘.", action: "stopAgent:", delegate: true),
                nil,
                ListedItem(title: "Close", shortcut: "⌘W", action: "closePane:", delegate: true),
                ListedItem(title: "Close Window", shortcut: "⇧⌘W", action: "performClose:", delegate: false),
            ]
            #expect(shell.items.count == shellItems.count, "\(shell.items.map(\.title))")
            for (item, expected) in zip(shell.items, shellItems) {
                if let expected { check(item, expected) } else { #expect(item.isSeparatorItem) }
            }

            let windowMenu = try #require(harness.menu("Window"))
            let tabNumbers = (1...8).map {
                ListedItem(title: "Select Tab \($0)", shortcut: "⌘\($0)", action: "selectTabByNumber:", delegate: true,
                           tag: $0)
            }
            let groups: [[ListedItem]] = [
                [ListedItem(title: "Minimize", shortcut: "⌘M", action: "performMiniaturize:", delegate: false),
                 ListedItem(title: "Zoom", shortcut: "", action: "performZoom:", delegate: false)],
                [ListedItem(title: "Show Previous Tab", shortcut: "⌘{", action: "selectPreviousTab:", delegate: true),
                 ListedItem(title: "Show Next Tab", shortcut: "⌘}", action: "selectNextTab:", delegate: true)]
                    + tabNumbers
                    + [ListedItem(title: "Select Last Tab", shortcut: "⌘9", action: "selectTabByNumber:", delegate: true,
                                  tag: 9)],
                [ListedItem(title: "Select Pane Left", shortcut: "⌥⌘←", action: "selectPaneLeft:", delegate: true),
                 ListedItem(title: "Select Pane Right", shortcut: "⌥⌘→", action: "selectPaneRight:", delegate: true),
                 ListedItem(title: "Select Pane Above", shortcut: "⌥⌘↑", action: "selectPaneAbove:", delegate: true),
                 ListedItem(title: "Select Pane Below", shortcut: "⌥⌘↓", action: "selectPaneBelow:", delegate: true),
                 ListedItem(title: "Zoom Pane", shortcut: "⇧⌘↩", action: "togglePaneZoom:", delegate: true),
                 ListedItem(title: "Equalize Panes", shortcut: "⌃⌘=", action: "equalizePanes:", delegate: true)],
                [ListedItem(title: "Bring All to Front", shortcut: "", action: "arrangeInFront:", delegate: false)],
            ]
            var previousEnd: Int?
            for group in groups {
                let titles = group.map(\.title)
                let found = group.compactMap { expected in windowMenu.items.firstIndex { $0.title == expected.title } }
                #expect(found.count == group.count, "\(titles) in \(windowMenu.items.map(\.title))")
                guard found.count == group.count, let first = found.first, let last = found.last else { continue }
                #expect(found == Array(first...last), "\(titles): \(found)")
                for (index, expected) in zip(found, group) { check(windowMenu.items[index], expected) }
                if let previousEnd {
                    #expect(first > previousEnd && windowMenu.items[(previousEnd + 1)..<first].contains(where: \.isSeparatorItem),
                            "\(titles)")
                }
                previousEnd = last
            }

            let hidden = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items)
                .filter { $0.target === delegate && $0.isHidden }
                .map { "\($0.title) \(displayedShortcut($0))" }
            #expect(hidden == ["Bigger ⌘="], "\(hidden)")

            let paneItems = ["Select Pane Left", "Select Pane Right", "Select Pane Above", "Select Pane Below",
                             "Zoom Pane", "Equalize Panes"]
            func enabled() -> [Bool] {
                windowMenu.update()
                return paneItems.map { title in windowMenu.items.first { $0.title == title }?.isEnabled ?? false }
            }
            #expect(enabled() == Array(repeating: false, count: paneItems.count))
            _ = try #require(await harness.split(.right))
            #expect(enabled() == Array(repeating: true, count: paneItems.count))
        }

        @Test("APP-SPLIT-006 closing the active pane gives its space to its sibling")
        func APP_SPLIT_006() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let a = tab.activePane
            let window = try #require(tab.window)
            let b = try #require(await harness.split(.right))
            let c = try #require(await harness.split(.down))
            harness.click(row: 0, col: 0, in: a)
            #expect(tab.activePane === a)

            let pidA = a.session.process!.pid
            #expect(harness.shortcut("w"))
            #expect(await harness.eventually(timeout: 3) { kill(pidA, 0) != 0 })
            #expect(a.terminalView.window == nil)
            #expect(tab.panes.elementsEqual([b, c], by: ===))
            let area = harness.areaSize(tab)
            let l = splitLength(0.5, of: area.height)
            #expect(harness.frame(of: b) == NSRect(x: 0, y: 0, width: area.width, height: l))
            #expect(harness.frame(of: c) == NSRect(x: 0, y: l + 1, width: area.width, height: area.height - 1 - l))
            #expect(harness.hasGridOfFrame(b) && harness.hasGridOfFrame(c))
            #expect(tab.activePane === b && window.firstResponder === b.terminalView)

            let pidB = b.session.process!.pid
            #expect(harness.shortcut("w"))
            #expect(await harness.eventually(timeout: 3) { kill(pidB, 0) != 0 })
            #expect(tab.panes.elementsEqual([c], by: ===))
            #expect(harness.frame(of: c) == NSRect(origin: .zero, size: area))
            #expect(c.session.terminal.cols == 80 && c.session.terminal.rows == 24)
            #expect(tab.activePane === c && window.firstResponder === c.terminalView)

            #expect(harness.shortcut("w"))
            #expect(await harness.eventually { harness.windows.isEmpty })
            #expect(tab.isClosed)
        }
    }
}
