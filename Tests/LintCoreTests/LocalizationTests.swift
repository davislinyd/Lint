import XCTest

/// Guards `Resources/en.lproj/Localizable.strings`: keys are the zh-Hant source text, so a
/// broken file or a mismatched format specifier only shows up at runtime in English.
final class LocalizationTests: XCTestCase {
    private static let formatSpecifier = try! NSRegularExpression(
        pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"
    )

    private func englishTable() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "en.lproj failed to parse")
        return table
    }

    private func specifiers(in string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        return Self.formatSpecifier.matches(in: string, range: range)
            .map { String(string[Range($0.range, in: string)!]) }
            .sorted()
    }

    func testEnglishTableHasNoEmptyValues() throws {
        let table = try englishTable()
        XCTAssertFalse(table.isEmpty)
        for (key, value) in table {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty translation for \(key)")
        }
    }

    func testEnglishFormatSpecifiersMatchKeys() throws {
        for (key, value) in try englishTable() {
            XCTAssertEqual(specifiers(in: value), specifiers(in: key), "format mismatch for \(key)")
        }
    }
}
