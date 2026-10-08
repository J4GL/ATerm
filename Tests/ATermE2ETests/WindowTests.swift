import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

extension E2E {
    @Suite @MainActor struct Windows {
        @Test("APP-WINDOW-001 launching the app opens a window running the user's login shell")
        func APP_WINDOW_001() async throws {
            let harness = AppHarness(configuration: AppHarness.fixture(loginShell: true))
            defer { harness.shutDown() }
            #expect(harness.controllers.count == 1)
            let controller = harness.controller
            let terminal = controller.session.terminal
            #expect(terminal.cols == 80 && terminal.rows == 24)
            #expect(controller.window?.firstResponder === controller.terminalView)
            #expect(controller.window?.appearance?.name == .darkAqua)

            let shell = LoginShell.command(environment: ProcessInfo.processInfo.environment,
                                           accountShell: LoginShell.accountShell())
            let expected = shell.arguments[0]
            let pid = controller.session.process!.pid
            #expect(pid > 0)
            #expect(expected.hasPrefix("-"))
            var args = ""
            let started = await harness.eventually {
                args = (try? processArguments(pid)) ?? ""
                return args.hasPrefix(expected)
            }
            #expect(started, "ps reported \(args.debugDescription)")
        }

        @Test("APP-WINDOW-002 typed keys run commands whose output is drawn")
        func APP_WINDOW_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let commandRow = await harness.run("echo hello")
            #expect(await harness.eventually { harness.screenLines()[commandRow + 1] == "hello" })

            let rendered = harness.render()
            let outputRow = commandRow + 1
            for col in 0..<5 {
                #expect(rendered.pixels(row: outputRow, col: col).contains { !$0.matches(backgroundColor) }, "cell \(col)")
            }
            #expect(rendered.pixels(row: outputRow, col: 5).allSatisfy { $0.matches(backgroundColor) })
        }

        @Test("APP-WINDOW-003 the tab title follows OSC titles else the foreground program")
        func APP_WINDOW_003() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let tab = harness.controller
            let window = tab.window!
            let strip = harness.strip()
            func shows(_ title: String) -> Bool {
                tab.title == title && strip.labels == [title] && window.title == title
            }
            #expect(await harness.eventually { shows("bash") })

            await harness.run("printf '\\033]2;Build\\007'")
            #expect(await harness.eventually { shows("Build") })

            #expect(await harness.waitForPrompt())
            await harness.run("printf '\\033]2;\\007'")
            #expect(await harness.eventually { shows("bash") })
        }

        @Test("APP-WINDOW-004 resizing the window resizes the terminal and the PTY")
        func APP_WINDOW_004() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let controller = harness.controller
            let view = controller.terminalView
            controller.window!.setContentSize(controller.windowController!.contentSize(cols: 100, rows: 30))
            let terminal = controller.session.terminal
            #expect(terminal.cols == 100 && terminal.rows == 30)
            #expect(controller.window!.contentResizeIncrements == view.cellSize)

            await harness.run("stty size")
            #expect(await harness.eventually { harness.screenContains("30 100") })
        }

        @Test("APP-WINDOW-005 a clean shell exit closes its pane an error keeps it open",
              arguments: ["exit", "exit in second tab", "exit 3", "exit in a split pane", "exit in an inactive pane"])
        func APP_WINDOW_005(command: String) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let controller = harness.controller
            let window = controller.window!
            switch command {
            case "exit":
                await harness.run("exit")
                #expect(await harness.eventually(timeout: 3) { harness.controllers.isEmpty })
                #expect(!window.isVisible && controller.isClosed && harness.windows.isEmpty)
            case "exit in second tab":
                #expect(harness.shortcut("t"))
                let second = try #require(harness.controllers.last)
                #expect(await harness.waitForPrompt(second))
                await harness.run("exit", in: second)
                #expect(await harness.eventually(timeout: 3) { second.isClosed })
                #expect(harness.controllers.count == 1 && harness.windows.count == 1 && !controller.isClosed)
                #expect(controller.windowController?.selectedTab === controller)
                #expect(!controller.terminalView.isHiddenOrHasHiddenAncestor)
                #expect(window.firstResponder === controller.terminalView)
            case "exit in a split pane", "exit in an inactive pane":
                let a = controller.activePane
                let b = try #require(await harness.split(.right))
                if command == "exit in a split pane" {
                    await harness.run("exit", in: b)
                } else {
                    await harness.run("sleep 1; exit", in: b)
                    harness.click(row: 0, col: 0, in: a)
                }
                #expect(await harness.eventually(timeout: 3) { b.isClosed })
                #expect(controller.panes.elementsEqual([a], by: ===))
                #expect(harness.frame(of: a) == NSRect(origin: .zero, size: harness.areaSize(controller)))
                #expect(controller.activePane === a && window.firstResponder === a.terminalView)
                #expect(!controller.isClosed && harness.windows.count == 1)
            default:
                await harness.run("exit 3")
                #expect(await harness.eventually(timeout: 3) {
                    harness.screenContains("[Process exited with code 3]", in: controller)
                })
                #expect(harness.controllers.count == 1 && !controller.isClosed && harness.windows.count == 1)
                let before = harness.screenLines(controller)
                harness.type("abc", in: controller)
                await harness.pause(0.3)
                #expect(harness.screenLines(controller) == before)
            }
        }

        @Test("APP-WINDOW-006 closing a pane a tab or a window with a running program asks for confirmation")
        func APP_WINDOW_006() async throws {
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                let controller = harness.controller
                controller.window!.performClose(nil)
                #expect(controller.window!.attachedSheet == nil)
                #expect(await harness.eventually { controller.isClosed })
            }
            for gesture in ["close window", "close tab"] {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                let controller = harness.controller
                let window = controller.window!
                let pid = controller.session.process!.pid
                await harness.run("sleep 30")
                #expect(await harness.eventually { controller.session.process!.hasForegroundJob })
                #expect(harness.shortcut("t"))
                let second = try #require(harness.controllers.last)
                #expect(await harness.waitForPrompt(second))
                if gesture == "close window" {
                    window.performClose(nil)
                } else {
                    controller.windowController!.select(controller)
                    #expect(harness.shortcut("w"))
                }
                let sheet = window.attachedSheet
                #expect(sheet != nil, "\(gesture)")
                #expect(!controller.isClosed && !second.isClosed)
                let alertText = sheet.map { allTexts(in: $0.contentView!) } ?? []
                #expect(alertText.contains { $0.contains("sleep") }, "\(alertText)")

                let terminate = sheet.flatMap { findButton(titled: "Terminate", in: $0.contentView!) }
                #expect(terminate != nil)
                terminate?.performClick(nil)
                #expect(await harness.eventually(timeout: 3) { controller.isClosed })
                #expect(await harness.eventually(timeout: 3) { kill(pid, 0) != 0 })
                if gesture == "close window" {
                    #expect(second.isClosed && harness.windows.isEmpty)
                } else {
                    #expect(!second.isClosed && harness.windows.count == 1)
                    #expect(second.windowController?.selectedTab === second)
                }
            }
            do {
                let fake = FakeOpenRouter()
                let harness = assistantHarness(fake)
                defer { harness.shutDown() }
                _ = await harness.useTemporaryDirectory()
                fake.queue(.agentTask("wait"), .bash("c1", "sleep 30"))
                #expect(await harness.openBar())
                harness.submit("wait a bit")
                #expect(await harness.eventually { harness.agentController != nil })
                let agent = try #require(harness.agentController)
                #expect(await harness.eventually(timeout: 5) { harness.screenLines(agent).contains("$ sleep 30") })
                #expect(agent.windowController?.selectedTab === agent)
                #expect(harness.shortcut("w"))
                let sheet = agent.window!.attachedSheet
                #expect(sheet != nil)
                #expect(!agent.isClosed)
                let alertText = sheet.map { allTexts(in: $0.contentView!) } ?? []
                #expect(alertText.contains { $0.contains("agent") }, "\(alertText)")
                let terminate = sheet.flatMap { findButton(titled: "Terminate", in: $0.contentView!) }
                #expect(terminate != nil)
                terminate?.performClick(nil)
                #expect(await harness.eventually(timeout: 3) { agent.isClosed })
                #expect(!harness.controller.isClosed && harness.windows.count == 1)
                #expect(await groupIsGone(agent.agentTab?.agent?.lastProcessGroup, harness: harness))
            }
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                let tab = harness.controller
                let a = tab.activePane
                let window = try #require(tab.window)
                let b = try #require(await harness.split(.right))
                let pidB = b.session.process!.pid
                await harness.run("sleep 30", in: b)
                #expect(await harness.eventually { b.session.process!.hasForegroundJob })
                #expect(harness.shortcut("w"))
                let sheet = try #require(window.attachedSheet)
                let texts = allTexts(in: sheet.contentView!)
                #expect(texts.contains("Do you want to terminate running processes in this pane?"), "\(texts)")
                #expect(texts.contains("Closing this pane will terminate sleep."), "\(texts)")
                #expect(!a.isClosed && !b.isClosed)
                findButton(titled: "Terminate", in: sheet.contentView!)?.performClick(nil)
                #expect(await harness.eventually(timeout: 3) { b.isClosed && kill(pidB, 0) != 0 })
                #expect(tab.panes.elementsEqual([a], by: ===))
                #expect(harness.frame(of: a) == NSRect(origin: .zero, size: harness.areaSize(tab)))
                #expect(tab.activePane === a)
            }
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                let tab = harness.controller
                let a = tab.activePane
                let window = try #require(tab.window)
                await harness.run("sleep 30")
                #expect(await harness.eventually { a.session.process!.hasForegroundJob })
                let b = try #require(await harness.split(.right))
                let pids = [a, b].map { $0.session.process!.pid }

                window.performClose(nil)
                let windowSheet = try #require(window.attachedSheet)
                var texts = allTexts(in: windowSheet.contentView!)
                #expect(texts.contains("Do you want to terminate running processes in this window?"), "\(texts)")
                #expect(texts.contains("Closing this window will terminate sleep."), "\(texts)")
                findButton(titled: "Cancel", in: windowSheet.contentView!)?.performClick(nil)
                #expect(await harness.eventually { window.attachedSheet == nil })
                #expect(!tab.isClosed && !a.isClosed && !b.isClosed && harness.windows.count == 1)

                harness.clickTab(0, part: .close)
                let tabSheet = try #require(window.attachedSheet)
                texts = allTexts(in: tabSheet.contentView!)
                #expect(texts.contains("Do you want to terminate running processes in this tab?"), "\(texts)")
                #expect(texts.contains("Closing this tab will terminate sleep."), "\(texts)")
                findButton(titled: "Terminate", in: tabSheet.contentView!)?.performClick(nil)
                #expect(await harness.eventually(timeout: 3) { tab.isClosed && harness.windows.isEmpty })
                #expect(await harness.eventually(timeout: 3) { pids.allSatisfy { kill($0, 0) != 0 } })
            }
        }

        @Test("APP-WINDOW-008 quitting asks first when a program runs in any pane then hangs up every shell")
        func APP_WINDOW_008() async throws {
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                #expect(harness.delegate.applicationShouldTerminate(NSApp) == .terminateNow)
                #expect(harness.alerts.run.isEmpty)
            }
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let a = harness.controller.activePane
            await harness.run("sleep 30")
            #expect(await harness.eventually { a.session.process!.hasForegroundJob })
            let b = try #require(await harness.split(.right))
            #expect(harness.shortcut("t"))
            let second = try #require(harness.controllers.last)
            #expect(await harness.waitForPrompt(second))

            harness.alerts.responses = [.alertSecondButtonReturn]
            #expect(harness.delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
            #expect(harness.alerts.run.count == 1)
            let alert = try #require(harness.alerts.run.first)
            #expect(alert.messageText == "Quit ATerm?")
            #expect(alert.informativeText == "A program is still running in one tab.")
            #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])

            harness.alerts.responses = [.alertFirstButtonReturn]
            #expect(harness.delegate.applicationShouldTerminate(NSApp) == .terminateNow)

            let pids = [a, b, second.activePane].map { $0.session.process!.pid }
            harness.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            #expect(await harness.eventually(timeout: 3) { pids.allSatisfy { kill($0, 0) != 0 } })
        }

        @Test("APP-WINDOW-007 the dock menu opens a new window", arguments: ["with a window", "after closing it"])
        func APP_WINDOW_007(start: String) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            if start == "after closing it" {
                harness.controller.window?.performClose(nil)
                #expect(await harness.eventually { harness.windows.isEmpty })
            }
            let before = harness.windows.count
            let menu = try #require(harness.delegate.applicationDockMenu(NSApp))
            let item = try #require(menu.items.first { $0.title == "New Window" })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            #expect(harness.windows.count == before + 1)
            let opened = try #require(harness.windows.last)
            #expect(harness.delegate.activeController === opened)
            let tab = try #require(opened.selectedTab)
            #expect(await harness.waitForPrompt(tab))
        }
    }
}

/// The command line of a process, as `ps -o args=` shows it.
func processArguments(_ pid: pid_t) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "args=", "-p", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
func findButton(titled title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for subview in view.subviews {
        if let button = findButton(titled: title, in: subview) { return button }
    }
    return nil
}

@MainActor
func allTexts(in view: NSView) -> [String] {
    var texts: [String] = []
    if let field = view as? NSTextField { texts.append(field.stringValue) }
    for subview in view.subviews { texts += allTexts(in: subview) }
    return texts
}
