import Foundation

/// How much unified memory a managed model asks for, as the model picker describes it. It says
/// nothing about quality.
public enum ModelMemoryClass: String, Equatable, Sendable {
    /// Fits a 16 GB Mac next to ordinary work.
    case balanced
    /// Big enough that loading it can push a 16 GB Mac into heavy swapping, or make it stop
    /// responding: the picker and the download screen say so.
    case large
}

/// What one managed model needs from `llama-server`, beyond the arguments every model gets.
///
/// Lint runs one workload — short prompts, short answers, no tool calls — so the sizes here are
/// tuning, not capability: an advanced user's own arguments override them (see
/// `LlamaServerLaunchPlan`). `reasoningArguments` is not tuning; a model that thinks before it
/// answers would return its reasoning instead of the rewritten text.
public struct ModelRuntimeProfile: Equatable, Sendable {
    /// Arguments that stop the model reasoning before it answers. Empty for a model with no
    /// thinking mode of its own.
    public var reasoningArguments: [String]
    /// `-c`. Big enough for the system prompt, the personalization and a normal selection.
    public var contextTokens: Int
    /// `-ctk` / `-ctv`. `q8_0` costs about half of the `f16` default per token of context.
    public var kvCacheType: String
    /// `-b`
    public var batchTokens: Int
    /// `-ub`
    public var ubatchTokens: Int

    public init(
        reasoningArguments: [String] = [],
        contextTokens: Int = 3072,
        kvCacheType: String = "q8_0",
        batchTokens: Int = 512,
        ubatchTokens: Int = 256
    ) {
        self.reasoningArguments = reasoningArguments
        self.contextTokens = contextTokens
        self.kvCacheType = kvCacheType
        self.batchTokens = batchTokens
        self.ubatchTokens = ubatchTokens
    }

    /// For a model Lint knows nothing about (the advanced `-hf` setting): Lint's own sizes, and
    /// thinking off — Lint always wants the rewritten text and nothing else, and for a model with no
    /// thinking mode the switch does nothing.
    public static let unknownModel = ModelRuntimeProfile(reasoningArguments: ["--reasoning", "off"])
}
