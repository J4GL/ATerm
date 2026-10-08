import AppKit
import ATermCore

/// The LLM assistant: OpenRouter, the key, the agent's environment. See SPEC/app/assistant.md.
public struct AssistantConfiguration {
    public var endpoint = OpenRouterClient.defaultEndpoint
    public var model = OpenRouterClient.defaultModel
    /// The reasoning level of every request; nil leaves the model's default.
    public var reasoningEffort: String?
    /// The catalog completing model lists without levels or prices (opencode's); nil uses none.
    public var modelCatalogURL: URL? = ModelCatalog.modelsDevURL
    public var keyStore: APIKeyStore = KeychainAPIKeyStore()
    /// Uses `OPENROUTER_API_KEY` from the app's environment when no key is stored.
    public var environmentKeyFallback = true
    public var sessionConfiguration: URLSessionConfiguration = .default
    public var retryDelays = OpenRouterClient.defaultRetryDelays
    /// The login shell's environment (its PATH…), for agent commands and secret detection.
    public var loginEnvironment: @Sendable () async -> [String: String] = {
        await LoginEnvironmentCache.shared.environment()
    }
    /// Files whose secrets are redacted.
    public var credentialFiles = SecretSources.defaultCredentialFiles(home: NSHomeDirectory())
    /// Seconds since the last key press or click anywhere, nil when unknown: an input the app did not see
    /// (⌘Tab, ⌘Space…) during a ⌘ hold rejects it.
    public var systemInputAge: @MainActor () -> TimeInterval? = AssistantConfiguration.secondsSinceSystemInput
    public var holdDelay = CommandHoldDetector.defaultDelay
    /// The model completes the line typed at the zsh prompt when the history has nothing for it
    /// (`AssistantSuggestions`, Settings). See SPEC/app/suggestions.md.
    public var commandCompletions = true
    /// The pause in typing after which the model is asked.
    public var completionDelay: TimeInterval = 1

    public init() {}

    @MainActor
    public static func secondsSinceSystemInput() -> TimeInterval? {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
    }
}

/// A shell to run instead of the user's login shell.
public struct ShellOverride: Sendable {
    public var executable: String
    /// The argument vector, starting with argv[0].
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Everything the app needs to open terminal windows.
public struct AppConfiguration {
    /// Runs this command instead of the login shell.
    public var shell: ShellOverride?
    /// Variables added to the shell environment.
    public var environment: [String: String] = [:]
    /// Font family name; nil uses the system monospaced font.
    public var fontName: String?
    public var fontSize: CGFloat = AppConfiguration.defaultFontSize
    public var scrollbackLines = 10_000
    /// Option sends ESC + key instead of composing characters.
    public var optionAsMeta = false
    /// Starts zsh with ATerm's suggestions (`Autosuggestions`). See SPEC/app/suggestions.md.
    public var autosuggestions = true
    /// Where the files and FIFOs of the zsh integration go.
    public var shellIntegrationDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent("ATerm")
    /// Orders windows on screen; the e2e fixture keeps them off screen.
    public var presentsWindows = true
    /// Lets blinking cursor styles blink.
    public var cursorBlinks = true
    public var pasteboard: NSPasteboard = .general
    public var palette: Palette = .default
    /// Opens links ⌘-clicked in the terminal.
    public var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var assistant = AssistantConfiguration()
    /// Where settings are saved (`OptionAsMeta`, `AssistantEndpoint`, `AssistantModel`, `AssistantSuggestions`…).
    public var defaults: UserDefaults = .standard
    /// Runs a window app-modally (Settings) until `stopModal`; the e2e fixture records it instead.
    public var runModal: @MainActor (NSWindow) -> Void = { window in _ = NSApp.runModal(for: window) }
    public var stopModal: @MainActor (NSWindow) -> Void = { window in
        if NSApp.modalWindow === window { NSApp.stopModal() }
    }
    /// Runs an alert app-modally and returns the button chosen; the e2e fixture records it and answers instead.
    public var runAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    public static let defaultFontSize: CGFloat = 13

    public init() {}

    /// The configuration of the running app, from the user defaults.
    public static func standard(defaults: UserDefaults = .standard) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.defaults = defaults
        if let name = defaults.string(forKey: "FontName"), !name.isEmpty { configuration.fontName = name }
        let size = defaults.double(forKey: "FontSize")
        if size >= 6 && size <= 72 { configuration.fontSize = CGFloat(size) }
        let scrollback = defaults.integer(forKey: "ScrollbackLines")
        if scrollback > 0 { configuration.scrollbackLines = scrollback }
        configuration.optionAsMeta = defaults.bool(forKey: "OptionAsMeta")
        configuration.autosuggestions = defaults.object(forKey: "Autosuggestions") as? Bool ?? true
        configuration.assistant.commandCompletions = defaults.object(forKey: "AssistantSuggestions") as? Bool ?? true
        if let model = defaults.string(forKey: "AssistantModel"), !model.isEmpty {
            configuration.assistant.model = model
        }
        if let effort = defaults.string(forKey: "AssistantReasoningEffort"), !effort.isEmpty {
            configuration.assistant.reasoningEffort = effort
        }
        if let endpoint = defaults.string(forKey: "AssistantEndpoint").flatMap(URL.init(string:)) {
            configuration.assistant.endpoint = endpoint
        }
        return configuration
    }
}
