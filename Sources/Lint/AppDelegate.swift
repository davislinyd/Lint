import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func start() {
        MainMenuInstaller.installIfNeeded()
        statusItem = StatusItemController(app: model)
        HotkeyCenter.register(
            improve: { [weak self] in self?.model.runCapture() },
            check: { [weak self] in self?.model.runCheckHotkey() }
        )
        model.startPolling()
        model.updates.start()
        Task { await model.presentInitialOnboarding() }
    }

    @objc func openSettingsFromMenu(_ sender: Any?) {
        model.openSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopManagedLocalServerIfNeeded()
    }
}
