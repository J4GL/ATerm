import AppKit
import Testing
@testable import ATermApp
import ATermCore

/// A drop carrying a pasteboard, as AppKit hands it to a dragging destination.
@MainActor
final class DropInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }

    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
final class URLRecorder {
    var urls: [URL] = []
}

extension E2E {
    @Suite @MainActor struct Edit {
        @Test("APP-EDIT-001 clear scrollback keeps only the current line")
        func APP_EDIT_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            await harness.run("seq 1 50")
            #expect(await harness.eventually { harness.row("50") != nil })
            #expect(await harness.waitForPrompt())

            #expect(harness.shortcut("k"))
            #expect(terminal.scrollbackCount == 0)
            #expect(terminal.screenLines[0] == "$")
            #expect(terminal.screenLines.dropFirst().allSatisfy { $0.isEmpty })
            #expect(terminal.cursorPosition.row == 0)

            await harness.run("echo after")
            #expect(await harness.eventually { terminal.screenLines[1] == "after" })
        }

        @Test("APP-EDIT-002 dropping files inserts their shell-escaped paths")
        func APP_EDIT_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            let row = terminal.cursorPosition.row
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("ATermDrop-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL, URL(fileURLWithPath: "/tmp/c'd") as NSURL])
            let view = harness.controller.terminalView
            let drop = DropInfo(pasteboard: pasteboard, window: view.window, location: NSPoint(x: 20, y: 20))
            #expect(view.performDragOperation(drop))
            #expect(await harness.eventually { terminal.text(row: row) == "$ /tmp/a\\ b.txt /tmp/c\\'d" })
        }

        @Test("APP-EDIT-003 command-click opens the link under the pointer")
        func APP_EDIT_003() async throws {
            let recorder = URLRecorder()
            var configuration = AppHarness.fixture()
            configuration.openURL = { recorder.urls.append($0) }
            let harness = AppHarness(configuration: configuration)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let row = await harness.run("echo see https://example.com/x?y=1. now") + 1
            #expect(await harness.eventually { harness.screenLines()[row] == "see https://example.com/x?y=1. now" })

            harness.click(row: row, col: 10, modifiers: .command)
            #expect(recorder.urls == [URL(string: "https://example.com/x?y=1")!])
            #expect(harness.controller.terminalView.selection == nil)

            harness.click(row: row, col: 1, modifiers: .command)
            #expect(recorder.urls.count == 1)
        }

        @Test("APP-EDIT-004 clicking the view after dropping a file at the zsh prompt removes the highlight of its path")
        func APP_EDIT_004() async throws {
            let harness = AppHarness(configuration: AppHarness.zshFixture())
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            let row = terminal.cursorPosition.row
            func inverse() -> [Bool] { (2...15).map { terminal.line(row).cells[$0].attributes.flags.contains(.inverse) } }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("ATermDrop-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL])
            let view = harness.controller.terminalView
            let drop = DropInfo(pasteboard: pasteboard, window: view.window, location: NSPoint(x: 20, y: 20))
            #expect(view.performDragOperation(drop))
            #expect(await harness.eventually {
                terminal.text(row: row) == "$ /tmp/a\\ b.txt" && inverse().allSatisfy { $0 }
            }, "\(terminal.text(row: row)) \(inverse())")

            harness.click(row: row + 3, col: 30)
            #expect(await harness.eventually { inverse().allSatisfy { !$0 } }, "\(inverse())")
            #expect(terminal.text(row: row) == "$ /tmp/a\\ b.txt")
            #expect(terminal.cursorPosition == Position(row: row, col: 16))
            #expect(view.selection == nil)
        }
    }
}
