import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Full panel / improve current selection (existing).
    static let improveText = Self("improveText", default: .init(.l, modifiers: [.command, .option]))
    /// Accept the ready chip / run check without clicking (works for any language).
    static let checkSuggestion = Self("checkSuggestion", default: .init(.k, modifiers: [.command, .option]))
}

enum HotkeyCenter {
    static func register(
        improve: @escaping @MainActor () -> Void,
        check: @escaping @MainActor () -> Void
    ) {
        KeyboardShortcuts.onKeyUp(for: .improveText) {
            Task { @MainActor in improve() }
        }
        KeyboardShortcuts.onKeyUp(for: .checkSuggestion) {
            Task { @MainActor in check() }
        }
    }
}
