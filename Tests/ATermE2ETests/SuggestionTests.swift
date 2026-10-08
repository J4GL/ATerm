import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

private let grey = RGB(95, 98, 112)
private let foreground = RGB(217, 219, 227)

extension E2E {
    @Suite @MainActor struct Suggestions {
        @Test("APP-SUGGEST-001 typing the start of a command from the history shows its end in grey",
              arguments: ["history file", "this session"])
        func APP_SUGGEST_001(source: String) async throws {
            let history = source == "history file" ? ["git status --short", "git stash list"] : []
            let harness = AppHarness(configuration: AppHarness.zshFixture(history: history))
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            if source == "this session" {
                let row = await harness.run("echo first-run")
                #expect(await harness.eventually { harness.screenLines()[row + 1] == "first-run" })
                #expect(await harness.waitForPrompt())
                harness.type("echo f")
                #expect(await harness.eventually {
                    harness.cursorRow.text == "$ echo first-run" && terminal.cursorPosition.col == 8
                }, "\(harness.cursorRow.text)")
                let row2 = harness.cursorRow.row
                #expect(harness.foregrounds(row: row2, 8..<16).allSatisfy { $0 == .indexed(8) })
                return
            }

            harness.type("git st")
            #expect(await harness.eventually {
                harness.cursorRow.text == "$ git stash list" && terminal.cursorPosition.col == 8
            }, "\(harness.cursorRow.text) \(terminal.cursorPosition)")
            let row = harness.cursorRow.row
            #expect(harness.foregrounds(row: row, 2..<8).allSatisfy { $0 == .default })
            #expect(harness.foregrounds(row: row, 8..<16).allSatisfy { $0 == .indexed(8) },
                    "\(harness.foregrounds(row: row, 8..<16))")
            let pixels = harness.render().pixels(row: row, col: 8)
            #expect(pixels.contains { $0.matches(grey, tolerance: 12) })
            #expect(!pixels.contains { $0.matches(foreground, tolerance: 12) })

            harness.type("at")
            #expect(await harness.eventually {
                harness.cursorRow.text == "$ git status --short" && terminal.cursorPosition.col == 10
            }, "\(harness.cursorRow.text) \(terminal.cursorPosition)")
            #expect(harness.foregrounds(row: row, 10..<20).allSatisfy { $0 == .indexed(8) })

            harness.type("x")
            #expect(await harness.eventually {
                harness.cursorRow.text == "$ git statx" && terminal.cursorPosition.col == 11
            }, "\(harness.cursorRow.text) \(terminal.cursorPosition)")
        }

        enum AcceptCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case optionRightThenRight, end, controlE, leftThenRight
            var testDescription: String { rawValue }
        }

        @Test("APP-SUGGEST-002 right arrow end and control-e accept the suggestion at the end of the line option-right arrow one word",
              arguments: AcceptCase.allCases)
        func APP_SUGGEST_002(acceptCase: AcceptCase) async throws {
            let harness = AppHarness(configuration: AppHarness.zshFixture(history: ["echo alpha beta gamma"]))
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let terminal = harness.controller.session.terminal
            harness.type("echo a")
            #expect(await harness.eventually {
                harness.cursorRow.text == "$ echo alpha beta gamma" && terminal.cursorPosition.col == 8
            }, "\(harness.cursorRow.text)")
            let row = harness.cursorRow.row

            func acceptedWhole() async -> Bool {
                await harness.eventually {
                    terminal.cursorPosition.col == 23 && harness.cursorRow.text == "$ echo alpha beta gamma"
                        && harness.foregrounds(row: row, 2..<23).allSatisfy { $0 == .default }
                }
            }

            switch acceptCase {
            case .optionRightThenRight:
                harness.press(.right, modifiers: .option)
                #expect(await harness.eventually { terminal.cursorPosition.col == 13 }, "\(terminal.cursorPosition)")
                #expect(harness.foregrounds(row: row, 2..<13).allSatisfy { $0 == .default })
                #expect(harness.foregrounds(row: row, 13..<23).allSatisfy { $0 == .indexed(8) })
                harness.press(.right)
                #expect(await acceptedWhole(), "\(harness.foregrounds(row: row, 2..<23))")
                harness.press(.returnKey)
                #expect(await harness.eventually { harness.screenLines()[row + 1] == "alpha beta gamma" })
            case .end:
                harness.press(.end)
                #expect(await acceptedWhole(), "\(harness.foregrounds(row: row, 2..<23))")
            case .controlE:
                harness.pressControl("e")
                #expect(await acceptedWhole(), "\(harness.foregrounds(row: row, 2..<23))")
            case .leftThenRight:
                harness.press(.left)
                #expect(await harness.eventually { terminal.cursorPosition.col == 7 })
                harness.press(.right)
                #expect(await harness.eventually { terminal.cursorPosition.col == 8 })
                await harness.pause(0.2)
                #expect(harness.cursorRow.text == "$ echo alpha beta gamma")
                #expect(harness.foregrounds(row: row, 8..<23).allSatisfy { $0 == .indexed(8) })
            }
        }

        @Test("APP-SUGGEST-003 return and control-c leave no grey text behind", arguments: ["Return", "⌃C"])
        func APP_SUGGEST_003(key: String) async throws {
            let harness = AppHarness(configuration: AppHarness.zshFixture(history: ["echo hello-ghost"]))
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            harness.type("ech")
            #expect(await harness.eventually {
                harness.cursorRow.text == "$ echo hello-ghost" && harness.controller.session.terminal.cursorPosition.col == 5
            }, "\(harness.cursorRow.text)")
            let row = harness.cursorRow.row
            if key == "Return" {
                harness.press(.returnKey)
                #expect(await harness.eventually { harness.screenLines()[row + 1] == "zsh: command not found: ech" },
                        "\(harness.screenLines())")
            } else {
                harness.pressControl("c")
                #expect(await harness.eventually { harness.cursorRow.row == row + 1 && harness.cursorRow.text == "$" },
                        "\(harness.screenLines())")
            }
            #expect(harness.screenLines()[row] == "$ ech")
        }

        @Test("APP-SUGGEST-004 with autosuggestions off zsh starts without the integration")
        func APP_SUGGEST_004() async throws {
            let suite = "ATermTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(AppConfiguration.standard(defaults: defaults).autosuggestions)
            defaults.set(false, forKey: "Autosuggestions")
            var configuration = AppHarness.zshFixture(history: ["git status"])
            configuration.autosuggestions = AppConfiguration.standard(defaults: defaults).autosuggestions
            let zdotdir = try #require(configuration.environment["ZDOTDIR"])
            let harness = AppHarness(configuration: configuration)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            await harness.run("print -r -- $ZDOTDIR")
            #expect(await harness.eventually { harness.logicalLines().contains(zdotdir) }, "\(harness.logicalLines())")
            #expect(await harness.waitForPrompt())
            harness.type("git s")
            #expect(await harness.eventually { harness.cursorRow.text == "$ git s" })
            await harness.pause(0.3)
            #expect(harness.cursorRow.text == "$ git s")
        }

        @Test("APP-SUGGEST-005 when the history has nothing the model's completion is shown after a pause",
              arguments: ["completion", "secret"])
        func APP_SUGGEST_005(scenario: String) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantZshHarness(fake, history: ["echo unrelated"])
            defer { harness.shutDown() }
            let directory = await harness.useTemporaryDirectory()
            let terminal = harness.controller.session.terminal
            if scenario == "secret" {
                let line = "API_TOKEN=s3cr3t-value-9876 ./deploy"
                fake.queue(.completion("API_TOKEN=<API_TOKEN_1:17chars> ./deploy --prod"))
                harness.type(line)
                #expect(await harness.eventually(timeout: 4) {
                    harness.cursorRow.text == "$ \(line) --prod"
                }, "\(harness.cursorRow.text)")
                let request = try #require(fake.chatRequests.first)
                #expect(fake.chatRequests.count == 1)
                #expect(request.content(1) == "API_TOKEN=<API_TOKEN_1:17chars> ./deploy")
                #expect(!request.bodyText.contains("s3cr3t-value-9876"))
                let row = harness.cursorRow.row
                let end = 2 + line.count
                #expect(harness.foregrounds(row: row, end..<(end + 7)).allSatisfy { $0 == .indexed(8) })
                return
            }

            fake.queue(.completion("ffmpeg -i in.mov out.mp4"))
            harness.type("ffmpeg -i")
            #expect(await harness.eventually { harness.cursorRow.text == "$ ffmpeg -i" })
            await harness.pause(0.5)
            #expect(fake.chatRequests.isEmpty)
            #expect(await harness.eventually(timeout: 3) { harness.cursorRow.text == "$ ffmpeg -i in.mov out.mp4" },
                    "\(harness.cursorRow.text)")
            await harness.pause(0.3)
            let request = try #require(fake.chatRequests.first)
            #expect(fake.chatRequests.count == 1)
            #expect(request.isCompletion)
            #expect(request.json["model"] as? String == OpenRouterClient.defaultModel)
            #expect(request.json["temperature"] as? Double == 0)
            let system = request.content(0)
            #expect(system.hasPrefix(AgentPrompts.completer + "\n\n<environment>"))
            #expect(system.contains("cwd: \(directory)"))
            #expect(request.content(1) == "ffmpeg -i")
            let row = harness.cursorRow.row
            #expect(terminal.cursorPosition.col == 11)
            #expect(harness.foregrounds(row: row, 11..<26).allSatisfy { $0 == .indexed(8) })

            harness.press(.right)
            #expect(await harness.eventually {
                terminal.cursorPosition.col == 26 && harness.foregrounds(row: row, 2..<26).allSatisfy { $0 == .default }
            })
            #expect(harness.cursorRow.text == "$ ffmpeg -i in.mov out.mp4")
        }

        enum SilentCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case historyMatches, returnPressed, shortLine, completionsOff, noKey, afterFailure
            var testDescription: String { rawValue }
        }

        @Test("APP-SUGGEST-006 no completion is requested when it cannot help or is not allowed",
              arguments: SilentCase.allCases)
        func APP_SUGGEST_006(silentCase: SilentCase) async throws {
            let fake = FakeOpenRouter()
            let history = silentCase == .historyMatches ? ["ffmpeg -i a.mov"] : []
            let keyStore = MemoryAPIKeyStore(key: silentCase == .noKey ? nil : "test-key")
            let harness = assistantZshHarness(fake, history: history, keyStore: keyStore) { configuration in
                if silentCase == .completionsOff { configuration.assistant.commandCompletions = false }
            }
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            switch silentCase {
            case .historyMatches:
                harness.type("ffmpeg -i")
                #expect(await harness.eventually { harness.cursorRow.text == "$ ffmpeg -i a.mov" })
                #expect(harness.foregrounds(row: harness.cursorRow.row, 11..<17).allSatisfy { $0 == .indexed(8) })
            case .returnPressed:
                harness.type("ffmpeg -i")
                await harness.pause(0.2)
                harness.press(.returnKey)
            case .shortLine:
                harness.type("ls")
            case .completionsOff, .noKey:
                harness.type("ffmpeg -i")
            case .afterFailure:
                fake.queue(.status(429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#))
                harness.type("ffmpeg -i")
                #expect(await harness.eventually(timeout: 3) { fake.chatRequests.count == 1 })
                await harness.pause(0.3)
                harness.pressControl("u")
                harness.type("ffprobe -v")
                await harness.pause(2)
                #expect(fake.chatRequests.count == 1)
                return
            }
            await harness.pause(2)
            #expect(fake.chatRequests.isEmpty, "\(fake.chatRequests.map(\.bodyText))")
        }
    }
}
