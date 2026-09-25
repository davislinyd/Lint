import Foundation

/// Files, mounts and signatures the installer needs. Tests pass a fake; the app uses `UpdateDisk.live`.
public struct UpdateDisk: Sendable {
    public var availableBytes: @Sendable (URL) throws -> Int64
    public var isWritable: @Sendable (URL) -> Bool
    public var teamID: @Sendable (URL) throws -> String
    public var createDirectory: @Sendable (URL) throws -> Void
    public var download: @Sendable (URL, URL) async throws -> Void
    public var readText: @Sendable (URL) throws -> String
    public var sha256: @Sendable (URL) throws -> String
    public var mount: @Sendable (URL) throws -> URL
    public var unmount: @Sendable (URL) throws -> Void
    public var shortVersion: @Sendable (URL) throws -> String
    public var signature: @Sendable (URL) throws -> UpdateSignature
    public var gatekeeperAccepts: @Sendable (URL) throws -> Bool
    public var ditto: @Sendable (URL, URL) throws -> Void
    public var remove: @Sendable (URL) throws -> Void
    public var beginSwap: @Sendable (Int32, URL, URL) throws -> Void

    public init(
        availableBytes: @escaping @Sendable (URL) throws -> Int64,
        isWritable: @escaping @Sendable (URL) -> Bool,
        teamID: @escaping @Sendable (URL) throws -> String,
        createDirectory: @escaping @Sendable (URL) throws -> Void,
        download: @escaping @Sendable (URL, URL) async throws -> Void,
        readText: @escaping @Sendable (URL) throws -> String,
        sha256: @escaping @Sendable (URL) throws -> String,
        mount: @escaping @Sendable (URL) throws -> URL,
        unmount: @escaping @Sendable (URL) throws -> Void,
        shortVersion: @escaping @Sendable (URL) throws -> String,
        signature: @escaping @Sendable (URL) throws -> UpdateSignature,
        gatekeeperAccepts: @escaping @Sendable (URL) throws -> Bool,
        ditto: @escaping @Sendable (URL, URL) throws -> Void,
        remove: @escaping @Sendable (URL) throws -> Void,
        beginSwap: @escaping @Sendable (Int32, URL, URL) throws -> Void
    ) {
        self.availableBytes = availableBytes
        self.isWritable = isWritable
        self.teamID = teamID
        self.createDirectory = createDirectory
        self.download = download
        self.readText = readText
        self.sha256 = sha256
        self.mount = mount
        self.unmount = unmount
        self.shortVersion = shortVersion
        self.signature = signature
        self.gatekeeperAccepts = gatekeeperAccepts
        self.ditto = ditto
        self.remove = remove
        self.beginSwap = beginSwap
    }
}

public struct UpdateInstaller: Sendable {
    public var disk: UpdateDisk

    public init(disk: UpdateDisk) {
        self.disk = disk
    }

    /// Downloads and checks a release, then asks a helper to swap it in after this process exits.
    /// The running app is never deleted here. `shouldCommit` is read again after the download so a
    /// switch to check-only can still stop the swap.
    public func install(
        release: UpdateRelease,
        runningApp: URL,
        home: URL,
        stagingRoot: URL,
        processID: Int32,
        shouldCommit: @escaping @Sendable () -> Bool = { true }
    ) async throws {
        guard UpdateLocation.isAllowed(runningApp, home: home) else {
            throw UpdateFailure.outsideInstallLocations
        }
        let team: String
        do {
            team = try disk.teamID(runningApp)
        } catch {
            throw UpdateFailure.developmentBuild
        }
        guard team == UpdateTrust.teamID else { throw UpdateFailure.developmentBuild }
        guard disk.isWritable(runningApp) else { throw UpdateFailure.notWritable }
        let free: Int64
        do {
            free = try disk.availableBytes(runningApp)
        } catch {
            throw UpdateFailure.insufficientDisk
        }
        guard release.byteSize > 0, free >= release.byteSize * 3 else { throw UpdateFailure.insufficientDisk }

        let staging = stagingRoot.appendingPathComponent(release.version.dotted, isDirectory: true)
        let image = staging.appendingPathComponent(release.diskImage.lastPathComponent)
        let incoming = runningApp.deletingLastPathComponent().appendingPathComponent("Lint.app.incoming", isDirectory: true)
        var mounted: URL?
        var handedOff = false
        do {
            try disk.createDirectory(staging)
            guard GitHubReleaseCatalog.allows(release.diskImage) else { throw UpdateFailure.untrustedURL }
            try await disk.download(release.diskImage, image)
            var checksumText: String?
            if let checksumFile = release.checksumFile {
                guard GitHubReleaseCatalog.allows(checksumFile) else { throw UpdateFailure.untrustedURL }
                let checksumURL = staging.appendingPathComponent(checksumFile.lastPathComponent)
                try await disk.download(checksumFile, checksumURL)
                checksumText = try disk.readText(checksumURL)
            }
            let expected = try GitHubReleaseCatalog.resolvedChecksum(
                assetDigest: release.assetDigest,
                checksumFile: checksumText
            ).get()
            let actual = try disk.sha256(image)
            guard actual == expected else { throw UpdateFailure.hashMismatch }

            guard shouldCommit() else { throw UpdateFailure.cancelled }
            let mountPoint = try disk.mount(image)
            mounted = mountPoint
            let payload = mountPoint.appendingPathComponent("Lint.app", isDirectory: true)
            try verify(payload, release: release)
            guard shouldCommit() else { throw UpdateFailure.cancelled }
            try? disk.remove(incoming)
            try disk.ditto(payload, incoming)
            try disk.unmount(mountPoint)
            mounted = nil
            try verify(incoming, release: release)
            guard shouldCommit() else { throw UpdateFailure.cancelled }
            guard UpdateLocation.isIncoming(incoming, for: runningApp) else {
                throw UpdateFailure.outsideInstallLocations
            }
            try disk.beginSwap(processID, runningApp, incoming)
            handedOff = true
            try? disk.remove(staging)
        } catch {
            if let mounted {
                try? disk.unmount(mounted)
            }
            // The helper is about to move `incoming` into place. Deleting it here would race that swap.
            if !handedOff {
                try? disk.remove(incoming)
            }
            try? disk.remove(staging)
            throw error
        }
    }

    private func verify(_ app: URL, release: UpdateRelease) throws {
        let version: String
        do {
            version = try disk.shortVersion(app)
        } catch {
            throw UpdateFailure.versionMismatch
        }
        guard version == release.version.dotted else { throw UpdateFailure.versionMismatch }
        let signature: UpdateSignature
        let accepted: Bool
        do {
            signature = try disk.signature(app)
            accepted = try disk.gatekeeperAccepts(app)
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.signatureRejected
        }
        guard signature.acceptsReleasePayload, accepted else {
            throw UpdateFailure.signatureRejected
        }
    }
}

enum UpdateSwap {
    static let shellScript = """
    pid="$1"
    dest="$2"
    incoming="$3"
    home="$4"
    normalize() {
      case "$1" in
        /System/Volumes/Data/*) printf '%s' "${1#/System/Volumes/Data}" ;;
        *) printf '%s' "$1" ;;
      esac
    }
    dest_key=$(normalize "$dest")
    incoming_key=$(normalize "$incoming")
    home_key=$(normalize "$home")
    case "$dest_key" in
      /Applications/Lint.app) ;;
      "$home_key"/Applications/Lint.app) ;;
      *) exit 2 ;;
    esac
    case "$incoming_key" in
      "$dest_key".incoming) ;;
      *) exit 2 ;;
    esac
    [ -d "$dest" ] || exit 1
    [ -d "$incoming" ] || exit 1
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
    done
    prev="$dest.previous"
    case "$prev" in
      *.app.previous) ;;
      *) exit 2 ;;
    esac
    rm -rf "$prev"
    mv "$dest" "$prev" || exit 1
    if mv "$incoming" "$dest"; then
      rm -rf "$prev"
      if [ -n "${LINT_UPDATE_SKIP_OPEN:-}" ]; then
        exit 0
      fi
      i=1
      while [ "$i" -le 10 ]; do
        open -n "$dest" && exit 0
        sleep 0.5
        i=$((i + 1))
      done
      exit 1
    else
      mv "$prev" "$dest" || true
      exit 1
    fi
    """

    static func launch(pid: Int32, destination: URL, incoming: URL, home: URL) throws {
        guard UpdateLocation.isAllowed(destination, home: home),
              UpdateLocation.isIncoming(incoming, for: destination)
        else { throw UpdateFailure.outsideInstallLocations }
        _ = try runScript(pid: pid, destination: destination, incoming: incoming, home: home, environment: [:], wait: false)
    }

    static func runScript(
        pid: Int32,
        destination: URL,
        incoming: URL,
        home: URL,
        environment: [String: String],
        wait: Bool
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", shellScript, "update-swap",
            String(pid), destination.path, incoming.path, home.path,
        ]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        try process.run()
        guard wait else { return 0 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
