import XCTest

@testable import LintCore

/// Which engine a request goes to, and what an upgrade does to the stored choice. None of this
/// needs Apple Intelligence, a particular Mac or a particular macOS: availability is a plain value.
final class WritingEngineTests: XCTestCase {
    private let everyStatus: [AppleIntelligenceStatus] = [
        .available, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedOS, .unavailable,
    ]

    // MARK: - Routing

    func testAutomaticUsesAppleIntelligenceWhenItIsAvailable() {
        for ready in [true, false] {
            XCTAssertEqual(
                WritingEngineRouter.route(selected: .automatic, apple: .available, localAIReady: ready), .appleIntelligence,
                "installed local AI does not win over available Apple Intelligence"
            )
        }
    }

    func testAutomaticFallsBackToLocalAIOnlyWhenItIsAlreadySetUp() {
        for status in everyStatus where status != .available {
            XCTAssertEqual(
                WritingEngineRouter.route(selected: .automatic, apple: status, localAIReady: true), .provider(.localLlama),
                "\(status)"
            )
            XCTAssertEqual(
                WritingEngineRouter.route(selected: .automatic, apple: status, localAIReady: false), .unavailable(status),
                "\(status): never a route that would need a download"
            )
        }
    }

    func testChoosingAppleIntelligenceNeverFallsBack() {
        XCTAssertEqual(WritingEngineRouter.route(selected: .appleIntelligence, apple: .available, localAIReady: false), .appleIntelligence)
        for status in everyStatus where status != .available {
            XCTAssertEqual(
                WritingEngineRouter.route(selected: .appleIntelligence, apple: status, localAIReady: true), .unavailable(status),
                "\(status): the user chose Apple Intelligence, so Gemma is not used behind their back"
            )
        }
    }

    func testEveryOtherProviderIsUsedExactlyAsBefore() {
        for kind in ProviderKind.allCases where kind != .automatic && kind != .appleIntelligence {
            for status in everyStatus {
                for ready in [true, false] {
                    XCTAssertEqual(
                        WritingEngineRouter.route(selected: kind, apple: status, localAIReady: ready), .provider(kind),
                        "\(kind) with Apple \(status)"
                    )
                }
            }
        }
    }

    func testLocalAISetupIsOfferedOnlyWhereItIsTheWayForward() {
        // Lint's local AI was chosen and is not ready: as before.
        XCTAssertTrue(WritingEngineRouter.offersLocalAISetup(selected: .localLlama, apple: .available, localAIReady: false))
        XCTAssertFalse(WritingEngineRouter.offersLocalAISetup(selected: .localLlama, apple: .available, localAIReady: true))
        // Automatic, on a Mac that can never run Apple Intelligence.
        XCTAssertTrue(WritingEngineRouter.offersLocalAISetup(selected: .automatic, apple: .deviceNotEligible, localAIReady: false))
        XCTAssertTrue(WritingEngineRouter.offersLocalAISetup(selected: .automatic, apple: .unsupportedOS, localAIReady: false))
        // Not while Apple Intelligence is only switched off or still downloading.
        XCTAssertFalse(WritingEngineRouter.offersLocalAISetup(selected: .automatic, apple: .appleIntelligenceNotEnabled, localAIReady: false))
        XCTAssertFalse(WritingEngineRouter.offersLocalAISetup(selected: .automatic, apple: .modelNotReady, localAIReady: false))
        XCTAssertFalse(WritingEngineRouter.offersLocalAISetup(selected: .automatic, apple: .available, localAIReady: false))
        // Never to someone who chose Apple Intelligence.
        for status in everyStatus {
            XCTAssertFalse(WritingEngineRouter.offersLocalAISetup(selected: .appleIntelligence, apple: status, localAIReady: false))
        }
    }

    func testOnlyPermanentReasonsCountAsPermanent() {
        XCTAssertEqual(everyStatus.filter(\.isPermanent), [.deviceNotEligible, .unsupportedOS])
        for status in everyStatus {
            XCTAssertFalse(status.userMessage.isEmpty)
        }
        XCTAssertFalse(
            AppleIntelligenceStatus.modelNotReady.userMessage.contains("Gemma"),
            "a model that is still downloading is not a reason to install another one"
        )
    }

    func testTheProviderServiceBuildsTheAppleProviderAndRefusesAnUnresolvedChoice() throws {
        let apple = LLMRuntimeConfig(
            kind: .appleIntelligence, baseURL: ProviderKind.appleIntelligence.defaultBaseURL,
            model: ProviderKind.appleIntelligence.defaultModel, apiKey: ""
        )
        XCTAssertEqual(try LLMService().provider(for: apple).id, .appleIntelligence)
        XCTAssertFalse(ProviderKind.appleIntelligence.requiresAPIKey)
        XCTAssertFalse(ProviderKind.automatic.requiresAPIKey)
        var automatic = apple
        automatic.kind = .automatic
        XCTAssertThrowsError(try LLMService().provider(for: automatic)) { error in
            guard case LLMError.unresolvedProvider = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Migration

    func testANewInstallGetsTheReviewedDefault() {
        XCTAssertEqual(
            WritingEngineMigration.migrate(storedProvider: nil, isNewInstall: true), WritingEngineMigration.newInstallDefault
        )
    }

    func testTheNewInstallDefaultStaysLintsLocalAIUntilTheEvaluationIsReviewed() {
        XCTAssertEqual(WritingEngineMigration.newInstallDefault, .localLlama)
    }

    func testAnExistingUserIsNeverSwitched() {
        // Gemma (managed local AI), a custom -hf model (still `.localLlama`), an OpenAI-compatible
        // endpoint, and an older install that never stored a provider at all.
        for stored in [ProviderKind.localLlama.rawValue, ProviderKind.openaiCompatible.rawValue, "gemini", "something-unknown"] {
            XCTAssertNil(WritingEngineMigration.migrate(storedProvider: stored, isNewInstall: false), stored)
            XCTAssertNil(WritingEngineMigration.migrate(storedProvider: stored, isNewInstall: true), stored)
        }
        XCTAssertNil(
            WritingEngineMigration.migrate(storedProvider: nil, isNewInstall: false),
            "an install with settings but no provider keeps whatever the older migrations decide"
        )
    }

    func testRunningTheMigrationAgainChangesNothing() {
        for (stored, isNew) in [(String?.none, true), (String?.none, false), ("localLlama", false), ("openaiCompatible", false)] {
            var defaults = [String: String]()
            if let stored { defaults["provider"] = stored }
            func run() {
                if let kind = WritingEngineMigration.migrate(storedProvider: defaults["provider"], isNewInstall: isNew) {
                    defaults["provider"] = kind.rawValue
                }
            }
            run()
            let once = defaults
            run()
            XCTAssertEqual(defaults, once, "\(String(describing: stored)) new=\(isNew)")
        }
    }

    func testTheMigrationDoesNotDependOnAppleIntelligence() {
        // Deterministic by construction: availability is not an input. Pinned so it stays that way.
        let signature: (String?, Bool) -> ProviderKind? = WritingEngineMigration.migrate
        XCTAssertNil(signature("localLlama", false))
    }
}
