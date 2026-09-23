import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can take a request right now, in Lint's own terms so that the
/// rest of Lint (and its tests) never touch `FoundationModels`.
public enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// This Mac cannot run Apple Intelligence (e.g. an Intel Mac).
    case deviceNotEligible
    /// The Mac could, but Apple Intelligence is turned off in System Settings.
    case appleIntelligenceNotEnabled
    /// Turned on, but the model is still downloading or being prepared. Temporary.
    case modelNotReady
    /// This macOS has no Foundation Models (before macOS 26), or Lint was built without it.
    case unsupportedOS
    /// A reason this version of Lint does not know about.
    case unavailable

    public var isAvailable: Bool { self == .available }

    /// Nothing the user can switch on makes Apple Intelligence work on this Mac. Only then does
    /// Lint point at its own local AI: for the other reasons the fix is on Apple's side.
    public var isPermanent: Bool {
        self == .deviceNotEligible || self == .unsupportedOS
    }

    /// One line for Settings and for a failed request.
    public var userMessage: String {
        switch self {
        case .available:
            String(localized: "Apple Intelligence 可以使用。")
        case .deviceNotEligible:
            String(localized: "這台 Mac 不支援 Apple Intelligence。")
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence 尚未開啟。可以在「系統設定 › Apple Intelligence 與 Siri」開啟。")
        case .modelNotReady:
            String(localized: "Apple Intelligence 的模型還在下載或準備中，完成後就能使用，請稍後再試。")
        case .unsupportedOS:
            String(localized: "Apple Intelligence 需要 macOS 26 或更新版本。")
        case .unavailable:
            String(localized: "Apple Intelligence 目前無法使用。")
        }
    }
}

/// Reads the system model's availability. A protocol so that routing can be tested without Apple
/// Intelligence, a particular Mac, or a particular macOS.
public protocol AppleIntelligenceAvailabilityChecking: Sendable {
    func currentStatus() -> AppleIntelligenceStatus
}

/// The real check. Cheap: it reads a property, and never loads the model or makes a request.
public struct SystemAppleIntelligence: AppleIntelligenceAvailabilityChecking {
    public init() {}

    public func currentStatus() -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleIntelligenceStatus(SystemLanguageModel.default.availability)
        }
        #endif
        return .unsupportedOS
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
extension AppleIntelligenceStatus {
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: self = .deviceNotEligible
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
            case .modelNotReady: self = .modelNotReady
            @unknown default: self = .unavailable
            }
        }
    }
}
#endif

/// What identifies the model a result came from, using public API only. Apple can change the
/// system model with an OS update, so an evaluation is only comparable with the same metadata.
public struct AppleModelMetadata: Codable, Equatable, Sendable {
    public var osVersion: String
    /// e.g. "AFM 3 Core"; nil where macOS does not expose it (before macOS 27).
    public var variant: String?
    /// Tokens the model takes in and gives out together; nil without Foundation Models.
    public var contextSize: Int?
    public var promptVersion: String

    public static func current() -> AppleModelMetadata {
        AppleModelMetadata(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            variant: AppleOnDeviceModel.variantName(),
            contextSize: AppleOnDeviceModel.contextSize(),
            promptVersion: WritingPromptComposer.onDevicePromptVersion
        )
    }
}
