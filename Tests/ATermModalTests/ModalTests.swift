import AppKit
import Foundation
import Testing
@testable import ATermApp
import ATermCore

// APP-SETTINGS-007 runs the app's real modal loop. Once a modal loop has run in a test process, AppKit later stops
// the Swift Testing runner's main run loop, which ends the process: this target holds this test alone.

/// What the timer saw inside the modal loop.
@MainActor
final class ModalLoopObservation {
    var modalWindow: NSWindow?
    var settingsWindow: NSWindow?
    var settingsVisible = false
    var terminalWorksWhenModal = true
    var misplaced: [String] = []
}

enum WayOut: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case save, cancel, closeButton

    var testDescription: String { rawValue }
}

/// The e2e fixture of SPEC/app/contract.md, with the app's own `runModal` and `stopModal`, and no API key (no
/// request is sent).
@MainActor
private func launchApp(defaultsSuite: String) -> AppDelegate {
    var configuration = AppConfiguration()
    configuration.presentsWindows = false
    configuration.cursorBlinks = false
    configuration.pasteboard = NSPasteboard(name: NSPasteboard.Name("ATermModalTests-\(UUID().uuidString)"))
    configuration.defaults = UserDefaults(suiteName: defaultsSuite)!
    configuration.shell = ShellOverride(executable: "/bin/bash", arguments: ["bash", "--noprofile", "--norc"])
    configuration.environment["PS1"] = "$ "
    configuration.environment["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
    configuration.assistant.keyStore = MemoryAPIKeyStore()
    configuration.assistant.environmentKeyFallback = false
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let delegate = AppDelegate(configuration: configuration)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    return delegate
}

@MainActor
@Test("APP-SETTINGS-007 settings is app modal until save cancel or the close button",
      .serialized, arguments: WayOut.allCases)
func APP_SETTINGS_007(way: WayOut) throws {
    let suite = "ATermModalTests-\(UUID().uuidString)"
    let delegate = launchApp(defaultsSuite: suite)
    defer {
        for controller in delegate.windowControllers { controller.window?.close() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    let terminalWindow = try #require(delegate.tabs.first?.window)

    let inside = ModalLoopObservation()
    let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
        MainActor.assumeIsolated {
            guard let settings = delegate.settingsController, let window = settings.window,
                  let content = window.contentView
            else { return }
            inside.settingsWindow = window
            inside.modalWindow = NSApp.modalWindow
            inside.settingsVisible = window.isVisible
            inside.terminalWorksWhenModal = terminalWindow.worksWhenModal
            content.layoutSubtreeIfNeeded()
            let controls: [NSView] = settings.labels + [settings.endpointField, settings.keyField, settings.modelField,
                                                        settings.reasoningPopUp, settings.suggestionsBox,
                                                        settings.testButton, settings.statusField,
                                                        settings.cancelButton, settings.saveButton]
            let allowed = content.bounds.insetBy(dx: 19.5, dy: 19.5)
            for control in controls {
                let rect = control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: content)
                if !allowed.contains(rect) { inside.misplaced.append("\(control) \(rect) in \(content.bounds)") }
            }
            switch way {
            case .save: settings.saveButton.performClick(nil)
            case .cancel: settings.cancelButton.performClick(nil)
            case .closeButton: window.performClose(nil)
            }
        }
    }
    RunLoop.main.add(timer, forMode: .common)

    // ⌘, through the main menu; it returns once the modal loop has ended.
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: terminalWindow.windowNumber, context: nil, characters: ",",
                                 charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
    #expect(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)

    let window = try #require(inside.settingsWindow, "the timer did not run inside the modal loop")
    #expect(inside.modalWindow === window)
    #expect(inside.settingsVisible)
    #expect(!inside.terminalWorksWhenModal)
    #expect(inside.misplaced.isEmpty, "\(inside.misplaced)")
    #expect(NSApp.modalWindow == nil)
    #expect(delegate.settingsController == nil && !window.isVisible)
}
