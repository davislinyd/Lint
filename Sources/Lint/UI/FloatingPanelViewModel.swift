import AppKit
import Foundation
import LintCore
import Observation

@MainActor
@Observable
final class FloatingPanelViewModel {
    var originalText = ""
    var resultText = ""
    /// Traditional Chinese gloss of `resultText` (bubble helper).
    var translationText = ""
    var isTranslating = false
    var isStreaming = false
    var errorMessage: String?
    var statusNote: String?
    /// Compared against `statusNote` to clear it once the user types; keep one localized copy.
    static let noSelectionNote = String(localized: "沒有選取文字。可直接在左側輸入，再按「產生」。")
    var usedClipboardFallback = false
    var mode: WritingMode = .proofread
    var testOutput: String = ""
    var lastUsage: TokenUsage?
    /// Compact bubble session — use lowest latency settings.
    private(set) var isAutoSuggestSession = false

    let settings: SettingsStore
    private let capture: TextCaptureService
    private let llm: LLMService
    private var translationTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    // Background prefetch while the selection chip is visible.
    private var prefetchTask: Task<Void, Never>?
    private var prefetchSourceText: String?
    private var prefetchBuffer = ""
    private var prefetchFinished = false
    private var prefetchError: String?
    private var prefetchAttachedToUI = false
    /// zh-TW gloss of the finished prefetch, fetched in the background so the bubble opens complete.
    private var prefetchTranslationTask: Task<Void, Never>?
    private var prefetchTranslation: String?
    private(set) var isPrefetching = false
    private(set) var isPrefetchReady = false
    /// Called when prefetch state flips (chip label can refresh).
    var onPrefetchStateChange: (() -> Void)?

    init(settings: SettingsStore, capture: TextCaptureService, llm: LLMService) {
        self.settings = settings
        self.capture = capture
        self.llm = llm
        self.mode = settings.lastMode
    }

    func adoptCapture(_ result: TextCaptureService.CaptureResult) {
        capture.adopt(result)
        // Debug: confirm Replace will have an AX target.
        print("Lint adoptCapture hasAX=\(result.axElement != nil) range=\(String(describing: result.selectedRange)) pid=\(String(describing: result.sourceAppPID)) textCount=\(result.text.count)")
    }

    /// Start (or keep) a background suggestion for the current selection chip.
    func beginPrefetch(for result: TextCaptureService.CaptureResult) {
        let text = result.text
        if prefetchSourceText == text, (isPrefetching || isPrefetchReady || prefetchAttachedToUI) {
            return
        }
        cancelPrefetch()
        prefetchSourceText = text
        prefetchBuffer = ""
        prefetchFinished = false
        prefetchError = nil
        prefetchAttachedToUI = false
        isPrefetching = true
        isPrefetchReady = false
        onPrefetchStateChange?()
        let adopted = result
        prefetchTask = Task { [weak self] in
            await self?.runPrefetch(for: adopted)
        }
    }

    private var prefetchSystemPrompt: String {
        settings.effectiveSystemPrompt(for: settings.lastMode) + "\n回覆只要修正後的全文，不要解釋。"
    }

    private var lastModelActivity = Date.distantPast

    /// The local model can be paged out while idle, making the next request take seconds
    /// (seen 4–13 s). Touch it (same system prompt as prefetch, so its KV prefix is cached
    /// too) as soon as typing starts, so the load overlaps with typing instead of the check.
    func warmUpIfIdle() {
        guard settings.wantsManagedLocalServer,
              Date().timeIntervalSince(lastModelActivity) > 60 else { return }
        lastModelActivity = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureLocalServerIfNeeded()
                let config = try self.settings.runtimeConfig()
                let request = ChatRequest(
                    model: config.model,
                    systemPrompt: self.prefetchSystemPrompt,
                    userText: "hi",
                    maxTokens: 1,
                    reasoningEffort: .low,
                    fastMode: self.settings.fastMode
                )
                for try await _ in try self.llm.stream(config: config, request: request) {}
            } catch {}
        }
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTranslationTask?.cancel()
        prefetchTranslationTask = nil
        prefetchTranslation = nil
        isPrefetching = false
        isPrefetchReady = false
        prefetchSourceText = nil
        prefetchBuffer = ""
        prefetchFinished = false
        prefetchError = nil
        prefetchAttachedToUI = false
        onPrefetchStateChange?()
    }

    /// Chip click: reuse prefetch if it matches, otherwise stream fresh.
    func consumePrefetchOrStream(_ result: TextCaptureService.CaptureResult) {
        let text = result.text
        if prefetchSourceText == text {
            errorMessage = nil
            statusNote = nil
            isAutoSuggestSession = true
            mode = settings.lastMode
            originalText = text
            usedClipboardFallback = result.usedClipboardFallback
            lastUsage = nil
            resultText = prefetchBuffer
            if prefetchFinished {
                isStreaming = false
                errorMessage = prefetchError
                prefetchTask = nil
                isPrefetching = false
                onPrefetchStateChange?()
                if prefetchError == nil, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let gloss = prefetchTranslation {
                        cancelTranslation()
                        translationText = gloss
                    } else {
                        prefetchTranslationTask?.cancel()
                        scheduleTranslationOfResult()
                    }
                }
                return
            }
            // Still running — attach the live buffer to the bubble UI.
            prefetchAttachedToUI = true
            isStreaming = true
            onPrefetchStateChange?()
            return
        }
        cancelPrefetch()
        prepareAutoSuggestUI(with: result)
        streamAdoptedCapture(result)
    }

    func captureAndStream() {
        streamTask?.cancel()
        streamTask = Task { await runCaptureAndStream() }
    }

    /// Auto-suggest path: capture already adopted on TextCaptureService.
    func prepareAutoSuggestUI(with result: TextCaptureService.CaptureResult) {
        errorMessage = nil
        resultText = ""
        clearTranslation()
        statusNote = nil
        isAutoSuggestSession = true
        mode = settings.lastMode
        originalText = result.text
        usedClipboardFallback = result.usedClipboardFallback
        isStreaming = true
        lastUsage = nil
    }

    func streamAdoptedCapture(_ result: TextCaptureService.CaptureResult) {
        streamTask?.cancel()
        streamTask = Task { await runAdoptedCapture(result) }
    }

    /// Show bubble chrome with a status/error and no streaming.
    func prepareMessageOnly(_ message: String) {
        streamTask?.cancel()
        cancelPrefetch()
        clearTranslation()
        isStreaming = false
        isAutoSuggestSession = true
        originalText = ""
        resultText = ""
        lastUsage = nil
        errorMessage = message
        statusNote = nil
    }

    func retry() {
        generateFromOriginal()
    }

    /// Run the model on whatever is currently in `originalText` (selection or typed).
    func generateFromOriginal() {
        streamTask?.cancel()
        cancelPrefetch()
        errorMessage = nil
        if statusNote == Self.noSelectionNote {
            statusNote = nil
        }
        streamTask = Task { await runStream(forceLowReasoning: isAutoSuggestSession) }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        if prefetchAttachedToUI {
            cancelPrefetch()
        }
        isStreaming = false
    }

    func copyResult() {
        guard !resultText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resultText, forType: .string)
    }

    func replaceOriginal() {
        Task {
            _ = await replaceOriginalReturningError()
        }
    }

    @discardableResult
    func replaceOriginalReturningError() async -> String? {
        if let message = await capture.replaceLast(with: resultText) {
            errorMessage = message
            return message
        }
        return nil
    }

    func testConnection() {
        streamTask?.cancel()
        streamTask = Task { await runTestConnection() }
    }

    private func ensureLocalServerIfNeeded() async throws {
        guard settings.wantsManagedLocalServer else { return }
        try await LocalLlamaServerManager.shared.ensureRunning(settings: settings)
    }

    private func runPrefetch(for result: TextCaptureService.CaptureResult) async {
        do {
            try await ensureLocalServerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let source = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            prefetchFinished = true
            isPrefetching = false
            isPrefetchReady = false
            prefetchError = String(localized: "沒有原文可送出。")
            onPrefetchStateChange?()
            return
        }

        do {
            let config = try settings.runtimeConfig()
            let request = ChatRequest(
                model: config.model,
                systemPrompt: prefetchSystemPrompt,
                userText: result.text,
                reasoningEffort: .low,
                fastMode: settings.fastMode
            )
            let stream = try llm.stream(config: config, request: request)
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .text(let token):
                    prefetchBuffer.append(token)
                    if prefetchAttachedToUI {
                        resultText = prefetchBuffer
                    }
                case .usage(let usage):
                    if prefetchAttachedToUI {
                        lastUsage = usage
                    }
                }
            }
            if Task.isCancelled { return }
            prefetchFinished = true
            lastModelActivity = Date()
            isPrefetching = false
            isPrefetchReady = prefetchError == nil && !prefetchBuffer.isEmpty
            if prefetchAttachedToUI {
                resultText = prefetchBuffer
                isStreaming = false
                errorMessage = prefetchBuffer.isEmpty ? (prefetchError ?? String(localized: "沒有收到建議。")) : nil
                if errorMessage == nil {
                    scheduleTranslationOfResult()
                }
            } else if isPrefetchReady {
                startPrefetchTranslation()
            }
            onPrefetchStateChange?()
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            prefetchError = error.localizedDescription
            prefetchFinished = true
            isPrefetching = false
            isPrefetchReady = false
            if prefetchAttachedToUI {
                isStreaming = false
                errorMessage = error.localizedDescription
            }
            onPrefetchStateChange?()
        }
    }

    private func runAdoptedCapture(_ result: TextCaptureService.CaptureResult) async {
        do {
            try await ensureLocalServerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if !isAutoSuggestSession || originalText != result.text {
            prepareAutoSuggestUI(with: result)
        }
        await runStream(forceLowReasoning: true)
    }

    private func runCaptureAndStream() async {
        do {
            try await ensureLocalServerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        resultText = ""
        originalText = ""
        statusNote = nil
        isAutoSuggestSession = false
        mode = settings.lastMode
        usedClipboardFallback = false
        if let captured = await capture.capture() {
            originalText = captured.text
            usedClipboardFallback = captured.usedClipboardFallback
            if captured.usedClipboardFallback {
                if !AccessibilityPermission.isTrusted {
                    statusNote = String(localized: "未授權輔助功能，已改用剪貼簿擷取。")
                } else {
                    statusNote = String(localized: "此應用程式無法用輔助功能讀取選取，已改用剪貼簿。")
                }
            }
            await runStream()
            return
        }
        // No selection: keep panel open for manual input.
        statusNote = Self.noSelectionNote
    }

    
    private func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    private func clearTranslation() {
        cancelTranslation()
        translationText = ""
    }

    /// After a suggestion is ready, fetch a short zh-TW gloss for the bubble.
    private func scheduleTranslationOfResult() {
        cancelTranslation()
        let source = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            translationText = ""
            return
        }
        translationTask = Task { await self.translateResult(source) }
    }

    private static let translationSystemPrompt = """
        你是翻譯。把使用者文字譯成流暢的台灣繁體中文。
        只輸出譯文，不要引號、標籤或說明。
        若原文已是繁體中文，原樣輸出即可。
        保留專有名詞、產品名、程式碼與 URL。
        """

    /// Local model only — a cloud provider would pay for a second request per typing pause.
    private func startPrefetchTranslation() {
        guard settings.wantsManagedLocalServer else { return }
        let source = prefetchBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        prefetchTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try self.settings.runtimeConfig()
                let request = ChatRequest(
                    model: config.model,
                    systemPrompt: Self.translationSystemPrompt,
                    userText: source,
                    maxTokens: 512,
                    reasoningEffort: .low,
                    fastMode: true
                )
                var out = ""
                for try await event in try self.llm.stream(config: config, request: request) {
                    if case .text(let token) = event { out += token }
                }
                if !Task.isCancelled {
                    self.prefetchTranslation = out.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {}
        }
    }

    private func translateResult(_ source: String) async {
        isTranslating = true
        translationText = ""
        defer { isTranslating = false }
        do {
            try await ensureLocalServerIfNeeded()
            let config = try settings.runtimeConfig()
            let request = ChatRequest(
                model: config.model,
                systemPrompt: Self.translationSystemPrompt,
                userText: source,
                maxTokens: 512,
                reasoningEffort: .low,
                fastMode: true
            )
            let stream = try llm.stream(config: config, request: request)
            var out = ""
            for try await event in stream {
                if Task.isCancelled { return }
                if case .text(let token) = event {
                    out += token
                    translationText = out
                }
            }
            if !Task.isCancelled {
                translationText = out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch is CancellationError {
            return
        } catch {
            // Soft-fail: gloss is optional; keep the suggestion usable.
            if translationText.isEmpty {
                translationText = ""
            }
        }
    }

    private func runStream(forceLowReasoning: Bool = false) async {
        do {
            try await ensureLocalServerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let source = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            errorMessage = String(localized: "沒有原文可送出。")
            isStreaming = false
            return
        }
        settings.lastMode = mode
        errorMessage = nil
        resultText = ""
        clearTranslation()
        lastUsage = nil
        isStreaming = true
        defer { isStreaming = false }
        do {
            let config = try settings.runtimeConfig()
            let effort: ReasoningEffort = forceLowReasoning ? .low : settings.reasoningEffort
            let systemPrompt: String
            if forceLowReasoning {
                systemPrompt = settings.effectiveSystemPrompt(for: mode)
                    + "\n回覆只要修正後的全文，不要解釋。"
            } else {
                systemPrompt = settings.effectiveSystemPrompt(for: mode)
            }
            let request = ChatRequest(
                model: config.model,
                systemPrompt: systemPrompt,
                userText: originalText,
                reasoningEffort: effort,
                fastMode: settings.fastMode
            )
            let stream = try llm.stream(config: config, request: request)
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .text(let token):
                    resultText.append(token)
                case .usage(let usage):
                    lastUsage = usage
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if !Task.isCancelled, errorMessage == nil, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleTranslationOfResult()
        }
    }

    private func runTestConnection() async {
        do {
            try await ensureLocalServerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        testOutput = ""
        errorMessage = nil
        lastUsage = nil
        isStreaming = true
        defer { isStreaming = false }
        do {
            let config = try settings.runtimeConfig()
            let request = ChatRequest(
                model: config.model,
                systemPrompt: "Reply with the single word pong. No other text.",
                userText: "ping",
                maxTokens: 64,
                reasoningEffort: settings.reasoningEffort,
                fastMode: settings.fastMode
            )
            let stream = try llm.stream(config: config, request: request)
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .text(let token):
                    testOutput.append(token)
                case .usage(let usage):
                    lastUsage = usage
                }
            }
            if testOutput.isEmpty {
                errorMessage = String(localized: "連線成功但沒有收到正文（可能全是 reasoning）。")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
