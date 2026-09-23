import XCTest

/// The resumable release workflow: Scripts/release.sh, Scripts/resume-release.sh and Scripts/formal-release.sh,
/// run for real against `ReleaseFixture`'s test doubles (no Apple service, signing identity or compiler).
final class ReleaseScriptTests: XCTestCase {
    private let pending: Int32 = 75
    private let invalid: Int32 = 65
    private let unreachable: Int32 = 69

    /// Runs release.sh in the fixture repository into a new dedicated output directory.
    private func build(
        _ fixture: ReleaseFixture, _ extra: [String: String] = [:], tag: String? = "v0.3.1"
    ) throws -> (result: TestSupport.ProcessResult, out: URL) {
        let out = fixture.root.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
        var env = ["LINT_RELEASE_OUTPUT_DIR": out.path, "LINT_BUILD_NUMBER": "42"]
        if let tag { env["LINT_RELEASE_TAG"] = tag }
        for (key, value) in extra { env[key] = value }
        return (try fixture.run("release.sh", [], env), out)
    }

    private func stateFile(_ out: URL) -> URL { out.appendingPathComponent("release-state.json") }
    private func dmg(_ out: URL, _ name: String = "Lint-0.3.1-macOS-arm64.dmg") -> URL { out.appendingPathComponent(name) }

    private func assertNoSecrets(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in files where !url.hasDirectoryPath {
            XCTAssertFalse(["p8", "p12"].contains(url.pathExtension), "a key file in the artifacts: \(url.path)", file: file, line: line)
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for secret in [ReleaseFixture.secretKeyID, ReleaseFixture.secretIssuer, "SECRETP8BODY", "PRIVATE KEY"] {
                XCTAssertFalse(text.contains(secret), "\(url.lastPathComponent) contains a secret", file: file, line: line)
            }
        }
    }

    // MARK: - release.sh: output directory

    func testACustomOutputDirectoryHoldsTheReleaseAndDistIsNotUsed() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["LINT_SKIP_NOTARIZE": "1"])
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        let name = "Lint-0.3.1-macOS-arm64-unnotarized.dmg"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg(out, name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg(out, name + ".sha256").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Lint.app").path), "the app is assembled in scratch space")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("dist").path), "dist/ is not touched")
        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "unnotarized")
        XCTAssertEqual(state["dmgSHA256"] as? String, try ReleaseFixture.sha256(dmg(out, name)))
        XCTAssertEqual(fixture.submissions(), 0, "a dry run never contacts Apple")
    }

    func testTheDefaultOutputIsStillDistRelease() throws {
        let fixture = try ReleaseFixture()
        let result = try fixture.run("release.sh", [], ["LINT_PREVIEW_BUILD": "1", "MOCK_ADHOC": "1"])
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        let release = fixture.repo.appendingPathComponent("dist/release")
        for name in ["Lint-0.3.1-macOS-arm64-preview.dmg", "Lint-0.3.1-macOS-arm64-preview.dmg.sha256", "Lint.app"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: release.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent("release-state.json").path))
    }

    func testNotarizingRequiresADedicatedOutputDirectory() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let result = try fixture.run("release.sh", [], ["LINT_RELEASE_TAG": "v0.3.1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("LINT_RELEASE_OUTPUT_DIR"), result.stderr)
        XCTAssertEqual(fixture.packageRuns(), 0, "it fails before building")
    }

    func testAnOutputDirectoryIsNeverReused() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let out = fixture.root.appendingPathComponent("used")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try "{}".write(to: stateFile(out), atomically: true, encoding: .utf8)
        let result = try fixture.run("release.sh", [], ["LINT_RELEASE_OUTPUT_DIR": out.path, "LINT_RELEASE_TAG": "v0.3.1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not empty"), result.stderr)
        XCTAssertEqual(try String(contentsOf: stateFile(out), encoding: .utf8), "{}")

        let relative = try fixture.run("release.sh", [], ["LINT_RELEASE_OUTPUT_DIR": "relative/out", "LINT_SKIP_NOTARIZE": "1"])
        XCTAssertNotEqual(relative.status, 0)
        XCTAssertTrue(relative.stderr.contains("absolute"), relative.stderr)
    }

    func testANotarizedBuildNeedsACleanCheckoutOfItsTag() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        try "// work in progress\n".write(to: fixture.repo.appendingPathComponent("Sources.swift"), atomically: true, encoding: .utf8)
        let dirty = try build(fixture).result
        XCTAssertNotEqual(dirty.status, 0)
        XCTAssertTrue(dirty.stderr.contains("uncommitted"), dirty.stderr)
        try fixture.git("checkout", "--", "Sources.swift")

        let mismatch = try build(fixture, ["LINT_RELEASE_COMMIT": String(repeating: "a", count: 40)]).result
        XCTAssertNotEqual(mismatch.status, 0)
        XCTAssertTrue(mismatch.stderr.contains("LINT_RELEASE_COMMIT"), mismatch.stderr)
        XCTAssertEqual(fixture.submissions(), 0)
    }

    // MARK: - release.sh: notarization outcomes

    func testAcceptedSubmissionIsStapledVerifiedAndRecorded() throws {
        let fixture = try ReleaseFixture()
        let commit = try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture)
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("FINALIZED"), result.stdout)

        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["schemaVersion"] as? Int, 1)
        XCTAssertEqual(state["version"] as? String, "0.3.1")
        XCTAssertEqual(state["tag"] as? String, "v0.3.1")
        XCTAssertEqual(state["commit"] as? String, commit)
        XCTAssertEqual(state["architecture"] as? String, "arm64")
        XCTAssertEqual(state["buildNumber"] as? String, "42")
        XCTAssertEqual(state["dmgPath"] as? String, dmg(out).path)
        XCTAssertEqual(state["submissionID"] as? String, ReleaseFixture.submissionID)
        XCTAssertEqual(state["notarizationStatus"] as? String, "Accepted")
        XCTAssertEqual(state["releaseStatus"] as? String, "finalized")
        for key in ["dmgCreatedAt", "submissionCreatedAt", "lastCheckedAt", "finalizedAt"] {
            XCTAssertNotNil((state[key] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, key)
        }

        // The submitted bytes are what Apple saw; stapling then changed the file, and the checksum is of the final one.
        let submitted = try XCTUnwrap(state["dmgSHA256"] as? String)
        let submissions = try String(contentsOf: fixture.mockDir.appendingPathComponent("submissions"), encoding: .utf8)
        XCTAssertEqual(submissions, "\(ReleaseFixture.submissionID) \(submitted)\n")
        let final = try ReleaseFixture.sha256(dmg(out))
        XCTAssertEqual(state["finalSHA256"] as? String, final)
        XCTAssertNotEqual(final, submitted)
        XCTAssertTrue(try String(contentsOf: dmg(out, "Lint-0.3.1-macOS-arm64.dmg.sha256"), encoding: .utf8).hasPrefix(final))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".finalize").path))
        XCTAssertTrue(fixture.calls().contains { $0.hasPrefix("spctl --assess --type execute") }, "Gatekeeper is asked")
        try assertNoSecrets(in: out)
    }

    func testAClientTimeoutWithASubmissionIDIsPendingNotFailed() throws {
        let fixture = try ReleaseFixture()
        let commit = try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["MOCK_WAIT": "timeout", "MOCK_INFO": "In Progress", "LINT_NOTARY_TIMEOUT": "1m"])
        XCTAssertEqual(result.status, pending, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("exit code 124"), result.stdout)
        XCTAssertTrue(result.stdout.contains("not a rejection"), result.stdout)
        XCTAssertTrue(result.stderr.contains("NOTARIZATION PENDING"), result.stderr)
        XCTAssertTrue(fixture.calls().contains { $0.contains("notarytool wait \(ReleaseFixture.submissionID) --timeout 1m") })

        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "pending")
        XCTAssertEqual(state["notarizationStatus"] as? String, "In Progress")
        XCTAssertEqual(state["submissionID"] as? String, ReleaseFixture.submissionID)
        XCTAssertEqual(state["commit"] as? String, commit)
        XCTAssertEqual(state["dmgSHA256"] as? String, try ReleaseFixture.sha256(dmg(out)), "the DMG is exactly the submitted file")
        XCTAssertEqual(state["finalSHA256"] as? String, "")
        XCTAssertFalse(fixture.calls().contains { $0.contains("stapler staple") }, "nothing is stapled while pending")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg(out, "Lint-0.3.1-macOS-arm64.dmg.sha256").path))
        try assertNoSecrets(in: out)
    }

    func testInvalidIsReportedWithItsLogAndNeverStapled() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["MOCK_WAIT": "invalid", "MOCK_INFO": "Invalid"])
        XCTAssertEqual(result.status, invalid, result.stderr + result.stdout)
        XCTAssertTrue(result.stderr.contains("NOTARIZATION REJECTED"), result.stderr)
        XCTAssertTrue(result.stderr.contains("secure timestamp"), "the log is printed\n\(result.stderr)")
        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "invalid")
        XCTAssertEqual(state["notarizationStatus"] as? String, "Invalid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("notarization-log.json").path))
        XCTAssertFalse(fixture.calls().contains { $0.contains("stapler staple") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg(out, "Lint-0.3.1-macOS-arm64.dmg.sha256").path), "no release checksum")
    }

    func testAnUploadFailureHasNoSubmissionAndSaysSo() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["MOCK_SUBMIT": "uploadfail"])
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("no submission ID"), result.stderr)
        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "submission-failed")
        XCTAssertEqual(state["submissionID"] as? String, "")
    }

    func testAnAuthFailureAfterSubmissionKeepsTheReleasePending() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["MOCK_WAIT": "authfail", "MOCK_INFO": "authfail"])
        XCTAssertEqual(result.status, unreachable, result.stderr + result.stdout)
        XCTAssertTrue(result.stderr.contains("STATUS UNAVAILABLE"), result.stderr)
        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "pending")
        XCTAssertEqual(state["submissionID"] as? String, ReleaseFixture.submissionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg(out).path), "the submitted DMG is kept")
    }

    // MARK: - resume-release.sh

    /// A release left pending by a client timeout.
    private func pendingRelease(_ fixture: ReleaseFixture) throws -> URL {
        try fixture.tagRelease("v0.3.1")
        let (result, out) = try build(fixture, ["MOCK_WAIT": "timeout", "MOCK_INFO": "In Progress"])
        XCTAssertEqual(result.status, pending, result.stderr)
        return out
    }

    func testResumeWhileStillInProgressChangesNothing() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        let before = try ReleaseFixture.sha256(dmg(out))
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "In Progress"])
        XCTAssertEqual(result.status, pending, result.stderr + result.stdout)
        XCTAssertTrue(result.stderr.contains("NOTARIZATION PENDING"), result.stderr)
        XCTAssertEqual(try ReleaseFixture.sha256(dmg(out)), before)
        XCTAssertEqual(try fixture.state(stateFile(out))["releaseStatus"] as? String, "pending")
        XCTAssertEqual(fixture.submissions(), 1, "resuming never submits again")
        XCTAssertEqual(fixture.packageRuns(), 1, "resuming never rebuilds")
    }

    func testResumeAcceptedStaplesTheExactSubmittedDMG() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        let submitted = try ReleaseFixture.sha256(dmg(out))
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("matches the submitted DMG"), result.stdout)
        let state = try fixture.state(stateFile(out))
        XCTAssertEqual(state["releaseStatus"] as? String, "finalized")
        XCTAssertEqual(state["dmgSHA256"] as? String, submitted)
        XCTAssertEqual(state["finalSHA256"] as? String, try ReleaseFixture.sha256(dmg(out)))
        XCTAssertEqual(fixture.submissions(), 1)
        XCTAssertEqual(fixture.packageRuns(), 1)
        let staples = fixture.calls().filter { $0.hasPrefix("xcrun stapler staple") }
        XCTAssertEqual(staples.count, 1)
        XCTAssertTrue(staples[0].hasSuffix(".finalize/Lint-0.3.1-macOS-arm64.dmg"), "a verified copy of the submitted file")
        try assertNoSecrets(in: out)

        // Running it again is harmless.
        let again = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertTrue(again.stdout.contains("already finalized"), again.stdout)
        XCTAssertEqual(fixture.calls().filter { $0.hasPrefix("xcrun stapler staple") }.count, 1)
    }

    func testResumeInvalidPrintsTheLogAndDoesNotStaple() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Invalid"])
        XCTAssertEqual(result.status, invalid, result.stderr + result.stdout)
        XCTAssertTrue(result.stderr.contains("secure timestamp"), result.stderr)
        XCTAssertEqual(try fixture.state(stateFile(out))["releaseStatus"] as? String, "invalid")
        XCTAssertFalse(fixture.calls().contains { $0.contains("stapler staple") })

        let again = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(again.status, invalid, "an Invalid submission stays Invalid")
    }

    func testResumeStopsWhenTheDMGIsMissing() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        try FileManager.default.removeItem(at: dmg(out))
        let callsBefore = fixture.calls().count
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("the submitted DMG is missing"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Do not rebuild it"), result.stderr)
        XCTAssertEqual(fixture.calls().count, callsBefore, "Apple is not even asked")
    }

    func testResumeStopsWhenTheDMGWasChanged() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        let handle = try FileHandle(forWritingTo: dmg(out))
        handle.seekToEndOfFile()
        handle.write(Data([0]))
        try handle.close()
        let callsBefore = fixture.calls().count
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("changed or replaced"), result.stderr)
        XCTAssertEqual(fixture.calls().count, callsBefore, "no status query and no stapling")
        XCTAssertEqual(try fixture.state(stateFile(out))["releaseStatus"] as? String, "pending")
    }

    func testResumeRefusesAStateThatWasNeverSubmitted() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let (_, out) = try build(fixture, ["MOCK_SUBMIT": "uploadfail"])
        let result = try fixture.run("resume-release.sh", [stateFile(out).path])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("nothing to resume"), result.stderr)
    }

    func testResumeVerifiesAgainstTheSubmittedCommitNotTheWorkingTree() throws {
        let fixture = try ReleaseFixture()
        let out = try pendingRelease(fixture)
        // Development moves on: an entitlement is added and committed. The release was signed without it.
        let entitlements = fixture.repo.appendingPathComponent("Resources/Lint.entitlements")
        let text = try String(contentsOf: entitlements, encoding: .utf8)
        try text.replacingOccurrences(of: "<dict>", with: "<dict>\n\t<key>com.apple.security.device.audio-input</key>\n\t<true/>")
            .write(to: entitlements, atomically: true, encoding: .utf8)
        try fixture.git("commit", "-q", "-am", "Next version")
        let result = try fixture.run("resume-release.sh", [stateFile(out).path], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
    }

    // MARK: - formal-release.sh

    func testStartBuildsTheTagInADetachedWorktreeAndPersistentDirectory() throws {
        let fixture = try ReleaseFixture()
        let commit = try fixture.tagRelease("v0.3.1")
        let result = try fixture.run("formal-release.sh", ["start", "v0.3.1"], ["MOCK_WAIT": "timeout", "MOCK_INFO": "In Progress"])
        XCTAssertEqual(result.status, pending, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("NOTARIZATION PENDING"), result.stdout)

        let dir = fixture.releaseDirectory("v0.3.1", commit)
        let worktree = dir.appendingPathComponent("worktree")
        XCTAssertEqual(try TestSupport.run("/usr/bin/git", ["-C", worktree.path, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), commit)
        let head = try TestSupport.run("/usr/bin/git", ["-C", worktree.path, "symbolic-ref", "-q", "HEAD"])
        XCTAssertNotEqual(head.status, 0, "the worktree is detached")
        let state = try fixture.state(dir.appendingPathComponent("artifacts/release-state.json"))
        XCTAssertEqual(state["commit"] as? String, commit)
        XCTAssertEqual(state["tag"] as? String, "v0.3.1")
        XCTAssertEqual(state["releaseStatus"] as? String, "pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("artifacts/Lint-0.3.1-macOS-arm64.dmg").path))
        let logs = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("logs").path)
        XCTAssertEqual(logs.filter { $0.hasPrefix("start-") }.count, 1)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "", "the source repository's files are untouched")
        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "main")

        let status = try fixture.run("formal-release.sh", ["status"])
        XCTAssertTrue(status.stdout.contains("pending"), status.stdout)
        XCTAssertTrue(status.stdout.contains(ReleaseFixture.submissionID), status.stdout)

        let again = try fixture.run("formal-release.sh", ["start", "v0.3.1"])
        XCTAssertNotEqual(again.status, 0)
        XCTAssertTrue(again.stderr.contains("unfinished") || again.stderr.contains("already holds"), again.stderr)
        XCTAssertEqual(fixture.submissions(), 1, "a pending release is never rebuilt or resubmitted")
    }

    func testStartRefusesTagsThatAreNotAFormalRelease() throws {
        let fixture = try ReleaseFixture()
        try fixture.tagRelease("v0.3.1")
        let malformed = try fixture.run("formal-release.sh", ["start", "v0.3.1-preview.1"])
        XCTAssertNotEqual(malformed.status, 0)
        XCTAssertTrue(malformed.stderr.contains("not a release tag"), malformed.stderr)

        try fixture.git("tag", "-a", "v0.3.9", "-m", "wrong version")
        let mismatch = try fixture.run("formal-release.sh", ["start", "v0.3.9"])
        XCTAssertNotEqual(mismatch.status, 0)
        XCTAssertTrue(mismatch.stderr.contains("Version mismatch"), mismatch.stderr)

        try fixture.git("switch", "-q", "-c", "side")
        try fixture.setVersion("0.4.0")
        try fixture.git("commit", "-q", "-am", "Side branch")
        try fixture.git("tag", "-a", "v0.4.0", "-m", "not on main")
        let offMain = try fixture.run("formal-release.sh", ["start", "v0.4.0"])
        XCTAssertNotEqual(offMain.status, 0)
        XCTAssertTrue(offMain.stderr.contains("not reachable from origin/main"), offMain.stderr)
        XCTAssertEqual(fixture.packageRuns(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.releaseRoot.path), "nothing is created for a refused release")
    }

    func testCleanupKeepsPendingReleasesAndNeverTouchesOtherVersions() throws {
        let fixture = try ReleaseFixture()
        let old = try fixture.tagRelease("v0.3.1")
        XCTAssertEqual(try fixture.run("formal-release.sh", ["start", "v0.3.1"], ["MOCK_WAIT": "timeout", "MOCK_INFO": "In Progress"]).status, pending)
        try fixture.setVersion("0.3.2")
        try fixture.git("commit", "-q", "-am", "Bump the version to 0.3.2")
        let new = try fixture.tagRelease("v0.3.2")
        XCTAssertEqual(try fixture.run("formal-release.sh", ["start", "v0.3.2"]).status, 0)
        let oldDir = fixture.releaseDirectory("v0.3.1", old)
        let newDir = fixture.releaseDirectory("v0.3.2", new)

        let refused = try fixture.run("formal-release.sh", ["cleanup", "v0.3.1"])
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.stderr.contains("--discard-pending"), refused.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("artifacts/Lint-0.3.1-macOS-arm64.dmg").path))

        let worktreeOnly = try fixture.run("formal-release.sh", ["cleanup", "v0.3.2", "--worktree-only"])
        XCTAssertEqual(worktreeOnly.status, 0, worktreeOnly.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("worktree").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("artifacts/Lint-0.3.2-macOS-arm64.dmg").path))

        let full = try fixture.run("formal-release.sh", ["cleanup", "v0.3.2"])
        XCTAssertEqual(full.status, 0, full.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.releaseRoot.appendingPathComponent("v0.3.2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("artifacts/release-state.json").path), "v0.3.1 is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("worktree/Scripts/release.sh").path))
        XCTAssertFalse(try fixture.git("worktree", "list").contains("v0.3.2"), "git forgets the removed worktree")

        let traversal = try fixture.run("formal-release.sh", ["cleanup", "../v0.3.1"])
        XCTAssertNotEqual(traversal.status, 0)
    }

    /// The whole story: v0.3.1 is submitted and stays In Progress, development of v0.3.2 goes on in the
    /// primary checkout (edits, dev builds, a preview), and v0.3.1 is then resumed and finalized from its
    /// untouched artifact.
    func testAPendingReleaseSurvivesDevelopmentAndIsFinalizedLater() throws {
        let fixture = try ReleaseFixture()
        let commit = try fixture.tagRelease("v0.3.1") // 1. main has the v0.3.1 release commit

        // 2-4. Start the release; Apple keeps it In Progress past the wait.
        let start = try fixture.run("formal-release.sh", ["start", "v0.3.1"], ["MOCK_WAIT": "timeout", "MOCK_INFO": "In Progress"])
        XCTAssertEqual(start.status, pending, start.stderr + start.stdout)
        let artifacts = fixture.releaseDirectory("v0.3.1", commit).appendingPathComponent("artifacts")
        let dmgURL = artifacts.appendingPathComponent("Lint-0.3.1-macOS-arm64.dmg")
        let stateURL = artifacts.appendingPathComponent("release-state.json")
        // 5. The state and the exact DMG are safe.
        let submitted = try ReleaseFixture.sha256(dmgURL)
        XCTAssertEqual(try fixture.state(stateURL)["dmgSHA256"] as? String, submitted)
        let stateBefore = try Data(contentsOf: stateURL)
        let modified = try FileManager.default.attributesOfItem(atPath: dmgURL.path)[.modificationDate] as? Date

        // 6. v0.3.2 work in the primary checkout.
        try fixture.setVersion("0.3.2")
        let source = fixture.repo.appendingPathComponent("Sources.swift")
        try "print(\"Lint 0.3.2 in progress\")\n".write(to: source, atomically: true, encoding: .utf8)
        let devStatus = try fixture.git("status", "--porcelain")

        // 7. Normal development builds: an app build, a packaging dry run and a preview into dist/.
        XCTAssertEqual(try fixture.run("package-app.sh", ["debug"]).status, 0)
        let dryRun = try fixture.run("release.sh", [], ["LINT_SKIP_NOTARIZE": "1"])
        XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
        let preview = try fixture.run("release.sh", [], ["LINT_PREVIEW_BUILD": "1", "MOCK_ADHOC": "1"])
        XCTAssertEqual(preview.status, 0, preview.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("dist/release/Lint-0.3.2-macOS-arm64-preview.dmg").path))

        // 8. v0.3.1 is unchanged.
        XCTAssertEqual(try ReleaseFixture.sha256(dmgURL), submitted)
        XCTAssertEqual(try Data(contentsOf: stateURL), stateBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dmgURL.path)[.modificationDate] as? Date, modified)

        // 9-12. Resume; Apple has accepted it; the SHA matches; staple and finalize.
        let resume = try fixture.run("formal-release.sh", ["resume", "v0.3.1"], ["MOCK_INFO": "Accepted"])
        XCTAssertEqual(resume.status, 0, resume.stderr + resume.stdout)
        XCTAssertTrue(resume.stdout.contains("SHA-256 \(submitted) matches the submitted DMG"), resume.stdout)
        let state = try fixture.state(stateURL)
        XCTAssertEqual(state["releaseStatus"] as? String, "finalized")
        XCTAssertEqual(state["commit"] as? String, commit)
        XCTAssertEqual(state["version"] as? String, "0.3.1")
        XCTAssertEqual(state["finalSHA256"] as? String, try ReleaseFixture.sha256(dmgURL))
        XCTAssertTrue(try String(contentsOf: artifacts.appendingPathComponent("Lint-0.3.1-macOS-arm64.dmg.sha256"), encoding: .utf8)
            .hasPrefix(try ReleaseFixture.sha256(dmgURL)))
        XCTAssertEqual(fixture.submissions(), 1, "one submission, never repeated")
        XCTAssertEqual(fixture.calls().filter { $0.hasPrefix("package-app release") && $0.contains("/LintRelease/") }.count, 1,
                       "v0.3.1 was built once, in its worktree")

        // 13. The v0.3.2 development files are untouched.
        XCTAssertEqual(try fixture.git("status", "--porcelain"), devStatus)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "print(\"Lint 0.3.2 in progress\")\n")
        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "main")
        let plist = try TestSupport.run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", fixture.repo.appendingPathComponent("Resources/Info.plist").path])
        XCTAssertEqual(plist.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0.3.2")
    }

    // MARK: - GitHub Actions

    private func workflow(_ name: String) throws -> String {
        try String(contentsOf: TestSupport.repoRoot.appendingPathComponent(".github/workflows/\(name)"), encoding: .utf8)
    }

    func testTheReleaseWorkflowKeepsAPendingDMGInsteadOfWaitingForHours() throws {
        let text = try workflow("release.yml")
        let triggers = try XCTUnwrap(text.components(separatedBy: "\non:\n").last?.components(separatedBy: "\npermissions:").first)
        XCTAssertFalse(triggers.contains("pull_request"), "the signing workflow never runs on pull requests")
        XCTAssertTrue(text.contains("LINT_RELEASE_OUTPUT_DIR:"), "a dedicated, never-wiped output directory")
        XCTAssertTrue(text.contains("group: release-${{ inputs.tag || github.ref_name }}"), "serialized per tag, not globally")
        XCTAssertTrue(text.contains("name: pending-release-${{ env.TAG }}"))
        XCTAssertTrue(text.contains("cmp \"$ARTIFACTS/$name\" \"$ROUNDTRIP/$name\""), "the kept DMG is checked byte-for-byte")
        XCTAssertTrue(text.contains("NOTARIZATION PENDING"))
        XCTAssertTrue(text.contains("Refuse to rebuild while a submission of this tag is pending"))
        XCTAssertFalse(text.contains("--wait"), "the workflow does not wait on its own; release.sh records the submission first")
    }

    func testTheResumeWorkflowNeverBuildsSignsOrSubmits() throws {
        let text = try workflow("resume-release.yml")
        let triggers = try XCTUnwrap(text.components(separatedBy: "\non:\n").last?.components(separatedBy: "\npermissions:").first)
        XCTAssertTrue(triggers.contains("workflow_dispatch"))
        for trigger in ["push:", "pull_request", "schedule:", "workflow_run"] {
            XCTAssertFalse(triggers.contains(trigger), trigger)
        }
        XCTAssertTrue(text.contains("./Scripts/resume-release.sh"))
        for forbidden in ["Scripts/release.sh", "package-app.sh", "swift build", "notarytool submit", "APPLE_DEVELOPER_ID_P12", "codesign"] {
            XCTAssertFalse(text.contains(forbidden), "resume must not build, sign or submit: \(forbidden)")
        }
        XCTAssertTrue(text.contains("group: release-${{ inputs.tag }}"), "same per-tag group as release.yml")
        XCTAssertTrue(text.contains("run-id: ${{ inputs.run_id }}"), "the exact artifact of the pending run")
        XCTAssertTrue(text.contains("dmgSHA256)\" = \"$EXPECTED_SHA256\""), "tied to the maintainer-supplied hash")
    }

    func testCIStillBuildsPreviewsIntoDistWithoutSecrets() throws {
        let text = try workflow("ci.yml")
        XCTAssertFalse(text.contains("secrets."))
        XCTAssertFalse(text.contains("LINT_RELEASE_OUTPUT_DIR"))
        XCTAssertTrue(text.contains("dist/release/*-preview.dmg"))
    }
}
