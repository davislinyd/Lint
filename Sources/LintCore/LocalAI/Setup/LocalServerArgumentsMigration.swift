import Foundation

/// The advanced "extra arguments" setting, across Lint versions.
///
/// Lint used to put its whole tuning into this one field, so every install has a copy of whatever
/// the built-in default was at the time. Tuning now comes from `ModelRuntimeProfile` — it has to,
/// because it differs per model — and the field went back to being only what the user typed. A
/// stored string that is exactly one of the old built-in defaults was never a choice, so it is
/// cleared; anything else was typed by the user and is kept untouched.
public enum LocalServerArgumentsMigration {
    /// Every exact string Lint has shipped as the built-in default, newest first. Nothing may ever
    /// be removed from this list: an install that skipped versions still holds an older one.
    public static let builtInDefaults = [
        "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6 --reasoning off",
        "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6",
        "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 8192 -np 1 -t 4",
    ]

    /// Running this twice gives the same answer as running it once: the result is either "" or a
    /// string that is not a built-in default, and neither changes on a second pass.
    public static func migrate(stored: String?) -> String {
        let value = stored ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return builtInDefaults.contains(trimmed) ? "" : value
    }
}
