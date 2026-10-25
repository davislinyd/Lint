import XCTest
@testable import LintCore

final class LivePanelOutputTests: XCTestCase {
    private func key(
        _ source: String = "this is a pen.", mode: WritingMode = .proofread, tone: WritingTone = .preserve,
        language: TranslationLanguage = .traditionalChinese
    ) -> WritingRequestKey {
        WritingRequestKey(source: source, mode: mode, tone: tone, customPrompt: "", translationLanguage: language)
    }

    private func shouldGenerate(
        enabled: Bool = true, provider: ProviderKind = .localLlama, requested: WritingRequestKey?, current: WritingRequestKey
    ) -> Bool {
        LivePanelOutput.shouldGenerate(enabled: enabled, provider: provider, requested: requested, current: current)
    }

    func testOnlyEnginesThatCostNothingPerRequestAreLive() {
        let free: Set<ProviderKind> = [.automatic, .appleIntelligence, .localLlama]
        for provider in ProviderKind.allCases {
            XCTAssertEqual(LivePanelOutput.isAvailable(for: provider), free.contains(provider), provider.rawValue)
        }
    }

    func testTheSwitchTurnsItOffEvenForAFreeEngine() {
        XCTAssertTrue(LivePanelOutput.isOn(enabled: true, provider: .localLlama))
        XCTAssertFalse(LivePanelOutput.isOn(enabled: false, provider: .localLlama))
        XCTAssertFalse(LivePanelOutput.isOn(enabled: true, provider: .openai))
    }

    func testNewTextIsGeneratedAndTheSameRequestIsNot() {
        XCTAssertTrue(shouldGenerate(requested: nil, current: key()))
        XCTAssertTrue(shouldGenerate(requested: key("this is a pen"), current: key("this is a pen.")))
        XCTAssertFalse(shouldGenerate(requested: key(), current: key()))
    }

    func testAnotherModeToneOrLanguageIsAnotherRequest() {
        XCTAssertTrue(shouldGenerate(requested: key(), current: key(mode: .translate)))
        XCTAssertTrue(shouldGenerate(requested: key(), current: key(tone: .formal)))
        XCTAssertTrue(shouldGenerate(
            requested: key(mode: .translate, language: .japanese), current: key(mode: .translate, language: .thai)
        ))
        XCTAssertFalse(shouldGenerate(
            requested: key(mode: .proofread, language: .japanese), current: key(mode: .proofread, language: .thai)
        ), "a proofread does not read the translation language")
    }

    func testNothingIsGeneratedForEmptyText() {
        XCTAssertFalse(shouldGenerate(requested: key("this is a pen."), current: key("")))
        XCTAssertFalse(shouldGenerate(requested: nil, current: key("")))
    }

    func testNothingIsGeneratedWhenOffOrOnAPaidEngine() {
        XCTAssertFalse(shouldGenerate(enabled: false, requested: nil, current: key()))
        XCTAssertFalse(shouldGenerate(provider: .openai, requested: nil, current: key()))
        XCTAssertFalse(shouldGenerate(provider: .chatgptAccount, requested: nil, current: key()))
        XCTAssertTrue(shouldGenerate(provider: .automatic, requested: nil, current: key()))
    }
}
