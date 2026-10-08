import AppKit
import Testing
@testable import ATermApp
import ATermCore

extension E2E {
    @Suite @MainActor struct Rendering {
        /// Runs a command at the prompt and returns the output row once `ready` holds.
        func output(_ harness: AppHarness, _ command: String, ready: @escaping (Terminal, Int) -> Bool) async -> Int {
            #expect(await harness.waitForPrompt())
            let row = await harness.run(command) + 1
            let terminal = harness.controller.session.terminal
            #expect(await harness.eventually { ready(terminal, row) })
            #expect(await harness.waitForPrompt())
            return row
        }

        @Test("APP-RENDER-001 cell backgrounds use the palette direct colors and inverse video")
        func APP_RENDER_001() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            let row = await output(harness, "printf '\\033[41m  \\033[44m  \\033[48;2;10;200;30m  \\033[7m  \\033[0m\\n'") {
                $0.line($1).cells[7].attributes.flags.contains(.inverse)
            }
            let rendered = harness.render()
            let expected: [(Int, RGB)] = [
                (0, RGB(229, 100, 106)), (1, RGB(229, 100, 106)), (2, RGB(108, 164, 236)), (3, RGB(108, 164, 236)),
                (4, RGB(10, 200, 30)), (5, RGB(10, 200, 30)), (6, RGB(217, 219, 227)), (7, RGB(217, 219, 227)),
                (9, backgroundColor),
            ]
            for (col, color) in expected {
                let actual = rendered.cellCenter(row: row, col: col)
                #expect(actual.matches(color), "cell \(col): \(actual) instead of \(color)")
            }
        }

        @Test("APP-RENDER-002 glyphs use their foreground color dimmed when faint")
        func APP_RENDER_002() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            let row = await output(harness, "printf '\\033[32m\\342\\226\\210\\033[0m \\033[2;32m\\342\\226\\210\\033[0m\\n'") {
                $0.line($1).cells[2].scalar == "█"
            }
            let rendered = harness.render()
            let full = rendered.cellCenter(row: row, col: 0)
            let dim = rendered.cellCenter(row: row, col: 2)
            #expect(full.matches(RGB(140, 203, 126)), "\(full)")
            #expect(dim.matches(RGB(85, 117, 82)), "\(dim)")
        }

        @Test("APP-RENDER-003 the cursor is a filled block when focused an outline otherwise and can be hidden")
        func APP_RENDER_003() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            var cursor = terminal.cursorPosition

            harness.reportKey(true)
            let focused = harness.render().cellCenter(row: cursor.row, col: cursor.col)
            #expect(focused.matches(cursorColor), "\(focused)")

            harness.reportKey(false)
            let unfocused = harness.render()
            #expect(unfocused.cellCorner(row: cursor.row, col: cursor.col).matches(cursorColor))
            #expect(unfocused.cellCenter(row: cursor.row, col: cursor.col).matches(backgroundColor))

            await harness.run("printf '\\033[?25l'")
            #expect(await harness.eventually { !terminal.cursorVisible })
            #expect(await harness.waitForPrompt())
            cursor = terminal.cursorPosition
            #expect(harness.render().cellCorner(row: cursor.row, col: cursor.col).matches(backgroundColor))
        }

        @Test("APP-RENDER-004 wide characters and emoji are drawn across two cells", arguments: [
            "\\344\\270\\255", "\\360\\237\\230\\200",
        ])
        func APP_RENDER_004(bytes: String) async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            let row = await output(harness, "printf '\(bytes)\\n'") { $0.line($1).cells[0].width == 2 }
            let rendered = harness.render()
            let left = rendered.pixels(row: row, col: 0)
            let right = rendered.pixels(row: row, col: 1)
            #expect(left.contains { !$0.matches(backgroundColor) })
            #expect(right.contains { !$0.matches(backgroundColor) })
            #expect(rendered.pixels(row: row, col: 2).allSatisfy { $0.matches(backgroundColor) })
            if bytes.hasPrefix("\\360") {
                #expect((left + right).contains { !$0.matches(backgroundColor) && !$0.isGray })
            }
        }

        @Test("APP-RENDER-006 box-drawing lines and block elements fill their cells exactly")
        func APP_RENDER_006() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            let first = await output(harness, "printf '\\342\\224\\202\\n\\342\\224\\202\\n\\342\\226\\210\\342\\226\\200\\342\\224\\274\\n'") {
                $0.line($1 + 2).cells[2].scalar == "┼"
            }
            let foreground = RGB(217, 219, 227)
            let rendered = harness.render()
            let view = harness.controller.terminalView
            let onePixel = 1 / rendered.scale
            for row in [first, first + 1] {
                let rect = view.cellRect(row: row, col: 0)
                let top = rendered.color(at: NSPoint(x: rect.midX, y: rect.minY + onePixel / 2))
                let bottom = rendered.color(at: NSPoint(x: rect.midX, y: rect.maxY - onePixel / 2))
                #expect(top.matches(foreground), "row \(row) top \(top)")
                #expect(bottom.matches(foreground), "row \(row) bottom \(bottom)")
            }
            let blocks = first + 2
            #expect(rendered.pixels(row: blocks, col: 0).allSatisfy { $0.matches(foreground) })
            #expect(rendered.pixels(row: blocks, col: 1, from: 0, to: 0.5).allSatisfy { $0.matches(foreground) })
            #expect(rendered.pixels(row: blocks, col: 1, from: 0.5, to: 1).allSatisfy { $0.matches(backgroundColor) })
            let cross = view.cellRect(row: blocks, col: 2)
            let edges = [
                NSPoint(x: cross.midX, y: cross.minY + onePixel / 2), NSPoint(x: cross.midX, y: cross.maxY - onePixel / 2),
                NSPoint(x: cross.minX + onePixel / 2, y: cross.midY), NSPoint(x: cross.maxX - onePixel / 2, y: cross.midY),
            ]
            for point in edges {
                #expect(rendered.color(at: point).matches(foreground), "cross edge \(point)")
            }
        }

        @Test("APP-RENDER-005 underline and strikethrough are drawn in the foreground color")
        func APP_RENDER_005() async throws {
            let harness = AppHarness()
            defer { harness.shutDown() }
            let row = await output(harness, "printf '\\033[4;31m \\033[0m \\033[9;31m \\033[0m\\n'") {
                $0.line($1).cells[2].attributes.flags.contains(.strikethrough)
            }
            let red = RGB(229, 100, 106)
            let rendered = harness.render()
            #expect(rendered.pixels(row: row, col: 0, from: 0.75, to: 1).contains { $0.matches(red, tolerance: 12) })
            #expect(rendered.pixels(row: row, col: 0, from: 0, to: 0.5).allSatisfy { $0.matches(backgroundColor) })
            #expect(rendered.pixels(row: row, col: 2, from: 0.25, to: 0.75).contains { $0.matches(red, tolerance: 12) })
            #expect(rendered.pixels(row: row, col: 2, from: 0, to: 0.25).allSatisfy { $0.matches(backgroundColor) })
            #expect(rendered.pixels(row: row, col: 2, from: 0.75, to: 1).allSatisfy { $0.matches(backgroundColor) })
        }
    }
}
