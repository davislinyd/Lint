import Foundation

/// Where one writing request goes. Decided per request from the user's choice and what is ready on
/// this Mac; the writing workflow only sees the result.
public enum WritingEngineRoute: Equatable, Sendable {
    /// Apple's on-device model. llama-server is not needed and not started.
    case appleIntelligence
    /// Any other provider, exactly as before (for `.localLlama`, Lint's managed llama-server).
    case provider(ProviderKind)
    /// Nothing can take the request; the reason is Apple Intelligence's.
    case unavailable(AppleIntelligenceStatus)

    public var providerKind: ProviderKind? {
        switch self {
        case .appleIntelligence: .appleIntelligence
        case .provider(let kind): kind
        case .unavailable: nil
        }
    }
}

public enum WritingEngineRouter {
    /// - `.automatic`: Apple Intelligence when it is available; otherwise Lint's local AI, but only
    ///   if it is already set up. Nothing is ever downloaded because Apple Intelligence is missing.
    /// - `.appleIntelligence`: only Apple Intelligence; when it is unavailable, say why.
    /// - anything else: that provider, as before.
    ///
    /// Under Automatic, a native-speaker rewrite (`WritingTone.isNative`) goes to Lint's local AI when
    /// it is set up, even if Apple Intelligence is available: measured, Apple's model replies to the
    /// text instead of rewriting it in about 3 of 29 English texts even with its own prompt and the
    /// guard. A user who chose Apple Intelligence keeps it.
    public static func route(
        selected: ProviderKind, apple: AppleIntelligenceStatus, localAIReady: Bool,
        mode: WritingMode? = nil, tone: WritingTone? = nil
    ) -> WritingEngineRoute {
        let route = baseRoute(selected: selected, apple: apple, localAIReady: localAIReady)
        if selected == .automatic, route == .appleIntelligence, localAIReady, prefersLocalModel(mode: mode, tone: tone) {
            return .provider(.localLlama)
        }
        return route
    }

    /// The tasks that go to Lint's local AI rather than Apple Intelligence when both are ready.
    public static func prefersLocalModel(mode: WritingMode?, tone: WritingTone?) -> Bool {
        mode == .proofread && tone?.isNative == true
    }

    private static func baseRoute(
        selected: ProviderKind, apple: AppleIntelligenceStatus, localAIReady: Bool
    ) -> WritingEngineRoute {
        switch selected {
        case .automatic:
            if apple.isAvailable { return .appleIntelligence }
            return localAIReady ? .provider(.localLlama) : .unavailable(apple)
        case .appleIntelligence:
            return apple.isAvailable ? .appleIntelligence : .unavailable(apple)
        default:
            return .provider(selected)
        }
    }

    /// Whether Lint should offer its own local AI setup (it never starts a download by itself):
    /// when the user chose local AI and it is not ready, or chose Automatic on a Mac that can never
    /// run Apple Intelligence. Not while Apple Intelligence is merely off or still downloading, and
    /// never for a user who chose Apple Intelligence.
    public static func offersLocalAISetup(
        selected: ProviderKind, apple: AppleIntelligenceStatus, localAIReady: Bool
    ) -> Bool {
        guard !localAIReady else { return false }
        switch selected {
        case .localLlama: return true
        case .automatic: return apple.isPermanent
        default: return false
        }
    }
}

/// The one-time choice of engine for this version. Deterministic: it reads only stored settings,
/// never whether Apple Intelligence happens to be available at the moment it runs.
public enum WritingEngineMigration {
    /// What a genuinely new install starts with. Still Lint's local AI: Apple Intelligence becomes
    /// the default only after the Apple vs Gemma evaluation has been reviewed (`docs/APPLE-INTELLIGENCE.md`).
    /// Changing it affects new installs only.
    public static let newInstallDefault: ProviderKind = .localLlama

    /// - Parameters:
    ///   - storedProvider: the provider saved before this version, if any.
    ///   - isNewInstall: nothing of Lint's was stored before this launch.
    /// - Returns: the provider to store, or nil to leave the stored setting exactly as it is. An
    ///   existing user is never switched, whatever they use.
    public static func migrate(storedProvider: String?, isNewInstall: Bool) -> ProviderKind? {
        guard isNewInstall, storedProvider == nil else { return nil }
        return newInstallDefault
    }
}
