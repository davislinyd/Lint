import AppKit
import Foundation
import LintCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel: NSObject, NSWindowDelegate {
    let settings: SettingsStore
    let updates: UpdateCoordinator
    let capture = TextCaptureService()
    /// Puts Lint's requests to its local model ahead of other apps' (Settings → Model → Other Apps).
    let modelGate = ModelPriorityGate()
    let llm: LLMService
    /// The keys other apps give Lint's API port.
    let localAPIKeyring: LocalAPIKeyring
    /// Lint's API port for other apps; off unless switched on in Settings.
    let localAPI: LocalAPIService
    let memory = MemoryCoordinator()
    let localAI: LocalAISetupCoordinator
    let appleIntelligence = SystemAppleIntelligence()
    let panel: FloatingPanelController
    var accessibilityTrusted = AccessibilityPermission.isTrusted
    /// The pane the settings window shows; a menu item can open it on a given pane.
    var settingsPane: SettingsPane = .general
    /// Set to a new value to make the general pane scroll to its update section once it appears.
    var scrollToUpdateSectionRequest: UUID?
    private var settingsWindow: NSWindow?
    private var localAISetupWindow: NSWindow?
    private var selectionMonitor: SelectionMonitor?
    /// What Lint does differently per app (observation mode), by bundle ID, as dreaming last wrote
    /// it. Empty while the mode is off: nothing is adjusted then.
    private(set) var appAdjustments: [String: AppAdjustment] = [:]

    override init() {
        let keychain = KeychainStore()
        let settings = SettingsStore(keychain: keychain)
        self.settings = settings
        llm = LLMService(localModel: LocalModelAccess(key: LocalLlamaServerManager.shared.serverKey, gate: modelGate))
        let keyring = LocalAPIKeyring(keychain: keychain)
        localAPIKeyring = keyring
        let starter = LocalModelStarter()
        localAPI = LocalAPIService(proxy: LocalAPIProxy(
            gate: modelGate, serverKey: LocalLlamaServerManager.shared.serverKey,
            keys: { keyring.lookup() },
            ensureBackend: { try await starter.ensure() }
        ))
        updates = UpdateCoordinator(settings: settings)
        let localAI = LocalAISetupCoordinator(
            configuration: { settings.localAIConfiguration },
            server: LocalLlamaServerManager.shared,
            accessibilityTrusted: AccessibilityPermission.isTrusted
        )
        self.localAI = localAI
        let viewModel = FloatingPanelViewModel(
            settings: settings, capture: capture, llm: llm, memory: memory, localAI: localAI,
            appleIntelligence: appleIntelligence
        )
        self.panel = FloatingPanelController(viewModel: viewModel)
        super.init()
        starter.model = self
        settings.onLocalAPIChanged = { [weak self] in self?.reconcileLocalAPI() }
        viewModel.onOpenLocalAISetup = { [weak self] in self?.presentLocalAISetup() }
        viewModel.onOpenModelSettings = { [weak self] in self?.openSettings() }
        viewModel.learnedTone = { [weak self] bundle in bundle.flatMap { self?.appAdjustments[$0] }?.tone }
        viewModel.onToneChosen = { [weak self] bundle in self?.forgetAdjustment(for: bundle, quiet: false, tone: true) }
        let monitor = SelectionMonitor(
            settings: settings,
            capture: capture,
            onSuggest: { [weak self] result in
                self?.panel.showSelectionChip(result)
            },
            onCleared: { [weak self] in
                // Only dismiss the small chip — never the suggestion bubble
                // (clicking the bubble clears selection and would race Replace).
                self?.panel.dismissChip()
            },
            onTyping: { [weak self] in
                // A suggestion is coming: no other app's request starts now, only to be interrupted.
                self?.modelGate.noteLintActivity()
                self?.panel.viewModel.warmUpIfIdle()
            },
            isQuietApp: { [weak self] bundle in
                bundle.flatMap { self?.appAdjustments[$0] }?.quiet ?? false
            }
        )
        self.selectionMonitor = monitor
        settings.onUpdatePreferenceChanged = { [weak self] in
            self?.updates.preferencesChanged()
        }
        settings.onCaptureWatchChanged = { [weak monitor] in
            monitor?.applyWatchSettings()
        }
        InteractionAnchor.start()
        if ProviderKind.chatgptAccount.isEnabled {
            ChatGPTBrowserBackendRegistry.shared.backend = ChatGPTWebBridge.shared
            ChatGPTWebBridge.shared.warmUp()
        }
        panel.onBubbleVisibilityChange = { [weak self, weak monitor] visible in
            monitor?.isPaused = visible
            if !visible {
                self?.restoreAccessoryIfNeeded()
            }
        }
        monitor.applyWatchSettings()
        Task {
            await self.memory.prepare(config: self.settings.memoryConfig)
            await self.refreshAppAdjustments()
        }
        Task { await self.ensureLocalServerIfNeeded() }
    }

    /// Reads what Lint does differently per app. Dreaming writes it in the background, so this is
    /// read again every minute (`startPolling`), and at once after the user changed something.
    func refreshAppAdjustments() async {
        guard settings.memoryConfig.observation else {
            appAdjustments = [:]
            return
        }
        appAdjustments = Dictionary(
            await memory.appAdjustments().map { ($0.app, $0) }, uniquingKeysWith: { first, _ in first }
        )
    }

    /// The user wants this app back to normal (see `MemoryCoordinator.forget`). Applied at once.
    func forgetAdjustment(for bundle: String?, quiet: Bool, tone: Bool) {
        guard let bundle, var adjustment = appAdjustments[bundle] else { return }
        guard (quiet && adjustment.quiet) || (tone && adjustment.tone != nil) else { return }
        if quiet { adjustment.quiet = false }
        if tone { adjustment.tone = nil }
        appAdjustments[bundle] = adjustment.quiet || adjustment.tone != nil ? adjustment : nil
        DiagnosticLog.shared.log("observe", "forgot quiet=\(quiet) tone=\(tone) app=\(bundle)")
        Task { await memory.forget(app: bundle, quiet: quiet, tone: tone) }
    }

    /// Apple Intelligence takes the requests: Lint's local AI is neither checked nor started for it.
    var usesAppleIntelligence: Bool {
        WritingEngineRouter.route(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(), localAIReady: false
        ) == .appleIntelligence
    }

    /// Where requests go now, for the menu bar.
    var writingRoute: WritingEngineRoute {
        WritingEngineRouter.route(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(),
            localAIReady: localAI.runtimeReady && localAI.modelReady
        )
    }

    /// The local model's state for the menu bar, or nil when the requests do not go to it. A download
    /// is shown whichever way they go.
    var localModelActivity: LocalModelActivity? {
        if localAI.downloadState.isActive { return localAI.activity }
        return writingRoute == .provider(.localLlama) ? localAI.activity : nil
    }

    /// Apple Intelligence picked from the menu bar: requests go to it from now on, and a llama-server
    /// Lint started is stopped at once so its memory is free.
    func useAppleIntelligence() {
        settings.selectProvider(.appleIntelligence)
        localAI.releaseForAppleIntelligence()
    }

    /// A model Lint manages, picked from the menu bar, is used from now on. One that is not installed
    /// is downloaded only after the user agreed to its size; picking the model in use does nothing,
    /// unless it still has to be downloaded.
    func useLocalModel(_ model: ModelDescriptor) {
        let changed = settings.localModelSource != .managed || settings.localManagedModelID != model.id
        let installed = localAI.isInstalled(model)
        if !changed, settings.providerKind == .localLlama, installed || localAI.downloadState.isActive { return }
        if !installed, !confirmDownload(of: model) { return }
        if settings.providerKind != .localLlama { settings.selectProvider(.localLlama) }
        settings.localModelSource = .managed
        settings.localManagedModelID = model.id
        Task { await localAI.useManagedModel(changed: changed) }
    }

    /// The same size and free space that Settings shows before a download.
    private func confirmDownload(of model: ModelDescriptor) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "下載模型？")
        alert.informativeText = LocalServerSection.downloadConfirmation(for: model)
        if model.memoryClass == .large {
            alert.alertStyle = .warning
            alert.informativeText += "\n\n" + LocalServerSection.largeModelWarning
        }
        alert.addButton(withTitle: String(localized: "下載並安裝"))
        alert.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Whether to offer Lint's local AI setup (menu item, first launch). Never downloads anything.
    var offersLocalAISetup: Bool {
        guard !usesAppleIntelligence else { return false }
        return WritingEngineRouter.offersLocalAISetup(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(),
            localAIReady: !localAI.needsSetup
        ) || (settings.providerKind == .localLlama && !localAI.isSetupComplete)
    }

    /// The first-run guide was closed before it was done: Settings and the hotkeys show it instead.
    var onboardingPending: Bool {
        WritingEngineRouter.onboardingPending(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(),
            localAIReady: !localAI.needsSetup, accessibilityTrusted: AccessibilityPermission.isTrusted
        )
    }

    /// At launch: look at what local AI still needs, and start the server if it is ready to start.
    func ensureLocalServerIfNeeded() async {
        guard !usesAppleIntelligence else { return }
        await localAI.refresh()
        let route = WritingEngineRouter.route(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(),
            localAIReady: localAI.runtimeReady && localAI.modelReady
        )
        guard settings.wantsManagedLocalServer(for: route), !localAI.needsSetup else { return }
        do {
            try await localAI.ensureServerRunning()
        } catch {
            // Non-fatal at launch — the request path will surface the error.
            DiagnosticLog.shared.log("server", "not started at launch \(DiagnosticLog.describe(error))")
        }
    }

    func stopManagedLocalServerIfNeeded() {
        localAI.stopManagedServer()
    }

    /// Listens on the API port while it is switched on and Lint's requests go to its local model.
    func reconcileLocalAPI() {
        // The keys are not touched here: Settings and the first request read them, off the main thread.
        let enabled = settings.localAPIEnabled && writingRoute == .provider(.localLlama)
        let configuration = LocalAPIService.Configuration(
            enabled: enabled, port: settings.localAPIPort, upstreamPort: settings.localServerPort,
            allowedOrigins: settings.localAPIAllowedOrigins, allowBrowserExtensions: settings.localAPIAllowBrowserExtensions
        )
        Task { await localAPI.apply(configuration) }
    }

    /// What an API request needs before it goes to the model: the same as Lint's own requests (the
    /// local engine, a running server, started if auto-start allows), waiting out a restart.
    func ensureLocalModelForAPI() async throws {
        guard writingRoute == .provider(.localLlama) else { throw LocalAPIBackendUnavailable.notLocalEngine }
        for _ in 0..<50 where localAI.isRestarting {
            try await Task.sleep(for: .milliseconds(200))
        }
        if localAI.isRestarting { throw LocalAPIBackendUnavailable.restarting }
        do {
            try await localAI.ensureServerRunning()
        } catch {
            throw LocalAPIBackendUnavailable.notRunning
        }
    }

    /// First launch: the Local AI setup screen if the local model still has to be installed (unless
    /// the user said "Later"), otherwise the old behaviour of opening Settings when Accessibility is off.
    func presentInitialOnboarding() async {
        if !usesAppleIntelligence { await localAI.refresh() }
        let offersSetup = !usesAppleIntelligence && WritingEngineRouter.offersLocalAISetup(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(), localAIReady: !localAI.needsSetup
        )
        if offersSetup, !settings.localAISetupDeferred {
            presentLocalAISetup()
        } else if !AccessibilityPermission.isTrusted {
            openSettings()
        }
    }

    func presentLocalAISetup() {
        if localAISetupWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "設定本機 AI")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LocalAISetupView(app: self, onClose: { [weak self] in
                self?.localAISetupWindow?.close()
            }))
            window.delegate = self
            window.center()
            localAISetupWindow = window
        }
        panel.dismissBubble()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        localAISetupWindow?.makeKeyAndOrderFront(nil)
    }

    func runCapture() {
        if onboardingPending { return presentLocalAISetup() }
        panel.run()
    }

    /// ⌥⌘K — run the pending chip / focused field check without clicking. Asking for a suggestion in
    /// an app that had gone quiet says that Lint is wanted there again.
    func runCheckHotkey() {
        if onboardingPending { return presentLocalAISetup() }
        forgetAdjustment(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, quiet: true, tone: false)
        panel.activateCheckFromHotkey(capture: capture)
    }

    /// Quit and reopen this app bundle (e.g. to apply a new UI language).
    func relaunch() {
        // Wait for this process to exit first, since `applicationWillTerminate` needs time to stop
        // the managed llama-server. Even then LaunchServices can lag behind the exit and fail a
        // plain `open` with -600, so use `-n` and retry.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; "
                + "for i in 1 2 3 4 5 6 7 8 9 10; do open -n \"$0\" && exit 0; sleep 0.5; done",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("app", "relaunch failed \(DiagnosticLog.describe(error))")
            return
        }
        NSApp.terminate(nil)
    }

    func startPolling() {
        Task { [weak self] in
            var seconds = 0
            while let self {
                self.accessibilityTrusted = AccessibilityPermission.isTrusted
                self.localAI.setAccessibilityTrusted(self.accessibilityTrusted)
                self.updates.installIfWaiting(panelVisible: self.panel.isVisible)
                // The engine can change without a setting changing (Automatic, a model download).
                self.reconcileLocalAPI()
                seconds += 1
                if seconds % 60 == 0 { await self.refreshAppAdjustments() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Shows the first-run guide instead while it is pending, unless the guide itself sends the user here.
    func openSettings(pane: SettingsPane? = nil, scrollToUpdateSection: Bool = false, skippingOnboarding: Bool = false) {
        if !skippingOnboarding, onboardingPending { return presentLocalAISetup() }
        if let pane { settingsPane = pane }
        if scrollToUpdateSection { scrollToUpdateSectionRequest = UUID() }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Lint 設定")
            window.contentMinSize = NSSize(width: 680, height: 460)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(app: self))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func restoreAccessoryIfNeeded() {
        let panelVisible = panel.isVisible
        let settingsVisible = settingsWindow?.isVisible == true
        let setupVisible = localAISetupWindow?.isVisible == true
        if !settingsVisible && !setupVisible && !panelVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        restoreAccessoryIfNeeded()
    }
}

/// Lets the API port, made before `AppModel` exists, start the model through it later.
@MainActor
private final class LocalModelStarter {
    weak var model: AppModel?

    func ensure() async throws {
        guard let model else { throw LocalAPIBackendUnavailable.notRunning }
        try await model.ensureLocalModelForAPI()
    }
}
