import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

/// Not smaller in either dimension and larger in at least one.
func grew(_ size: NSSize, from old: NSSize) -> Bool {
    size.width >= old.width && size.height >= old.height && size != old
}

extension E2E {
    @Suite @MainActor struct TabsFonts {
        @Test("APP-TAB-001 new tab opens a tab in the same window in the current directory")
        func APP_TAB_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let first = harness.controller
            await harness.run("cd /tmp")
            #expect(await harness.eventually { first.session.process!.currentDirectory == "/private/tmp" })

            #expect(harness.shortcut("t"))
            #expect(harness.controllers.count == 2)
            guard harness.controllers.count == 2 else { return }
            let second = harness.controllers[1]
            #expect(harness.windows.count == 1)
            #expect(harness.windows.first?.tabs.elementsEqual([first, second], by: ===) == true)
            #expect(harness.windows.first?.selectedTab === second)
            #expect(second.window?.firstResponder === second.terminalView)
            #expect(second.session.process!.pid != first.session.process!.pid)
            #expect(await harness.waitForPrompt(second))
            #expect(second.session.process!.currentDirectory == "/private/tmp")

            let fake = FakeOpenRouter()
            let assistant = assistantHarness(fake)
            defer { assistant.shutDown() }
            let directory = await assistant.useTemporaryDirectory()
            fake.queue(.agentTask("sub exists"), .bash("c1", "mkdir -p sub && cd sub"), .agentText("done\nGOAL MET"))
            #expect(await assistant.openBar())
            assistant.submit("make sub")
            #expect(await assistant.eventually { assistant.agentController != nil })
            let agent = try #require(assistant.agentController)
            #expect(await assistant.eventually(timeout: 5) { agent.agentTab?.isRunning == false
                && assistant.screenLines(agent).contains { $0.contains("✓ Goal met") } })
            assistant.reportKey(true, agent)
            #expect(assistant.shortcut("t"))
            #expect(assistant.controllers.count == 3)
            guard assistant.controllers.count == 3 else { return }
            let shell = assistant.controllers[2]
            #expect(assistant.windows.count == 1 && shell.windowController === agent.windowController)
            #expect(await assistant.eventually { shell.session.process?.currentDirectory == directory + "/sub" })
        }

        @Test("APP-TAB-002 new window opens a separate window in the home directory")
        func APP_TAB_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let first = harness.controller
            await harness.run("cd /tmp")
            #expect(await harness.eventually { first.session.process!.currentDirectory == "/private/tmp" })

            #expect(harness.shortcut("n"))
            #expect(harness.controllers.count == 2)
            guard harness.controllers.count == 2 else { return }
            let second = harness.controllers[1]
            #expect(harness.windows.count == 2)
            #expect(harness.windows.allSatisfy { $0.tabs.count == 1 })
            #expect(second.window !== first.window)
            #expect(await harness.waitForPrompt(second))
            let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
            #expect(second.session.process!.currentDirectory == home)
        }

        @Test("APP-FONT-001 font size changes keep the grid of the tab area", arguments: ["two tabs", "split tab"])
        func APP_FONT_001(layout: String) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            if layout == "split tab" {
                #expect(await harness.waitForPrompt())
                let tab = harness.controller
                let a = tab.activePane
                let windowController = try #require(tab.windowController)
                let window = try #require(tab.window)
                let b = try #require(await harness.split(.right))
                #expect(harness.shortcut("+"))
                #expect(a.terminalView.fontSize == 14 && b.terminalView.fontSize == 14)
                let expected = windowController.contentSize(cols: 80, rows: 24)
                let content = try #require(window.contentView).bounds.size
                #expect(abs(content.width - expected.width) < 0.01 && abs(content.height - expected.height) < 0.01,
                        "\(content) \(expected)")
                let area = harness.areaSize(tab)
                let l = splitLength(0.5, of: area.width)
                #expect(harness.frame(of: a) == NSRect(x: 0, y: 0, width: l, height: area.height))
                #expect(harness.frame(of: b) == NSRect(x: l + 1, y: 0, width: area.width - 1 - l, height: area.height))
                #expect(harness.hasGridOfFrame(a) && harness.hasGridOfFrame(b))
                return
            }
            let controller = harness.controller
            let view = controller.terminalView
            let terminal = controller.session.terminal
            let window = controller.window!
            #expect(harness.shortcut("t"))
            #expect(harness.controllers.count == 2)
            let other = harness.controllers[1]
            let otherTerminal = other.session.terminal
            controller.windowController!.select(controller)
            #expect(view.fontSize == 13)
            let cell = view.cellSize
            let content = window.contentLayoutRect.size

            #expect(harness.shortcut("+"))
            #expect(view.fontSize == 14 && other.terminalView.fontSize == 14)
            #expect(grew(view.cellSize, from: cell), "\(cell) → \(view.cellSize)")
            #expect(grew(window.contentLayoutRect.size, from: content), "\(content) → \(window.contentLayoutRect.size)")
            #expect(terminal.cols == 80 && terminal.rows == 24)
            #expect(otherTerminal.cols == 80 && otherTerminal.rows == 24)

            #expect(harness.shortcut("-"))
            #expect(harness.shortcut("-"))
            #expect(view.fontSize == 12 && other.terminalView.fontSize == 12)
            #expect(terminal.cols == 80 && terminal.rows == 24)
            #expect(otherTerminal.cols == 80 && otherTerminal.rows == 24)

            #expect(harness.shortcut("0"))
            #expect(view.fontSize == 13 && other.terminalView.fontSize == 13)
            #expect(terminal.cols == 80 && terminal.rows == 24)
            #expect(otherTerminal.cols == 80 && otherTerminal.rows == 24)
        }
    }
}
