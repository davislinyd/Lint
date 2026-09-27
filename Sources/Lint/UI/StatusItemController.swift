import AppKit
import LintCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var pollTask: Task<Void, Never>?
    private var wasStreaming = false
    /// The menu's first row, kept so its title follows a download while the menu is open.
    private weak var statusRow: NSMenuItem?

    init(app: AppModel) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.isVisible = true
        observeLocalModel()
        menu.delegate = self
        // The Tone submenu is switched off while a custom prompt is the mode, and it is the only item
        // that ever is (the others are enabled, or disabled on purpose).
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        if app.localModelActivity != nil {
            Task { await app.localAI.refreshServerActivity() }
        }
    }

    /// Keeps the icon, its tooltip and the menu's first row in step with the local model. While the
    /// requests go to it, the server is asked every 5 s (it says nothing by itself when its model falls
    /// asleep or wakes up), and once more as soon as a request ends.
    private func observeLocalModel() {
        let (activity, rowTitle, streaming) = withObservationTracking {
            (app.localModelActivity, statusRowTitle, app.panel.viewModel.isStreaming)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLocalModel() }
        }
        statusRow?.title = rowTitle
        guard let button = statusItem.button else { return }
        button.image = StatusBarIcon.image(activity: activity)
        button.toolTip = activity.map(\.toolTip) ?? "Lint"

        guard activity != nil else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        if wasStreaming, !streaming {
            Task { await app.localAI.refreshServerActivity() }
        }
        wasStreaming = streaming
        if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let localAI = self?.app.localAI else { return }
                    await localAI.refreshServerActivity()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
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

    @objc private func selectTone(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tone = WritingTone(rawValue: raw)
        else { return }
        app.settings.setTone(tone, for: app.settings.lastMode)
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

    @objc private func openDiagnostics() {
        app.openSettings(pane: .diagnostics)
    }

    @objc private func openLocalAISetup() {
        app.presentLocalAISetup()
    }

    @objc private func checkForUpdates() {
        app.updates.checkNow()
    }

    @objc private func installUpdate() {
        app.updates.installNow()
    }

    @objc private func showRelease() {
        app.updates.openReleasePage()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func selectLocalModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let model = ModelCatalog.descriptor(id: id) else { return }
        // After the menu has closed: a download is agreed to in an alert first.
        DispatchQueue.main.async { [weak self] in
            self?.app.useLocalModel(model)
        }
    }

    @objc private func selectAppleIntelligence() {
        app.useAppleIntelligence()
    }

    @objc private func cancelDownload() {
        app.localAI.cancelInstall()
    }

    // A failure to start shows in the icon and its tooltip.
    @objc private func startServer() {
        Task { try? await app.localAI.startServer() }
    }

    @objc private func stopServer() {
        Task { await app.localAI.stopServer() }
    }

    @objc private func restartServer() {
        Task { try? await app.localAI.restartServer() }
    }

    @objc private func recheckServer() {
        Task {
            await app.localAI.refresh()
            await app.localAI.refreshServerActivity()
        }
    }

    /// The local model's state, or which engine takes the requests.
    private var statusRowTitle: String {
        if let activity = app.localModelActivity { return activity.statusLine }
        switch app.writingRoute {
        case .appleIntelligence: return String(localized: "模型：\(ProviderKind.appleIntelligence.title)")
        case .provider(let kind): return String(localized: "模型：\(kind.title)")
        case .unavailable: return String(localized: "模型：\(String(localized: "尚未設定"))")
        }
    }

    /// The models to pick from and, while the requests go to the local model, its server.
    private func localModelMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let settings = app.settings
        let localAI = app.localAI
        let route = app.writingRoute
        let usesLocal = route == .provider(.localLlama)

        if usesLocal, settings.localModelSource == .custom {
            let custom = NSMenuItem(title: String(localized: "自訂（Hugging Face）"), action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            submenu.addItem(custom)
        }
        for model in ModelCatalog.all {
            let title = LocalServerSection.pickerLabel(for: model, installed: localAI.isInstalled(model))
            let item = NSMenuItem(title: title, action: #selector(selectLocalModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            let inUse = usesLocal && settings.localModelSource == .managed && settings.localManagedModelID == model.id
            item.state = inUse ? .on : .off
            submenu.addItem(item)
        }
        let apple = app.appleIntelligence.currentStatus()
        if apple.isAvailable || settings.providerKind == .appleIntelligence {
            let item = NSMenuItem(title: ProviderKind.appleIntelligence.title, action: #selector(selectAppleIntelligence), keyEquivalent: "")
            item.target = self
            item.state = route == .appleIntelligence ? .on : .off
            item.isEnabled = apple.isAvailable
            submenu.addItem(item)
        }
        if localAI.downloadState.isActive {
            submenu.addItem(.separator())
            let cancel = NSMenuItem(title: String(localized: "取消下載"), action: #selector(cancelDownload), keyEquivalent: "")
            cancel.target = self
            submenu.addItem(cancel)
        }
        guard usesLocal else { return submenu }

        submenu.addItem(.separator())
        let busy = localAI.isRestarting || localAI.downloadState.isActive
        switch localAI.serverStatus {
        case .stopped, .failed:
            let start = NSMenuItem(title: String(localized: "啟動服務"), action: #selector(startServer), keyEquivalent: "")
            start.target = self
            start.isEnabled = !busy && localAI.runtimeReady && localAI.modelReady
            submenu.addItem(start)
        case .starting, .running:
            let stop = NSMenuItem(title: String(localized: "停止服務"), action: #selector(stopServer), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = !localAI.isRestarting
            submenu.addItem(stop)
        }
        let restart = NSMenuItem(title: String(localized: "重新啟動服務"), action: #selector(restartServer), keyEquivalent: "")
        restart.target = self
        if case .running = localAI.serverStatus { restart.isEnabled = !busy } else { restart.isEnabled = false }
        submenu.addItem(restart)
        let check = NSMenuItem(title: String(localized: "重新檢查"), action: #selector(recheckServer), keyEquivalent: "")
        check.target = self
        submenu.addItem(check)
        return submenu
    }

    private func rebuild() {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusRowTitle, action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.setSubmenu(localModelMenu(), for: status)
        statusRow = status
        menu.addItem(.separator())

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

        let currentMode = app.settings.lastMode
        let currentTone = app.settings.tone(for: currentMode)
        let toneMenu = NSMenu(title: String(localized: "語氣"))
        for tone in WritingTone.allCases {
            let item = NSMenuItem(title: tone.title, action: #selector(selectTone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tone.rawValue
            item.state = currentMode.supportsTone && currentTone == tone ? .on : .off
            toneMenu.addItem(item)
        }
        let toneRoot = NSMenuItem(title: String(localized: "語氣"), action: nil, keyEquivalent: "")
        toneRoot.isEnabled = currentMode.supportsTone
        menu.addItem(toneRoot)
        menu.setSubmenu(toneMenu, for: toneRoot)

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

        if app.offersLocalAISetup {
            let setup = NSMenuItem(title: String(localized: "設定本機 AI…"), action: #selector(openLocalAISetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        menu.addItem(.separator())
        let check = NSMenuItem(title: String(localized: "檢查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = !app.updates.isBusy
        menu.addItem(check)
        if let title = app.updates.menuInstallTitle() {
            let install = NSMenuItem(title: title, action: #selector(installUpdate), keyEquivalent: "")
            install.target = self
            install.isEnabled = !app.updates.isBusy
            menu.addItem(install)
        } else if let title = app.updates.menuAnnounceTitle() {
            let announce = NSMenuItem(title: title, action: #selector(showRelease), keyEquivalent: "")
            announce.target = self
            menu.addItem(announce)
        }
        let version = NSMenuItem(title: "Lint \(AppVersion.display)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let diagnostics = NSMenuItem(title: String(localized: "診斷記錄…"), action: #selector(openDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        let settings = NSMenuItem(title: String(localized: "設定…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quitItem = NSMenuItem(title: String(localized: "結束 Lint"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

private extension LocalModelActivity {
    var statusLine: String {
        let title = switch self {
        case .notLoaded: String(localized: "未載入")
        case .loading: String(localized: "載入中")
        case .running: String(localized: "運作中")
        case .idle: String(localized: "閒置中")
        case .restarting: String(localized: "重啟中")
        case .failed: String(localized: "失敗")
        case .downloading(let state): Self.downloadTitle(state)
        }
        return String(localized: "本機模型：\(title)")
    }

    static func downloadTitle(_ state: ModelDownloadState) -> String {
        switch state {
        case .downloading(let received, let total?) where total > 0:
            let percent = (Double(min(received, total)) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
            let done = ModelInstallError.formatBytes(received)
            let size = ModelInstallError.formatBytes(total)
            return String(localized: "下載中 \(percent)（\(done) / \(size)）")
        case .downloading(let received, _):
            return String(localized: "下載中 \(ModelInstallError.formatBytes(received))")
        case .verifying: return String(localized: "正在驗證下載的檔案…")
        case .installing: return String(localized: "正在安裝…")
        default: return String(localized: "下載中…")
        }
    }

    var toolTip: String {
        if case .failed(let reason) = self { return "Lint\n\(statusLine)\n\(reason)" }
        return "Lint\n\(statusLine)"
    }
}
