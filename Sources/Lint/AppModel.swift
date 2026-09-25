import AppKit
import Foundation
import LintCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel: NSObject, NSWindowDelegate {
    let settings: SettingsStore
    let capture = TextCaptureService()
    let llm = LLMService()
    let memory = MemoryCoordinator()
    let localAI: LocalAISetupCoordinator
    let appleIntelligence = SystemAppleIntelligence()
    let panel: FloatingPanelController
    var accessibilityTrusted = AccessibilityPermission.isTrusted
    private var settingsWindow: NSWindow?
    private var localAISetupWindow: NSWindow?
    private var selectionMonitor: SelectionMonitor?

    override init() {
        let keychain = KeychainStore()
        let settings = SettingsStore(keychain: keychain)
        self.settings = settings
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
        viewModel.onOpenLocalAISetup = { [weak self] in self?.presentLocalAISetup() }
        viewModel.onOpenModelSettings = { [weak self] in self?.openSettings() }
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
                self?.panel.viewModel.warmUpIfIdle()
            }
        )
        self.selectionMonitor = monitor
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
        monitor.start()
        Task { await self.memory.prepare(config: self.settings.memoryConfig) }
        Task { await self.ensureLocalServerIfNeeded() }
    }

    /// Apple Intelligence takes the requests: Lint's local AI is neither checked nor started for it.
    var usesAppleIntelligence: Bool {
        WritingEngineRouter.route(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(), localAIReady: false
        ) == .appleIntelligence
    }

    /// Whether to offer Lint's local AI setup (menu item, first launch). Never downloads anything.
    var offersLocalAISetup: Bool {
        guard !usesAppleIntelligence else { return false }
        return WritingEngineRouter.offersLocalAISetup(
            selected: settings.providerKind, apple: appleIntelligence.currentStatus(),
            localAIReady: !localAI.needsSetup
        ) || (settings.providerKind == .localLlama && !localAI.isSetupComplete)
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
            NSLog("Lint local server: \(error.localizedDescription)")
        }
    }

    func stopManagedLocalServerIfNeeded() {
        localAI.stopManagedServer()
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
        panel.run()
    }

    /// ⌥⌘K — run the pending chip / focused field check without clicking.
    func runCheckHotkey() {
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
            NSLog("Lint relaunch failed: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    func startPolling() {
        Task { [weak self] in
            while let self {
                self.accessibilityTrusted = AccessibilityPermission.isTrusted
                self.localAI.setAccessibilityTrusted(self.accessibilityTrusted)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func openSettings() {
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
