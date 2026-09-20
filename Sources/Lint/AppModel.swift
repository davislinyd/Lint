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
    let learning = LearningCoordinator()
    let panel: FloatingPanelController
    var accessibilityTrusted = AccessibilityPermission.isTrusted
    private var settingsWindow: NSWindow?
    private var selectionMonitor: SelectionMonitor?

    override init() {
        let keychain = KeychainStore()
        let settings = SettingsStore(keychain: keychain)
        self.settings = settings
        let viewModel = FloatingPanelViewModel(settings: settings, capture: capture, llm: llm, learning: learning)
        self.panel = FloatingPanelController(viewModel: viewModel)
        super.init()
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
        Task { await self.learning.prepare(config: self.settings.learningConfig) }
        Task {
            await self.promptInstallLlamaIfNeeded()
            await self.ensureLocalServerIfNeeded()
        }
    }


    /// First launch / missing binary: offer Homebrew install (never silent).
    func promptInstallLlamaIfNeeded() async {
        guard settings.wantsManagedLocalServer else { return }
        let state = LocalLlamaServerManager.detectBinary(preferred: settings.localServerBinaryPath)
        switch state {
        case .found(let path):
            if settings.localServerBinaryPath != path {
                settings.localServerBinaryPath = path
            }
            return
        case .missing, .brewUnavailable:
            break
        }

        let skipKey = "app.lint.localServer.skipInstallPrompt"
        if UserDefaults.standard.bool(forKey: skipKey) { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "尚未偵測到 llama-server")
        switch state {
        case .brewUnavailable:
            alert.informativeText = String(localized: "本機沒有 Homebrew，無法自動安裝。請先到 https://brew.sh 安裝後，再開設定按「安裝 llama-server」。")
            alert.addButton(withTitle: String(localized: "知道了"))
            alert.addButton(withTitle: String(localized: "不要再提醒"))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                UserDefaults.standard.set(true, forKey: skipKey)
            }
            return
        default:
            alert.informativeText = String(localized: "Lint 可用 Homebrew 安裝 llama.cpp（含 llama-server）。需要網路，通常數分鐘。要現在安裝嗎？")
            alert.addButton(withTitle: String(localized: "安裝"))
            alert.addButton(withTitle: String(localized: "稍後"))
            alert.addButton(withTitle: String(localized: "不要再提醒"))
        }
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            UserDefaults.standard.set(true, forKey: skipKey)
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        do {
            let path = try await LocalLlamaServerManager.shared.installViaHomebrew()
            settings.localServerBinaryPath = path
            UserDefaults.standard.set(false, forKey: skipKey)
            NSLog("Lint: installed llama-server at \(path)")
        } catch {
            let err = NSAlert()
            err.messageText = String(localized: "安裝失敗")
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    func ensureLocalServerIfNeeded() async {
        guard settings.wantsManagedLocalServer else { return }
        do {
            try await LocalLlamaServerManager.shared.ensureRunning(settings: settings)
        } catch {
            // Non-fatal at launch — request path will surface the error.
            NSLog("Lint local server: \(error.localizedDescription)")
        }
    }

    func stopManagedLocalServerIfNeeded() {
        LocalLlamaServerManager.shared.stopIfStartedByUs()
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
        if !settingsVisible && !panelVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        restoreAccessoryIfNeeded()
    }
}
