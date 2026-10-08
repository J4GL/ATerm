import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

/// A terminal the helpers act on: a pane, or a tab (its active pane).
@MainActor
protocol TerminalHost: AnyObject {
    var session: TerminalSession { get }
    var terminalView: TerminalView { get }
    var assistant: AssistantController { get }
    var window: NSWindow? { get }
}

extension TerminalTab: TerminalHost {}
extension TerminalPane: TerminalHost {}

/// Drives the real app classes in-process. See SPEC/app/contract.md.
@MainActor
final class AppHarness {
    let delegate: AppDelegate
    let configuration: AppConfiguration
    /// The private defaults suite of each fixture configuration, removed by `shutDown()`.
    private static var suiteNames: [ObjectIdentifier: String] = [:]
    /// The temporary directories of the zsh fixtures, removed by `shutDown()`.
    static var temporaryDirectories: Set<String> = []

    /// The e2e fixture: off-screen windows, private pasteboard, no blinking,
    /// `/bin/bash --noprofile --norc` with `PS1='$ '`.
    static func fixture(loginShell: Bool = false) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.presentsWindows = false
        configuration.cursorBlinks = false
        configuration.pasteboard = NSPasteboard(name: NSPasteboard.Name("ATermTests-\(UUID().uuidString)"))
        let suite = "ATermTests-\(UUID().uuidString)"
        configuration.defaults = UserDefaults(suiteName: suite)!
        Self.suiteNames[ObjectIdentifier(configuration.defaults)] = suite
        configuration.environment["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        if !loginShell {
            configuration.shell = ShellOverride(executable: "/bin/bash", arguments: ["bash", "--noprofile", "--norc"])
            configuration.environment["PS1"] = "$ "
        }
        return configuration
    }

    /// The windows run modally and the modal runs stopped, recorded instead of running a modal loop.
    let modal = ModalRecorder()
    /// The alerts run modally, recorded and answered instead of running a modal loop.
    let alerts = AlertRecorder()

    init(configuration: AppConfiguration = AppHarness.fixture()) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var configuration = configuration
        let modal = modal
        configuration.runModal = { modal.run.append($0) }
        configuration.stopModal = { modal.stopped.append($0) }
        let alerts = alerts
        configuration.runAlert = { alerts.answer($0) }
        self.configuration = configuration
        delegate = AppDelegate(configuration: configuration)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    /// Every tab of every window, in window order then strip order.
    var controllers: [TerminalTab] { delegate.tabs }
    /// The first tab.
    var controller: TerminalTab { controllers[0] }
    var windows: [TerminalWindowController] { delegate.windowControllers }
    var pasteboard: NSPasteboard { configuration.pasteboard }

    /// Stops every agent, closes every window and hangs up every shell.
    func shutDown() {
        for pane in controllers.flatMap(\.panes) {
            pane.agentTab?.stop()
        }
        for window in windows {
            window.window?.close()
        }
        delegate.settingsController?.window?.close()
        if let suite = Self.suiteNames.removeValue(forKey: ObjectIdentifier(configuration.defaults)) {
            configuration.defaults.removePersistentDomain(forName: suite)
        }
        for path in [configuration.environment["ZDOTDIR"], configuration.shellIntegrationDirectory].compactMap({ $0 })
        where Self.temporaryDirectories.remove(path) != nil {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Waiting

    /// Polls `condition` on the main actor until it holds or `timeout` seconds elapse.
    func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Screen

    func screenLines(_ controller: (any TerminalHost)? = nil) -> [String] {
        (controller ?? self.controller).session.terminal.screenLines
    }

    func row(_ text: String, in controller: (any TerminalHost)? = nil) -> Int? {
        screenLines(controller).firstIndex(of: text)
    }

    func screenContains(_ text: String, in controller: (any TerminalHost)? = nil) -> Bool {
        screenLines(controller).contains { $0.contains(text) }
    }

    /// Waits for the prompt `$ ` on the cursor row.
    func waitForPrompt(_ controller: (any TerminalHost)? = nil) async -> Bool {
        let controller = controller ?? self.controller
        return await eventually {
            let terminal = controller.session.terminal
            return terminal.text(row: terminal.cursorPosition.row).hasSuffix("$")
                && terminal.cursorPosition.col == terminal.text(row: terminal.cursorPosition.row).count + 1
        }
    }

    /// Types a command, waits for its echo (wrapped rows joined), presses Return and returns the cursor's row.
    @discardableResult
    func run(_ command: String, in controller: (any TerminalHost)? = nil) async -> Int {
        let controller = controller ?? self.controller
        let terminal = controller.session.terminal
        if controller.window?.firstResponder !== controller.terminalView {
            Issue.record("run(\(command)): the keys would go to another view than this terminal")
        }
        type(command, in: controller)
        _ = await eventually { EnvironmentContext.recentLines(of: terminal, count: 1).last?.hasSuffix(command) == true }
        let row = terminal.cursorPosition.row
        press(.returnKey, in: controller)
        return row
    }

    // MARK: - Keyboard

    enum Key {
        case returnKey, up, down, left, right, end, f5, escape, pageUp, pageDown

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            case .left: "\u{F702}"
            case .right: "\u{F703}"
            case .end: "\u{F72B}"
            case .f5: "\u{F708}"
            case .escape: "\u{1B}"
            case .pageUp: "\u{F72C}"
            case .pageDown: "\u{F72D}"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .returnKey: 36
            case .up: 126
            case .down: 125
            case .left: 123
            case .right: 124
            case .end: 119
            case .f5: 96
            case .escape: 53
            case .pageUp: 116
            case .pageDown: 121
            }
        }
    }

    func keyEvent(characters: String, ignoringModifiers: String? = nil, keyCode: UInt16 = 0,
                  modifiers: NSEvent.ModifierFlags = [], window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    func type(_ text: String, in controller: (any TerminalHost)? = nil) {
        let window = (controller ?? self.controller).window!
        for character in text {
            window.sendEvent(keyEvent(characters: String(character), window: window))
        }
    }

    func press(_ key: Key, modifiers: NSEvent.ModifierFlags = [], in controller: (any TerminalHost)? = nil) {
        let window = (controller ?? self.controller).window!
        window.sendEvent(keyEvent(characters: key.characters, keyCode: key.keyCode, modifiers: modifiers, window: window))
    }

    /// Control + a letter, as AppKit reports it.
    func pressControl(_ letter: Character, in controller: (any TerminalHost)? = nil) {
        let window = (controller ?? self.controller).window!
        let code = Character(Unicode.Scalar(letter.asciiValue! & 0x1F))
        window.sendEvent(keyEvent(characters: String(code), ignoringModifiers: String(letter),
                                  modifiers: .control, window: window))
    }

    /// A menu shortcut, delivered through the main menu as NSApplication does.
    @discardableResult
    func shortcut(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        let window = controllers.last?.window
        return NSApp.mainMenu?.performKeyEquivalent(with: keyEvent(characters: key, modifiers: modifiers, window: window)) ?? false
    }

    /// A key equivalent delivered as NSApplication does: the window's views first, then the main menu.
    @discardableResult
    func chord(_ key: String, modifiers: NSEvent.ModifierFlags = .command,
               in controller: (any TerminalHost)? = nil) -> Bool {
        let window = (controller ?? self.controller).window!
        let event = keyEvent(characters: key, modifiers: modifiers, window: window)
        return window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    /// Chooses a menu item by title, as a click does.
    @discardableResult
    func chooseMenuItem(_ title: String) -> Bool {
        guard let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.title == title }),
              let action = item.action
        else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: - ⌘ hold and the assistant

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A modifier change, as AppKit reports it to the first responder.
    func modifiers(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 55, at timestamp: TimeInterval,
                   in controller: (any TerminalHost)? = nil) {
        let window = (controller ?? self.controller).window!
        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: timestamp,
                                     windowNumber: window.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
    }

    func commandDown(at timestamp: TimeInterval, in controller: (any TerminalHost)? = nil) {
        modifiers(.command, at: timestamp, in: controller)
    }

    func commandUp(at timestamp: TimeInterval, in controller: (any TerminalHost)? = nil) {
        modifiers([], at: timestamp, in: controller)
    }

    /// Holds ⌘ for 0.6 s (by the event times) and waits for the bar.
    func openBar(in controller: (any TerminalHost)? = nil) async -> Bool {
        let controller = controller ?? self.controller
        let start = now
        commandDown(at: start, in: controller)
        commandUp(at: start + 0.6, in: controller)
        return await eventually { controller.assistant.bar.mode != .hidden }
    }

    /// Types a request in the open bar and presses Return.
    func submit(_ text: String, in controller: (any TerminalHost)? = nil) {
        type(text, in: controller)
        press(.returnKey, in: controller)
    }

    /// Moves the shell to a fresh temporary directory (symlinks resolved) and waits for the prompt.
    func useTemporaryDirectory(in controller: (any TerminalHost)? = nil) async -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ATermE2E-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolved = realpath(base.path, nil)!
        defer { free(resolved) }
        let path = String(cString: resolved)
        _ = await waitForPrompt(controller)
        await run("cd \(path) && clear", in: controller)
        _ = await eventually { (controller ?? self.controller).session.currentDirectory == path }
        _ = await waitForPrompt(controller)
        return path
    }

    /// The first agent tab.
    var agentController: TerminalTab? { controllers.first { $0.agentTab != nil } }

    /// The logical lines (wrapped rows joined) of the scrollback and the screen, up to the cursor.
    func logicalLines(_ controller: (any TerminalHost)? = nil) -> [String] {
        EnvironmentContext.recentLines(of: (controller ?? self.controller).session.terminal, count: 100_000)
    }

    /// True once `lines` appear on the controller's screen in this order.
    func showsInOrder(_ lines: [String], in controller: any TerminalHost) -> Bool {
        var remaining = lines[...]
        for line in logicalLines(controller) {
            if let next = remaining.first, line.contains(next) { remaining.removeFirst() }
        }
        return remaining.isEmpty
    }

    // MARK: - Focus

    func reportKey(_ isKey: Bool, _ controller: (any TerminalHost)? = nil) {
        let window = (controller ?? self.controller).window!
        NotificationCenter.default.post(name: isKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
                                        object: window)
    }

    // MARK: - Mouse

    func mouseEvent(_ type: NSEvent.EventType, row: Int, col: Int, clickCount: Int = 1,
                    modifiers: NSEvent.ModifierFlags = [], in controller: (any TerminalHost)? = nil) -> NSEvent {
        let controller = controller ?? self.controller
        let view = controller.terminalView
        let rect = view.cellRect(row: row, col: col)
        let location = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clickCount, pressure: 1)!
    }

    func click(row: Int, col: Int, count: Int = 1, modifiers: NSEvent.ModifierFlags = [],
               in controller: (any TerminalHost)? = nil) {
        let view = (controller ?? self.controller).terminalView
        for click in 1...count {
            view.mouseDown(with: mouseEvent(.leftMouseDown, row: row, col: col, clickCount: click, modifiers: modifiers,
                                            in: controller))
            view.mouseUp(with: mouseEvent(.leftMouseUp, row: row, col: col, clickCount: click, modifiers: modifiers,
                                          in: controller))
        }
    }

    func drag(from start: (row: Int, col: Int), to end: (row: Int, col: Int),
              in controller: (any TerminalHost)? = nil) {
        let view = (controller ?? self.controller).terminalView
        view.mouseDown(with: mouseEvent(.leftMouseDown, row: start.row, col: start.col, in: controller))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, row: end.row, col: end.col, in: controller))
        view.mouseUp(with: mouseEvent(.leftMouseUp, row: end.row, col: end.col, in: controller))
    }

    /// Scrolls the wheel by whole lines (positive: up, toward older lines).
    func scrollWheel(lines: Int, in controller: (any TerminalHost)? = nil) {
        let view = (controller ?? self.controller).terminalView
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                              wheel1: Int32(lines), wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cgEvent)!)
    }

    // MARK: - Tab strip

    enum TabPart {
        case body, close
    }

    /// Opens tabs with ⌘T until there is one per title, titles them by OSC and selects the last.
    func openTabs(titled titles: [String]) async {
        while controllers.count < titles.count { shortcut("t") }
        for (tab, title) in zip(controllers, titles) {
            // Key events go to the window's selected tab.
            tab.windowController?.select(tab)
            _ = await waitForPrompt(tab)
            await run("printf '\\033]2;\(title)\\007'", in: tab)
            _ = await eventually { tab.title == title }
        }
        if let last = controllers.last { last.windowController?.select(last) }
    }

    func strip(_ tab: TerminalTab? = nil) -> TabStripView {
        (tab ?? controller).windowController!.tabStrip
    }

    /// A mouse event at a point of the strip.
    func stripEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                    in tab: TerminalTab? = nil) -> NSEvent {
        let strip = strip(tab)
        return NSEvent.mouseEvent(with: type, location: strip.convert(point, to: nil), modifierFlags: [],
                                  timestamp: now, windowNumber: strip.window!.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    /// Clicks a point of the strip with the left button, or the middle one.
    func clickStrip(at point: NSPoint, middle: Bool = false, in tab: TerminalTab? = nil) {
        let strip = strip(tab)
        if middle {
            strip.otherMouseDown(with: stripEvent(.otherMouseDown, at: point, in: tab))
            strip.otherMouseUp(with: stripEvent(.otherMouseUp, at: point, in: tab))
        } else {
            strip.mouseDown(with: stripEvent(.leftMouseDown, at: point, in: tab))
            strip.mouseUp(with: stripEvent(.leftMouseUp, at: point, in: tab))
        }
    }

    /// Moves the pointer to a point of the strip, or out of it (nil).
    func moveMouse(inStrip point: NSPoint?, in tab: TerminalTab? = nil) {
        let strip = strip(tab)
        if let point {
            strip.mouseMoved(with: stripEvent(.mouseMoved, at: point, in: tab))
        } else {
            strip.mouseExited(with: stripEvent(.mouseMoved, at: NSPoint(x: -10, y: -10), in: tab))
        }
    }

    /// Clicks tab `index` of the window of `tab`, on its body or its ×.
    func clickTab(_ index: Int, part: TabPart = .body, middle: Bool = false, in tab: TerminalTab? = nil) {
        let strip = strip(tab)
        let rect = part == .body ? strip.tabRect(at: index) : strip.closeButtonRect(at: index)
        let point = part == .body ? NSPoint(x: rect.minX + 6, y: rect.midY) : NSPoint(x: rect.midX, y: rect.midY)
        clickStrip(at: point, middle: middle, in: tab)
    }

    /// Renders the tab strip of the window of `tab` into an sRGB bitmap, sampled in strip coordinates (y down).
    func renderStrip(_ tab: TerminalTab? = nil) -> (NSPoint) -> RGB {
        let view = strip(tab)
        let (rep, scale) = snapshot(view)
        return { point in
            let x = min(max(0, Int(point.x * scale)), rep.pixelsWide - 1)
            let y = min(max(0, Int(point.y * scale)), rep.pixelsHigh - 1)
            return rep.rgb(x: x, y: y)
        }
    }

    // MARK: - Pixels

    /// The view rendered into an sRGB bitmap.
    func render(_ controller: (any TerminalHost)? = nil) -> RenderedView {
        let view = (controller ?? self.controller).terminalView
        let (rep, scale) = snapshot(view)
        return RenderedView(rep: rep, view: view, scale: scale)
    }
}

/// `view` rendered into an sRGB bitmap at its window's scale.
@MainActor
func snapshot(_ view: NSView) -> (rep: NSBitmapImageRep, scale: CGFloat) {
    let scale = view.window?.backingScaleFactor ?? 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                               pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!.retagging(with: .sRGB)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return (rep, scale)
}

extension NSBitmapImageRep {
    /// The color of device pixel (x, y), y down.
    func rgb(x: Int, y: Int) -> RGB {
        let color = colorAt(x: x, y: y)!
        return RGB(UInt8((color.redComponent * 255).rounded()), UInt8((color.greenComponent * 255).rounded()),
                   UInt8((color.blueComponent * 255).rounded()))
    }
}

/// A rendered snapshot of a terminal view, sampled in view coordinates (y down).
@MainActor
struct RenderedView {
    let rep: NSBitmapImageRep
    let view: TerminalView
    let scale: CGFloat

    func color(at point: NSPoint) -> RGB {
        let x = min(max(0, Int(point.x * scale)), rep.pixelsWide - 1)
        let y = min(max(0, Int(point.y * scale)), rep.pixelsHigh - 1)
        return rep.rgb(x: x, y: y)
    }

    func cellCenter(row: Int, col: Int) -> RGB {
        let rect = view.cellRect(row: row, col: col)
        return color(at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// The top-left device pixel of a cell.
    func cellCorner(row: Int, col: Int) -> RGB {
        let rect = view.cellRect(row: row, col: col)
        return color(at: NSPoint(x: rect.minX + 0.5 / scale, y: rect.minY + 0.5 / scale))
    }

    /// Every pixel of a band of a cell; `from`/`to` are fractions of the cell height.
    func pixels(row: Int, col: Int, from top: CGFloat = 0, to bottom: CGFloat = 1) -> [RGB] {
        let rect = view.cellRect(row: row, col: col)
        let x0 = Int((rect.minX * scale).rounded()), x1 = Int((rect.maxX * scale).rounded())
        let y0 = Int(((rect.minY + rect.height * top) * scale).rounded())
        let y1 = Int(((rect.minY + rect.height * bottom) * scale).rounded())
        var result: [RGB] = []
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                result.append(rep.rgb(x: x, y: y))
            }
        }
        return result
    }
}

extension RGB {
    /// True when every channel is within `tolerance` of `other`.
    func matches(_ other: RGB, tolerance: Int = 3) -> Bool {
        abs(Int(r) - Int(other.r)) <= tolerance && abs(Int(g) - Int(other.g)) <= tolerance
            && abs(Int(b) - Int(other.b)) <= tolerance
    }

    var isGray: Bool { max(r, g, b) - min(r, g, b) <= 12 }
}

let backgroundColor = RGB(30, 31, 38)
let cursorColor = RGB(242, 197, 114)
let selectionColor = RGB(59, 74, 106)

/// The alerts the app ran modally, answered with the responses the test queues, else with the second button
/// (Cancel).
@MainActor
final class AlertRecorder {
    var run: [NSAlert] = []
    var responses: [NSApplication.ModalResponse] = []

    func answer(_ alert: NSAlert) -> NSApplication.ModalResponse {
        run.append(alert)
        return responses.isEmpty ? .alertSecondButtonReturn : responses.removeFirst()
    }
}

/// The windows the app ran modally and stopped.
@MainActor
final class ModalRecorder {
    var run: [NSWindow] = []
    var stopped: [NSWindow] = []
}
