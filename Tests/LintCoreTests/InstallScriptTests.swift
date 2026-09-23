import XCTest

@testable import LintCore

/// Scripts/install.sh and the packaging scripts: no Homebrew, no sudo by default, no need for .git,
/// and the release pipeline's existing checks are still there. The scripts themselves were also run
/// for real (a git-less copy, a fake HOME, the preview DMG); these tests keep those properties from
/// quietly regressing.
final class InstallScriptTests: XCTestCase {
    private let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin" // no Homebrew anywhere on it

    private func codeLines(_ script: String) throws -> [String] {
        try String(contentsOfFile: TestSupport.script(script), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    private func dryRun(_ arguments: [String] = [], home: URL? = nil) throws -> TestSupport.ProcessResult {
        var env = ["PATH": systemPath]
        if let home { env["HOME"] = home.path }
        return try TestSupport.run(TestSupport.script("install.sh"), ["--dry-run"] + arguments, environment: env)
    }

    func testTheInstallerChecksItsPrerequisitesWithoutHomebrew() throws {
        let home = try TestSupport.makeTempDirectory()
        let result = try dryRun(home: home)
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("Homebrew is not required"), result.stdout)
        XCTAssertTrue(result.stdout.contains("destination: \(home.path)/Applications/Lint.app"), "the default is ~/Applications, no sudo\n\(result.stdout)")
        XCTAssertFalse(result.stdout.contains("password"), "the default install never asks for a password")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications").path), "a dry run installs nothing")
    }

    func testSystemInstallMustBeAskedForExplicitly() throws {
        let result = try dryRun(["--system"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("destination: /Applications/Lint.app"), result.stdout)
    }

    func testUnknownOptionsFail() throws {
        let result = try TestSupport.run(TestSupport.script("install.sh"), ["--bogus"], environment: ["PATH": systemPath])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("unknown option"), result.stderr)
    }

    func testNoScriptInstallsOrCallsHomebrew() throws {
        for name in [
            "install.sh", "fetch-llama-runtime.sh", "sign-llama-runtime.sh", "package-app.sh", "run-dev.sh", "release.sh",
            "resume-release.sh", "formal-release.sh",
        ] {
            for line in try codeLines(name) {
                for forbidden in ["brew install", "/opt/homebrew", "command -v brew", "brew --prefix", "brew.sh", "HOMEBREW"] {
                    XCTAssertFalse(line.contains(forbidden), "\(name) must not use Homebrew: \(line)")
                }
            }
        }
    }

    func testTheSourceInstallDoesNotNeedGitMetadata() throws {
        // A GitHub "Download ZIP" has no .git; none of the build path may run git.
        for name in ["install.sh", "fetch-llama-runtime.sh", "sign-llama-runtime.sh", "package-app.sh"] {
            for line in try codeLines(name) {
                XCTAssertNil(line.range(of: "(^|[;&|(`]|\\$\\()\\s*git\\s", options: .regularExpression), "\(name) must not run git: \(line)")
            }
        }
    }

    func testSudoIsOnlyEverUsedForTheExplicitSystemInstall() throws {
        let lines = try codeLines("install.sh").filter { $0.contains("sudo") }
        XCTAssertEqual(lines.count, 1, "sudo appears in run_priv only:\n\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("run_priv()") })
        // USE_SUDO can only become set for --system.
        let text = try String(contentsOfFile: TestSupport.script("install.sh"), encoding: .utf8)
        let assignments = text.components(separatedBy: "USE_SUDO=1")
        XCTAssertEqual(assignments.count, 2)
        let before = assignments[0]
        XCTAssertTrue(before.range(of: "if \\[ \"\\$DEST_KIND\" = system \\]", options: .regularExpression) != nil)
    }

    func testTheInstallerLeavesAnotherRunningLintAlone() throws {
        let text = try String(contentsOfFile: TestSupport.script("install.sh"), encoding: .utf8)
        XCTAssertTrue(text.contains("running_from_destination"))
        XCTAssertFalse(text.contains("tell application id"), "quitting by bundle id would also quit a copy that is not being replaced")
    }

    // MARK: - package-app.sh keeps doing everything it did

    func testPackageAppStillAssemblesTheWholeApp() throws {
        let text = try String(contentsOfFile: TestSupport.script("package-app.sh"), encoding: .utf8)
        for needle in [
            "swift build", "Info.plist", "PlistBuddy", "LINT_BUILD_NUMBER", "AppIcon.icns", "Resources/*.lproj",
            "\"$BIN_DIR\"/*.bundle", "PkgInfo", "LINT_RELEASE_BUILD", "--options runtime --timestamp", "Apple Development",
            "fetch-llama-runtime.sh", "sign-llama-runtime.sh", "LlamaRuntime",
            // FoundationModels must stay weak-linked, or Lint stops launching before macOS 26.
            "LC_LOAD_WEAK_DYLIB",
        ] {
            XCTAssertTrue(text.contains(needle), "package-app.sh lost: \(needle)")
        }
        // SwiftPM resource bundles are copied before signing.
        let copy = try XCTUnwrap(text.range(of: "\"$BIN_DIR\"/*.bundle")).lowerBound
        let firstSign = try XCTUnwrap(text.range(of: "sign-llama-runtime.sh")).lowerBound
        XCTAssertLessThan(copy, firstSign)
    }

    func testTheNestedRuntimeIsSignedBeforeTheOuterAppAndNeverWithDeep() throws {
        let lines = try codeLines("package-app.sh")
        let runtimeSign = lines.indices.filter { lines[$0].contains("sign-llama-runtime.sh") }
        let outerSign = lines.indices.filter { lines[$0].contains("codesign") && lines[$0].contains("\"$APP\"") }
        XCTAssertEqual(runtimeSign.count, 4, "release (with and without a keychain), development identity, ad-hoc")
        XCTAssertEqual(outerSign.count, 3, "release, development identity, ad-hoc")
        // Each outer signature comes after at least one runtime signature in its own branch.
        for outer in outerSign {
            XCTAssertTrue(runtimeSign.contains { $0 < outer && outer - $0 < 12 }, "the runtime must be signed just before the app: line \(outer)")
        }
        for line in lines where line.contains("codesign") || line.contains("sign-llama-runtime") {
            XCTAssertFalse(line.contains("--deep"), "--deep must not be used to sign: \(line)")
        }
        for line in try codeLines("sign-llama-runtime.sh") {
            XCTAssertFalse(line.contains("--deep"), line)
        }
    }

    func testReleaseScriptStillEnforcesTheExistingChecks() throws {
        let text = try String(contentsOfFile: TestSupport.script("release.sh"), encoding: .utf8)
        for needle in [
            "Developer ID Application", "runtime[^)]*\\)", "Timestamp=", "TeamIdentifier", "get-task-allow", "notarytool submit",
            "stapler staple", "spctl --assess", "hdiutil verify", "must contain exactly Lint.app and Applications",
            "codesign --verify --deep --strict", "shasum -a 256", "LINT_PREVIEW_BUILD",
            // and the new runtime checks
            "verify_llama_runtime", "verify_app_resources", "LlamaRuntimeManifest.json",
        ] {
            XCTAssertTrue(text.contains(needle), "release.sh lost: \(needle)")
        }
        // The runtime is verified wherever the app is: in the build output and in the app inside the DMG.
        XCTAssertEqual(text.components(separatedBy: "verify_app_signature \"").count - 1, 2)
    }
}
