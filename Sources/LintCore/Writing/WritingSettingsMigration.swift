import Foundation

/// What a writing mode saved by an earlier version means now. Before tone was a setting of its own,
/// "formal", "concise" and "professional" were modes, and were all proofreading in a tone.
///
/// Keyed by the old raw value rather than by enum case, so that it keeps working once those cases
/// are gone: values written by an older build can turn up in settings and in the learning database.
public enum LegacyWritingMode {
    public static func resolve(_ rawValue: String) -> (mode: WritingMode, tone: WritingTone)? {
        switch rawValue {
        case "proofread": (.proofread, .preserve)
        case "toneFormal": (.proofread, .formal)
        case "toneConcise": (.proofread, .concise)
        case "toneProfessional": (.proofread, .professional)
        case "translate": (.translate, .preserve)
        case "custom": (.custom, .preserve)
        default: nil
        }
    }
}

/// Moving stored settings to tone as a setting of its own. Both functions only read what they are
/// given, so that running the migration again cannot change its result.
public enum WritingSettingsMigration {
    /// The mode names that earlier versions stored under `lastMode` and as prompt override keys.
    private static let legacyNames = ["proofread", "toneFormal", "toneConcise", "toneProfessional", "translate"]

    /// The mode to start in, and the tone to give proofreading if the stored mode was one of the old
    /// tone modes (nil when it was not, and the tone stays as it is). An unknown value is proofreading.
    public static func migrateLastMode(_ stored: String?) -> (mode: WritingMode, proofreadTone: WritingTone?) {
        guard let stored, let resolved = LegacyWritingMode.resolve(stored) else { return (.proofread, nil) }
        return (resolved.mode, resolved.tone == .preserve ? nil : resolved.tone)
    }

    /// Prompt overrides are full system prompts, and stay that: an old tone prompt becomes the override
    /// of proofreading in that tone, not a tone modifier. The old keys are left in place, and a
    /// key that already exists in its new form is never overwritten.
    public static func migrateOverrides(_ overrides: [String: String]) -> [String: String] {
        var migrated = overrides
        for name in legacyNames {
            guard let text = overrides[name], let resolved = LegacyWritingMode.resolve(name) else { continue }
            let key = WritingPromptComposer.overrideKey(mode: resolved.mode, tone: resolved.tone)
            if migrated[key] == nil { migrated[key] = text }
        }
        return migrated
    }
}
