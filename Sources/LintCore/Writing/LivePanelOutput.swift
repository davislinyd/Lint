import Foundation

/// Live output in the ⌥⌘L panel: the answer follows the text as it is typed, once typing pauses.
public enum LivePanelOutput {
    /// How long typing has to stop before a request goes out; every key starts the wait again.
    public static let pause: Duration = .milliseconds(600)

    /// Only engines that cost nothing per request. Another one would be paid at every pause in typing,
    /// as with the gloss under a suggestion (`FloatingPanelViewModel.translateEditedResult`).
    public static func isAvailable(for provider: ProviderKind) -> Bool {
        switch provider {
        case .automatic, .appleIntelligence, .localLlama: true
        default: false
        }
    }

    public static func isOn(enabled: Bool, provider: ProviderKind) -> Bool {
        enabled && isAvailable(for: provider)
    }

    /// `requested` is what the panel last asked for, `current` what its text and settings ask for now.
    /// Only a different request is sent: text that was typed and deleted again, or whitespace at its
    /// ends (the caller trims `current.source`), asks for nothing new.
    public static func shouldGenerate(
        enabled: Bool, provider: ProviderKind, requested: WritingRequestKey?, current: WritingRequestKey
    ) -> Bool {
        isOn(enabled: enabled, provider: provider) && !current.source.isEmpty && requested != current
    }
}
