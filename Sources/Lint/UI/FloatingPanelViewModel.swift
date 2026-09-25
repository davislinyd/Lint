import AppKit
import Foundation
import LintCore
import Observation

@MainActor
@Observable
final class FloatingPanelViewModel {
    var originalText = ""
    var resultText = ""
    /// Gloss of `resultText` in `translationLanguage` (bubble helper).
    var translationText = ""
    /// The language `translationText` is in.
    private(set) var translationLanguage: TranslationLanguage = .traditionalChinese
    var isTranslating = false { didSet { reportInteractiveActivity() } }
    var isStreaming = false { didSet { reportInteractiveActivity() } }
    var errorMessage: String? {
        didSet { if errorMessage == nil { setupErrorPending = false } }
    }
    /// The last local-server check failed because Local AI is not set up yet (a background warm-up
    /// can hit this without any message being shown).
    private var setupErrorPending = false
    /// The message on screen is "Local AI is not set up yet": the panel offers a Set Up Local AI
    /// button instead of leaving the user with a bare message.
    var needsLocalAISetup: Bool { setupErrorPending && errorMessage != nil }
    var onOpenLocalAISetup: (() -> Void)?
    var onOpenModelSettings: (() -> Void)?
    var statusNote: String?
    /// Compared against `statusNote` to clear it once the user types; keep one localized copy.
    static let noSelectionNote = String(localized: "沒有選取文字。可直接在左側輸入，再按「產生」。")
    var usedClipboardFallback = false
    /// The task. Choosing another one brings back the tone that task remembers.
    var mode: WritingMode = .proofread {
        didSet { if mode != oldValue { tone = settings.tone(for: mode) } }
    }
    /// How it should sound; each task remembers its own (see `SettingsStore.tones`).
    var tone: WritingTone = .preserve {
        didSet { if tone != oldValue { settings.setTone(tone, for: mode) } }
    }
    /// The task, and the tone if one applies and was chosen: what the panel and the bubble call it.
    var modeTitle: String { mode.displayTitle(tone: tone) }
    var testOutput: String = ""
    var lastUsage: TokenUsage?
    /// Compact bubble session — use lowest latency settings.
    private(set) var isAutoSuggestSession = false
    /// Bumped to ask the full panel to open its result editor with the focus in it. A count rather
    /// than a flag, so that asking again while the editor is already open still fires.
    private(set) var resultEditRequest = 0

    let settings: SettingsStore
    private let capture: TextCaptureService
    private let llm: LLMService
    private let learning: LearningCoordinator
    private let localAI: LocalAISetupCoordinator
    private let appleIntelligence: any AppleIntelligenceAvailabilityChecking
    /// Only the newest request may put its answer on screen (see `WritingRequestTickets`).
    private var tickets = WritingRequestTickets()
    private var translationTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    /// A finished suggestion, kept apart from `resultText` (which the user may edit) so feedback can
    /// compare the two. nil while streaming or after a failure, so half-streamed text never counts.
    private struct GeneratedSuggestion {
        let source: String
        let text: String
        let mode: WritingMode
        let tone: WritingTone
        /// Memories that were in the prompt that produced it.
        let usedMemoryIDs: [UUID]
        /// The engine that wrote it (Automatic resolved), as recorded with feedback.
        let provider: ProviderKind
        /// What a translation was written in; nil for the other tasks.
        let translationLanguage: TranslationLanguage?
    }
    private var generated: GeneratedSuggestion?

    // Background prefetch while the selection chip is visible.
    private var prefetchTask: Task<Void, Never>?
    /// What the prefetch in flight (or finished) was asked for. It is used only for a request with an
    /// equal key: not one for another text, mode, tone, translation target or custom prompt.
    private var prefetchKey: WritingRequestKey?
    private var prefetchBuffer = ""
    private var prefetchUsedMemoryIDs: [UUID] = []
    private var prefetchFinished = false
    private var prefetchError: String?
    /// The engine the prefetch went to, and for the on-device path what the output check made of it.
    private var prefetchProvider: ProviderKind = .localLlama
    private var prefetchNote: String?
    private var prefetchIsSuggestion = true
    private var prefetchAttachedToUI = false
    /// Gloss of the finished prefetch, fetched in the background so the bubble opens complete.
    private var prefetchTranslationTask: Task<Void, Never>?
    private var prefetchTranslation: (language: TranslationLanguage, text: String)?
    private(set) var isPrefetching = false { didSet { reportInteractiveActivity() } }
    private(set) var isPrefetchReady = false
    /// Called when prefetch state flips (chip label can refresh).
    var onPrefetchStateChange: (() -> Void)?

    init(
        settings: SettingsStore, capture: TextCaptureService, llm: LLMService, learning: LearningCoordinator,
        localAI: LocalAISetupCoordinator,
        appleIntelligence: any AppleIntelligenceAvailabilityChecking = SystemAppleIntelligence()
    ) {
        self.settings = settings
        self.capture = capture
        self.llm = llm
        self.learning = learning
        self.localAI = localAI
        self.appleIntelligence = appleIntelligence
        loadSelectionFromSettings()
    }

    /// The task last used, and the tone that task remembers.
    private func loadSelectionFromSettings() {
        mode = settings.lastMode
        tone = settings.tone(for: mode)
    }

    func adoptCapture(_ result: TextCaptureService.CaptureResult) {
        capture.adopt(result)
        // Debug: confirm Replace will have an AX target.
        print("Lint adoptCapture hasAX=\(result.axElement != nil) range=\(String(describing: result.selectedRange)) pid=\(String(describing: result.sourceAppPID)) textCount=\(result.text.count)")
    }

    /// Start (or keep) a background suggestion for the current selection chip.
    func beginPrefetch(for result: TextCaptureService.CaptureResult) {
        let key = currentRequestKey(for: result.text)
        if prefetchKey == key, (isPrefetching || isPrefetchReady || prefetchAttachedToUI) {
            return
        }
        cancelPrefetch()
        prefetchKey = key
        prefetchBuffer = ""
        prefetchFinished = false
        prefetchError = nil
        prefetchAttachedToUI = false
        isPrefetching = true
        isPrefetchReady = false
        onPrefetchStateChange?()
        prefetchNote = nil
        prefetchIsSuggestion = true
        let adopted = result
        // Built now, not when the request goes out: it has to be the prompt that `key` stands for.
        let prompts = PrefetchPrompts(
            standard: Self.terseSystemPrompt(settings.effectiveSystemPrompt(for: key.mode, tone: key.tone)),
            apple: settings.effectiveSystemPrompt(for: key.mode, tone: key.tone, profile: .english(.appleOnDevice)),
            local: settings.effectiveSystemPrompt(for: key.mode, tone: key.tone, profile: .english(.localModel))
        )
        prefetchTask = Task { [weak self] in
            await self?.runPrefetch(for: adopted, key: key, prompts: prompts)
        }
    }

    /// A prefetch's prompts, built when it starts: which one is sent depends on the engine the request
    /// is routed to, which is only known later.
    private struct PrefetchPrompts {
        let standard: String
        let apple: String
        let local: String

        func prompt(for profile: WritingPromptProfile) -> String {
            switch profile {
            case .standard: standard
            case .english(.appleOnDevice): apple
            case .english(.localModel): local
            }
        }
    }

    /// The request the settings in force now make for `source`.
    private func currentRequestKey(for source: String) -> WritingRequestKey {
        let mode = settings.lastMode
        return WritingRequestKey(
            source: source, mode: mode, tone: settings.tone(for: mode), customPrompt: settings.customPrompt,
            translationLanguage: settings.translationLanguage
        )
    }

    /// Prefetch, the bubble and the warm-up ask for the bare text, so they say so.
    private static func terseSystemPrompt(_ prompt: String) -> String {
        prompt + "\n回覆只要修正後的全文，不要解釋。"
    }

    /// Proofreading wants near-deterministic output, but llama-server samples at about 0.8 unless
    /// told otherwise. Hosted OpenAI models may reject the field, so only local and compatible endpoints get it.
    private static func rewriteTemperature(for kind: ProviderKind) -> Double? {
        kind == .localLlama || kind == .openaiCompatible ? 0.3 : nil
    }

    private var lastModelActivity = Date.distantPast

    /// The local model can be paged out while idle, making the next request take seconds
    /// (seen 4–13 s). Touch it (same system prompt as prefetch, so its KV prefix is cached
    /// too) as soon as typing starts, so the load overlaps with typing instead of the check.
    /// Only for Lint's local server. Apple Intelligence is not warmed up: `LanguageModelSession.prewarm`
    /// made no measurable difference on the development Mac (docs/APPLE-INTELLIGENCE.md), so the model
    /// is touched only by a real request.
    func warmUpIfIdle() {
        guard Date().timeIntervalSince(lastModelActivity) > 60 else { return }
        lastModelActivity = Date()
        Task { [weak self] in
            guard let self else { return }
            let route = await self.resolveRoute()
            guard self.settings.wantsManagedLocalServer(for: route) else { return }
            do {
                try await self.ensureLocalServerIfNeeded(for: route)
                let config = try self.settings.runtimeConfig(for: .localLlama)
                let request = ChatRequest(
                    model: config.model,
                    // The prompt the next request will start with, so llama-server caches its prefix.
                    systemPrompt: self.settings.effectiveSystemPrompt(
                        for: self.settings.lastMode, tone: self.settings.tone(for: self.settings.lastMode),
                        profile: WritingPromptProfile.for(provider: .localLlama)
                    ),
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
        prefetchKey = nil
        prefetchBuffer = ""
        prefetchUsedMemoryIDs = []
        prefetchFinished = false
        prefetchError = nil
        prefetchNote = nil
        prefetchIsSuggestion = true
        prefetchAttachedToUI = false
        onPrefetchStateChange?()
    }

    /// Chip click: reuse prefetch if it matches, otherwise stream fresh.
    func consumePrefetchOrStream(_ result: TextCaptureService.CaptureResult) {
        let text = result.text
        // Only a prefetch made for what the settings ask for now; after a change of mode, tone or
        // translation target (from the status menu, say) it would answer another question.
        if prefetchKey == currentRequestKey(for: text) {
            errorMessage = nil
            statusNote = nil
            generated = nil
            isAutoSuggestSession = true
            loadSelectionFromSettings()
            originalText = text
            usedClipboardFallback = result.usedClipboardFallback
            lastUsage = nil
            resultText = prefetchBuffer
            if prefetchFinished {
                isStreaming = false
                errorMessage = prefetchError
                statusNote = prefetchNote
                prefetchTask = nil
                isPrefetching = false
                onPrefetchStateChange?()
                if prefetchError == nil, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    generated = prefetchIsSuggestion ? GeneratedSuggestion(
                        source: text, text: resultText, mode: mode, tone: tone, usedMemoryIDs: prefetchUsedMemoryIDs,
                        provider: prefetchProvider, translationLanguage: prefetchKey?.translationLanguage
                    ) : nil
                    if let gloss = prefetchTranslation, gloss.language == settings.translationLanguage {
                        cancelTranslation()
                        translationLanguage = gloss.language
                        translationText = gloss.text
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

    /// `showPanel` runs once the selection has been read: showing the panel activates Lint, and from then on
    /// the focused element is Lint's own, not the field the selection is in.
    func captureAndStream(showPanel: @escaping @MainActor () -> Void) {
        streamTask?.cancel()
        streamTask = Task { await runCaptureAndStream(showPanel: showPanel) }
    }

    /// Auto-suggest path: capture already adopted on TextCaptureService.
    func prepareAutoSuggestUI(with result: TextCaptureService.CaptureResult) {
        errorMessage = nil
        resultText = ""
        generated = nil
        clearTranslation()
        statusNote = nil
        isAutoSuggestSession = true
        loadSelectionFromSettings()
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
        generated = nil
        lastUsage = nil
        errorMessage = message
        statusNote = nil
    }

    func retry() {
        generateFromOriginal()
    }

    /// A finished suggestion is on screen, so it can be handed to the full panel to edit.
    var canEditInFullPanel: Bool {
        !isStreaming && !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The bubble hands its suggestion to the full panel. Nothing is regenerated or reset: the
    /// panel shows what the bubble showed, with the result ready to edit. From here it is a
    /// full-panel session, so a retry follows the settings and not the bubble's low-latency shortcuts.
    func handOffForEditing() {
        isAutoSuggestSession = false
        resultEditRequest += 1
    }

    /// Run the model on whatever is currently in `originalText` (selection or typed).
    func generateFromOriginal() {
        // Running again on the same text, mode and tone is a rejection; a new text, mode or tone is not.
        if let generated, generated.source == originalText, generated.mode == mode, generated.tone == tone {
            recordFeedback(.regenerated)
        }
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
        tickets.invalidate()
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
        recordFeedback(.copied)
    }

    @discardableResult
    func replaceOriginalReturningError() async -> String? {
        if let message = await capture.replaceLast(with: resultText) {
            errorMessage = message
            return message
        }
        recordFeedback(.replaced)
        return nil
    }

    /// Says whether the user is waiting on a suggestion, so that the upkeep of the learned memories
    /// keeps out of the way of it.
    private func reportInteractiveActivity() {
        learning.setInteractiveActivity(isStreaming || isPrefetching || isTranslating)
    }

    /// Lint edits English only: a proofread of text without any English is not sent to a model, so
    /// the local one is not even woken for it.
    private static func hasNoEnglish(_ text: String, mode: WritingMode) -> Bool {
        mode == .proofread && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !TextScript.hasEnglish(text)
    }

    private static var noEnglishMessage: String { String(localized: "Lint 只校對英文，這段文字裡沒有英文。") }

    /// The prompt with the user's learned habits added; untouched, and without a moment's delay,
    /// while learning is off. The lookup runs off the main actor and is cut short rather than let
    /// it hold a suggestion back.
    private func personalize(
        _ prompt: String, for text: String, mode: WritingMode, tone: WritingTone, english: Bool,
        translationLanguage: TranslationLanguage?
    ) async -> PersonalizedPrompt {
        guard settings.learningEnabled else {
            return PersonalizedPrompt(systemPrompt: prompt, usedMemoryIDs: [])
        }
        return await learning.personalize(
            prompt: prompt, for: text, mode: mode, tone: tone, english: english,
            translationLanguage: translationLanguage ?? .traditionalChinese, config: settings.learningConfig
        )
    }

    /// Tells the learning subsystem what the user did with the suggestion on screen. Fire and
    /// forget; a suggestion that never finished streaming is passed as nil and ignored there.
    private func recordFeedback(_ gesture: UserGesture) {
        guard settings.learningEnabled else { return }
        // A translation into another language is only there to be read: nothing is learned from it.
        if let language = generated?.translationLanguage, language != .traditionalChinese { return }
        let feedback = LearningFeedback(
            gesture: gesture,
            mode: generated?.mode ?? mode,
            tone: generated?.tone ?? tone,
            originalText: generated?.source ?? originalText,
            generatedText: generated?.text,
            finalText: resultText,
            provider: (generated?.provider ?? settings.providerKind).rawValue,
            model: settings.model,
            usedMemoryIDs: generated?.usedMemoryIDs ?? []
        )
        let config = settings.learningConfig
        Task { [learning] in
            await learning.recordFeedback(feedback, config: config)
        }
    }

    func testConnection() {
        streamTask?.cancel()
        streamTask = Task { await runTestConnection() }
    }

    /// Where a request goes now (see `WritingEngineRouter`). Cheap: Apple Intelligence's status is a
    /// property read, and local AI is only looked at (never started) if it has not been yet.
    private func resolveRoute() async -> WritingEngineRoute {
        let selected = settings.providerKind
        let apple = selected == .automatic || selected == .appleIntelligence
            ? appleIntelligence.currentStatus() : .unavailable
        if selected == .automatic, !apple.isAvailable, !localAI.hasChecked {
            await localAI.refresh()
        }
        return WritingEngineRouter.route(
            selected: selected, apple: apple,
            localAIReady: localAI.hasChecked && localAI.runtimeReady && localAI.modelReady
        )
    }

    /// The engine for a request, ready to use: Lint's local server is started only when the request
    /// goes to it. When nothing can take the request, a friendly error (with the local AI setup
    /// button only where `WritingEngineRouter.offersLocalAISetup` says so).
    private func prepareEngine() async throws -> WritingEngineRoute {
        let route = await resolveRoute()
        if case .unavailable(let status) = route {
            if WritingEngineRouter.offersLocalAISetup(selected: settings.providerKind, apple: status, localAIReady: false) {
                setupErrorPending = true
            }
            throw AppleIntelligenceError.unavailable(status)
        }
        if route == .appleIntelligence {
            localAI.releaseForAppleIntelligence()
        }
        try await ensureLocalServerIfNeeded(for: route)
        return route
    }

    private func ensureLocalServerIfNeeded(for route: WritingEngineRoute) async throws {
        guard settings.wantsManagedLocalServer(for: route) else { return }
        do {
            try await localAI.ensureServerRunning()
        } catch let error as LocalAIError where error.needsSetup {
            // Not set up yet: a friendly message with a way forward, never a connection error.
            setupErrorPending = true
            throw error
        }
    }

    func openLocalAISetup() {
        onOpenLocalAISetup?()
    }

    func openModelSettings() {
        onOpenModelSettings?()
    }

    private func runPrefetch(
        for result: TextCaptureService.CaptureResult, key: WritingRequestKey,
        prompts: PrefetchPrompts
    ) async {
        if Self.hasNoEnglish(result.text, mode: key.mode) {
            prefetchFinished = true
            isPrefetching = false
            isPrefetchReady = false
            prefetchError = Self.noEnglishMessage
            onPrefetchStateChange?()
            return
        }
        let route: WritingEngineRoute
        do {
            route = try await prepareEngine()
        } catch is CancellationError {
            return
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
            guard let kind = route.providerKind else { return }
            let config = try settings.runtimeConfig(for: kind)
            prefetchProvider = kind
            let onDevice = route == .appleIntelligence
            let profile = WritingPromptProfile.for(provider: kind)
            let basePrompt = prompts.prompt(for: profile)
            let personalized = await personalize(
                basePrompt, for: result.text, mode: key.mode, tone: key.tone, english: profile.isEnglish,
                translationLanguage: key.translationLanguage
            )
            // More typing cancels this prefetch; do not send the model a request for stale text.
            if Task.isCancelled { return }
            prefetchUsedMemoryIDs = personalized.usedMemoryIDs
            if onDevice {
                let written = try await writeOnDevice(
                    config: config, systemPrompt: personalized.systemPrompt, source: result.text,
                    mode: key.mode, tone: key.tone
                ) { [weak self] usage in
                    if self?.prefetchAttachedToUI == true { self?.lastUsage = usage }
                }
                // A newer selection replaced this prefetch while the model was answering.
                if Task.isCancelled || prefetchKey != key { return }
                prefetchBuffer = written.text
                prefetchNote = Self.note(for: written.outcome)
                prefetchIsSuggestion = Self.isSuggestion(written.outcome)
            } else {
                let request = ChatRequest(
                    model: config.model,
                    systemPrompt: profile.isEnglish
                        ? WritingPromptComposer.withLanguageLine(personalized.systemPrompt, for: result.text, mode: key.mode)
                        : personalized.systemPrompt,
                    userText: result.text,
                    reasoningEffort: .low,
                    temperature: Self.rewriteTemperature(for: config.kind),
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
                statusNote = prefetchNote
                if errorMessage == nil {
                    generated = prefetchIsSuggestion ? GeneratedSuggestion(
                        source: result.text, text: prefetchBuffer, mode: key.mode, tone: key.tone,
                        usedMemoryIDs: personalized.usedMemoryIDs, provider: kind,
                        translationLanguage: key.translationLanguage
                    ) : nil
                    scheduleTranslationOfResult()
                }
            } else if isPrefetchReady {
                startPrefetchTranslation(route: route)
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

    /// The on-device path: the text is split if it is too long for the model's context, every answer
    /// is checked, a failed one is retried once, and a proofread that still fails keeps the source
    /// (`WritingPipeline`). One request per piece; each answer arrives whole.
    private func writeOnDevice(
        config: LLMRuntimeConfig, systemPrompt: String, source: String, mode: WritingMode, tone: WritingTone,
        onUsage: (TokenUsage) -> Void
    ) async throws -> WritingPipelineResult {
        let budget = AppleFoundationModelProvider.contextSize.map {
            WritingChunkBudget(contextSize: $0, instructions: systemPrompt)
        }
        return try await WritingPipeline.run(
            source: source, mode: mode, tone: tone, systemPrompt: systemPrompt, budget: budget
        ) { prompt, text in
            let request = ChatRequest(
                model: config.model, systemPrompt: prompt, userText: text,
                maxTokens: WritingPipeline.responseTokenLimit(for: text), reasoningEffort: nil,
                transformsUserText: mode != .custom
            )
            var answer = ""
            for try await event in try llm.stream(config: config, request: request) {
                switch event {
                case .text(let token): answer += token
                case .usage(let usage): onUsage(usage)
                }
            }
            return answer
        }
    }

    /// What to tell the user when the output check changed what they see.
    private static func note(for outcome: GuardedWritingResult.Outcome) -> String? {
        switch outcome {
        case .accepted, .acceptedAfterRetry: nil
        case .keptSource: String(localized: "模型的建議改動過多或漏掉了原文內容，所以保留原文。")
        case .flagged: String(localized: "這份結果可能漏掉或改動了原文的部分內容，使用前請先核對。")
        }
    }

    /// The source text kept as a fallback is not something the model suggested, so it is not
    /// feedback on a suggestion either.
    private static func isSuggestion(_ outcome: GuardedWritingResult.Outcome) -> Bool {
        if case .keptSource = outcome { return false }
        return true
    }

    private func runAdoptedCapture(_ result: TextCaptureService.CaptureResult) async {
        do {
            _ = try await prepareEngine()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if !isAutoSuggestSession || originalText != result.text {
            prepareAutoSuggestUI(with: result)
        }
        await runStream(forceLowReasoning: true)
    }

    private func runCaptureAndStream(showPanel: @MainActor () -> Void) async {
        let captured = await capture.capture()
        showPanel()
        do {
            _ = try await prepareEngine()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        resultText = ""
        generated = nil
        originalText = ""
        statusNote = nil
        isAutoSuggestSession = false
        loadSelectionFromSettings()
        usedClipboardFallback = false
        if let captured {
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

    /// After a suggestion is ready, fetch a short gloss in the translation language for the bubble.
    private func scheduleTranslationOfResult() {
        cancelTranslation()
        let source = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            translationText = ""
            return
        }
        let language = settings.translationLanguage
        translationTask = Task { await self.translateResult(source, into: language) }
    }

    /// The reading aid under a suggestion: the English translation prompt where the engine takes the
    /// English prompts, the original short one elsewhere.
    private static func glossPrompt(for kind: ProviderKind, into language: TranslationLanguage) -> String {
        let profile = WritingPromptProfile.for(provider: kind)
        return profile.isEnglish
            ? WritingPromptComposer.compose(
                mode: .translate, tone: .preserve, customPrompt: "", profile: profile, translationLanguage: language
            )
            : translationSystemPrompt(into: language)
    }

    private static func translationSystemPrompt(into language: TranslationLanguage) -> String {
        let name = language.chineseName
        return """
            你是翻譯。把使用者文字譯成流暢的\(language == .traditionalChinese ? "台灣繁體中文" : name)。
            只輸出譯文，不要引號、標籤或說明。
            若原文已是\(name)，原樣輸出即可。
            保留專有名詞、產品名、程式碼與 URL。
            """
    }

    /// Lint's local model only — a cloud provider would pay for a second request per typing pause,
    /// and Apple Intelligence gets no request for a suggestion the user may never open.
    private func startPrefetchTranslation(route: WritingEngineRoute) {
        guard settings.wantsManagedLocalServer(for: route) else { return }
        let source = prefetchBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = settings.translationLanguage
        prefetchTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try self.settings.runtimeConfig(for: .localLlama)
                let request = ChatRequest(
                    model: config.model,
                    systemPrompt: Self.glossPrompt(for: .localLlama, into: language),
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
                    self.prefetchTranslation = (language, out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {}
        }
    }

    private func translateResult(_ source: String, into language: TranslationLanguage) async {
        isTranslating = true
        translationLanguage = language
        translationText = ""
        defer { isTranslating = false }
        do {
            let route = try await prepareEngine()
            guard let kind = route.providerKind else { return }
            let config = try settings.runtimeConfig(for: kind)
            let onDevice = route == .appleIntelligence
            let request = ChatRequest(
                model: config.model,
                systemPrompt: Self.glossPrompt(for: kind, into: language),
                userText: source,
                maxTokens: 512,
                reasoningEffort: .low,
                fastMode: true,
                transformsUserText: onDevice
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
        if Self.hasNoEnglish(originalText, mode: mode) {
            errorMessage = Self.noEnglishMessage
            isStreaming = false
            return
        }
        let route: WritingEngineRoute
        do {
            route = try await prepareEngine()
        } catch is CancellationError {
            return
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
        let generationSource = originalText
        let generationMode = mode
        let generationTone = tone
        let generationLanguage: TranslationLanguage? = mode == .translate ? settings.translationLanguage : nil
        let ticket = tickets.issue()
        errorMessage = nil
        resultText = ""
        generated = nil
        clearTranslation()
        lastUsage = nil
        isStreaming = true
        defer { isStreaming = false }
        var usedMemoryIDs: [UUID] = []
        var isSuggestion = true
        guard let kind = route.providerKind else { return }
        do {
            let config = try settings.runtimeConfig(for: kind)
            let onDevice = route == .appleIntelligence
            let profile = WritingPromptProfile.for(provider: kind)
            let effort: ReasoningEffort = forceLowReasoning ? .low : settings.reasoningEffort
            let systemPrompt: String
            if profile.isEnglish {
                // The English prompts already ask for the bare text.
                systemPrompt = settings.effectiveSystemPrompt(for: generationMode, tone: generationTone, profile: profile)
            } else if forceLowReasoning {
                systemPrompt = Self.terseSystemPrompt(
                    settings.effectiveSystemPrompt(for: generationMode, tone: generationTone)
                )
            } else {
                systemPrompt = settings.effectiveSystemPrompt(for: generationMode, tone: generationTone)
            }
            let personalized = await personalize(
                systemPrompt, for: generationSource, mode: generationMode, tone: generationTone, english: profile.isEnglish,
                translationLanguage: generationLanguage
            )
            if Task.isCancelled { return }
            usedMemoryIDs = personalized.usedMemoryIDs
            if onDevice {
                let written = try await writeOnDevice(
                    config: config, systemPrompt: personalized.systemPrompt, source: generationSource,
                    mode: generationMode, tone: generationTone
                ) { [weak self] usage in
                    if self?.tickets.isCurrent(ticket) == true { self?.lastUsage = usage }
                }
                // A newer request (or a cancel) owns the screen now: this answer is dropped.
                guard !Task.isCancelled, tickets.isCurrent(ticket) else { return }
                resultText = written.text
                statusNote = Self.note(for: written.outcome)
                isSuggestion = Self.isSuggestion(written.outcome)
            } else {
                let request = ChatRequest(
                    model: config.model,
                    systemPrompt: profile.isEnglish
                        ? WritingPromptComposer.withLanguageLine(personalized.systemPrompt, for: generationSource, mode: generationMode)
                        : personalized.systemPrompt,
                    userText: generationSource,
                    reasoningEffort: effort,
                    temperature: Self.rewriteTemperature(for: config.kind),
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
            }
        } catch is CancellationError {
            return
        } catch {
            guard tickets.isCurrent(ticket) else { return }
            errorMessage = error.localizedDescription
            return
        }
        if !Task.isCancelled, tickets.isCurrent(ticket), errorMessage == nil,
           !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isSuggestion {
                generated = GeneratedSuggestion(
                    source: generationSource, text: resultText, mode: generationMode, tone: generationTone,
                    usedMemoryIDs: usedMemoryIDs, provider: kind, translationLanguage: generationLanguage
                )
            }
            scheduleTranslationOfResult()
        }
    }

    private func runTestConnection() async {
        let route: WritingEngineRoute
        do {
            route = try await prepareEngine()
        } catch is CancellationError {
            return
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
            guard let kind = route.providerKind else { return }
            let config = try settings.runtimeConfig(for: kind)
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
