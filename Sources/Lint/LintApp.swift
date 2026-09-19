import AppKit

@main
enum LintRuntime {
    nonisolated(unsafe) static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            Self.delegate = delegate
            app.delegate = delegate
            delegate.start()
            app.setActivationPolicy(.accessory)
        }
        app.run()
    }
}
