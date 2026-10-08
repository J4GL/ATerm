import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

extension FakeOpenRouter.Reply {
    /// A model list answer: id, name and per-token prices (input, cached, output).
    static func models(_ models: [(String, String, String?, String?, String?)]) -> Self {
        let data = models.map { id, name, input, cached, output -> [String: Any] in
            var pricing: [String: Any] = [:]
            if let input { pricing["prompt"] = input }
            if let cached { pricing["input_cache_read"] = cached }
            if let output { pricing["completion"] = output }
            return ["id": id, "name": name, "pricing": pricing]
        }
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self)
        return .json(200, body)
    }

    static func modelIDs(_ ids: [String]) -> Self {
        models(ids.map { ($0, $0, "0", nil, "0") })
    }
}

extension FakeOpenRouter.Recorded {
    var path: String { request.url?.path ?? "" }
}

extension FakeOpenRouter {
    /// The chat requests (POST), model list and catalog requests excluded.
    var chatRequests: [Recorded] { requests.filter { $0.request.httpMethod == "POST" } }
}

@MainActor
extension AppHarness {
    var settings: SettingsWindowController? { delegate.settingsController }
    var services: AssistantServices { delegate.assistantServices }

    /// Presses ⌘, with the fake answering the model list loaded at opening with an empty list, and waits for it.
    func openSettings(_ fake: FakeOpenRouter) async -> SettingsWindowController? {
        let loads = services.apiKey() != nil && services.models == nil
        if loads { fake.queue(.models([])) }
        guard shortcut(","), let settings else { return nil }
        if loads { _ = await eventually { settings.isLoadingModels == false && services.models != nil } }
        return settings
    }

    /// Types into a field of the settings window through its field editor, replacing its text.
    func replaceText(of field: NSTextField, with text: String, in settings: SettingsWindowController) {
        let window = settings.window!
        window.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.selectAll(nil)
        if text.isEmpty {
            (field.currentEditor() as? NSTextView)?.deleteBackward(nil)
        }
        for character in text {
            window.sendEvent(keyEvent(characters: String(character), window: window))
        }
    }

    func press(_ key: Key, in settings: SettingsWindowController) {
        let window = settings.window!
        window.sendEvent(keyEvent(characters: key.characters, keyCode: key.keyCode, window: window))
    }
}

extension E2E {
    @Suite @MainActor struct Settings {
        @Test("APP-SETTINGS-001 command comma opens settings showing the current endpoint key state and model",
              arguments: ["key stored", "no key"])
        func APP_SETTINGS_001(state: String) async throws {
            let fake = FakeOpenRouter()
            let store = MemoryAPIKeyStore(key: state == "key stored" ? "test-key" : nil)
            let harness = assistantHarness(fake, keyStore: store)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            let window = try #require(settings.window)
            #expect(settings.keyField.stringValue.isEmpty)
            if state == "no key" {
                #expect(settings.keyField.placeholderString == "Paste your API key")
                return
            }
            #expect(window.title == "Settings")
            #expect(settings.endpointField.stringValue == fake.endpoint.absoluteString)
            #expect(settings.keyField.placeholderString == "Saved in Keychain")
            #expect(settings.modelField.stringValue == OpenRouterClient.defaultModel)
            let titles = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).map(\.title) ?? []
            #expect(!titles.contains("OpenRouter API Key…"))
            #expect(harness.shortcut(","))
            #expect(harness.settings === settings)
        }

        @Test("APP-SETTINGS-002 saving applies the endpoint key and model to the next request and persists them")
        func APP_SETTINGS_002() async throws {
            let fake = FakeOpenRouter()
            let other = FakeOpenRouter()
            let store = MemoryAPIKeyStore(key: "test-key")
            let harness = assistantHarness(fake, keyStore: store)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            settings.endpointField.stringValue = other.endpoint.absoluteString
            settings.keyField.stringValue = "key-3"
            settings.modelField.stringValue = "m/new"
            settings.saveButton.performClick(nil)
            #expect(settings.window?.isVisible != true && harness.settings == nil)
            #expect(store.load() == "key-3")
            let defaults = harness.configuration.defaults
            #expect(defaults.string(forKey: "AssistantEndpoint") == other.endpoint.absoluteString)
            #expect(defaults.string(forKey: "AssistantModel") == "m/new")
            let reloaded = AppConfiguration.standard(defaults: defaults)
            #expect(reloaded.assistant.endpoint == other.endpoint)
            #expect(reloaded.assistant.model == "m/new")

            other.queue(.commands([("ls", "List")]))
            #expect(await harness.openBar())
            harness.submit("hi")
            #expect(await harness.eventually { other.requests.count == 1 })
            let request = try #require(other.requests.first)
            #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer key-3")
            #expect(request.json["model"] as? String == "m/new")
            #expect(fake.chatRequests.isEmpty)
        }

        @Test("APP-SETTINGS-003 an invalid endpoint is refused and empty fields restore the defaults",
              arguments: ["not a url", "ftp://example.com/v1", "chat completions", "", "empty model"])
        func APP_SETTINGS_003(endpoint: String) async throws {
            let fake = FakeOpenRouter()
            let store = MemoryAPIKeyStore(key: "test-key")
            var configuration = AppHarness.fixture()
            configuration.assistant = fake.assistantConfiguration(keyStore: store)
            if endpoint == "empty model" {
                configuration.defaults.set("m/old", forKey: "AssistantModel")
                configuration.assistant.model = "m/old"
            }
            let harness = AppHarness(configuration: configuration)
            harness.reportKey(true)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let defaults = harness.configuration.defaults
            let settings = try #require(await harness.openSettings(fake))

            if endpoint == "empty model" {
                settings.modelField.stringValue = ""
                settings.saveButton.performClick(nil)
                #expect(harness.settings == nil)
                #expect(defaults.object(forKey: "AssistantModel") == nil)
                #expect(harness.services.model == OpenRouterClient.defaultModel)
                return
            }

            settings.endpointField.stringValue = endpoint == "chat completions"
                ? fake.endpoint.absoluteString + "/chat/completions/" : endpoint
            settings.keyField.stringValue = "key-4"
            settings.modelField.stringValue = "m/other"
            settings.saveButton.performClick(nil)
            if endpoint.isEmpty {
                #expect(harness.settings == nil)
                #expect(defaults.object(forKey: "AssistantEndpoint") == nil)
                #expect(harness.services.endpoint == OpenRouterClient.defaultEndpoint)
                #expect(store.load() == "key-4")
                #expect(defaults.string(forKey: "AssistantModel") == "m/other")
                return
            }
            #expect(harness.settings === settings)
            #expect(settings.statusField.stringValue == (endpoint == "chat completions"
                ? "Use the API base URL, without /chat/completions." : "Invalid endpoint URL."))
            #expect(defaults.object(forKey: "AssistantEndpoint") == nil)
            #expect(defaults.object(forKey: "AssistantModel") == nil)
            #expect(store.load() == "test-key")
            fake.queue(.commands([("ls", "List")]))
            #expect(await harness.openBar())
            harness.submit("hi")
            #expect(await harness.eventually { fake.chatRequests.count == 1 })
            #expect(fake.chatRequests.first?.json["model"] as? String == OpenRouterClient.defaultModel)
        }

        enum TestCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case typedKey, storedKey, rejected, fallback, htmlPages, chatCompletionsURL, noKey

            var testDescription: String { rawValue }
        }

        @Test("APP-SETTINGS-004 test checks the key being edited against the endpoint being edited",
              arguments: TestCase.allCases)
        func APP_SETTINGS_004(scenario: TestCase) async throws {
            let fake = FakeOpenRouter()
            let other = FakeOpenRouter()
            let store = MemoryAPIKeyStore(key: scenario == .noKey ? nil : "test-key")
            let harness = assistantHarness(fake, keyStore: store)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            if scenario == .noKey {
                settings.testButton.performClick(nil)
                #expect(settings.statusField.stringValue == "Enter an API key to test.")
                await harness.pause(0.2)
                #expect(fake.requests.isEmpty)
                return
            }
            let before = fake.requests.count
            settings.endpointField.stringValue = other.endpoint.absoluteString
            let three = FakeOpenRouter.Reply.modelIDs(["a/one", "b/two", "c/three"])
            let expected: (key: String, status: String, paths: [String])
            switch scenario {
            case .typedKey:
                other.queue(three)
                expected = ("key-5", "✓ Key valid — 3 models", ["/api/v1/models/user"])
            case .storedKey:
                other.queue(three)
                expected = ("test-key", "✓ Key valid — 3 models", ["/api/v1/models/user"])
            case .rejected:
                other.queue(.json(401, #"{"error":{"code":401,"message":"User not found."}}"#))
                expected = ("bad", "✗ Invalid API key: User not found.", ["/api/v1/models/user"])
            case .fallback:
                other.queue(.json(404, #"{"error":{"code":404,"message":"Not Found"}}"#), .modelIDs(["a/one"]))
                expected = ("key-5", "✓ 1 model (this endpoint does not check the key)",
                            ["/api/v1/models/user", "/api/v1/models"])
            case .htmlPages:
                let page = "<!DOCTYPE html><html lang=\"fr\"><head><meta charset=\"utf-8\"></head><body>x</body></html>"
                other.queue(.json(404, page), .json(404, page))
                expected = ("key-5", "✗ Request refused: HTTP 404 (not found)", ["/api/v1/models/user", "/api/v1/models"])
            case .chatCompletionsURL:
                settings.endpointField.stringValue = other.endpoint.absoluteString + "/chat/completions"
                expected = ("key-5", "✗ Use the API base URL, without /chat/completions.", [])
            case .noKey:
                return
            }
            settings.keyField.stringValue = scenario == .storedKey ? "" : expected.key
            settings.testButton.performClick(nil)
            #expect(await harness.eventually { settings.statusField.stringValue == expected.status },
                    "\(settings.statusField.stringValue)")
            #expect(other.requests.map(\.path) == expected.paths)
            for request in other.requests {
                #expect(request.request.httpMethod == "GET")
                #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expected.key)")
            }
            #expect(fake.requests.count == before)
            #expect(store.load() == "test-key")
            #expect(harness.configuration.defaults.object(forKey: "AssistantEndpoint") == nil)
        }

        @Test("APP-SETTINGS-005 the model field completes from the model list with prices")
        func APP_SETTINGS_005() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            fake.queue(.models([
                ("anthropic/claude-a", "Anthropic: Claude A", "0.000003", "0.0000003", "0.000015"),
                ("openai/gpt-b", "OpenAI: GPT B", "0.000001", nil, "0.000004"),
                ("x/claude-c", "X: Claude C", "0", nil, "0"),
            ]))
            settings.testButton.performClick(nil)
            #expect(await harness.eventually { settings.statusField.stringValue == "✓ Key valid — 3 models" })
            let field = settings.modelField

            harness.replaceText(of: field, with: "CLAUDE", in: settings)
            #expect(settings.isCompletionShown)
            #expect(settings.completionRows.map(\.id) == ["anthropic/claude-a", "x/claude-c"])
            #expect(settings.completionRows.map(\.price) == ["in $3.00 · cached $0.30 · out $15.00 /M", "free"])
            #expect(settings.selectedCompletionRow == nil)

            harness.replaceText(of: field, with: "gpt", in: settings)
            #expect(settings.completionRows.map(\.id) == ["openai/gpt-b"])
            #expect(settings.completionRows.map(\.price) == ["in $1.00 · cached — · out $4.00 /M"])

            harness.replaceText(of: field, with: "claude", in: settings)
            harness.press(.down, in: settings)
            harness.press(.down, in: settings)
            harness.press(.returnKey, in: settings)
            #expect(field.stringValue == "x/claude-c")
            #expect(!settings.isCompletionShown)
            #expect(harness.settings === settings)

            harness.replaceText(of: field, with: "open", in: settings)
            #expect(settings.isCompletionShown)
            harness.press(.escape, in: settings)
            #expect(!settings.isCompletionShown)
            #expect(field.stringValue == "open")
            #expect(harness.settings === settings)

            harness.replaceText(of: field, with: "zzz", in: settings)
            #expect(!settings.isCompletionShown)
        }

        @Test("APP-SETTINGS-006 opening settings with a known key loads the model list once",
              arguments: ["key stored", "no key"])
        func APP_SETTINGS_006(state: String) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake, keyStore: MemoryAPIKeyStore(key: state == "key stored" ? "test-key" : nil))
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            if state == "no key" {
                #expect(harness.shortcut(","))
                await harness.pause(0.2)
                #expect(fake.requests.isEmpty)
                return
            }
            fake.queue(.modelIDs(["a/one", "b/two"]))
            #expect(harness.shortcut(","))
            let settings = try #require(harness.settings)
            #expect(await harness.eventually { harness.services.models != nil })
            #expect(fake.requests.map(\.path) == ["/api/v1/models/user"])
            harness.replaceText(of: settings.modelField, with: "one", in: settings)
            #expect(settings.completionRows.map(\.id) == ["a/one"])
            #expect(settings.statusField.stringValue.isEmpty)

            settings.window?.performClose(nil)
            #expect(harness.settings == nil)
            #expect(harness.shortcut(","))
            await harness.pause(0.2)
            #expect(fake.requests.count == 1)
        }

        enum StatusCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
            case none, valid, longError

            var testDescription: String { rawValue }
        }

        @Test("APP-SETTINGS-008 every control fits in the window whatever the status", arguments: StatusCase.allCases)
        func APP_SETTINGS_008(status: StatusCase) async throws {
            let fake = FakeOpenRouter()
            let harness = assistantHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            let long = "✗ Invalid API key: " + String(repeating: "x", count: 600)
            switch status {
            case .none:
                break
            case .valid:
                fake.queue(.modelIDs(["a/one", "b/two", "c/three"]))
                settings.testButton.performClick(nil)
                #expect(await harness.eventually { settings.statusField.stringValue == "✓ Key valid — 3 models" })
            case .longError:
                fake.queue(.json(401, #"{"error":{"code":401,"message":"\#(String(repeating: "x", count: 600))"}}"#))
                settings.testButton.performClick(nil)
                #expect(await harness.eventually { settings.statusField.stringValue == long })
            }
            let content = try #require(settings.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let controls: [NSView] = settings.labels + [settings.endpointField, settings.keyField, settings.modelField,
                                                        settings.reasoningPopUp, settings.suggestionsBox,
                                                        settings.testButton, settings.statusField,
                                                        settings.cancelButton, settings.saveButton]
            let frames = controls.map { $0.superview!.convert($0.alignmentRect(forFrame: $0.frame), to: content) }
            let inside = content.bounds.insetBy(dx: 12, dy: 12)
            for (control, frame) in zip(controls, frames) {
                #expect(inside.contains(frame), "\(control) \(frame) outside \(inside)")
            }
            for i in frames.indices {
                for j in frames.indices where j > i {
                    #expect(!frames[i].intersects(frames[j]), "\(controls[i]) overlaps \(controls[j])")
                }
            }
            let font = try #require(settings.statusField.font)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            #expect(settings.statusField.frame.height <= 3 * lineHeight + 4)
            #expect(settings.statusField.toolTip == (status == .none ? nil : settings.statusField.stringValue))
            let save = frames.last!
            #expect(abs(content.bounds.maxX - save.maxX - 20) < 0.5)
            let bottomGap = content.isFlipped ? content.bounds.maxY - save.maxY : save.minY - content.bounds.minY
            #expect(abs(bottomGap - 20) < 0.5)
        }

        @Test("APP-SETTINGS-009 the reasoning pop-up offers the model's levels and the chosen one is sent")
        func APP_SETTINGS_009() async throws {
            let fake = FakeOpenRouter()
            var configuration = AppHarness.fixture()
            configuration.assistant = fake.assistantConfiguration()
            configuration.assistant.modelCatalogURL = fake.endpoint.appendingPathComponent("catalog.json")
            let harness = AppHarness(configuration: configuration)
            harness.reportKey(true)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let catalog = #"{"opencode-go":{"api":"\#(fake.endpoint.absoluteString)","models":{"space-bunny-free":{"reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}]}}}}"#
            fake.queue(.json(404, #"{"error":{"message":"Not Found"}}"#),
                       .json(200, #"{"data":[{"id":"space-bunny-free"},{"id":"plain"}]}"#), .json(200, catalog))
            #expect(harness.shortcut(","))
            let settings = try #require(harness.settings)
            #expect(await harness.eventually { harness.services.models != nil })
            #expect(fake.requests.map(\.path) == ["/api/v1/models/user", "/api/v1/models", "/api/v1/catalog.json"])
            #expect(settings.reasoningPopUp.itemTitles == ["Default"])

            harness.replaceText(of: settings.modelField, with: "space-bunny-free", in: settings)
            #expect(settings.reasoningPopUp.itemTitles == ["Default", "low", "medium", "high", "xhigh", "max"])
            #expect(settings.reasoningPopUp.titleOfSelectedItem == "Default")
            settings.reasoningPopUp.selectItem(withTitle: "high")
            settings.saveButton.performClick(nil)
            let defaults = harness.configuration.defaults
            #expect(defaults.string(forKey: "AssistantReasoningEffort") == "high")
            #expect(AppConfiguration.standard(defaults: defaults).assistant.reasoningEffort == "high")
            fake.queue(.commands([("ls", "List")]))
            #expect(await harness.openBar())
            harness.submit("hi")
            #expect(await harness.eventually { fake.chatRequests.count == 1 })
            #expect(fake.chatRequests.last?.json["reasoning_effort"] as? String == "high")
            harness.press(.escape)

            #expect(harness.shortcut(","))
            let reopened = try #require(harness.settings)
            #expect(reopened.reasoningPopUp.titleOfSelectedItem == "high")
            harness.replaceText(of: reopened.modelField, with: "plain", in: reopened)
            #expect(reopened.reasoningPopUp.itemTitles == ["Default"])
            #expect(reopened.reasoningPopUp.titleOfSelectedItem == "Default")
            reopened.saveButton.performClick(nil)
            #expect(defaults.object(forKey: "AssistantReasoningEffort") == nil)
            fake.queue(.commands([("ls", "List")]))
            #expect(await harness.openBar())
            harness.submit("hi")
            #expect(await harness.eventually { fake.chatRequests.count == 2 })
            #expect(fake.chatRequests.last?.json["reasoning_effort"] == nil)
        }

        @Test("APP-SETTINGS-010 the suggestions box turns the model's completions on and off")
        func APP_SETTINGS_010() async throws {
            let fake = FakeOpenRouter()
            let harness = assistantZshHarness(fake)
            defer { harness.shutDown() }
            #expect(await harness.waitForPrompt())
            let settings = try #require(await harness.openSettings(fake))
            #expect(settings.suggestionsBox.title == "Complete commands with the model")
            #expect(settings.suggestionsBox.state == .on)
            settings.suggestionsBox.performClick(nil)
            settings.saveButton.performClick(nil)
            let defaults = harness.configuration.defaults
            #expect(defaults.object(forKey: "AssistantSuggestions") as? Bool == false)
            #expect(!AppConfiguration.standard(defaults: defaults).assistant.commandCompletions)
            harness.type("ffmpeg -i")
            await harness.pause(2)
            #expect(fake.chatRequests.isEmpty)

            let reopened = try #require(await harness.openSettings(fake))
            #expect(reopened.suggestionsBox.state == .off)
            reopened.suggestionsBox.performClick(nil)
            reopened.saveButton.performClick(nil)
            #expect(defaults.object(forKey: "AssistantSuggestions") == nil)
            fake.queue(.completion("ffprobe -v error"))
            harness.pressControl("u")
            harness.type("ffprobe -v")
            #expect(await harness.eventually(timeout: 3) { fake.chatRequests.count == 1 })
            #expect(fake.chatRequests.first?.content(1) == "ffprobe -v")
        }
    }
}
