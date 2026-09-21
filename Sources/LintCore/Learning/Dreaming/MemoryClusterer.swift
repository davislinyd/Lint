import Foundation

/// Groups memories that say much the same thing. Only memories of one language, kind and mode scope
/// are ever compared, which also keeps the comparisons few. Deterministic for the same memories and
/// the same similarity.
///
/// A memory joins a cluster only if it is alike enough to *every* member already in it. Chaining
/// (A is like B, B is like C, so all three) would let A and C, which have nothing in common, end up
/// behind one rule.
struct MemoryClusterer: Sendable {
    var similarity: any MemorySimilarityService
    var threshold = LearningPolicy.dreamSimilarityThreshold
    var minClusterSize = LearningPolicy.dreamMinClusterSize

    private struct Partition: Hashable {
        let language: String
        let kind: MemoryKind
        let modeScope: WritingMode?

        var sortKey: String { "\(language)|\(kind.rawValue)|\(modeScope?.rawValue ?? "")" }
    }

    func clusters(from memories: [WritingMemory], at now: Date) async -> [MemoryCluster] {
        var partitions: [Partition: [WritingMemory]] = [:]
        for memory in memories {
            let key = Partition(language: memory.language, kind: memory.kind, modeScope: memory.modeScope)
            partitions[key, default: []].append(memory)
        }

        var result: [MemoryCluster] = []
        for partition in partitions.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            let ranked = (partitions[partition] ?? [])
                .map { (memory: $0, importance: MemoryImportanceScorer.score($0, at: now)) }
                .sorted { lhs, rhs in
                    if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
                    return lhs.memory.dedupKey < rhs.memory.dedupKey
                }
                .map(\.memory)

            var groups: [[WritingMemory]] = []
            for memory in ranked {
                var placed = false
                for index in groups.indices where await fits(memory, in: groups[index]) {
                    groups[index].append(memory)
                    placed = true
                    break
                }
                if !placed { groups.append([memory]) }
            }
            for group in groups where group.count >= minClusterSize {
                result.append(MemoryCluster(
                    language: partition.language, kind: partition.kind,
                    modeScope: partition.modeScope, members: group
                ))
            }
        }
        return result
    }

    private func fits(_ memory: WritingMemory, in group: [WritingMemory]) async -> Bool {
        for member in group where await similarity.similarity(memory, member) < threshold {
            return false
        }
        return true
    }
}
