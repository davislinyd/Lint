import Foundation

/// How long local AI may sit unused before llama-server releases the model's memory. The server
/// process stays up and keeps answering; the next suggestion loads the model again, which takes a
/// few seconds.
public enum IdleSleepOption: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800

    public var id: Int { rawValue }

    /// What `--sleep-idle-seconds` is given; 0 means the flag is left out entirely.
    public var seconds: Int { rawValue }

    public static let `default` = IdleSleepOption.fiveMinutes

    /// The option a stored number of seconds stands for; anything else falls back to the default,
    /// so a hand-edited value can never leave the setting showing nothing.
    public static func resolve(_ seconds: Int?) -> IdleSleepOption {
        guard let seconds else { return .default }
        return IdleSleepOption(rawValue: seconds) ?? .default
    }
}
