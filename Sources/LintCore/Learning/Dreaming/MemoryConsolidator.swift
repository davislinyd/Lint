import CryptoKit
import Foundation

/// Turns a cluster of compatible memories into a proposal for one higher-level memory, or into
/// nothing when there is no safe wording for it. It never touches the database: what to store is
/// decided here, whether it is stored is decided after `MemoryConsolidationValidator` has looked at it.
///
/// A family (`MemoryFamily`) is worded from a fixed template that holds nothing of the sources. Any
/// other cluster is left alone, unless a synthesis provider is present to word it.
struct MemoryConsolidator: Sendable {
    var synthesis: (any MemorySynthesisProvider)?

    static let redundantPrepositionInstruction = MemoryWording.redundantPrepositions.chinese

    /// The identity a rule-worded memory for this cluster is kept under, nil if no rule covers the
    /// cluster. One per family, whatever the sources: sources that turn up later join the same
    /// memory instead of making another.
    func ruleParentKey(for cluster: MemoryCluster) -> String? {
        commonFamily(of: cluster).map { Self.parentKey(family: $0, cluster: cluster) }
    }

    func proposal(for cluster: MemoryCluster, at now: Date) async -> ConsolidationProposal? {
        if let family = commonFamily(of: cluster) {
            return ruleProposal(family: family, cluster: cluster)
        }
        guard let synthesis else { return nil }
        let sources = cluster.members.map { memory in
            SynthesisSource(
                id: memory.id, kind: memory.kind, language: memory.language,
                mode: memory.modeScope, tone: memory.toneScope,
                instruction: memory.instruction, triggers: memory.triggers,
                confidence: memory.confidence(at: now), occurrenceCount: memory.occurrenceCount
            )
        }
        do {
            switch try await synthesis.synthesize(sources) {
            case .noConsolidation:
                return nil
            case .rule(let instruction, let triggers):
                return ConsolidationProposal(
                    parentDedupKey: Self.synthesizedKey(cluster: cluster),
                    sourceIDs: cluster.members.map(\.id),
                    kind: cluster.kind, language: cluster.language,
                    modeScope: cluster.modeScope, toneScope: cluster.toneScope,
                    targetLevel: .generalized, instruction: instruction, triggers: triggers,
                    origin: .synthesized
                )
            }
        } catch {
            // A provider that fails only means there is nothing to combine this time.
            NSLog("Lint learning: memory synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func ruleProposal(family: MemoryFamily, cluster: MemoryCluster) -> ConsolidationProposal {
        switch family {
        case .redundantPreposition:
            // A habit (no triggers): it is meant to cover verbs that have not been seen yet.
            return ConsolidationProposal(
                parentDedupKey: Self.parentKey(family: family, cluster: cluster),
                sourceIDs: cluster.members.map(\.id),
                kind: cluster.kind, language: cluster.language,
                modeScope: cluster.modeScope, toneScope: cluster.toneScope,
                targetLevel: .generalized,
                instruction: Self.redundantPrepositionInstruction,
                triggers: [],
                origin: .rule(family),
                allowedExtraWords: ["discuss", "about"]
            )
        }
    }

    private func commonFamily(of cluster: MemoryCluster) -> MemoryFamily? {
        guard let first = cluster.members.first.flatMap(MemoryFamily.of),
              cluster.members.allSatisfy({ MemoryFamily.of($0) == first })
        else { return nil }
        return first
    }

    private static func parentKey(family: MemoryFamily, cluster: MemoryCluster) -> String {
        scopedKey("dream:\(family.rawValue)", cluster: cluster)
    }

    /// Stable for the same sources. Once they are covered they are no longer clustered, so the same
    /// rule is not derived again.
    private static func synthesizedKey(cluster: MemoryCluster) -> String {
        let digest = SHA256.hash(data: Data(cluster.members.map(\.dedupKey).sorted().joined(separator: "\n").utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return scopedKey("dream:synthesized", cluster: cluster) + ":" + hash
    }

    private static func scopedKey(_ prefix: String, cluster: MemoryCluster) -> String {
        [
            prefix, cluster.kind.rawValue, cluster.language,
            MemoryScope.keySegment(mode: cluster.modeScope, tone: cluster.toneScope),
        ].compactMap { $0 }.joined(separator: ":")
    }
}
