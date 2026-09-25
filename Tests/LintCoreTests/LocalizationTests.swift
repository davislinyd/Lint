import XCTest

/// Guards `Resources/*.lproj`: keys are the zh-Hant source text, so a broken file, a missing key or a
/// mismatched format specifier only shows up at runtime in that language.
final class LocalizationTests: XCTestCase {
    private static let formatSpecifier = try! NSRegularExpression(
        pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"
    )

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")

    /// Every localization but zh-Hant, the development language, whose table is empty by design.
    private func translatedLanguages() throws -> [String] {
        let languages = try FileManager.default.contentsOfDirectory(atPath: Self.resources.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .filter { $0 != "zh-Hant" }
            .sorted()
        XCTAssertTrue(languages.contains("en"))
        return languages
    }

    private func table(_ language: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = Self.resources.appendingPathComponent("\(language).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language).lproj/\(name) failed to parse")
    }

    private func specifiers(in string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        return Self.formatSpecifier.matches(in: string, range: range)
            .map { String(string[Range($0.range, in: string)!]) }
            .sorted()
    }

    func testNoTableHasEmptyValues() throws {
        for language in try translatedLanguages() {
            let table = try table(language)
            XCTAssertFalse(table.isEmpty, language)
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): empty translation for \(key)")
            }
        }
    }

    func testFormatSpecifiersMatchKeys() throws {
        for language in try translatedLanguages() {
            for (key, value) in try table(language) {
                XCTAssertEqual(specifiers(in: value), specifiers(in: key), "\(language): format mismatch for \(key)")
            }
        }
    }

    func testEveryTableTranslatesWhatEnglishDoes() throws {
        let english = Set(try table("en").keys)
        for language in try translatedLanguages() where language != "en" {
            let keys = Set(try table(language).keys)
            XCTAssertEqual(english.subtracting(keys).sorted(), [], "\(language) is missing keys")
            XCTAssertEqual(keys.subtracting(english).sorted(), [], "\(language) has keys English does not")
        }
    }

    func testEveryLanguageTranslatesTheInfoPlist() throws {
        let english = try table("en", "InfoPlist")
        XCTAssertFalse(english.isEmpty)
        for language in try translatedLanguages() {
            let table = try table(language, "InfoPlist")
            XCTAssertEqual(Set(table.keys), Set(english.keys), language)
            XCTAssertFalse(table.values.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, language)
        }
    }

    func testTheBundleListsEveryLocalization() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.resources.appendingPathComponent("Info.plist")))
        let listed = try XCTUnwrap(plist["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(listed), Set(try translatedLanguages() + ["zh-Hant"]))
        XCTAssertEqual(listed.count, Set(listed).count, "listed twice")
    }
}
