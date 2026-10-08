import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

let stripBackground = RGB(20, 21, 26)

/// The tab rectangles, + button and × of the geometry in SPEC/app/tab-strip.md.
@MainActor
struct StripGeometry {
    let start: CGFloat
    let width: CGFloat
    let count: Int

    init(_ strip: TabStripView, window: NSWindow, count: Int) {
        let zoom = window.standardWindowButton(.zoomButton)!
        let zoomFrame = strip.convert(zoom.frame, from: zoom.superview)
        start = zoomFrame.maxX + 12
        width = min(240, (strip.bounds.width - 8 - 28 - start) / CGFloat(count))
        self.count = count
    }

    func tab(_ index: Int) -> NSRect {
        NSRect(x: start + CGFloat(index) * width, y: 8, width: width, height: 30)
    }

    func close(_ index: Int) -> NSRect {
        let tab = tab(index)
        return NSRect(x: tab.maxX - 13 - 8, y: tab.midY - 8, width: 16, height: 16)
    }

    var newTab: NSRect {
        NSRect(x: start + CGFloat(count) * width + 4, y: 11, width: 24, height: 24)
    }
}

func close(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

extension E2E {
    @Suite @MainActor struct TabStrip {
        @Test("APP-TAB-003 the tab strip sits in the title bar and lists the window's tabs", arguments: [1, 3, 12])
        func APP_TAB_003(count: Int) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            while harness.controllers.count < count { #expect(harness.shortcut("t")) }
            let windowController = try #require(harness.windows.first)
            let window = try #require(windowController.window)
            let strip = windowController.tabStrip
            let tabs = windowController.tabs
            #expect(tabs.count == count && harness.windows.count == 1)
            let selected = try #require(tabs.last)
            #expect(windowController.selectedTab === selected)
            window.layoutIfNeeded()

            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .hidden)
            #expect(window.tabbingMode == .disallowed)

            let content = try #require(window.contentView)
            let stripFrame = content.convert(strip.bounds, from: strip)
            let top = content.isFlipped ? stripFrame.minY : content.bounds.height - stripFrame.maxY
            #expect(abs(top) < 0.01 && stripFrame.height == 38 && stripFrame.width == content.bounds.width,
                    "\(stripFrame) in \(content.bounds)")
            let viewFrame = content.convert(selected.terminalView.bounds, from: selected.terminalView)
            #expect(abs(viewFrame.height + 38 - content.bounds.height) < 0.01 && viewFrame.width == content.bounds.width,
                    "\(viewFrame)")
            #expect(content.isFlipped ? abs(viewFrame.minY - stripFrame.maxY) < 0.01 : abs(viewFrame.maxY - stripFrame.minY) < 0.01)

            let stripMid = strip.convert(NSPoint(x: 0, y: strip.bounds.midY), to: nil).y
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try #require(window.standardWindowButton(kind))
                let mid = button.convert(NSPoint(x: 0, y: button.bounds.midY), to: nil).y
                #expect(abs(mid - stripMid) <= 1, "\(kind): \(mid) vs \(stripMid)")
            }

            let geometry = StripGeometry(strip, window: window, count: count)
            let zoom = window.standardWindowButton(.zoomButton)!
            #expect(geometry.start > strip.convert(zoom.frame, from: zoom.superview).maxX)
            for index in 0..<count {
                #expect(close(strip.tabRect(at: index), geometry.tab(index)), "tab \(index): \(strip.tabRect(at: index))")
                #expect(close(strip.closeButtonRect(at: index), geometry.close(index)), "× \(index)")
            }
            #expect(close(strip.newTabButtonRect, geometry.newTab), "+ \(strip.newTabButtonRect)")
            #expect(strip.newTabButtonRect.maxX <= strip.bounds.width)
            if count == 1 { #expect(geometry.width == 240) }
            #expect(strip.labels == tabs.map(\.title))

            let pixel = harness.renderStrip()
            for index in 0..<count {
                let rect = strip.tabRect(at: index)
                let color = pixel(NSPoint(x: rect.minX + 6, y: rect.midY))
                let expected = index == count - 1 ? backgroundColor : stripBackground
                #expect(color.matches(expected), "tab \(index): \(color)")
            }
            let corner = pixel(NSPoint(x: strip.bounds.width - 4, y: 4))
            #expect(corner.matches(stripBackground), "\(corner)")
        }

        @Test("APP-TAB-004 clicking a tab selects it and the close middle and plus buttons close and open tabs")
        func APP_TAB_004() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            await harness.run("cd /tmp")
            #expect(await harness.eventually { harness.controller.session.currentDirectory == "/private/tmp" })
            await harness.openTabs(titled: ["A", "B", "C"])
            let windowController = try #require(harness.windows.first)
            let window = try #require(windowController.window)
            let (a, b, c) = (harness.controllers[0], harness.controllers[1], harness.controllers[2])
            #expect(windowController.selectedTab === c)

            harness.clickTab(0)
            #expect(windowController.selectedTab === a)
            #expect(!a.terminalView.isHiddenOrHasHiddenAncestor && window.firstResponder === a.terminalView)
            #expect(b.terminalView.isHiddenOrHasHiddenAncestor && c.terminalView.isHiddenOrHasHiddenAncestor)
            #expect(window.title == "A")

            let pidB = b.session.process!.pid
            harness.clickTab(1, middle: true)
            #expect(windowController.tabs.map(\.title) == ["A", "C"])
            #expect(windowController.selectedTab === a && b.isClosed)
            #expect(await harness.eventually(timeout: 3) { kill(pidB, 0) != 0 })

            harness.clickTab(1, part: .close)
            #expect(windowController.tabs.map(\.title) == ["A"])
            #expect(windowController.selectedTab === a && c.isClosed)

            let plus = harness.strip().newTabButtonRect
            harness.clickStrip(at: NSPoint(x: plus.midX, y: plus.midY))
            #expect(windowController.tabs.count == 2)
            let new = try #require(windowController.tabs.last)
            #expect(windowController.selectedTab === new && window.firstResponder === new.terminalView)
            #expect(await harness.eventually { new.session.currentDirectory == "/private/tmp" })
        }

        @Test("APP-TAB-005 dragging a tab reorders the tabs", arguments: [false, true])
        func APP_TAB_005(shortMove: Bool) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            await harness.openTabs(titled: ["A", "B", "C"])
            let windowController = try #require(harness.windows.first)
            let window = try #require(windowController.window)
            let strip = harness.strip()
            let a = harness.controllers[0]
            let geometry = StripGeometry(strip, window: window, count: 3)
            #expect(windowController.selectedTab === harness.controllers[2])

            let start = NSPoint(x: strip.tabRect(at: 0).midX, y: strip.tabRect(at: 0).midY)
            strip.mouseDown(with: harness.stripEvent(.leftMouseDown, at: start))
            #expect(windowController.selectedTab === a)

            if shortMove {
                let end = NSPoint(x: start.x + 2, y: start.y)
                strip.mouseDragged(with: harness.stripEvent(.leftMouseDragged, at: end))
                strip.mouseUp(with: harness.stripEvent(.leftMouseUp, at: end))
                #expect(windowController.tabs.map(\.title) == ["A", "B", "C"])
                #expect(windowController.selectedTab === a)
                #expect(close(strip.tabRect(at: 0), geometry.tab(0)), "\(strip.tabRect(at: 0))")
                return
            }
            let end = NSPoint(x: geometry.tab(2).midX + geometry.width / 4, y: start.y)
            strip.mouseDragged(with: harness.stripEvent(.leftMouseDragged, at: NSPoint(x: geometry.tab(1).midX, y: start.y)))
            strip.mouseDragged(with: harness.stripEvent(.leftMouseDragged, at: end))
            #expect(windowController.tabs.map(\.title) == ["B", "C", "A"])
            #expect(abs(strip.tabRect(at: 2).midX - end.x) < 0.01, "\(strip.tabRect(at: 2)) vs \(end)")

            strip.mouseUp(with: harness.stripEvent(.leftMouseUp, at: end))
            #expect(windowController.tabs.map(\.title) == ["B", "C", "A"])
            #expect(windowController.selectedTab === a)
            #expect(close(strip.tabRect(at: 2), geometry.tab(2)), "\(strip.tabRect(at: 2))")
        }

        @Test("APP-TAB-006 keyboard shortcuts select and close tabs")
        func APP_TAB_006() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            await harness.openTabs(titled: ["A", "B", "C", "D"])
            let windowController = try #require(harness.windows.first)
            let window = try #require(windowController.window)

            func expectSelected(_ title: String, _ step: String) {
                let selected = windowController.selectedTab
                #expect(selected?.title == title, "\(step)")
                #expect(selected.map { !$0.terminalView.isHiddenOrHasHiddenAncestor && window.firstResponder === $0.terminalView } == true,
                        "\(step)")
                #expect(window.title == title, "\(step)")
            }
            expectSelected("D", "start")
            #expect(harness.shortcut("}", modifiers: [.command, .shift]))
            expectSelected("A", "⌘}")
            #expect(harness.shortcut("{", modifiers: [.command, .shift]))
            expectSelected("D", "⌘{")
            #expect(harness.shortcut("2"))
            expectSelected("B", "⌘2")
            #expect(harness.shortcut("9"))
            expectSelected("D", "⌘9")
            #expect(harness.shortcut("w"))
            #expect(windowController.tabs.map(\.title) == ["A", "B", "C"])
            expectSelected("C", "⌘W")
        }

        @Test("APP-TAB-007 only the empty part of the strip moves the window")
        func APP_TAB_007() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(harness.shortcut("t"))
            let windowController = try #require(harness.windows.first)
            let window = try #require(windowController.window)
            let strip = harness.strip()
            #expect(windowController.tabs.count == 2 && windowController.selectedTab === windowController.tabs[1])

            let tab0 = strip.tabRect(at: 0)
            harness.moveMouse(inStrip: NSPoint(x: tab0.minX + 6, y: tab0.midY))
            #expect(!window.isMovable, "tab body")
            let close1 = strip.closeButtonRect(at: 1)
            harness.moveMouse(inStrip: NSPoint(x: close1.midX, y: close1.midY))
            #expect(!window.isMovable, "×")
            let plus = strip.newTabButtonRect
            harness.moveMouse(inStrip: NSPoint(x: plus.midX, y: plus.midY))
            #expect(!window.isMovable, "+")
            harness.moveMouse(inStrip: NSPoint(x: strip.bounds.width - 4, y: 19))
            #expect(window.isMovable, "empty")
            harness.moveMouse(inStrip: nil)
            #expect(window.isMovable, "outside")

            let tab1 = strip.tabRect(at: 1)
            let start = NSPoint(x: tab1.midX, y: tab1.midY)
            strip.mouseDown(with: harness.stripEvent(.leftMouseDown, at: start))
            #expect(!window.isMovable, "pressed")
            let end = NSPoint(x: start.x - 20, y: start.y)
            strip.mouseDragged(with: harness.stripEvent(.leftMouseDragged, at: end))
            #expect(!window.isMovable, "dragging")
            #expect(abs(strip.tabRect(at: 1).midX - end.x) < 0.01, "\(strip.tabRect(at: 1)) vs \(end)")
            strip.mouseUp(with: harness.stripEvent(.leftMouseUp, at: end))
        }
    }
}
