import AppKit
import Testing
@testable import ATermApp
import ATermCore

extension E2E {
    @Suite @MainActor struct ScrollSelection {
        func displayedRows(_ view: TerminalView) -> [String] {
            (0..<view.terminal.rows).map { view.displayedLine($0).text }
        }

        @Test("APP-SCROLL-001 the wheel scrolls through the scrollback typing returns to the bottom")
        func APP_SCROLL_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let view = harness.controller.terminalView
            let terminal = harness.controller.session.terminal
            await harness.run("seq 1 100; sleep 1; echo tick")
            #expect(await harness.eventually { harness.row("100") != nil })

            let before = harness.render()
            harness.scrollWheel(lines: 5)
            let expectedTop = terminal.line(absolute: terminal.firstScreenLineIndex - 5)?.text
            #expect(view.displayedLine(0).text == expectedTop)
            let scrolled = displayedRows(view)
            #expect(before.pixels(row: 0, col: 0) != harness.render().pixels(row: 0, col: 0)
                || before.pixels(row: 0, col: 1) != harness.render().pixels(row: 0, col: 1))

            #expect(await harness.eventually(timeout: 3) { harness.row("tick") != nil })
            #expect(displayedRows(view) == scrolled)

            harness.type("x")
            #expect(await harness.eventually { displayedRows(view) == terminal.screenLines })
        }

        @Test("APP-SCROLL-002 in the alternate screen the wheel sends cursor keys")
        func APP_SCROLL_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            await harness.run("printf '\\033[?1049h'; cat -v")
            let terminal = harness.controller.session.terminal
            #expect(await harness.eventually { terminal.isAlternateScreenActive && harness.controller.session.process!.hasForegroundJob })
            harness.scrollWheel(lines: 3)
            harness.press(.returnKey)
            #expect(await harness.eventually { harness.row("^[[A^[[A^[[A") != nil })
        }

        @Test("APP-SCROLL-003 page up and page down scroll the scrollback on the main screen")
        func APP_SCROLL_003() async throws {
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                let view = harness.controller.terminalView
                let terminal = harness.controller.session.terminal
                await harness.run("seq 1 100")
                #expect(await harness.eventually { harness.row("100") != nil })
                #expect(await harness.waitForPrompt())
                harness.press(.pageUp)
                #expect(view.displayedLine(0).text == terminal.line(absolute: terminal.firstScreenLineIndex - 24)?.text)
                harness.press(.pageDown)
                #expect(displayedRows(view) == terminal.screenLines)
            }
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                await harness.run("cat -v")
                #expect(await harness.eventually { harness.controller.session.process!.hasForegroundJob })
                harness.press(.pageUp, modifiers: .shift)
                harness.press(.returnKey)
                #expect(await harness.eventually { harness.row("^[[5;2~") != nil })
            }
            do {
                let harness = AppHarness()
                defer { harness.shutDown() }
                #expect(await harness.waitForPrompt())
                await harness.run("printf '\\033[?1049h'; cat -v")
                #expect(await harness.eventually {
                    harness.controller.session.terminal.isAlternateScreenActive
                        && harness.controller.session.process!.hasForegroundJob
                })
                harness.press(.pageUp)
                harness.press(.returnKey)
                #expect(await harness.eventually { harness.row("^[[5~") != nil })
            }
        }

        @Test("APP-SELECT-001 dragging selects text highlighted and copy puts it on the pasteboard")
        func APP_SELECT_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let row = await harness.run("echo hello world") + 1
            #expect(await harness.eventually { harness.screenLines()[row] == "hello world" })
            #expect(await harness.waitForPrompt())

            harness.drag(from: (row, 0), to: (row, 4))
            let rendered = harness.render()
            for col in 0...4 {
                #expect(rendered.cellCorner(row: row, col: col).matches(selectionColor), "cell \(col)")
            }
            #expect(rendered.cellCorner(row: row, col: 6).matches(backgroundColor))

            harness.controller.terminalView.copy(nil)
            #expect(harness.pasteboard.string(forType: .string) == "hello")
        }

        @Test("APP-SELECT-002 double click selects a word triple click a line")
        func APP_SELECT_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let row = await harness.run("echo hello world") + 1
            #expect(await harness.eventually { harness.screenLines()[row] == "hello world" })
            let view = harness.controller.terminalView

            harness.click(row: row, col: 8, count: 2)
            view.copy(nil)
            #expect(harness.pasteboard.string(forType: .string) == "world")

            harness.click(row: row, col: 2, count: 3)
            view.copy(nil)
            #expect(harness.pasteboard.string(forType: .string) == "hello world")
        }
    }
}
