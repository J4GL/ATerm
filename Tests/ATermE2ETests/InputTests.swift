import AppKit
import Testing
@testable import ATermApp
import ATermCore

extension E2E {
    @Suite @MainActor struct Input {
        /// Starts `command` (usually ending with `cat -v`) and waits until it runs.
        func start(_ harness: AppHarness, _ command: String) async {
            #expect(await harness.waitForPrompt())
            await harness.run(command)
            #expect(await harness.eventually { harness.controller.session.process!.hasForegroundJob })
        }

        @Test("APP-INPUT-001 special keys and modifiers reach programs encoded")
        func APP_INPUT_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            await start(harness, "cat -v")
            harness.press(.up)
            harness.press(.left, modifiers: .option)
            harness.pressControl("a")
            harness.press(.f5)
            harness.press(.returnKey)
            #expect(await harness.eventually { harness.row("^[[A^[b^A^[[15~") != nil })

            // Control + keypad Clear: a function key without terminal encoding sends nothing.
            let window = harness.controller.window!
            window.sendEvent(harness.keyEvent(characters: "\u{F739}", keyCode: 71, modifiers: .control, window: window))
            harness.type("x")
            harness.press(.returnKey)
            #expect(await harness.eventually { harness.row("x") != nil })
        }

        @Test("APP-INPUT-002 composed text from dead keys and input methods is sent once committed")
        func APP_INPUT_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let view = harness.controller.terminalView
            let terminal = harness.controller.session.terminal
            harness.type("echo ")
            #expect(await harness.eventually { terminal.text(row: terminal.cursorPosition.row) == "$ echo" })
            let cursor = terminal.cursorPosition

            view.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(view.hasMarkedText())
            let foreground = RGB(217, 219, 227)
            #expect(harness.render().pixels(row: cursor.row, col: cursor.col, from: 0.8, to: 1)
                .contains { $0.matches(foreground, tolerance: 12) })
            await harness.pause(0.3)
            #expect(terminal.text(row: cursor.row) == "$ echo")

            view.insertText("ê", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!view.hasMarkedText())
            harness.press(.returnKey)
            #expect(await harness.eventually { terminal.text(row: cursor.row + 1) == "ê" })
        }

        @Test("APP-INPUT-003 paste sends the pasteboard text bracketed when requested")
        func APP_INPUT_003() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            await start(harness, "printf '\\033[?2004h'; cat -v")
            harness.pasteboard.clearContents()
            harness.pasteboard.setString("a\nb", forType: .string)
            harness.controller.terminalView.paste(nil)
            harness.press(.returnKey)
            #expect(await harness.eventually { harness.row("^[[200~a") != nil && harness.row("b^[[201~") != nil })
        }

        enum MouseCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case click = "reported click"
            case shiftClick = "shift click is not reported"
            case shiftDragAfterReportedClick = "shift drag starts a new selection"

            var testDescription: String { rawValue }
        }

        @Test("APP-INPUT-004 mouse clicks are reported to programs that ask unless shift is held",
              arguments: MouseCase.allCases)
        func APP_INPUT_004(_ mouseCase: MouseCase) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            switch mouseCase {
            case .click, .shiftClick:
                await start(harness, "printf '\\033[?1000h\\033[?1006h'; cat -v")
                #expect(await harness.eventually { harness.controller.session.terminal.modes.mouseTracking == .normal })
                harness.click(row: 5, col: 10, modifiers: mouseCase == .shiftClick ? .shift : [])
                harness.press(.returnKey)
                if mouseCase == .shiftClick {
                    await harness.pause(0.5)
                    #expect(!harness.screenContains("^[[<"))
                } else {
                    #expect(await harness.eventually { harness.row("^[[<0;11;6M^[[<0;11;6m") != nil })
                }
            case .shiftDragAfterReportedClick:
                #expect(await harness.waitForPrompt())
                let command = await harness.run("echo alpha; echo delta")
                let alpha = command + 1
                let delta = command + 2
                #expect(await harness.eventually { harness.screenLines()[delta] == "delta" })
                await start(harness, "printf '\\033[?1000h'; cat")
                #expect(await harness.eventually { harness.controller.session.terminal.modes.mouseTracking == .normal })
                let view = harness.controller.terminalView
                func shiftDrag(_ row: Int) {
                    view.mouseDown(with: harness.mouseEvent(.leftMouseDown, row: row, col: 0, modifiers: .shift))
                    view.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, row: row, col: 4, modifiers: .shift))
                    view.mouseUp(with: harness.mouseEvent(.leftMouseUp, row: row, col: 4, modifiers: .shift))
                }
                shiftDrag(alpha)
                harness.click(row: alpha, col: 0)
                shiftDrag(delta)
                view.copy(nil)
                #expect(harness.pasteboard.string(forType: .string) == "delta")
            }
        }

        @Test("APP-INPUT-005 focus changes are reported to programs that ask")
        func APP_INPUT_005() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            harness.reportKey(true)
            await start(harness, "printf '\\033[?1004h'; cat -v")
            #expect(await harness.eventually { harness.controller.session.terminal.modes.focusReporting })
            harness.reportKey(false)
            harness.reportKey(true)
            harness.press(.returnKey)
            #expect(await harness.eventually { harness.row("^[[O^[[I") != nil })
        }
    }
}
