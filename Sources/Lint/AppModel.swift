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
    let panel: FloatingPanelController
    var accessibilityTrusted = AccessibilityPermission.isTrusted
    private var settingsWindow: NSWindow?
    private var selectionMonitor: SelectionMonitor?

    override init() {
        let keychain = KeychainStore()
        let settings = SettingsStore(keychain: keychain)
        self.settings = settings
        let viewModel = FloatingPanelViewModel(settings: settings, capture: capture, llm: llm)
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
        alert.messageText = "尚未偵測到 llama-server"
        switch state {
        case .brewUnavailable:
            alert.informativeText = "本機沒有 Homebrew，無法自動安裝。請先到 https://brew.sh 安裝後，再開設定按「安裝 llama-server」。"
            alert.addButton(withTitle: "知道了")
            alert.addButton(withTitle: "不要再提醒")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                UserDefaults.standard.set(true, forKey: skipKey)
            }
            return
        default:
            alert.informativeText = "Lint 可用 Homebrew 安裝 llama.cpp（含 llama-server）。需要網路，通常數分鐘。要現在安裝嗎？"
            alert.addButton(withTitle: "安裝")
            alert.addButton(withTitle: "稍後")
            alert.addButton(withTitle: "不要再提醒")
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
            err.messageText = "安裝失敗"
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
            window.title = "Lint 設定"
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
