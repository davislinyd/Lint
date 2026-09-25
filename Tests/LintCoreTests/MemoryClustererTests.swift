import XCTest
@testable import LintCore

/// Answers from a table of pairs (by `dedupKey`), and a fixed value for every other pair.
private struct TableSimilarity: MemorySimilarityService {
    var table: [Set<String>: Double] = [:]
    var fallback = 0.0

    func similarity(_ lhs: WritingMemory, _ rhs: WritingMemory) async -> Double {
        table[[lhs.dedupKey, rhs.dedupKey]] ?? fallback
    }
}

/// Remembers which pairs were compared.
private final class Comparisons: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [(WritingMemory, WritingMemory)] = []

    func record(_ lhs: WritingMemory, _ rhs: WritingMemory) {
        lock.lock()
        pairs.append((lhs, rhs))
        lock.unlock()
    }

    var all: [(WritingMemory, WritingMemory)] {
        lock.lock()
        defer { lock.unlock() }
        return pairs
    }
}

private struct RecordingSimilarity: MemorySimilarityService {
    let comparisons: Comparisons

    func similarity(_ lhs: WritingMemory, _ rhs: WritingMemory) async -> Double {
        comparisons.record(lhs, rhs)
        return 1
    }
}

final class MemoryClustererTests: XCTestCase {
    private let now = DreamFixtures.now

    private func memory(
        _ key: String, kind: MemoryKind = .style, language: String = "en", scope: WritingMode? = nil,
        tone: WritingTone? = nil, evidence: Double = 1.2
    ) -> WritingMemory {
        DreamFixtures.plain(key, kind: kind, language: language, scope: scope, tone: tone, evidence: evidence)
    }

    private func clusterer(
        _ similarity: any MemorySimilarityService, threshold: Double = 0.85, minimum: Int = 3
    ) -> MemoryClusterer {
        MemoryClusterer(similarity: similarity, threshold: threshold, minClusterSize: minimum)
    }

    private func keys(_ clusters: [MemoryCluster]) -> [[String]] {
        clusters.map { $0.members.map(\.dedupKey) }
    }

    func testAlikeMemoriesOfOneKindFormOneCluster() async throws {
        let memories = (0..<4).map { memory("k\($0)", evidence: 4 - Double($0) * 0.1) }
        let result = await clusterer(TableSimilarity(fallback: 1)).clusters(from: memories, at: now)
        XCTAssertEqual(keys(result), [["k0", "k1", "k2", "k3"]])
        let cluster = try XCTUnwrap(result.first)
        XCTAssertEqual(cluster.kind, .style)
        XCTAssertEqual(cluster.language, "en")
        XCTAssertNil(cluster.modeScope)
        XCTAssertNil(cluster.toneScope)
    }

    func testMemoriesOfDifferentLanguagesNeverCluster() async {
        let mixed = [memory("a"), memory("b"), memory("c", language: "zh-Hant")]
        let none = await clusterer(TableSimilarity(fallback: 1)).clusters(from: mixed, at: now)
        XCTAssertTrue(none.isEmpty, "two English and one Chinese memory are not three of anything")

        let both = (0..<3).map { memory("en\($0)") } + (0..<3).map { memory("zh\($0)", language: "zh-Hant") }
        let result = await clusterer(TableSimilarity(fallback: 1)).clusters(from: both, at: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { cluster in cluster.members.allSatisfy { $0.language == cluster.language } })
    }

    func testMemoriesOfDifferentKindsNeverCluster() async {
        let mixed = [memory("a"), memory("b"), memory("c", kind: .grammar)]
        let result = await clusterer(TableSimilarity(fallback: 1)).clusters(from: mixed, at: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testMemoriesOfDifferentModeScopesNeverCluster() async throws {
        // Translation terminology is not general proofreading style, and one tone is not another.
        let mixed = [memory("a"), memory("b", scope: .translate), memory("c", scope: .proofread, tone: .formal)]
        let result = await clusterer(TableSimilarity(fallback: 1)).clusters(from: mixed, at: now)
        XCTAssertTrue(result.isEmpty)

        let translations = (0..<3).map { memory("t\($0)", scope: .translate) } + [memory("p")]
        let grouped = await clusterer(TableSimilarity(fallback: 1)).clusters(from: translations, at: now)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.modeScope, .translate)
        XCTAssertEqual(grouped.first?.members.count, 3)
    }

    func testMemoriesOfDifferentTonesNeverCluster() async throws {
        // Professional and concise style memories are both proofreading now; that is no reason to
        // put them behind one rule.
        let professional = (0..<3).map { memory("p\($0)", scope: .proofread, tone: .professional) }
        let concise = (0..<3).map { memory("c\($0)", scope: .proofread, tone: .concise) }
        let global = (0..<3).map { memory("g\($0)") }
        let result = await clusterer(TableSimilarity(fallback: 1))
            .clusters(from: professional + concise + global, at: now)

        XCTAssertEqual(result.count, 3)
        for cluster in result {
            XCTAssertEqual(cluster.members.count, 3)
            XCTAssertEqual(Set(cluster.members.map(\.toneScope)).count, 1, "one tone to a cluster")
            XCTAssertEqual(Set(cluster.members.map(\.toneScope)), [cluster.toneScope])
        }
        XCTAssertEqual(Set(result.map(\.toneScope)), [.professional, .concise, nil])

        let mixed = [
            memory("a", scope: .proofread, tone: .professional), memory("b", scope: .proofread, tone: .concise),
            memory("c", scope: .proofread, tone: .formal),
        ]
        let none = await clusterer(TableSimilarity(fallback: 1)).clusters(from: mixed, at: now)
        XCTAssertTrue(none.isEmpty)
    }

    func testAClusterBelowTheMinimumSizeIsDropped() async {
        let two = [memory("a"), memory("b")]
        let dropped = await clusterer(TableSimilarity(fallback: 1)).clusters(from: two, at: now)
        XCTAssertTrue(dropped.isEmpty)
        let kept = await clusterer(TableSimilarity(fallback: 1), minimum: 2).clusters(from: two, at: now)
        XCTAssertEqual(kept.count, 1)
        let alone = await clusterer(TableSimilarity(fallback: 1), minimum: 1).clusters(from: [memory("a")], at: now)
        XCTAssertEqual(alone.count, 1)
    }

    func testWeakSimilarityDoesNothing() async {
        let memories = (0..<5).map { memory("k\($0)") }
        let result = await clusterer(TableSimilarity(fallback: 0.5)).clusters(from: memories, at: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testTheThresholdIsInclusive() async {
        let memories = (0..<3).map { memory("k\($0)") }
        let at = await clusterer(TableSimilarity(fallback: 0.85)).clusters(from: memories, at: now)
        XCTAssertEqual(at.count, 1)
        let below = await clusterer(TableSimilarity(fallback: 0.8499)).clusters(from: memories, at: now)
        XCTAssertTrue(below.isEmpty)
    }

    func testAChainOfSimilarMemoriesDoesNotJoinTheOnesAtItsEnds() async {
        // A is like B and B is like C, but A is not like C.
        let table: [Set<String>: Double] = [["A", "B"]: 0.9, ["B", "C"]: 0.9, ["A", "C"]: 0.2]
        for evidence in [(3.0, 2.0, 1.0), (1.0, 2.0, 3.0), (2.0, 3.0, 1.0)] {
            let memories = [
                memory("A", evidence: evidence.0), memory("B", evidence: evidence.1), memory("C", evidence: evidence.2),
            ]
            let result = await clusterer(TableSimilarity(table: table), minimum: 2).clusters(from: memories, at: now)
            XCTAssertFalse(
                keys(result).contains { $0.contains("A") && $0.contains("C") },
                "A and C must not share a cluster (importance order \(evidence))"
            )
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.members.count, 2)
        }
    }

    func testEveryPairInAClusterMustBeAlike() async {
        let table: [Set<String>: Double] = [["a", "d"]: 0.5]
        let memories = [
            memory("a", evidence: 4), memory("b", evidence: 3), memory("c", evidence: 2), memory("d", evidence: 1),
        ]
        let result = await clusterer(TableSimilarity(table: table, fallback: 0.9)).clusters(from: memories, at: now)
        XCTAssertEqual(keys(result), [["a", "b", "c"]], "d is not like a, so it stays out")
    }

    func testTheResultDoesNotDependOnTheInputOrder() async {
        let memories = (0..<6).map { memory("k\($0)", evidence: 1.2 + Double($0 % 3)) }
        let table: [Set<String>: Double] = [["k0", "k5"]: 0.1, ["k1", "k4"]: 0.3]
        let expected = keys(await clusterer(TableSimilarity(table: table, fallback: 0.95)).clusters(from: memories, at: now))
        XCTAssertFalse(expected.isEmpty)
        for seed in 0..<8 {
            var shuffled = memories
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            shuffled.shuffle(using: &generator)
            let result = await clusterer(TableSimilarity(table: table, fallback: 0.95)).clusters(from: shuffled, at: now)
            XCTAssertEqual(keys(result), expected, "seed \(seed)")
        }
    }

    func testMembersComeMostImportantFirstAndTiesGoToTheKey() async {
        let memories = [
            memory("b", evidence: 2), memory("c", evidence: 5), memory("a", evidence: 2), memory("d", evidence: 3),
        ]
        let result = await clusterer(TableSimilarity(fallback: 1)).clusters(from: memories, at: now)
        XCTAssertEqual(keys(result), [["c", "d", "a", "b"]])
    }

    func testOnlyMemoriesOfTheSamePartitionAreCompared() async {
        let comparisons = Comparisons()
        var memories: [WritingMemory] = []
        for language in ["en", "zh-Hant"] {
            for kind in [MemoryKind.grammar, .style] {
                for (scope, tone) in [(nil, nil), (WritingMode.proofread, WritingTone.formal)] as [(WritingMode?, WritingTone?)] {
                    for index in 0..<8 {
                        let name = "\(language)-\(kind)-\(scope?.rawValue ?? "all")-\(index)"
                        memories.append(memory(name, kind: kind, language: language, scope: scope, tone: tone))
                    }
                }
            }
        }
        let result = await clusterer(RecordingSimilarity(comparisons: comparisons)).clusters(from: memories, at: now)

        XCTAssertEqual(result.count, 8)
        let pairs = comparisons.all
        XCTAssertTrue(pairs.allSatisfy { lhs, rhs in
            lhs.language == rhs.language && lhs.kind == rhs.kind && lhs.modeScope == rhs.modeScope
                && lhs.toneScope == rhs.toneScope
        })
        // 8 partitions of 8: at most 28 pairs each, against 2,016 for all 64 compared with each other.
        XCTAssertLessThanOrEqual(pairs.count, 8 * 28)
    }

    func testMemoriesOfOneFamilyAreAlikeWhateverTheirWords() async {
        let similarity = StructuralMemorySimilarity()
        let (discuss, mention) = (DreamFixtures.preposition("discuss"), DreamFixtures.preposition("mention"))
        let same = await similarity.similarity(discuss, mention)
        XCTAssertEqual(same, 1)

        let articles = DreamFixtures.plain(
            "grammar:en:articles", kind: .grammar,
            instruction: "英文常漏用或誤用冠詞（a／an／the）：請特別檢查單數可數名詞前的冠詞。"
        )
        let other = await similarity.similarity(discuss, articles)
        XCTAssertLessThan(other, MemoryPolicy.dreamSimilarityThreshold)

        let real = DreamFixtures.prepositions(4) + [articles]
        let result = await clusterer(similarity).clusters(from: real, at: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Set(result.first?.members.map(\.dedupKey) ?? []), Set(real.dropLast().map(\.dedupKey)))
    }

    func testUnrelatedMemoriesOfOneKindStaySeparate() async {
        func spelling(_ wrong: String, _ right: String) -> WritingMemory {
            DreamFixtures.plain(
                "spelling:en:\(wrong)>\(right)", kind: .spelling, triggers: [wrong],
                instruction: "使用者偏好「\(right)」而非「\(wrong)」。"
            )
        }
        let memories = [spelling("teh", "the"), spelling("recieve", "receive"), spelling("seperate", "separate")]
        let result = await clusterer(StructuralMemorySimilarity()).clusters(from: memories, at: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testLexicalSimilarityFollowsWordingAndTriggers() {
        func memory(_ instruction: String, _ triggers: [String]) -> WritingMemory {
            DreamFixtures.plain("k\(instruction.hashValue)", triggers: triggers, instruction: instruction)
        }
        let a = memory("請使用簡短的句子。", ["short"])
        XCTAssertEqual(LexicalMemorySimilarity.score(a, a), 1, accuracy: 1e-12)
        XCTAssertEqual(
            LexicalMemorySimilarity.score(memory("請使用簡短的句子。", []), memory("請使用簡短的句子。", [])), 1,
            accuracy: 1e-12, "two habits are compared by their wording alone"
        )
        XCTAssertLessThan(LexicalMemorySimilarity.score(a, memory("請使用簡短的句子。", ["long"])), 0.7)
        XCTAssertLessThan(LexicalMemorySimilarity.score(a, memory("完全不同的規則", ["short"])), 0.5)
        XCTAssertEqual(LexicalMemorySimilarity.shingles(of: "Use 'the' word"), ["use", "'the'", "word"])
        XCTAssertEqual(LexicalMemorySimilarity.shingles(of: "簡短的句"), ["簡短", "短的", "的句"])
    }
}

/// The same shuffle for the same seed, so a failing order can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
