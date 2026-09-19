import AppKit

/// Menu-bar apps start without a main menu. Without an Edit menu, SwiftUI/AppKit
/// text fields never receive ⌘A / ⌘C / ⌘V / ⌘X / undo.
enum MainMenuInstaller {
    @MainActor
    static func installIfNeeded() {
        if let existing = NSApp.mainMenu,
           existing.items.contains(where: { $0.submenu?.title == "Edit" || $0.submenu?.title == "編輯" }) {
            return
        }

        let mainMenu = NSMenu()

        let appName = ProcessInfo.processInfo.processName
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        appMenu.addItem(withTitle: String(localized: "關於 \(appName)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "設定…"), action: #selector(AppDelegate.openSettingsFromMenu(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "隱藏 \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "隱藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "顯示全部"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "結束 \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: String(localized: "編輯"))
        let editItem = NSMenuItem(title: String(localized: "編輯"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        editMenu.addItem(withTitle: String(localized: "還原"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "剪下"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "拷貝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "貼上"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "刪除"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: String(localized: "全選"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: String(localized: "視窗"))
        let windowItem = NSMenuItem(title: String(localized: "視窗"), action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        windowMenu.addItem(withTitle: String(localized: "關閉視窗"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }
}
