import XCTest

@testable import LintCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mapping Foundation Models' availability and errors into Lint's. The framework's values are
/// constructed here, never obtained from the model: no request is made and Apple Intelligence does
/// not have to be on.
final class AppleIntelligenceTests: XCTestCase {
    func testAvailabilityMapsOntoLintsStatus() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        XCTAssertEqual(AppleIntelligenceStatus(SystemLanguageModel.Availability.available), .available)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.deviceNotEligible)), .deviceNotEligible)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.appleIntelligenceNotEnabled)), .appleIntelligenceNotEnabled)
        XCTAssertEqual(AppleIntelligenceStatus(.unavailable(.modelNotReady)), .modelNotReady)
        #else
        throw XCTSkip("built without Foundation Models")
        #endif
    }

    func testTheSystemCheckAlwaysAnswers() {
        // Whatever this Mac is: available, a reason, or unsupported. It never crashes or requests anything.
        _ = SystemAppleIntelligence().currentStatus()
    }

    func testCancellationStaysACancellation() {
        XCTAssertTrue(AppleIntelligenceError.map(CancellationError()) is CancellationError)
        let lint = AppleIntelligenceError.refusal
        XCTAssertEqual(AppleIntelligenceError.map(lint) as? AppleIntelligenceError, lint)
    }

    func testAnUnknownErrorBecomesAGenericFailureWithItsDetailsKeptForDiagnostics() throws {
        struct Weird: Error {}
        let mapped = try XCTUnwrap(AppleIntelligenceError.map(Weird()) as? AppleIntelligenceError)
        guard case .generationFailed(let diagnostic) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertTrue(diagnostic.contains("Weird"))
        XCTAssertFalse(mapped.localizedDescription.contains("Weird"), "raw framework text is never shown")
    }

    func testMacOS26GenerationErrorsMapOntoLintsErrors() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "raw framework detail")
        let cases: [(LanguageModelSession.GenerationError, AppleIntelligenceError)] = [
            (.exceededContextWindowSize(context), .contextSizeExceeded),
            (.assetsUnavailable(context), .assetsUnavailable),
            (.guardrailViolation(context), .guardrailViolation),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguage),
            (.rateLimited(context), .rateLimited),
            (.concurrentRequests(context), .busy),
            (.refusal(.init(transcriptEntries: []), context), .refusal),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(AppleIntelligenceError.map(error) as? AppleIntelligenceError, expected, "\(error)")
        }
        let decoding = AppleIntelligenceError.map(LanguageModelSession.GenerationError.decodingFailure(context))
        guard case .generationFailed = decoding as? AppleIntelligenceError else { return XCTFail("\(decoding)") }
        #else
        throw XCTSkip("built without Foundation Models")
        #endif
    }

    func testMacOS27LanguageModelErrorsMapOntoLintsErrors() throws {
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(macOS 27.0, *) else { throw XCTSkip("needs macOS 27") }
        let cases: [(LanguageModelError, AppleIntelligenceError)] = [
            (.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "x")), .contextSizeExceeded),
            (.guardrailViolation(.init(debugDescription: "x")), .guardrailViolation),
            (.refusal(.init(explanation: "no", debugDescription: "x")), .refusal),
            (.rateLimited(.init(resetDate: nil, debugDescription: "x")), .rateLimited),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(AppleIntelligenceError.map(error) as? AppleIntelligenceError, expected, "\(error)")
        }
        XCTAssertEqual(
            AppleIntelligenceError.map(LanguageModelSession.Error.concurrentRequests) as? AppleIntelligenceError, .busy
        )
        #else
        throw XCTSkip("needs the macOS 27 SDK")
        #endif
    }

    func testEveryErrorHasAMessageForTheUser() {
        let errors: [AppleIntelligenceError] = [
            .unavailable(.appleIntelligenceNotEnabled), .contextSizeExceeded, .guardrailViolation, .refusal,
            .unsupportedLanguage, .rateLimited, .busy, .assetsUnavailable, .timedOut, .generationFailed(diagnostic: "x"),
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
        XCTAssertEqual(
            AppleIntelligenceError.unavailable(.modelNotReady).errorDescription,
            AppleIntelligenceStatus.modelNotReady.userMessage
        )
    }

    func testMetadataNamesThePromptVersionAndTheOS() {
        let metadata = AppleModelMetadata.current()
        XCTAssertEqual(metadata.promptVersion, WritingPromptComposer.englishPromptVersion)
        XCTAssertFalse(metadata.osVersion.isEmpty)
    }
}
