import XCTest

@testable import LintCore

final class ModelFileRewriterTests: XCTestCase {
    /// Writes `shards` where an installed model lives. `hashOf` gives the catalog hash a different
    /// content, to stand for a file that does not match.
    private func install(_ shards: [(String, Data)], hashOf: [(String, Data)]? = nil) throws -> (ModelDescriptor, LocalAIPaths) {
        let (model, _) = TestModel.make(shards: hashOf ?? shards)
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let directory = paths.installDirectory(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in shards { try data.write(to: directory.appendingPathComponent(name)) }
        return (model, paths)
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testEachFileIsRewrittenOnceWithTheSameBytes() throws {
        // Bigger than one 16 MB chunk, so the copy loop runs more than once.
        let shards = [("m-00001-of-00002.gguf", TestModel.payload("a", count: 17 * 1024 * 1024 + 5)), ("m-00002-of-00002.gguf", TestModel.payload("b", count: 2500))]
        let (model, paths) = try install(shards)
        let directory = paths.installDirectory(for: model)
        let before = try shards.map { try inode(directory.appendingPathComponent($0.0)) }

        try ModelFileRewriter().rewriteIfNeeded(model, in: paths)

        for (index, (name, data)) in shards.enumerated() {
            let url = directory.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: url), data, name)
            XCTAssertTrue(ModelFileRewriter.isRewritten(url), name)
            XCTAssertNotEqual(try inode(url), before[index], "\(name) is a new file")
        }
        XCTAssertEqual(try names(in: directory), shards.map(\.0), "no temporary file is left")
        if case .installed = LocalModelManager(paths: paths).status(of: model) {} else { XCTFail("still installed") }

        let rewritten = try shards.map { try inode(directory.appendingPathComponent($0.0)) }
        try ModelFileRewriter().rewriteIfNeeded(model, in: paths)
        XCTAssertEqual(try shards.map { try inode(directory.appendingPathComponent($0.0)) }, rewritten, "never twice")
    }

    func testACopyThatDoesNotMatchTheCatalogNeverReplacesTheFile() throws {
        let data = TestModel.payload("a", count: 3000)
        let (model, paths) = try install([("m.gguf", data)], hashOf: [("m.gguf", TestModel.payload("z", count: 3000))])
        let url = paths.installDirectory(for: model).appendingPathComponent("m.gguf")
        let before = try inode(url)

        XCTAssertThrowsError(try ModelFileRewriter().rewriteIfNeeded(model, in: paths)) {
            XCTAssertEqual($0 as? ModelFileRewriteError, .checksumMismatch(file: "m.gguf"))
        }
        XCTAssertEqual(try inode(url), before)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertFalse(ModelFileRewriter.isRewritten(url), "so the next launch tries again")
        XCTAssertEqual(try names(in: url.deletingLastPathComponent()), ["m.gguf"])
    }

    func testTooLittleSpaceLeavesTheFileAsItWas() throws {
        let (model, paths) = try install([("m.gguf", TestModel.payload("a", count: 3000))])
        let url = paths.installDirectory(for: model).appendingPathComponent("m.gguf")
        let before = try inode(url)

        XCTAssertThrowsError(try ModelFileRewriter(diskSpace: FakeDiskSpace(bytes: 100)).rewriteIfNeeded(model, in: paths)) {
            XCTAssertEqual($0 as? ModelFileRewriteError, .notEnoughSpace(needed: 3004, available: 100))
        }
        XCTAssertEqual(try inode(url), before)
        XCTAssertFalse(ModelFileRewriter.isRewritten(url))
        XCTAssertEqual(try names(in: url.deletingLastPathComponent()), ["m.gguf"])
    }

    func testWhatAnInterruptedRewriteLeftBehindIsReplaced() throws {
        let data = TestModel.payload("a", count: 3000)
        let (model, paths) = try install([("m.gguf", data)])
        let directory = paths.installDirectory(for: model)
        try Data("half a copy".utf8).write(to: directory.appendingPathComponent(".m.gguf.rewrite"))

        try ModelFileRewriter().rewriteIfNeeded(model, in: paths)

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("m.gguf")), data)
        XCTAssertEqual(try names(in: directory), ["m.gguf"])
    }

    func testAModelThatIsNotInstalledIsLeftAlone() throws {
        let (model, _) = TestModel.make(shards: [("m.gguf", TestModel.payload("a", count: 3000))])
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        XCTAssertNoThrow(try ModelFileRewriter().rewriteIfNeeded(model, in: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.installDirectory(for: model).path))
    }
}
