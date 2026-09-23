import Foundation
import XCTest

/// A throwaway git repository with the real release scripts, a fake `package-app.sh`, and test doubles for
/// every Apple tool the scripts call (codesign, hdiutil, security, spctl, lipo, file, swift, and xcrun's
/// notarytool and stapler). Nothing contacts Apple, signs, compiles or mounts anything.
///
/// The fake "disk image" is a tar archive: hdiutil attach extracts it into the mount point, detach writes a
/// read-write image back, and stapling appends a block (so, as for real, it changes the file's SHA-256) and
/// records the new hash for `stapler validate`. Each tool call is appended to `calls.log`.
struct ReleaseFixture {
    let root: URL
    let repo: URL
    let mockDir: URL
    let bin: URL
    let releaseRoot: URL
    let keyFile: URL

    /// Values that stand in for the App Store Connect credentials; they must never reach any artifact.
    static let secretKeyID = "SECRETKEYID9"
    static let secretIssuer = "69a6de7f-SECRET-ISSUER-47e3-e053-5b8c7c11a4d1"
    static let secretKeyBody = "-----BEGIN PRIVATE KEY-----SECRETP8BODY-----END PRIVATE KEY-----"
    static let submissionID = "5d7e0c3a-1b2f-4c8d-9e6a-7f1b2c3d4e5f"

    init(version: String = "0.3.1", name: String = #function) throws {
        root = try TestSupport.makeTempDirectory(name)
        repo = root.appendingPathComponent("repo")
        mockDir = root.appendingPathComponent("mock")
        bin = root.appendingPathComponent("bin")
        releaseRoot = root.appendingPathComponent("Application Support/LintRelease")
        keyFile = root.appendingPathComponent("keys/AuthKey_TEST.p8")
        let fm = FileManager.default
        for dir in [repo, mockDir, bin, keyFile.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Self.secretKeyBody.write(to: keyFile, atomically: true, encoding: .utf8)

        // The mock tools.
        let mock = bin.appendingPathComponent("mock-tool")
        try Self.mockTool.write(to: mock, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)
        for tool in ["xcrun", "codesign", "hdiutil", "security", "spctl", "lipo", "file", "swift"] {
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent(tool).path, withDestinationPath: "mock-tool")
        }

        // The repository: the scripts under test, the resources they verify against, a stand-in source file.
        let real = TestSupport.repoRoot
        let scripts = repo.appendingPathComponent("Scripts")
        let resources = repo.appendingPathComponent("Resources")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for script in ["release.sh", "resume-release.sh", "formal-release.sh"] {
            try fm.copyItem(at: real.appendingPathComponent("Scripts/\(script)"), to: scripts.appendingPathComponent(script))
        }
        let package = scripts.appendingPathComponent("package-app.sh")
        try Self.fakePackageApp.write(to: package, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
        for item in try fm.contentsOfDirectory(atPath: real.appendingPathComponent("Resources").path)
        where item.hasSuffix(".lproj") || ["Info.plist", "Lint.entitlements", "LlamaRuntimeManifest.json"].contains(item) {
            try fm.copyItem(at: real.appendingPathComponent("Resources/\(item)"), to: resources.appendingPathComponent(item))
        }
        try "print(\"Lint \(version)\")\n".write(to: repo.appendingPathComponent("Sources.swift"), atomically: true, encoding: .utf8)
        try ".build/\ndist/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try setVersion(version)

        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("commit", "-q", "-m", "Lint \(version)")
    }

    // MARK: - Running things

    /// The environment every script runs with: mock tools first on PATH, fake credentials, and none of the
    /// caller's release settings (an empty value counts as unset in the scripts).
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "MOCK_DIR": mockDir.path,
            "LINT_RELEASE_ROOT": releaseRoot.path,
            "APPLE_API_KEY_PATH": keyFile.path,
            "APPLE_API_KEY_ID": Self.secretKeyID,
            "APPLE_API_ISSUER_ID": Self.secretIssuer,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
        for name in [
            "LINT_PREVIEW_BUILD", "LINT_SKIP_NOTARIZE", "LINT_RELEASE_TAG", "LINT_RELEASE_COMMIT", "LINT_BUILD_NUMBER",
            "LINT_KEYCHAIN", "LINT_RELEASE_OUTPUT_DIR", "LINT_NOTARY_TIMEOUT", "LINT_RELEASE_BUILD", "LINT_DIST_DIR",
            "CODESIGN_IDENTITY", "APPLE_TEAM_ID", "GITHUB_OUTPUT", "MOCK_SUBMIT", "MOCK_WAIT", "MOCK_INFO", "MOCK_ADHOC",
        ] {
            env[name] = ""
        }
        for (key, value) in extra { env[key] = value }
        return env
    }

    @discardableResult
    func run(_ script: String, _ arguments: [String] = [], in directory: URL? = nil, _ extra: [String: String] = [:]) throws
        -> TestSupport.ProcessResult
    {
        let dir = directory ?? repo
        return try TestSupport.run(
            dir.appendingPathComponent("Scripts/\(script)").path, arguments, environment: environment(extra), currentDirectory: dir
        )
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let result = try TestSupport.run("/usr/bin/git", ["-C", repo.path] + arguments, environment: environment())
        guard result.status == 0 else { throw FixtureError.git(arguments.joined(separator: " "), result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags HEAD and makes it reachable from origin/main, as after a merge and a push.
    func tagRelease(_ tag: String) throws -> String {
        try git("tag", "-a", tag, "-m", "Lint \(tag)")
        let commit = try git("rev-parse", "HEAD")
        try git("update-ref", "refs/remotes/origin/main", commit)
        return commit
    }

    func setVersion(_ version: String) throws {
        let plist = repo.appendingPathComponent("Resources/Info.plist").path
        let result = try TestSupport.run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleShortVersionString \(version)", plist])
        guard result.status == 0 else { throw FixtureError.git("PlistBuddy", result.stderr) }
    }

    // MARK: - Inspecting results

    func releaseDirectory(_ name: String, _ commit: String) -> URL {
        releaseRoot.appendingPathComponent("\(name)/\(commit)")
    }

    func state(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    func calls() -> [String] {
        let text = (try? String(contentsOf: mockDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func submissions() -> Int { calls().filter { $0.hasPrefix("xcrun notarytool submit") }.count }
    func packageRuns() -> Int { calls().filter { $0.hasPrefix("package-app") }.count }

    static func sha256(_ url: URL) throws -> String {
        let result = try TestSupport.run("/usr/bin/shasum", ["-a", "256", url.path])
        return String(result.stdout.prefix(64))
    }

    enum FixtureError: Error { case git(String, String) }

    // MARK: - Test doubles

    static let fakePackageApp = #"""
    #!/bin/bash
    # Test double for Scripts/package-app.sh: the same app layout, no compiler, no network, no signing.
    set -eu
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
    APP="${LINT_DIST_DIR:-$ROOT/dist}/Lint.app"
    echo "package-app ${1:-debug} $ROOT -> $APP" >>"$MOCK_DIR/calls.log"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fake_Fake.bundle"
    { echo "Lint executable built from:"; cat "$ROOT/Sources.swift"; } >"$APP/Contents/MacOS/Lint"
    cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
    if [ -n "${LINT_BUILD_NUMBER:-}" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LINT_BUILD_NUMBER" "$APP/Contents/Info.plist"
    fi
    printf 'APPL????' >"$APP/Contents/PkgInfo"
    cp "$ROOT/Resources/Lint.entitlements" "$APP/Contents/MockEntitlements.plist" # what the mock codesign reports as signed
    echo icon >"$APP/Contents/Resources/AppIcon.icns"
    for lproj in "$ROOT"/Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
    rt="$APP/Contents/Resources/LlamaRuntime/arm64"
    mkdir -p "$rt/licenses"
    echo server >"$rt/llama-server"; chmod +x "$rt/llama-server"
    echo library >"$rt/libllama.dylib"
    echo license >"$rt/licenses/LICENSE"
    manifest="$ROOT/Resources/LlamaRuntimeManifest.json"
    printf '{"architecture":"arm64","tag":"%s","archiveSHA256":"%s"}\n' \
      "$(plutil -extract upstream.tag raw -o - "$manifest")" "$(plutil -extract runtimes.arm64.sha256 raw -o - "$manifest")" \
      >"$rt/runtime-info.json"
    printf '%s\n' "$APP"
    """#

    static let mockTool = #"""
    #!/bin/bash
    # Test double for the Apple tools Scripts/release.sh uses. It never contacts Apple.
    #   MOCK_SUBMIT  ok | uploadfail          (notarytool submit)
    #   MOCK_WAIT    accepted | invalid | timeout | authfail   (notarytool wait)
    #   MOCK_INFO    Accepted | In Progress | Invalid | authfail (notarytool info)
    #   MOCK_ADHOC   1 makes codesign describe an ad-hoc signature (previews)
    set -u
    M="$MOCK_DIR"
    tool=$(basename "$0")
    echo "$tool $*" >>"$M/calls.log"
    sha() { shasum -a 256 "$1" | awk '{print $1}'; }
    last() { local a; for a in "$@"; do :; done; printf '%s' "$a"; }

    notarytool() {
      local sub="$1"; shift
      case "$sub" in
        submit)
          case "${MOCK_SUBMIT:-ok}" in
            uploadfail) echo "Error: Failed to upload file." >&2; exit 1 ;;
          esac
          echo "$SUBMISSION $(sha "$1")" >>"$M/submissions"
          echo "Conducting pre-submission checks for $(basename "$1") and initiating connection to the Apple notary service..."
          printf '{"id":"%s","message":"Successfully uploaded file","path":"%s"}\n' "$SUBMISSION" "$1"
          ;;
        wait)
          case "${MOCK_WAIT:-accepted}" in
            accepted) printf '{"id":"%s","message":"Processing complete","status":"Accepted"}\n' "$1" ;;
            invalid) printf '{"id":"%s","message":"Processing complete","status":"Invalid"}\n' "$1" ;;
            timeout) echo "Error: Timeout of 45m reached; submission $1 is still In Progress." >&2; exit 124 ;;
            authfail) echo "Error: HTTP status code: 401. Unable to authenticate." >&2; exit 1 ;;
          esac
          ;;
        info)
          case "${MOCK_INFO:-Accepted}" in
            authfail) echo "Error: HTTP status code: 401. Unable to authenticate." >&2; exit 1 ;;
            *) printf '{"createdDate":"2026-09-22T10:00:00.000Z","id":"%s","name":"Lint.dmg","status":"%s"}\n' "$1" "${MOCK_INFO:-Accepted}" ;;
          esac
          ;;
        log)
          printf '{"jobId":"%s","status":"Invalid","issues":[{"severity":"error","message":"The signature does not include a secure timestamp."}]}\n' "$1" >"$2"
          ;;
        *) echo "mock notarytool: unexpected $sub" >&2; exit 2 ;;
      esac
    }

    SUBMISSION=5d7e0c3a-1b2f-4c8d-9e6a-7f1b2c3d4e5f
    case "$tool" in
      swift) exit 0 ;;
      security)
        echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Test Co (TEAMTEST01)"'
        echo '     1 valid identities found'
        ;;
      spctl) echo "$(last "$@"): accepted"; echo "source=Notarized Developer ID" ;;
      lipo) echo arm64 ;;
      file) case "$2" in */llama-server|*.dylib) echo "Mach-O 64-bit executable arm64" ;; *) echo "ASCII text" ;; esac ;;
      codesign)
        case " $* " in
          *" --verify "*) exit 0 ;;
          *" --entitlements :- "*) cat "$(last "$@")/Contents/MockEntitlements.plist" ;;
          *" -dvv "*)
            {
              echo "Executable=$(last "$@")"
              echo "Identifier=app.lint.assistant"
              echo "CodeDirectory v=20500 size=1000 flags=0x10000(runtime) hashes=20+7 location=embedded"
              if [ -n "${MOCK_ADHOC:-}" ]; then
                echo "Signature=adhoc"
                echo "TeamIdentifier=not set"
              else
                echo "Authority=Developer ID Application: Test Co (TEAMTEST01)"
                echo "Authority=Developer ID Certification Authority"
                echo "Authority=Apple Root CA"
                echo "Timestamp=Sep 22, 2026 at 10:00:00"
                echo "TeamIdentifier=TEAMTEST01"
              fi
            } >&2
            ;;
          *" --sign "*) exit 0 ;;
          *) echo "mock codesign: unexpected $*" >&2; exit 2 ;;
        esac
        ;;
      hdiutil)
        sub="$1"; shift
        case "$sub" in
          create)
            empty=$(mktemp -d); tar -cf "$(last "$@")" -C "$empty" .; rmdir "$empty" ;;
          attach)
            img="$1"; shift; mp=""; mode=rw
            while [ $# -gt 0 ]; do
              case "$1" in -mountpoint) mp="$2"; shift ;; -readonly) mode=ro ;; esac
              shift
            done
            mkdir -p "$mp"; tar -xf "$img" -C "$mp" || exit 1
            printf '%s\t%s\t%s\n' "$mp" "$img" "$mode" >>"$M/mounts"
            ;;
          detach)
            mp="$1"
            line=$(awk -F'\t' -v mp="$mp" '$1 == mp' "$M/mounts" 2>/dev/null | tail -1)
            [ -n "$line" ] || exit 0
            img=$(printf '%s' "$line" | cut -f2); mode=$(printf '%s' "$line" | cut -f3)
            if [ "$mode" = rw ]; then tar -cf "$img" -C "$mp" .; fi
            find "$mp" -mindepth 1 -delete
            awk -F'\t' -v mp="$mp" '$1 != mp' "$M/mounts" >"$M/mounts.tmp"; mv "$M/mounts.tmp" "$M/mounts"
            ;;
          convert)
            src="$1"; out=""
            while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
            cp "$src" "$out"
            ;;
          verify) tar -tf "$1" >/dev/null ;;
          *) echo "mock hdiutil: unexpected $sub" >&2; exit 2 ;;
        esac
        ;;
      xcrun)
        if [ "$1" = --find ]; then echo "/usr/bin/$2"; exit 0; fi
        sub="$1"; shift
        case "$sub" in
          notarytool) notarytool "$@" ;;
          stapler)
            case "$1" in
              staple) dd if=/dev/zero bs=512 count=2 2>/dev/null >>"$2"; sha "$2" >>"$M/stapled"; echo "The staple and validate action worked!" ;;
              validate)
                if grep -qx "$(sha "$2")" "$M/stapled" 2>/dev/null; then echo "The validate action worked!"
                else echo "$2 does not have a ticket stapled to it." >&2; exit 65; fi
                ;;
            esac
            ;;
          *) echo "mock xcrun: unexpected $sub" >&2; exit 2 ;;
        esac
        ;;
    esac
    """#
}
