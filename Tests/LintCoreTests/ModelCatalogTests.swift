import XCTest

@testable import LintCore

/// The catalog is the one place Lint trusts about what to download, so every entry is checked for
/// the properties the download and install code relies on. Nothing here touches the network.
final class ModelCatalogTests: XCTestCase {
    private let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")

    func testTheCatalogHoldsTheThreeModelsAndNothingIsDuplicated() {
        XCTAssertEqual(
            ModelCatalog.all.map(\.id),
            ["gemma-4-e4b-it-qat-q4_0", "qwen3-4b-instruct-2507-q4_k_m", "gemma-4-12b-it-qat-q4_0"]
        )
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        XCTAssertEqual(Set(ModelCatalog.all.map { $0.huggingFaceSpec.lowercased() }).count, ModelCatalog.all.count)
    }

    func testGemmaE4BIsTheOneRecommendedAnd12BIsMarkedLarge() {
        XCTAssertEqual(ModelCatalog.all.filter(\.recommended).count, 1, "exactly one model is recommended")
        XCTAssertEqual(ModelCatalog.recommended.id, "gemma-4-e4b-it-qat-q4_0")
        XCTAssertEqual(ModelCatalog.all.first?.id, ModelCatalog.recommended.id, "the picker lists it first")
        XCTAssertEqual(ModelCatalog.all.filter { $0.memoryClass == .large }.map(\.id), ["gemma-4-12b-it-qat-q4_0"])
        XCTAssertLessThan(ModelCatalog.recommended.totalBytes ?? 0, ModelCatalog.gemma4_12bQATQ4_0.totalBytes ?? 0)
    }

    func testTheE4BEntryIsExactlyWhatWasVerified() {
        let e4b = ModelCatalog.gemma4_e4bQATQ4_0
        XCTAssertEqual(e4b.repository, "google/gemma-4-E4B-it-qat-q4_0-gguf")
        XCTAssertEqual(e4b.revision, "4b4a2c1d584be7264f87aac328a1bc739ce81b6c")
        XCTAssertEqual(e4b.files.map(\.fileName), ["gemma-4-E4B_q4_0-it.gguf"], "the language model only, no mmproj")
        XCTAssertEqual(e4b.totalBytes, 5_154_941_280)
        XCTAssertEqual(e4b.primaryFile.sha256, "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee")
    }

    func testTheQwenEntryIsExactlyWhatWasVerified() {
        let qwen = ModelCatalog.qwen3_4bInstruct2507Q4_K_M
        XCTAssertEqual(qwen.repository, "unsloth/Qwen3-4B-Instruct-2507-GGUF")
        XCTAssertEqual(qwen.revision, "a06e946bb6b655725eafa393f4a9745d460374c9")
        XCTAssertEqual(qwen.primaryFile.fileName, "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
        XCTAssertEqual(qwen.totalBytes, 2_497_281_120)
        XCTAssertEqual(qwen.primaryFile.sha256, "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
        XCTAssertFalse(qwen.recommended)
    }

    func testEveryEntryIsPinnedVerifiableAndSafeToWriteToDisk() throws {
        for model in ModelCatalog.all {
            XCTAssertFalse(model.id.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertEqual(model.license, "Apache-2.0", "\(model.id): only permissively licensed models are managed")
            XCTAssertEqual(model.repository.split(separator: "/").count, 2, "\(model.id): owner/name")
            XCTAssertEqual(model.revision.count, 40, "\(model.id): a full commit sha, never a branch")
            XCTAssertTrue(model.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(model.id): lowercase hex")
            XCTAssertFalse(model.files.isEmpty)
            for file in model.files {
                XCTAssertTrue(file.hasSafeFileName, "\(model.id): \(file.fileName) is joined onto Lint's own folders")
                XCTAssertTrue(file.fileName.hasSuffix(".gguf"))
                XCTAssertGreaterThan(try XCTUnwrap(file.sizeBytes), 0, "\(model.id): \(file.fileName)")
                let sha = try XCTUnwrap(file.sha256, "\(model.id): \(file.fileName) must be checksummed")
                XCTAssertEqual(sha.count, 64, "\(model.id): SHA-256 is 64 hex characters")
                XCTAssertTrue(sha.unicodeScalars.allSatisfy(hexDigits.contains), "\(model.id): SHA-256 is lowercase hex")
                XCTAssertEqual(file.url.scheme, "https")
                XCTAssertEqual(file.url.host, "huggingface.co")
                XCTAssertEqual(
                    file.url.path, "/\(model.repository)/resolve/\(model.revision)/\(file.fileName)",
                    "\(model.id): the download URL pins the same revision the hash was read at"
                )
            }
        }
    }

    func testTheHuggingFaceSpecNamesTheSameRepository() {
        for model in ModelCatalog.all {
            let repository = model.huggingFaceSpec.split(separator: ":").first.map(String.init) ?? ""
            XCTAssertEqual(repository.lowercased(), model.repository.lowercased(), "\(model.id)")
            XCTAssertEqual(ModelCatalog.descriptor(matchingHuggingFaceSpec: " \(model.huggingFaceSpec.uppercased()) ")?.id, model.id)
        }
        XCTAssertNil(ModelCatalog.descriptor(matchingHuggingFaceSpec: "someone/else:q4"))
    }

    // MARK: - Which model a stored setting selects

    func testAStoredSelectionSurvivesAnUpgradeAndOnlyAnUnknownOneFallsBack() {
        for id in ModelCatalog.all.map(\.id) {
            XCTAssertEqual(ModelCatalog.resolveManagedModelID(id), id, "someone on \(id) stays on it")
        }
        XCTAssertEqual(ModelCatalog.resolveManagedModelID(nil), ModelCatalog.recommended.id, "a new install")
        XCTAssertEqual(ModelCatalog.resolveManagedModelID("  \n "), ModelCatalog.recommended.id)
        XCTAssertEqual(ModelCatalog.resolveManagedModelID("llama-9000"), ModelCatalog.recommended.id, "unknown or corrupt id")
        for stored in [nil, "", "gemma-4-12b-it-qat-q4_0", "llama-9000"] {
            let once = ModelCatalog.resolveManagedModelID(stored)
            XCTAssertEqual(ModelCatalog.resolveManagedModelID(once), once, "stored: \(stored ?? "nil")")
        }
    }

    // MARK: - Runtime profiles

    func testEachModelCarriesItsOwnRuntimeNeeds() {
        XCTAssertEqual(ModelCatalog.qwen3_4bInstruct2507Q4_K_M.runtimeProfile.reasoningArguments, [], "no thinking mode")
        for gemma in [ModelCatalog.gemma4_e4bQATQ4_0, ModelCatalog.gemma4_12bQATQ4_0] {
            XCTAssertEqual(gemma.runtimeProfile.reasoningArguments, ["--reasoning", "off"], "\(gemma.id): Gemma 4 thinks unless told not to")
        }
        for model in ModelCatalog.all {
            XCTAssertEqual(model.runtimeProfile.contextTokens, 3072, model.id)
            XCTAssertEqual(model.runtimeProfile.kvCacheType, "q8_0", model.id)
        }
    }
}
