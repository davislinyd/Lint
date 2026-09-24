import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device `SystemLanguageModel` behind Lint's usual provider interface. It only ever uses
/// the on-device model: no Private Cloud Compute, no network, no API key.
///
/// Every request gets a new session that is dropped when it answers, so one text never sits in the
/// transcript of the next. The whole answer arrives as one `.text` event: Lint needs the final text
/// before it can check and show it, so there is nothing to gain from streaming it.
public struct AppleFoundationModelProvider: LLMProvider {
    public let id: ProviderKind = .appleIntelligence

    public init() {}

    /// The on-device model's context in tokens, from the runtime; nil where there is no such model.
    public static var contextSize: Int? { AppleOnDeviceModel.contextSize() }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = try await AppleOnDeviceModel.respond(to: request)
                    try Task.checkCancellation()
                    continuation.yield(.text(answer.text))
                    if let usage = answer.usage { continuation.yield(.usage(usage)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppleIntelligenceError.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The calls into Foundation Models, each behind the availability check it needs.
enum AppleOnDeviceModel {
    static func respond(to request: ChatRequest) async throws -> (text: String, usage: TokenUsage?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = systemModel(transformsUserText: request.transformsUserText)
            let status = AppleIntelligenceStatus(model.availability)
            guard status.isAvailable else { throw AppleIntelligenceError.unavailable(status) }
            let session = LanguageModelSession(model: model, instructions: request.systemPrompt)
            // Greedy: the same text gets the same suggestion, and proofreading has no use for variety.
            // A cap only when the caller asked for less than the whole context.
            let cap = request.maxTokens < model.contextSize ? request.maxTokens : nil
            // The macOS 27 SDK renamed `sampling:` to `samplingMode:` (and deprecated the old name);
            // the macOS 26 SDK, which CI builds with, has only `sampling:`. Same call either way.
            #if compiler(>=6.4)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
            #else
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: cap)
            #endif
            let response = try await session.respond(to: request.userText, options: options)
            return (response.content, usage(of: response))
        }
        #endif
        throw AppleIntelligenceError.unavailable(.unsupportedOS)
    }

    /// The model's context in tokens, from the runtime (macOS 26 reports 4096 before 26.4 exposed it).
    static func contextSize() -> Int? {
        #if canImport(FoundationModels)
        // 0 has been seen while the system could not load the model: that is no size to split by.
        if #available(macOS 26.0, *) {
            let size = SystemLanguageModel.default.contextSize
            return size > 0 ? size : nil
        }
        #endif
        return nil
    }

    static func variantName() -> String? {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27.0, *) { return SystemLanguageModel.default.variant.displayName }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    /// Rewriting the user's own text (which can quote anything: profanity, an incident report, an
    /// angry email) uses Apple's guardrails for content transformations. Anything else, such as a
    /// custom prompt that may ask for new content, keeps the default guardrails.
    @available(macOS 26.0, *)
    private static func systemModel(transformsUserText: Bool) -> SystemLanguageModel {
        SystemLanguageModel(
            useCase: .general,
            guardrails: transformsUserText ? .permissiveContentTransformations : .default
        )
    }

    @available(macOS 26.0, *)
    private static func usage(of response: LanguageModelSession.Response<String>) -> TokenUsage? {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            let usage = response.usage
            return TokenUsage(
                promptTokens: usage.input.totalTokenCount,
                completionTokens: usage.output.totalTokenCount,
                reasoningTokens: usage.output.reasoningTokenCount,
                cachedPromptTokens: usage.input.cachedTokenCount,
                totalTokens: usage.totalTokenCount
            )
        }
        #endif
        return nil
    }
    #endif
}
