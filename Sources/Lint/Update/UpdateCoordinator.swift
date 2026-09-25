import AppKit
import Foundation
import LintCore
import Observation

/// Checks GitHub for a newer release and, when the setting says so, swaps in the notarized app.
@MainActor
@Observable
final class UpdateCoordinator {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(SemanticVersion)
        case downloading
        case waitingForPanel(SemanticVersion)
        case failed(UpdateFailure)
    }

    private enum Record {
        static let lastCheckAt = "app.lint.update.lastCheckAt"
        static let availableVersion = "app.lint.update.availableVersion"
        static let availablePage = "app.lint.update.availablePage"
        static let failure = "app.lint.update.failure"
    }

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let client: UpdateClient
    private let installer: UpdateInstaller
    private let currentVersion: () -> String
    private let runningApp: () -> URL
    private let home: URL
    private let stagingRoot: URL
    private let startupDelay: Duration
    private let gate = CommitGate()

    private(set) var phase: Phase = .idle
    private(set) var releasePage: URL?
    private var lastCheckAt: Date?
    private var checkedThisLaunch = false
    private var generation = 0
    private var pending: UpdateRelease?
    private var automaticCommit = false
    private var started = false
    private var schedule: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(
        settings: SettingsStore,
        defaults: UserDefaults = .standard,
        client: UpdateClient = .live(),
        installer: UpdateInstaller = UpdateInstaller(disk: .live()),
        currentVersion: @escaping () -> String = { AppVersion.short },
        runningApp: @escaping () -> URL = { Bundle.main.bundleURL },
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        stagingRoot: URL? = nil,
        startupDelay: Duration = .seconds(20)
    ) {
        self.settings = settings
        self.defaults = defaults
        self.client = client
        self.installer = installer
        self.currentVersion = currentVersion
        self.runningApp = runningApp
        self.home = home
        self.stagingRoot = stagingRoot ?? LocalAIPaths.standard().updatesDirectory
        self.startupDelay = startupDelay
        if let stored = defaults.object(forKey: Record.lastCheckAt) as? TimeInterval {
            lastCheckAt = Date(timeIntervalSince1970: stored)
        }
        if let page = defaults.string(forKey: Record.availablePage),
           let url = URL(string: page), GitHubReleaseCatalog.allows(url) {
            releasePage = url
        }
        if let code = defaults.string(forKey: Record.failure), let failure = UpdateFailure(rawValue: code) {
            phase = .failed(failure)
        } else if let raw = defaults.string(forKey: Record.availableVersion),
                  let version = SemanticVersion(parsing: raw) {
            phase = .available(version)
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    var showsInstallButton: Bool {
        guard case .available = phase, settings.updateMode == .manual, !isBusy else { return false }
        return true
    }

    var showsReleasePage: Bool {
        guard let releasePage, GitHubReleaseCatalog.allows(releasePage) else { return false }
        switch phase {
        case .available where settings.updateMode == .checkOnly:
            return true
        case .failed(let failure) where failure.offersReleasePage:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            String(localized: "尚未檢查")
        case .checking:
            String(localized: "正在檢查…")
        case .upToDate:
            String(localized: "已是最新版本")
        case .available(let version), .waitingForPanel(let version):
            if case .waitingForPanel = phase {
                String(localized: "更新已就緒，建議視窗關閉後會重新啟動")
            } else {
                String(localized: "發現新版本 \(version.dotted)")
            }
        case .downloading:
            String(localized: "正在下載…")
        case .failed(let failure):
            failure.message
        }
    }

    var lastCheckText: String? {
        lastCheckAt?.formatted(date: .abbreviated, time: .shortened)
    }

    func menuInstallTitle() -> String? {
        guard case .available(let version) = phase, settings.updateMode == .manual else { return nil }
        return String(localized: "下載並安裝 \(version.dotted)")
    }

    func menuAnnounceTitle() -> String? {
        guard case .available(let version) = phase, settings.updateMode == .checkOnly else { return nil }
        return String(localized: "有新版本 \(version.dotted)")
    }

    func start() {
        guard !started else { return }
        started = true
        armSchedule(afterStartupDelay: true)
    }

    func preferencesChanged() {
        if automaticCommit, settings.updateMode != .automatic {
            gate.set(false)
        }
        if settings.updateMode == .checkOnly {
            gate.set(false)
        }
        if case .waitingForPanel(let version) = phase, settings.updateMode != .automatic {
            phase = .available(version)
            pending = nil
        }
        guard started else { return }
        armSchedule(afterStartupDelay: false)
    }

    func checkNow() {
        begin(.userCheck)
    }

    func installNow() {
        begin(.userInstall)
    }

    func openReleasePage() {
        guard let releasePage, GitHubReleaseCatalog.allows(releasePage) else { return }
        NSWorkspace.shared.open(releasePage)
    }

    /// Called from the existing one-second poll. Automatic install waits until the suggestion UI is gone.
    func installIfWaiting(panelVisible: Bool) {
        guard case .waitingForPanel = phase, !panelVisible, settings.updateMode == .automatic else { return }
        let token = generation
        phase = .downloading
        automaticCommit = true
        gate.set(true)
        work?.cancel()
        work = Task { [weak self] in
            await self?.runInstall(token: token)
        }
    }

    private func begin(_ trigger: UpdateTrigger) {
        switch phase {
        case .checking, .downloading: return
        default: break
        }
        generation += 1
        let token = generation
        phase = .checking
        work?.cancel()
        work = Task { [weak self] in
            await self?.lookup(trigger, token: token)
        }
    }

    private func armSchedule(afterStartupDelay: Bool) {
        schedule?.cancel()
        schedule = Task { [weak self] in
            guard let self else { return }
            if afterStartupDelay {
                try? await Task.sleep(for: startupDelay)
            }
            guard !Task.isCancelled else { return }
            await self.followSchedule()
        }
    }

    private func followSchedule() async {
        if settings.updateFrequency == .launch {
            await runScheduled()
            return
        }
        while !Task.isCancelled {
            let wait = UpdatePolicy.delayUntilDue(
                frequency: settings.updateFrequency,
                lastCheck: lastCheckAt,
                now: Date()
            )
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
            if UpdatePolicy.isDue(
                frequency: settings.updateFrequency,
                lastCheck: lastCheckAt,
                now: Date(),
                checkedThisLaunch: checkedThisLaunch
            ) {
                await runScheduled()
            } else if wait == 0 {
                return
            } else {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func runScheduled() async {
        guard UpdatePolicy.isDue(
            frequency: settings.updateFrequency,
            lastCheck: lastCheckAt,
            now: Date(),
            checkedThisLaunch: checkedThisLaunch
        ) else { return }
        switch phase {
        case .checking, .downloading: return
        default: break
        }
        generation += 1
        let token = generation
        phase = .checking
        await lookup(.scheduled, token: token)
    }

    private func lookup(_ trigger: UpdateTrigger, token: Int) async {
        checkedThisLaunch = true
        let checked = Date()
        lastCheckAt = checked
        defaults.set(checked.timeIntervalSince1970, forKey: Record.lastCheckAt)
        do {
            let release = try await client.latest(
                architecture: .current,
                userAgent: "Lint/\(currentVersion()) (\(UpdateTrust.bundleID))"
            )
            guard generation == token else { return }
            defaults.removeObject(forKey: Record.failure)
            guard let local = SemanticVersion(parsing: currentVersion()) else {
                phase = .failed(.developmentBuild)
                defaults.set(UpdateFailure.developmentBuild.rawValue, forKey: Record.failure)
                return
            }
            switch UpdatePolicy.action(
                mode: settings.updateMode,
                trigger: trigger,
                local: local,
                remote: release.version
            ) {
            case .upToDate:
                clearAvailable()
                phase = .upToDate
            case .report(let version):
                remember(release)
                phase = .available(version)
            case .install(let version):
                remember(release)
                guard settings.updateMode != .checkOnly else {
                    phase = .available(version)
                    return
                }
                if settings.updateMode == .automatic {
                    pending = release
                    automaticCommit = true
                    gate.set(true)
                    phase = .waitingForPanel(version)
                    return
                }
                phase = .downloading
                automaticCommit = false
                gate.set(true)
                await runInstall(token: token)
            }
        } catch let failure as UpdateFailure {
            guard generation == token else { return }
            if failure == .cancelled {
                if let pending {
                    phase = .available(pending.version)
                } else {
                    phase = .idle
                }
                return
            }
            defaults.set(failure.rawValue, forKey: Record.failure)
            phase = .failed(failure)
            NSLog("Lint update: \(failure.rawValue)")
        } catch {
            guard generation == token else { return }
            defaults.set(UpdateFailure.unreachable.rawValue, forKey: Record.failure)
            phase = .failed(.unreachable)
        }
    }

    private func runInstall(token: Int) async {
        guard let release = pending ?? rememberedRelease() else {
            if generation == token { phase = .idle }
            return
        }
        guard generation == token else { return }
        phase = .downloading
        do {
            try await installer.install(
                release: release,
                runningApp: runningApp(),
                home: home,
                stagingRoot: stagingRoot,
                processID: ProcessInfo.processInfo.processIdentifier,
                shouldCommit: { [gate] in gate.isAllowed }
            )
            guard generation == token else { return }
            clearAvailable()
            NSApp.terminate(nil)
        } catch let failure as UpdateFailure {
            guard generation == token else { return }
            pending = nil
            automaticCommit = false
            if failure == .cancelled {
                phase = .available(release.version)
                return
            }
            defaults.set(failure.rawValue, forKey: Record.failure)
            phase = .failed(failure)
            NSLog("Lint update: \(failure.rawValue)")
        } catch {
            guard generation == token else { return }
            pending = nil
            phase = .failed(.unreachable)
        }
    }

    private func remember(_ release: UpdateRelease) {
        pending = release
        releasePage = release.page
        defaults.set(release.version.dotted, forKey: Record.availableVersion)
        defaults.set(release.page.absoluteString, forKey: Record.availablePage)
    }

    private func clearAvailable() {
        pending = nil
        releasePage = nil
        defaults.removeObject(forKey: Record.availableVersion)
        defaults.removeObject(forKey: Record.availablePage)
        defaults.removeObject(forKey: Record.failure)
    }

    private func rememberedRelease() -> UpdateRelease? {
        pending
    }
}

private extension UpdateFailure {
    var offersReleasePage: Bool {
        switch self {
        case .outsideInstallLocations, .notWritable, .developmentBuild, .insufficientDisk:
            true
        default:
            false
        }
    }

    var message: String {
        switch self {
        case .malformedRelease, .identityMismatch:
            String(localized: "釋出內容無法辨識")
        case .untrustedURL, .unreachable:
            String(localized: "無法檢查更新")
        case .noAssetForArchitecture:
            String(localized: "沒有適合這台 Mac 的安裝檔")
        case .noPublishedRelease:
            String(localized: "沒有可用的正式版")
        case .rateLimited:
            String(localized: "目前無法向 GitHub 查詢，稍後會再試")
        case .missingChecksum:
            String(localized: "發布沒有校驗碼")
        case .checksumConflict:
            String(localized: "發布的校驗碼不一致")
        case .hashMismatch:
            String(localized: "下載的安裝檔與發布的校驗碼不符")
        case .signatureRejected:
            String(localized: "簽章驗證沒有通過，已捨棄這個安裝檔")
        case .outsideInstallLocations:
            String(localized: "這份 Lint 不在可以替換的安裝位置")
        case .notWritable:
            String(localized: "Lint 的安裝位置無法寫入")
        case .insufficientDisk:
            String(localized: "磁碟空間不足，無法下載更新")
        case .developmentBuild:
            String(localized: "這份是開發用的 Lint，不會被換掉")
        case .versionMismatch:
            String(localized: "安裝檔裡的版本與發布不一致")
        case .mountFailed:
            String(localized: "無法掛載更新")
        case .downloadFailed:
            String(localized: "下載失敗")
        case .cancelled:
            String(localized: "尚未檢查")
        }
    }
}

private final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    func set(_ allowed: Bool) {
        lock.lock()
        self.allowed = allowed
        lock.unlock()
    }

    var isAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }
}
