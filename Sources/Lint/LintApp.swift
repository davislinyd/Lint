import AppKit
import LintCore

@main
enum LintRuntime {
    nonisolated(unsafe) static var delegate: AppDelegate?

    static func main() {
        startDiagnosticLog()
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

    private static func startDiagnosticLog() {
        let log = DiagnosticLog.shared
        log.start(in: DiagnosticLog.standardDirectory)
        // Replace events used to go, unbounded, to these two files (the second one readable by anyone).
        for legacy in ["/tmp/lint-replace.log", DiagnosticLog.standardDirectory.appendingPathComponent("replace.log").path] {
            try? FileManager.default.removeItem(atPath: legacy)
        }
        log.log("app", "launch Lint \(AppVersion.short) (\(AppVersion.build)) · \(DiagnosticLog.systemSummary)")
    }
}
