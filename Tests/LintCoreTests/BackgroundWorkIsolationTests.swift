import XCTest

@testable import LintCore

/// Learning, memory extraction and Dreaming run on their own, in the background, whenever the user
/// is not waiting for a suggestion. None of that may install local AI, start llama-server, or wake
/// a model that llama.cpp put to sleep — it all has to be answerable from SQLite and plain Swift.
///
/// The guard is a source scan, because the property is "this code cannot reach that code": a
/// behavioural test would only prove that today's call path happens not to.
final class BackgroundWorkIsolationTests: XCTestCase {
    /// Anything that could reach the local server, by type or by the name of the call.
    private let forbidden = [
        "LocalAISetupCoordinator", "LocalServerControlling", "LlamaServerLaunchPlan",
        "LocalAIConfiguration", "ModelDownloadManager", "LocalModelManager", "ModelCatalog",
        "ensureServerRunning", "startServer", "installModel", "warmUpIfIdle",
        "LLMService", "LLMProvider", "ChatRequest", "URLSession",
        // Apple's on-device model: background work must not make a request to it either.
        "FoundationModels", "AppleFoundationModelProvider", "SystemLanguageModel", "LanguageModelSession",
    ]

    private func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = TestSupport.repoRoot.appendingPathComponent(relativePath, isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testNothingInLearningOrDreamingCanReachLocalAI() throws {
        let files = try swiftFiles(under: "Sources/LintCore/Learning")
        XCTAssertGreaterThan(files.count, 10, "the scan found the Learning sources")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for name in forbidden {
                XCTAssertFalse(
                    source.contains(name),
                    "\(file.lastPathComponent) mentions \(name): background learning must never start, install or wake local AI"
                )
            }
        }
    }

    /// Everything Learning imports is on-device: the database, Apple's on-device language
    /// tokenizer, hashing. Nothing that can open a connection or load a model.
    func testLearningOnlyImportsLocalThings() throws {
        let allowed: Set<String> = ["Foundation", "CryptoKit", "GRDB", "NaturalLanguage", "SQLite3", "os"]
        for file in try swiftFiles(under: "Sources/LintCore/Learning") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) where line.hasPrefix("import ") {
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(allowed.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }
}
