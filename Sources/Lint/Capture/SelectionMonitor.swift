import AppKit
import ApplicationServices

/// Polls AX selection and/or focused field text, then shows the check chip after debounce.
/// - Selection path: ~180ms after a stable highlight.
/// - Live typing path: ~500ms after the focused field stops changing.
@MainActor
final class SelectionMonitor {
    private let settings: SettingsStore
    private let capture: TextCaptureService
    private let onSuggest: (TextCaptureService.CaptureResult) -> Void
    private let onCleared: () -> Void
    /// While true, ignore input changes (bubble is interacting).
    var isPaused = false
    private var loopTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var pendingText: String?
    private var pendingSince: ContinuousClock.Instant?
    private var pendingResult: TextCaptureService.CaptureResult?
    private var lastHandledText: String?
    private let minLength = 8
    private let selectionStableDuration: Duration = .milliseconds(180)
    private let typingIdleDuration: Duration = .milliseconds(500)
    private let pollInterval: Duration = .milliseconds(100)
    /// Ignore brief AX gaps so the chip does not dismiss / jump.
    private let clearGrace: Duration = .milliseconds(450)

    init(
        settings: SettingsStore,
        capture: TextCaptureService,
        onSuggest: @escaping (TextCaptureService.CaptureResult) -> Void,
        onCleared: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.capture = capture
        self.onSuggest = onSuggest
        self.onCleared = onCleared
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.tick()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        clearTask?.cancel()
        clearTask = nil
        pendingText = nil
        pendingSince = nil
        pendingResult = nil
    }

    private func tick() {
        guard !isPaused else { return }
        let watchSelection = settings.autoSuggestOnSelection
        let watchTyping = settings.liveWatchWhileTyping
        guard watchSelection || watchTyping else {
            pendingText = nil
            pendingSince = nil
            pendingResult = nil
            clearTask?.cancel()
            clearTask = nil
            return
        }
        guard AccessibilityPermission.isTrusted else { return }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontBundle == Bundle.main.bundleIdentifier {
            return
        }

        let peeked: TextCaptureService.CaptureResult?
        let idle: Duration
        if watchSelection, let selection = capture.peekAXSelection() {
            peeked = selection
            idle = selectionStableDuration
        } else if watchTyping,
                  let snippet = capture.peekAXFocusedSnippet(),
                  TextLanguage.shouldAutoWatchTyping(snippet.text) {
            peeked = snippet
            idle = typingIdleDuration
        } else {
            peeked = nil
            idle = selectionStableDuration
        }

        guard let peeked else {
            scheduleClearIfNeeded()
            return
        }

        clearTask?.cancel()
        clearTask = nil

        let trimmed = peeked.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLength else {
            pendingText = nil
            pendingSince = nil
            pendingResult = nil
            if lastHandledText != nil {
                lastHandledText = nil
                onCleared()
            }
            return
        }

        if trimmed == lastHandledText {
            // Same text, but geometry may have caught up after a large paste — re-park chip.
            capture.adopt(peeked)
            onSuggest(peeked)
            return
        }

        let now = ContinuousClock.now
        if trimmed == pendingText, let since = pendingSince {
            if now - since >= idle {
                lastHandledText = trimmed
                pendingText = nil
                pendingSince = nil
                pendingResult = nil
                capture.adopt(peeked)
                onSuggest(peeked)
            } else {
                // Update anchor geometry while waiting so a late show is accurate.
                pendingResult = peeked
            }
        } else {
            // User kept typing (or selection changed). Hide any chip that would
            // cover the caret / new characters, then restart the idle timer.
            if lastHandledText != nil {
                lastHandledText = nil
                onCleared()
            }
            pendingText = trimmed
            pendingSince = now
            pendingResult = peeked
        }
    }

    private func scheduleClearIfNeeded() {
        let hadSuggestion = lastHandledText != nil || pendingText != nil
        guard hadSuggestion else { return }
        guard clearTask == nil else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: self?.clearGrace ?? .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            let stillThere =
                (self.settings.autoSuggestOnSelection && self.capture.peekAXSelection() != nil)
                || (self.settings.liveWatchWhileTyping && self.capture.peekAXFocusedSnippet() != nil)
            if stillThere { return }
            self.pendingText = nil
            self.pendingSince = nil
            self.pendingResult = nil
            self.lastHandledText = nil
            self.clearTask = nil
            self.onCleared()
        }
    }
}
