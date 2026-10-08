import AppKit

/// The menu bar. Application commands target the app delegate; editing commands go to the first responder.
@MainActor
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(applicationMenu(target: target)))
        menu.addItem(submenu(shellMenu(target: target)))
        menu.addItem(submenu(editMenu(target: target)))
        menu.addItem(submenu(viewMenu(target: target)))
        let window = windowMenu(target: target)
        menu.addItem(submenu(window))
        NSApp.windowsMenu = window
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func applicationMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "ATerm")
        menu.addItem(item("About ATerm", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target))
        menu.addItem(.separator())
        let services = item("Services", nil)
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide ATerm", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit ATerm", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func shellMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n", target: target))
        menu.addItem(item("New Tab", #selector(AppDelegate.newTab(_:)), "t", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", #selector(AppDelegate.splitRight(_:)), "d", target: target))
        // An uppercase key equivalent means ⇧, which is how AppKit reports ⇧⌘D.
        menu.addItem(item("Split Down", #selector(AppDelegate.splitDown(_:)), "D", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Ask…", #selector(AppDelegate.askAssistant(_:)), target: target))
        menu.addItem(item("Stop Agent", #selector(AppDelegate.stopAgent(_:)), ".", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(AppDelegate.closePane(_:)), "w", target: target))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift]))
        return menu
    }

    private static func editMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", #selector(AppDelegate.clearScrollback(_:)), "k", target: target))
        return menu
    }

    private static func viewMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Bigger", #selector(AppDelegate.makeTextBigger(_:)), "+", target: target))
        let alternate = item("Bigger", #selector(AppDelegate.makeTextBigger(_:)), "=", target: target)
        alternate.isHidden = true
        alternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(alternate)
        menu.addItem(item("Smaller", #selector(AppDelegate.makeTextSmaller(_:)), "-", target: target))
        menu.addItem(item("Default Size", #selector(AppDelegate.makeTextStandardSize(_:)), "0", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Use Option as Meta Key", #selector(AppDelegate.toggleOptionAsMeta(_:)), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(AppDelegate.selectPreviousTab(_:)), "{", target: target))
        menu.addItem(item("Show Next Tab", #selector(AppDelegate.selectNextTab(_:)), "}", target: target))
        for number in 1...9 {
            let select = item(number == 9 ? "Select Last Tab" : "Select Tab \(number)",
                              #selector(AppDelegate.selectTabByNumber(_:)), "\(number)", target: target)
            select.tag = number
            menu.addItem(select)
        }
        menu.addItem(.separator())
        let arrows: [(String, Selector, NSEvent.SpecialKey)] = [
            ("Select Pane Left", #selector(AppDelegate.selectPaneLeft(_:)), .leftArrow),
            ("Select Pane Right", #selector(AppDelegate.selectPaneRight(_:)), .rightArrow),
            ("Select Pane Above", #selector(AppDelegate.selectPaneAbove(_:)), .upArrow),
            ("Select Pane Below", #selector(AppDelegate.selectPaneBelow(_:)), .downArrow),
        ]
        for (title, action, key) in arrows {
            menu.addItem(item(title, action, String(key.unicodeScalar), modifiers: [.command, .option], target: target))
        }
        menu.addItem(item("Zoom Pane", #selector(AppDelegate.togglePaneZoom(_:)), "\r", modifiers: [.command, .shift],
                          target: target))
        menu.addItem(item("Equalize Panes", #selector(AppDelegate.equalizePanes(_:)), "=", modifiers: [.command, .control],
                          target: target))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
