import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

/// A harness of the assistant fixture. See SPEC/app/assistant.md.
@MainActor
func assistantHarness(_ fake: FakeOpenRouter, keyStore: APIKeyStore = MemoryAPIKeyStore(key: "test-key"),
                      environment: [String: String] = [:]) -> AppHarness {
    var configuration = AppHarness.fixture()
    configuration.environment.merge(environment) { $1 }
    configuration.assistant = fake.assistantConfiguration(keyStore: keyStore, loginEnvironment: environment)
    let harness = AppHarness(configuration: configuration)
    harness.reportKey(true)
    return harness
}

@MainActor
extension AssistantBar {
    /// The bar's text field has the keyboard.
    var fieldHasFocus: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    var keyFieldHasFocus: Bool {
        guard let editor = keyField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }
}

/// True once the group of the agent's last command is known and no process is left in it.
@MainActor
func groupIsGone(_ group: @autoclosure () -> pid_t?, harness: AppHarness) async -> Bool {
    await harness.eventually(timeout: 3) {
        guard let group = group() else { return false }
        return kill(-group, 0) != 0 && errno == ESRCH
    }
}

extension E2E {
    @Suite @MainActor struct Assistant {
        enum HoldCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case holdAndRelease, tap, chord, click, menu

            var testDescription: String { rawValue }
        }

        @Test("APP-ASSIST-001 holding command alone opens the assistant bar", arguments: HoldCase.allCases)
        func APP_ASSIST_001(_ holdCase: HoldCase) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let controller = harness.controller
            let bar = controller.assistant.bar
            let start = harness.now
            switch holdCase {
            case .holdAndRelease:
                harness.commandDown(at: start)
                await harness.pause(0.5)
                #expect(bar.mode == .hint)
                #expect(bar.hintLabel.stringValue == "Release ⌘ to ask")
                harness.commandUp(at: start + 0.6)
                #expect(bar.mode == .prompt)
                #expect(bar.field.stringValue.isEmpty)
                #expect(bar.fieldHasFocus)
                #expect(!controller.terminalView.isFocused)
            case .tap:
                harness.commandDown(at: start)
                harness.commandUp(at: start + 0.1)
                await harness.pause(0.5)
                #expect(bar.mode == .hidden)
                #expect(controller.window?.firstResponder === controller.terminalView)
            case .chord:
                harness.commandDown(at: start)
                await harness.pause(0.5)
                #expect(bar.mode == .hint)
                harness.chord("c")
                #expect(bar.mode == .hidden)
                harness.commandUp(at: start + 0.8)
                #expect(bar.mode == .hidden)
            case .click:
                harness.commandDown(at: start)
                await harness.pause(0.5)
                #expect(bar.mode == .hint)
                harness.click(row: 0, col: 0)
                #expect(bar.mode == .hidden)
                harness.commandUp(at: start + 0.8)
                #expect(bar.mode == .hidden)
            case .menu:
                #expect(harness.chooseMenuItem("Ask…"))
                #expect(bar.mode == .prompt)
                #expect(bar.fieldHasFocus)
            }
        }

        @Test("APP-ASSIST-002 esc closes the bar and gives the keyboard back to the shell")
        func APP_ASSIST_002() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let controller = harness.controller
            #expect(await harness.openBar())
            harness.type("abc")
            #expect(controller.assistant.bar.field.stringValue == "abc")
            harness.press(.escape)
            #expect(controller.assistant.bar.mode == .hidden)
            #expect(controller.window?.firstResponder === controller.terminalView)
            await harness.run("echo back")
            #expect(await harness.eventually { harness.row("back") != nil })
        }

        enum SuggestionCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case runSecond, insertFirst, halfTypedLine, busyTab, fullScreen

            var testDescription: String { rawValue }
        }

        @Test("APP-ASSIST-003 suggested commands run or are inserted in the current tab",
              arguments: SuggestionCase.allCases)
        func APP_ASSIST_003(_ suggestionCase: SuggestionCase) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            _ = await harness.useTemporaryDirectory()
            let controller = harness.controller
            let terminal = controller.session.terminal
            let bar = controller.assistant.bar
            fake.queue(.commands([("echo first-choice", "First"), ("echo second-choice", "Second")]))

            if suggestionCase == .halfTypedLine {
                harness.type("abc")
                #expect(await harness.eventually { terminal.text(row: terminal.cursorPosition.row).hasSuffix("abc") })
            }
            if suggestionCase == .busyTab {
                await harness.run("sleep 3")
                #expect(await harness.eventually { controller.session.hasRunningJob })
            }
            if suggestionCase == .fullScreen {
                await harness.run("less /etc/hosts")
                #expect(await harness.eventually { terminal.isAlternateScreenActive })
            }
            #expect(await harness.openBar())
            harness.submit("say it")
            #expect(await harness.eventually { bar.mode == .suggestions })
            #expect(fake.requests.count == 1)
            #expect(fake.requests.first?.messages.last?["content"] as? String == "say it")
            #expect(bar.suggestions.map(\.command) == ["echo first-choice", "echo second-choice"])
            #expect(bar.suggestions.map(\.explanation) == ["First", "Second"])
            #expect(bar.selectedIndex == 0)

            switch suggestionCase {
            case .runSecond:
                harness.press(.down)
                #expect(bar.selectedIndex == 1)
                harness.press(.returnKey)
                #expect(bar.mode == .hidden)
                #expect(controller.window?.firstResponder === controller.terminalView)
                #expect(await harness.eventually {
                    guard let row = harness.row("$ echo second-choice") else { return false }
                    return harness.screenLines().dropFirst(row + 1).first == "second-choice"
                })
            case .insertFirst:
                harness.press(.returnKey, modifiers: .option)
                #expect(await harness.eventually {
                    terminal.text(row: terminal.cursorPosition.row) == "$ echo first-choice"
                })
                await harness.pause(0.5)
                #expect(!harness.screenLines().contains("first-choice"))
            case .halfTypedLine:
                harness.press(.returnKey)
                #expect(await harness.eventually {
                    guard let row = harness.row("$ echo first-choice") else { return false }
                    return harness.screenLines().dropFirst(row + 1).first == "first-choice"
                })
                #expect(!harness.screenLines().contains { $0.contains("abc") })
            case .busyTab:
                harness.press(.returnKey)
                #expect(bar.statusText == "Inserted without running: a program is running in this tab.")
                let inserted = await harness.eventually(timeout: 6) {
                    !controller.session.hasRunningJob
                        && terminal.text(row: terminal.cursorPosition.row).hasSuffix("$ echo first-choice")
                }
                #expect(inserted, "\(harness.screenLines())")
                await harness.pause(0.5)
                #expect(!harness.screenLines().contains("first-choice"))
            case .fullScreen:
                harness.press(.returnKey)
                #expect(bar.statusText == "Copied: a full-screen program is running in this tab.")
                #expect(harness.pasteboard.string(forType: .string) == "echo first-choice")
                harness.press(.escape)
                harness.type("q")
                #expect(await harness.eventually { !terminal.isAlternateScreenActive })
                #expect(await harness.waitForPrompt())
                #expect(!harness.screenLines().contains { $0.contains("first-choice") })
            }
        }

        @Test("APP-ASSIST-004 an agent task runs in a new read-only tab that shows its work")
        func APP_ASSIST_004() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            let directory = await harness.useTemporaryDirectory()
            let command = #"echo a; sleep 1; echo b; printf hello > proof.txt; printf '\033]0;evil\007\033[6n'"#
            fake.queue(.agentTask("proof.txt contains hello"), .bash("c1", command, text: "I'll create it.\u{1B}]0;evil2\u{07}\u{1B}]10;#1e1f26\u{07}"),
                       .agentText("Created.\nGOAL MET"))
            #expect(await harness.openBar())
            harness.submit("make proof")

            #expect(await harness.eventually { harness.agentController != nil })
            let agent = try #require(harness.agentController)
            #expect(harness.controller.assistant.bar.mode == .hidden)
            #expect(harness.windows.count == 1 && agent.window === harness.controller.window)
            #expect(harness.windows.first?.selectedTab === agent)
            var sawAWithoutB = false
            #expect(await harness.eventually(timeout: 10) {
                let lines = harness.screenLines(agent)
                if lines.contains("a") && !lines.contains("b") { sawAWithoutB = true }
                return lines.contains { $0.contains("✓ Goal met") }
            })
            #expect(sawAWithoutB)
            let transcript = harness.logicalLines(agent)
            let inOrder = harness.showsInOrder(["◎ Goal: proof.txt contains hello", "I'll create it.", "$ " + command,
                                                "a", "b", "Created.", "✓ Goal met"], in: agent)
            #expect(inOrder, "\(transcript)")
            #expect(agent.session.displayTitle == "Agent — proof.txt contains hello")
            #expect(agent.session.terminal.palette.foreground == Palette.default.foreground)
            #expect(FileManager.default.contents(atPath: directory + "/proof.txt") == Data("hello".utf8))
            #expect(fake.requests.count == 3)
            #expect(fake.requests.first?.isRouter == true)
            let last = try #require(fake.requests.last?.messages.last)
            #expect(last["role"] as? String == "tool")
            #expect(last["tool_call_id"] as? String == "c1")
            let result = last["content"] as? String ?? ""
            #expect(result.contains("Exit code: 0"))
            #expect(result.contains("a\nb"))
            #expect(agent.assistant.bar.mode == .hidden)
        }

        enum StopGesture: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case controlC, commandPeriod, quit

            var testDescription: String { rawValue }
        }

        @Test("APP-ASSIST-005 the agent tab ignores typing while the agent works and stops on request",
              arguments: StopGesture.allCases)
        func APP_ASSIST_005(_ gesture: StopGesture) async throws {
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

            let before = harness.screenLines(agent)
            harness.type("x", in: agent)
            await harness.pause(0.3)
            #expect(harness.screenLines(agent) == before)
            #expect(agent.assistant.bar.mode == .hidden)

            switch gesture {
            case .controlC: harness.pressControl("c", in: agent)
            case .commandPeriod: #expect(harness.shortcut("."))
            case .quit: harness.delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            }
            if gesture != .quit {
                #expect(await harness.eventually(timeout: 3) {
                    harness.screenLines(agent).contains { $0.contains("■ Stopped") }
                })
            }
            #expect(await groupIsGone(agent.agentTab?.agent?.lastProcessGroup, harness: harness))
            #expect(fake.requests.count == 2)
        }

        enum ApprovalKey: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case escape, returnKey

            var testDescription: String { rawValue }
        }

        @Test("APP-ASSIST-006 a risky command waits for return or esc in the agent tab",
              arguments: ApprovalKey.allCases)
        func APP_ASSIST_006(_ key: ApprovalKey) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            let directory = await harness.useTemporaryDirectory()
            try FileManager.default.createDirectory(atPath: directory + "/build", withIntermediateDirectories: true)
            fake.queue(.agentTask("build is gone"), .bash("c1", "rm -rf build"), .agentText("ok\nGOAL MET"))
            #expect(await harness.openBar())
            harness.submit("clean the build")
            #expect(await harness.eventually { harness.agentController != nil })
            let agent = try #require(harness.agentController)
            #expect(await harness.eventually(timeout: 5) {
                let lines = harness.screenLines(agent)
                return lines.contains { $0.contains("⚠ Risky command") }
                    && lines.contains { $0.contains("Press Return to run it, Esc to skip.") }
                    && agent.session.displayTitle.hasPrefix("⚠")
            })
            harness.press(key == .escape ? .escape : .returnKey, in: agent)
            #expect(await harness.eventually(timeout: 5) {
                harness.screenLines(agent).contains { $0.contains("✓ Goal met") }
            })
            let result = fake.requests.last?.messages.last?["content"] as? String ?? ""
            if key == .escape {
                #expect(FileManager.default.fileExists(atPath: directory + "/build"))
                #expect(result == Agent.deniedResult)
            } else {
                #expect(!FileManager.default.fileExists(atPath: directory + "/build"))
                #expect(result.hasPrefix("Exit code: 0"))
            }
        }

        @Test("APP-ASSIST-007 typing in an idle agent tab replies to the agent in the same conversation")
        func APP_ASSIST_007() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            _ = await harness.useTemporaryDirectory()
            fake.queue(.agentTask("the server listens"), .agentText("Which port?\nNEED INPUT"))
            #expect(await harness.openBar())
            harness.submit("start the server")
            #expect(await harness.eventually { harness.agentController != nil })
            let agent = try #require(harness.agentController)
            #expect(await harness.eventually(timeout: 5) {
                harness.screenLines(agent).contains { $0.contains("? Needs input") }
            })
            let previous = try #require(fake.requests.last?.messages)

            harness.type("8", in: agent)
            let bar = agent.assistant.bar
            #expect(await harness.eventually { bar.mode == .prompt })
            #expect(bar.isReply)
            #expect(bar.field.stringValue == "8")
            fake.queue(.agentText("Using 8080.\nGOAL MET"))
            harness.submit("080", in: agent)
            #expect(await harness.eventually(timeout: 5) {
                harness.showsInOrder(["Using 8080.", "✓ Goal met"], in: agent)
            })
            #expect(fake.requests.count == 3)
            let reply = try #require(fake.requests.last)
            #expect(!reply.isRouter)
            #expect(reply.messages.count == previous.count + 2)
            #expect(reply.messages.last?["role"] as? String == "user")
            #expect(reply.messages.last?["content"] as? String == "8080")
            #expect(reply.messages[previous.count]["content"] as? String == "Which port?\nNEED INPUT")
        }

        @Test("APP-ASSIST-008 requests carry the real machine user directory and recent output")
        func APP_ASSIST_008() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            let directory = await harness.useTemporaryDirectory()
            await harness.run("echo marker-4242")
            #expect(await harness.eventually { harness.row("marker-4242") != nil })
            #expect(await harness.waitForPrompt())
            fake.queue(.commands([("ls", "List")]))
            #expect(await harness.openBar())
            harness.submit("what is here")
            #expect(await harness.eventually { fake.requests.count == 1 })
            let request = try #require(fake.requests.first)
            let system = request.content(0)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            #expect(system.contains("cwd: \(directory)\n"))
            #expect(system.contains("user: \(NSUserName()) "))
            #expect(system.contains("os: macOS \(version.majorVersion).\(version.minorVersion)"))
            #expect(system.contains("terminal: 80x24, running bash"))
            let recent = try #require(system.components(separatedBy: "<recent_terminal_output>").last)
            #expect(recent.components(separatedBy: "\n").contains("marker-4242"))
            #expect(request.content(1) == "what is here")
        }

        @Test("APP-ASSIST-009 no secret reaches the network and placeholders are restored when a command runs")
        func APP_ASSIST_009() async throws {
            let canary = "cnry-7f3a9d2e41"
            let placeholder = "<ATERM_CANARY_TOKEN_1:15chars>"
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake, environment: ["ATERM_CANARY_TOKEN": canary])
            defer { harness.shutDown() }
            let directory = await harness.useTemporaryDirectory()
            await harness.run("echo $ATERM_CANARY_TOKEN")
            #expect(await harness.eventually { harness.row(canary) != nil })
            #expect(await harness.waitForPrompt())
            fake.queue(.agentTask("canary.txt holds the canary"),
                       .bash("c1", #"printf %s "\#(placeholder)" > canary.txt && cat canary.txt"#),
                       .agentText("done\nGOAL MET"))
            #expect(await harness.openBar())
            harness.submit("use the canary")
            #expect(await harness.eventually(timeout: 10) {
                harness.agentController.map { harness.screenLines($0).contains { $0.contains("✓ Goal met") } } ?? false
            })
            #expect(fake.requests.count == 3)
            #expect(fake.requests.allSatisfy { !$0.bodyText.contains(canary) })
            #expect(fake.requests.first?.bodyText.contains(placeholder) == true)
            #expect(FileManager.default.contents(atPath: directory + "/canary.txt") == Data(canary.utf8))
            let result = fake.requests.last?.messages.last?["content"] as? String ?? ""
            #expect(result.contains(placeholder))
        }

        @Test("APP-ASSIST-010 a missing or rejected key is asked for in the bar")
        func APP_ASSIST_010() async throws {
            let fake = FakeOpenRouter()
            let store = MemoryAPIKeyStore()
            let harness = assistantHarness(fake, keyStore: store)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let bar = harness.controller.assistant.bar
            #expect(await harness.openBar())
            #expect(bar.mode == .key)
            #expect(bar.keyFieldHasFocus)
            harness.submit("test-key-2")
            #expect(store.load() == "test-key-2")
            #expect(bar.mode == .prompt)
            fake.queue(.commands([("ls", "List")]))
            harness.submit("hi")
            #expect(await harness.eventually { fake.requests.count == 1 })
            #expect(fake.requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-2")
            #expect(await harness.eventually { bar.mode == .suggestions })

            harness.press(.escape)
            fake.queue(.status(401, #"{"error":{"code":401,"message":"User not found."}}"#))
            #expect(await harness.openBar())
            harness.submit("hi")
            #expect(await harness.eventually { bar.mode == .key })
            #expect(bar.statusText == "Invalid API key: User not found.")
        }

        @Test("APP-ASSIST-011 the bar is centered in the terminal")
        func APP_ASSIST_011() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let controller = harness.controller
            let view = controller.terminalView
            let bar = controller.assistant.bar
            fake.queue(.commands([("echo first-choice", "First"), ("echo second-choice", "Second")]))
            func centered(_ step: String) {
                #expect(abs(bar.frame.midX - view.bounds.midX) <= 0.5 && abs(bar.frame.midY - view.bounds.midY) <= 0.5,
                        "\(step): \(bar.frame) in \(view.bounds)")
            }

            let start = harness.now
            harness.commandDown(at: start)
            #expect(await harness.eventually { bar.mode == .hint })
            centered("hint")
            let hintHeight = bar.frame.height

            harness.commandUp(at: start + 0.6)
            #expect(bar.mode == .prompt)
            #expect(bar.frame.height > hintHeight)
            centered("prompt")
            let promptHeight = bar.frame.height

            harness.submit("say it")
            #expect(await harness.eventually { bar.mode == .suggestions })
            #expect(bar.frame.height > promptHeight)
            centered("suggestions")

            controller.window!.setContentSize(controller.windowController!.contentSize(cols: 120, rows: 40))
            #expect(controller.session.terminal.cols == 120 && controller.session.terminal.rows == 40)
            centered("resized")
        }

        @Test("APP-ASSIST-012 the agent tab shows when a request is retried")
        func APP_ASSIST_012() async throws {
            let fake = FakeOpenRouter()
            var configuration = AppHarness.fixture()
            configuration.assistant = fake.assistantConfiguration()
            configuration.assistant.retryDelays = [1]
            let harness = AppHarness(configuration: configuration)
            harness.reportKey(true)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            fake.queue(.agentTask("say done"), .status(503, #"{"error":{"code":503,"message":"Overloaded"}}"#),
                       .agentText("Done.\nGOAL MET"))
            #expect(await harness.openBar())
            harness.submit("go")

            #expect(await harness.eventually { harness.agentController != nil })
            let agent = try #require(harness.agentController)
            var sawRetry = false
            #expect(await harness.eventually(timeout: 10) {
                let lines = harness.screenLines(agent)
                if lines.contains(where: { $0.contains("↻ HTTP 503, retry 2/2 in 1 s") }) { sawRetry = true }
                return lines.contains { $0.contains("✓ Goal met") }
            })
            #expect(sawRetry, "\(harness.screenLines(agent))")
            #expect(harness.showsInOrder(["Done.", "✓ Goal met"], in: agent))
            #expect(fake.requests.count == 3)
        }
    }
}
