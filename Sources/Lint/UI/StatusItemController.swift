import AppKit
import LintCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(app: AppModel) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Lint")
            button.image?.isTemplate = true
            button.toolTip = "Lint"
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    @objc private func runCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.app.runCapture()
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WritingMode(rawValue: raw)
        else { return }
        app.settings.lastMode = mode
    }

    @objc private func promptAccess() {
        AccessibilityPermission.prompt()
    }

    @objc private func openAccessSettings() {
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func openSettings() {
        app.openSettings()
    }

    @objc private func openLocalAISetup() {
        app.presentLocalAISetup()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func rebuild() {
        menu.removeAllItems()

        let run = NSMenuItem(title: String(localized: "改善選取文字"), action: #selector(runCapture), keyEquivalent: "")
        run.target = self
        menu.addItem(run)

        let modeMenu = NSMenu(title: String(localized: "模式"))
        for mode in WritingMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = app.settings.lastMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeRoot = NSMenuItem(title: String(localized: "模式"), action: nil, keyEquivalent: "")
        menu.addItem(modeRoot)
        menu.setSubmenu(modeMenu, for: modeRoot)

        menu.addItem(.separator())

        if app.accessibilityTrusted {
            let status = NSMenuItem(title: String(localized: "輔助功能：已授權"), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            let status = NSMenuItem(title: String(localized: "輔助功能：未授權（剪貼簿備援）"), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let prompt = NSMenuItem(title: String(localized: "授權輔助功能…"), action: #selector(promptAccess), keyEquivalent: "")
            prompt.target = self
            menu.addItem(prompt)
            let open = NSMenuItem(title: String(localized: "打開系統設定"), action: #selector(openAccessSettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        if app.settings.providerKind == .localLlama, !app.localAI.isSetupComplete {
            let setup = NSMenuItem(title: String(localized: "設定本機 AI…"), action: #selector(openLocalAISetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        menu.addItem(.separator())
        let version = NSMenuItem(title: "Lint \(AppVersion.display)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let settings = NSMenuItem(title: String(localized: "設定…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quitItem = NSMenuItem(title: String(localized: "結束 Lint"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
