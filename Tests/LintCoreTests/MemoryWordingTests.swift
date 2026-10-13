import XCTest
@testable import LintCore

/// A memory's stored (Chinese) wording is read back into the English one an English prompt gets.
final class MemoryWordingTests: XCTestCase {
    private let every: [MemoryWording] = [
        .articles,
        .preferredSpelling(wrong: "color", right: "colour"),
        .misspelling(wrong: "recieve", right: "receive"),
        .extraPreposition(verb: "discuss", preposition: "about"),
        .preferredReplacement(from: "reach out", to: "contact"),
        .acceptedReplacement(from: "open the light", to: "turn on the light"),
        .terminology(from: "軟件", to: "軟體"),
        .redundantPrepositions,
        .keepReverted(from: "big", to: "large"),
        .keepRejected(from: "reach out", to: "contact"),
        .profile([.keepContractions, .noTerminalPeriod]),
        .profile(StyleTrait.allCases),
    ]

    func testEveryStoredWordingIsReadBackAsItself() {
        for wording in every {
            XCTAssertEqual(MemoryWording(chinese: wording.chinese), wording, wording.chinese)
        }
    }

    func testTheEnglishWordingCarriesNoChineseButTheTermsItQuotes() {
        for wording in every {
            let english: String
            if case .terminology = wording {
                english = wording.english.replacingOccurrences(of: "軟件", with: "").replacingOccurrences(of: "軟體", with: "")
            } else {
                english = wording.english
            }
            XCTAssertFalse(english.unicodeScalars.contains(where: TextScript.isHan), wording.english)
        }
        XCTAssertEqual(
            MemoryWording.misspelling(wrong: "recieve", right: "receive").english,
            "This user often misspells \"receive\" as \"recieve\": where the text has \"recieve\", check whether \"receive\" is meant, and fix it only then."
        )
    }

    func testTheWordingsLintWritesAreTheOnesItStored() {
        // Stored memories keep their text: these are the exact wordings of earlier versions.
        XCTAssertEqual(MemoryWording.articles.chinese, "英文常漏用或誤用冠詞（a／an／the）：請特別檢查單數可數名詞前的冠詞。")
        XCTAssertEqual(MemoryWording.terminology(from: "軟件", to: "軟體").chinese, "用詞：請用「軟體」，不要用「軟件」。")
        XCTAssertEqual(MemoryConsolidator.redundantPrepositionInstruction, MemoryWording.redundantPrepositions.chinese)
    }

    func testTheStyleProfileListsItsTraitsInOneOrderAndNothingElseIsOne() throws {
        XCTAssertEqual(
            MemoryWording.profile(of: [.keepLowercaseStart, .keepContractions]),
            .profile([.keepContractions, .keepLowercaseStart])
        )
        XCTAssertNil(MemoryWording.profile(of: []))
        let one = try XCTUnwrap(MemoryWording.profile(of: [.noTerminalPeriod]))
        XCTAssertEqual(one.chinese, "這位使用者自己的寫法，請照原樣保留：訊息結尾不加句點，不要補上。")
        XCTAssertEqual(
            one.english, "This user's own way of writing, to be left as it is: a message ends without a period, so none is added."
        )
        let two = MemoryWording.profile([.keepContractions, .noTerminalPeriod]).chinese
        let swapped = "這位使用者自己的寫法，請照原樣保留：訊息結尾不加句點，不要補上；會用縮寫（如 don't），不要展開。"
        XCTAssertNotEqual(two, swapped)
        XCTAssertNil(MemoryWording(chinese: swapped), "another order is not what Lint writes")
        XCTAssertNil(MemoryWording(chinese: "這位使用者自己的寫法，請照原樣保留：一律用英式拼法。"))
        XCTAssertNil(MemoryWording(chinese: "這位使用者自己的寫法，請照原樣保留：。"))
        XCTAssertNil(MemoryWording(chinese: one.chinese + "另外不要用驚嘆號。"))
    }

    func testTextTheUserWroteIsNotAWording() {
        XCTAssertNil(MemoryWording(chinese: "寫信給客戶時用 Hi 開頭，不要用 Dear。"))
        XCTAssertNil(MemoryWording(chinese: "Always use British spelling."))
        XCTAssertNil(MemoryWording(chinese: MemoryWording.articles.chinese + " 另外注意時態。"), "an edited wording is the user's")
        // A word said twice must be the same word both times.
        XCTAssertNil(MemoryWording(chinese: "使用者常把「receive」誤寫成「recieve」；原文出現「recieve」時請確認是否應為「deceive」，僅在語意符合時修正。"))
    }
}
