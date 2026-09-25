import Foundation

public enum UpdateMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case manual
    case checkOnly

    public var id: String { rawValue }
}

public enum UpdateCheckFrequency: String, CaseIterable, Identifiable, Sendable {
    case launch
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    /// Nil for a check that happens once each time Lint starts, not on a clock.
    public var interval: TimeInterval? {
        switch self {
        case .launch: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }
}

public enum UpdateTrigger: Equatable, Sendable {
    case scheduled
    case userCheck
    case userInstall
}

public enum UpdateAction: Equatable, Sendable {
    case upToDate
    case report(SemanticVersion)
    case install(SemanticVersion)
}

public enum UpdatePolicy {
    public static func isDue(
        frequency: UpdateCheckFrequency,
        lastCheck: Date?,
        now: Date,
        checkedThisLaunch: Bool
    ) -> Bool {
        switch frequency {
        case .launch:
            return !checkedThisLaunch
        case .daily, .weekly, .monthly:
            guard let lastCheck, let interval = frequency.interval else { return true }
            return now.timeIntervalSince(lastCheck) >= interval
        }
    }

    public static func delayUntilDue(
        frequency: UpdateCheckFrequency,
        lastCheck: Date?,
        now: Date
    ) -> TimeInterval {
        guard let lastCheck, let interval = frequency.interval else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastCheck))
    }

    /// `remote` nil means the published release is not newer than this copy.
    public static func action(
        mode: UpdateMode,
        trigger: UpdateTrigger,
        local: SemanticVersion,
        remote: SemanticVersion?
    ) -> UpdateAction {
        guard let remote, remote > local else { return .upToDate }
        switch mode {
        case .checkOnly:
            return .report(remote)
        case .manual:
            return trigger == .userInstall ? .install(remote) : .report(remote)
        case .automatic:
            return .install(remote)
        }
    }
}
