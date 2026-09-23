import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why an Apple Intelligence request failed, as the user should read it. The framework's own
/// description is kept in `diagnostic` (and logged) for development; it is never shown.
public enum AppleIntelligenceError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(AppleIntelligenceStatus)
    /// The text (with the instructions) does not fit the model's context.
    case contextSizeExceeded
    /// Apple's safety guardrails stopped the request or the answer.
    case guardrailViolation
    case refusal
    case unsupportedLanguage
    /// macOS is limiting how often Lint may use the model.
    case rateLimited
    /// Another request on the same session was still running.
    case busy
    /// The model's files are not on this Mac (yet).
    case assetsUnavailable
    case timedOut
    case generationFailed(diagnostic: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let status):
            status.userMessage
        case .contextSizeExceeded:
            String(localized: "文字太長，Apple Intelligence 一次處理不了。請分段選取後再試。")
        case .guardrailViolation:
            String(localized: "Apple Intelligence 的安全機制拒絕處理這段文字。可以改用 Lint 本機 AI。")
        case .refusal:
            String(localized: "Apple Intelligence 拒絕處理這段文字。")
        case .unsupportedLanguage:
            String(localized: "Apple Intelligence 不支援這段文字的語言。")
        case .rateLimited:
            String(localized: "macOS 暫時限制了 Apple Intelligence 的使用次數，請稍後再試。")
        case .busy:
            String(localized: "Apple Intelligence 正在處理另一個要求，請稍後再試。")
        case .assetsUnavailable:
            String(localized: "Apple Intelligence 的模型還沒準備好，請稍後再試。")
        case .timedOut:
            String(localized: "Apple Intelligence 回應逾時，請再試一次。")
        case .generationFailed:
            String(localized: "Apple Intelligence 無法產生建議，請再試一次。")
        }
    }

    public var diagnostic: String {
        if case .generationFailed(let diagnostic) = self { return diagnostic }
        return String(describing: self)
    }

    private static let log = Logger(subsystem: "app.lint.assistant", category: "AppleIntelligence")

    /// Lint's error for whatever the framework threw. Cancellation passes through untouched, so
    /// that a cancelled request stays a cancellation and is never shown as a failure.
    public static func map(_ error: Error) -> Error {
        if error is CancellationError || error is AppleIntelligenceError { return error }
        let mapped = frameworkError(error) ?? .generationFailed(diagnostic: String(reflecting: error))
        log.error("request failed: \(mapped.diagnostic, privacy: .public) (\(String(reflecting: error), privacy: .private))")
        return mapped
    }

    private static func frameworkError(_ error: Error) -> AppleIntelligenceError? {
        #if canImport(FoundationModels)
        // The macOS 27 error types exist only in the macOS 27 SDK (Swift 6.4); a build with an older
        // SDK still maps the macOS 26 ones below.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .contextSizeExceeded
                case .rateLimited: return .rateLimited
                case .guardrailViolation: return .guardrailViolation
                case .refusal: return .refusal
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .timeout: return .timedOut
                default: return .generationFailed(diagnostic: String(reflecting: error))
                }
            }
            if error is SystemLanguageModel.Error { return .assetsUnavailable }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests { return .busy }
        }
        #endif
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextSizeExceeded
            case .assetsUnavailable: return .assetsUnavailable
            case .guardrailViolation: return .guardrailViolation
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited: return .rateLimited
            case .concurrentRequests: return .busy
            case .refusal: return .refusal
            default: return .generationFailed(diagnostic: String(reflecting: error))
            }
        }
        #endif
        return nil
    }
}
