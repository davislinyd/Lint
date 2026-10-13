import AppKit
import LintCore

/// Observation mode: follows the field a suggestion was made for until its text is sent, so that
/// memory learns what became of the suggestion (`FieldSessionTracker`). It reads that one field,
/// every 100 ms, and only while a session is open. The texts stay in memory and go with the session.
@MainActor
final class FieldObserver {
    private let settings: SettingsStore
    private let memory: MemoryCoordinator
    private var tracker = FieldSessionTracker()
    /// The capture whose field is followed, and the number that stands for that field.
    private var capture: TextCaptureService.CaptureResult?
    private var fieldID = 0
    private var loopTask: Task<Void, Never>?
    private let pollInterval: Duration = .milliseconds(100)
    /// An app that takes this long to answer is not followed: every read would stall Lint.
    private let slowRead: Duration = .milliseconds(500)

    init(settings: SettingsStore, memory: MemoryCoordinator) {
        self.settings = settings
        self.memory = memory
    }

    private var isEnabled: Bool { settings.memoryEnabled && settings.observationEnabled }

    /// A finished suggestion waits behind the ready chip over the field of `capture`.
    func suggestionReady(_ suggestion: ObservedSuggestion, for capture: TextCaptureService.CaptureResult) {
        note(suggestion, for: capture, opened: false)
    }

    /// A finished suggestion for the text of `capture` is on screen. False when it is not followed:
    /// observation mode is off, the model changed nothing, or the field cannot be read back.
    func opened(_ suggestion: ObservedSuggestion, for capture: TextCaptureService.CaptureResult) -> Bool {
        note(suggestion, for: capture, opened: true)
    }

    /// Replace wrote `written` over the text the suggestion on screen was made for.
    func replaced(written: String) {
        _ = tracker.handle(.replaced(written: written), at: Date())
    }

    /// The suggestion on screen was copied.
    func copied() {
        _ = tracker.handle(.copied, at: Date())
    }

    @discardableResult
    private func note(
        _ suggestion: ObservedSuggestion, for capture: TextCaptureService.CaptureResult, opened: Bool
    ) -> Bool {
        guard isEnabled else {
            stop()
            return false
        }
        guard !suggestion.changesNothing,
              let app = capture.sourceBundleID, app != Bundle.main.bundleIdentifier,
              !LiveCheckPolicy.isDenylisted(app),
              let value = TextCaptureService.readValue(of: capture),
              let located = suggestion.located(
                  in: value,
                  // A range some app made up must not trap; `located` checks the rest.
                  utf16Range: capture.selectedRange.flatMap { $0.length >= 0 ? $0.location..<($0.location + $0.length) : nil }
              )
        else { return false }
        if let followed = self.capture, TextCaptureService.sameField(followed, capture) {
            // The same field: its session goes on.
        } else {
            fieldID += 1
            DiagnosticLog.shared.log("observe", "start app=\(app)")
        }
        self.capture = capture
        let field = ObservedField(app: app, id: fieldID)
        if let ended = tracker.handle(opened ? .opened(located, in: field) : .suggestionReady(located, in: field), at: Date()) {
            record(ended)
        }
        startLoop()
        return true
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.poll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func poll() {
        guard isEnabled, let capture else {
            stop()
            return
        }
        let started = ContinuousClock.now
        let value = TextCaptureService.readValue(of: capture)
        let outcome: SessionOutcome?
        if ContinuousClock.now - started > slowRead {
            DiagnosticLog.shared.log("observe", "the field is too slow to read")
            outcome = tracker.giveUp()
        } else {
            outcome = tracker.handle(.fieldRead(value), at: Date())
        }
        if let outcome { record(outcome) }
        if !tracker.isTracking { stop() }
    }

    /// Stops reading. A session that is still open is dropped, and nothing is recorded for it.
    private func stop() {
        loopTask?.cancel()
        loopTask = nil
        capture = nil
        tracker = FieldSessionTracker()
    }

    private func record(_ outcome: SessionOutcome) {
        DiagnosticLog.shared.log(
            "observe",
            "end app=\(outcome.app) result=\(outcome.result.rawValue) ending=\(outcome.ending.rawValue) "
                + "sentChars=\(outcome.sentText.map { String($0.count) } ?? "none")"
        )
        let config = settings.memoryConfig
        Task { [memory] in
            await memory.recordObservation(outcome, config: config)
        }
    }
}
