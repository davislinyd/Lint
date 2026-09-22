import XCTest
@testable import LintCore

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[SynthesisSource]] = []

    func record(_ sources: [SynthesisSource]) {
        lock.lock()
        received.append(sources)
        lock.unlock()
    }

    var all: [[SynthesisSource]] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private struct ScriptedSynthesis: MemorySynthesisProvider {
    var result: Result<SynthesisResult, any Error>
    var requests = Requests()

    func synthesize(_ sources: [SynthesisSource]) async throws -> SynthesisResult {
        requests.record(sources)
        return try result.get()
    }
}

private struct BrokenSynthesis: Error {}

final class MemoryConsolidatorTests: XCTestCase {
    private let now = DreamFixtures.now

    private func styleCluster() -> MemoryCluster {
        DreamFixtures.cluster((0..<3).map { DreamFixtures.plain("style:en:k\($0)", triggers: ["t\($0)"]) })
    }

    /// What the extractor and the lifecycle make of one piece of accepted feedback.
    private func learned(_ original: String, _ suggestion: String, at date: Date? = nil) -> [WritingMemory] {
        let feedback = LearningFeedback(
            gesture: .replaced, mode: .proofread, originalText: original, generatedText: suggestion,
            finalText: suggestion, provider: "p", model: "m"
        )
        return MemoryExtractor().candidates(from: feedback, action: .accepted).map {
            MemoryLifecycle.merging($0, weight: 0.35, at: date ?? now, into: nil)
        }
    }

    func testTheFamilyIsWhatTheExtractorReallyWrites() throws {
        let discuss = try XCTUnwrap(learned("We will discuss about the plan tomorrow morning.", "We will discuss the plan tomorrow morning.").first)
        XCTAssertEqual(discuss.dedupKey, "grammar:en:discuss about")
        XCTAssertEqual(MemoryFamily.of(discuss), .redundantPreposition)
        let fixture = DreamFixtures.preposition("discuss")
        XCTAssertEqual(discuss.instruction, fixture.instruction, "the fixtures are what the extractor writes")
        XCTAssertEqual(discuss.triggers, fixture.triggers)

        // Articles are one memory already, so there is nothing to combine, and it is no family.
        let articles = try XCTUnwrap(learned("I have meeting tomorrow morning.", "I have a meeting tomorrow morning.").first)
        XCTAssertEqual(articles.dedupKey, "grammar:en:articles")
        XCTAssertNil(MemoryFamily.of(articles))
        let spelling = try XCTUnwrap(learned("I think teh plan works fine today.", "I think the plan works fine today.").first)
        XCTAssertEqual(spelling.kind, .spelling)
        XCTAssertNil(MemoryFamily.of(spelling))
    }

    func testOnlyAPlainVerbAndPrepositionMakeAMemberOfTheFamily() {
        func member(
            _ key: String, kind: MemoryKind = .grammar, language: String = "en",
            scope: WritingMode? = nil, tone: WritingTone? = nil
        ) -> WritingMemory {
            DreamFixtures.plain(key, kind: kind, language: language, scope: scope, tone: tone)
        }
        XCTAssertEqual(MemoryFamily.of(member("grammar:en:emphasize on")), .redundantPreposition)
        XCTAssertEqual(MemoryFamily.of(member("grammar:en:can't-stop about")), .redundantPreposition)
        for (name, memory) in [
            ("not a preposition", member("grammar:en:discuss banana")),
            ("no verb", member("grammar:en: about")),
            ("three words", member("grammar:en:discuss the about")),
            ("one word", member("grammar:en:discuss")),
            ("digits", member("grammar:en:disc4ss about")),
            ("another kind", member("grammar:en:discuss about", kind: .style)),
            ("another language", member("grammar:en:discuss about", language: "zh-Hant")),
            ("a mode scope", member("grammar:en:discuss about", scope: .translate)),
            ("a tone scope", member("grammar:en:discuss about", tone: .formal)),
            ("a spelling pair", member("grammar:en:a>b about")),
        ] {
            XCTAssertNil(MemoryFamily.of(memory), name)
        }
        var generalized = member("grammar:en:discuss about")
        generalized.level = .generalized
        XCTAssertNil(MemoryFamily.of(generalized), "a derived memory is no source")
    }

    func testAFamilyIsWordedByItsTemplate() async throws {
        let cluster = DreamFixtures.cluster(DreamFixtures.prepositions(3))
        let proposal = try unwrapped(await MemoryConsolidator().proposal(for: cluster, at: now))

        XCTAssertEqual(proposal.parentDedupKey, "dream:redundant-preposition:grammar:en")
        XCTAssertEqual(proposal.sourceIDs, cluster.members.map(\.id))
        XCTAssertEqual(proposal.kind, .grammar)
        XCTAssertEqual(proposal.language, "en")
        XCTAssertNil(proposal.modeScope)
        XCTAssertEqual(proposal.targetLevel, .generalized)
        XCTAssertEqual(proposal.instruction, MemoryConsolidator.redundantPrepositionInstruction)
        XCTAssertEqual(proposal.triggers, [], "a habit, so that it also covers verbs not seen yet")
        XCTAssertEqual(proposal.origin, .rule(.redundantPreposition))
    }

    func testTheTemplateHoldsNothingOfTheSources() async throws {
        let cluster = DreamFixtures.cluster(DreamFixtures.prepositions(3))
        let proposal = try unwrapped(await MemoryConsolidator().proposal(for: cluster, at: now))
        for source in cluster.members {
            let verb = source.dedupKey.dropFirst("grammar:en:".count).split(separator: " ")[0]
            XCTAssertFalse(proposal.instruction.contains(verb), "\(verb) must not leak into the derived memory")
        }
    }

    func testTheIdentityDoesNotDependOnWhichSourcesThereAre() async throws {
        let consolidator = MemoryConsolidator()
        let small = try unwrapped(await consolidator.proposal(for: DreamFixtures.cluster(DreamFixtures.prepositions(3)), at: now))
        let large = try unwrapped(await consolidator.proposal(for: DreamFixtures.cluster(DreamFixtures.prepositions(6)), at: now))
        XCTAssertEqual(small.parentDedupKey, large.parentDedupKey)
        XCTAssertEqual(consolidator.ruleParentKey(for: DreamFixtures.cluster(DreamFixtures.prepositions(2))), small.parentDedupKey)
    }

    func testTheSameClusterAlwaysGivesTheSameProposal() async {
        let cluster = DreamFixtures.cluster(DreamFixtures.prepositions(4))
        let first = await MemoryConsolidator().proposal(for: cluster, at: now)
        let second = await MemoryConsolidator().proposal(for: cluster, at: now)
        XCTAssertEqual(first, second)
    }

    func testAClusterWithNoSafeWordingIsLeftAlone() async {
        let consolidator = MemoryConsolidator()
        let noRule = await consolidator.proposal(for: styleCluster(), at: now)
        XCTAssertNil(noRule, "alike is not enough to invent a rule")
        XCTAssertNil(consolidator.ruleParentKey(for: styleCluster()))

        let articles = DreamFixtures.plain("grammar:en:articles", kind: .grammar)
        let mixed = DreamFixtures.cluster(DreamFixtures.prepositions(3) + [articles])
        let mixedProposal = await consolidator.proposal(for: mixed, at: now)
        XCTAssertNil(mixedProposal, "one member of another shape and there is no common rule")
    }

    func testAProviderIsAskedOnlyAboutWhatNoRuleCovers() async {
        let provider = ScriptedSynthesis(result: .success(.noConsolidation))
        let consolidator = MemoryConsolidator(synthesis: provider)
        _ = await consolidator.proposal(for: DreamFixtures.cluster(DreamFixtures.prepositions(3)), at: now)
        XCTAssertTrue(provider.requests.all.isEmpty)
        _ = await consolidator.proposal(for: styleCluster(), at: now)
        XCTAssertEqual(provider.requests.all.count, 1)
    }

    func testTheProviderSeesTheLearnedMetadataAndNothingElse() async {
        let provider = ScriptedSynthesis(result: .success(.noConsolidation))
        let cluster = styleCluster()
        _ = await MemoryConsolidator(synthesis: provider).proposal(for: cluster, at: now)

        let expected = cluster.members.map { memory in
            SynthesisSource(
                id: memory.id, kind: memory.kind, language: memory.language,
                mode: memory.modeScope, tone: memory.toneScope,
                instruction: memory.instruction, triggers: memory.triggers,
                confidence: memory.confidence(at: now), occurrenceCount: memory.occurrenceCount
            )
        }
        XCTAssertEqual(provider.requests.all, [expected])
    }

    func testAProvidersRuleBecomesAProposalForTheWholeCluster() async throws {
        let provider = ScriptedSynthesis(result: .success(.rule(instruction: "使用者偏好簡潔的用詞。", triggers: ["t0"])))
        let cluster = styleCluster()
        let proposal = try unwrapped(await MemoryConsolidator(synthesis: provider).proposal(for: cluster, at: now))

        XCTAssertEqual(proposal.origin, .synthesized)
        XCTAssertEqual(proposal.sourceIDs, cluster.members.map(\.id))
        XCTAssertEqual(proposal.targetLevel, .generalized)
        XCTAssertEqual(proposal.instruction, "使用者偏好簡潔的用詞。")
        XCTAssertEqual(proposal.triggers, ["t0"])
        XCTAssertTrue(proposal.parentDedupKey.hasPrefix("dream:synthesized:style:en:"))
        XCTAssertFalse(proposal.parentDedupKey.contains(">"))
    }

    func testASynthesizedIdentityFollowsTheSourcesNotTheirOrder() async throws {
        let provider = ScriptedSynthesis(result: .success(.rule(instruction: "x", triggers: [])))
        let consolidator = MemoryConsolidator(synthesis: provider)
        let cluster = styleCluster()
        var reversed = cluster
        reversed.members.reverse()
        let a = try unwrapped(await consolidator.proposal(for: cluster, at: now))
        let b = try unwrapped(await consolidator.proposal(for: reversed, at: now))
        XCTAssertEqual(a.parentDedupKey, b.parentDedupKey)

        let other = DreamFixtures.cluster((5..<8).map { DreamFixtures.plain("style:en:k\($0)") })
        let c = try unwrapped(await consolidator.proposal(for: other, at: now))
        XCTAssertNotEqual(a.parentDedupKey, c.parentDedupKey)
    }

    func testTheIdentityOfADerivedMemoryNamesItsTone() async throws {
        let provider = ScriptedSynthesis(result: .success(.rule(instruction: "x", triggers: [])))
        let consolidator = MemoryConsolidator(synthesis: provider)
        func cluster(_ scope: WritingMode?, _ tone: WritingTone?) -> MemoryCluster {
            DreamFixtures.cluster((0..<3).map { DreamFixtures.plain("style:en:k\($0)", scope: scope, tone: tone) })
        }
        let professional = try unwrapped(await consolidator.proposal(for: cluster(.proofread, .professional), at: now))
        let concise = try unwrapped(await consolidator.proposal(for: cluster(.proofread, .concise), at: now))
        let global = try unwrapped(await consolidator.proposal(for: cluster(nil, nil), at: now))

        XCTAssertEqual([professional.modeScope, concise.modeScope, global.modeScope], [.proofread, .proofread, nil])
        XCTAssertEqual([professional.toneScope, concise.toneScope, global.toneScope], [.professional, .concise, nil])
        XCTAssertEqual(
            Set([professional.parentDedupKey, concise.parentDedupKey, global.parentDedupKey]).count, 3,
            "two tones never share a derived memory"
        )
        XCTAssertTrue(professional.parentDedupKey.hasPrefix("dream:synthesized:style:en:proofread|professional:"))
        XCTAssertFalse(professional.parentDedupKey.contains(">"))
        XCTAssertFalse(professional.parentDedupKey.contains(where: \.isWhitespace))
    }

    func testTheProviderIsToldTheToneOfWhatItCombines() async {
        let provider = ScriptedSynthesis(result: .success(.noConsolidation))
        let cluster = DreamFixtures.cluster(
            (0..<3).map { DreamFixtures.plain("style:en:k\($0)", scope: .proofread, tone: .formal) }
        )
        _ = await MemoryConsolidator(synthesis: provider).proposal(for: cluster, at: now)
        XCTAssertEqual(provider.requests.all.first?.map(\.tone), [.formal, .formal, .formal])
    }

    func testNoConsolidationAndAFailingProviderBothMeanNothing() async {
        let none = ScriptedSynthesis(result: .success(.noConsolidation))
        let noProposal = await MemoryConsolidator(synthesis: none).proposal(for: styleCluster(), at: now)
        XCTAssertNil(noProposal)
        let broken = ScriptedSynthesis(result: .failure(BrokenSynthesis()))
        let brokenProposal = await MemoryConsolidator(synthesis: broken).proposal(for: styleCluster(), at: now)
        XCTAssertNil(brokenProposal)
    }
}

/// `XCTUnwrap` as a function, so that its argument can be awaited: `try unwrapped(await thing())`.
func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
