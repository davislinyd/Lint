import Foundation

/// The last check before a proposal is stored, whoever wrote it. A proposal that fails is dropped
/// as a whole: nothing of it is kept.
struct MemoryConsolidationValidator: Sendable {
    enum Rejection: Error, Equatable, Sendable {
        case noSources
        case duplicateSources
        case sourceOutsideCluster
        case tooFewSources
        /// A source that is pinned, disabled, hand-edited, not established yet, or not a specific memory.
        case protectedSource
        case incompatibleSources
        case notGeneralized
        case invalidParentKey
        case emptyInstruction
        case instructionTooLong
        case multilineInstruction
        case containsEmail
        case containsURL
        case containsPath
        case containsNumber
        case promptInjection
        /// A word or quoted term that none of the sources has.
        case referencesOutsideSources
        case tooManyTriggers
        case unsupportedTrigger
    }

    private static let injectionMarkers = [
        "ignore", "disregard", "override", "system prompt", "system:", "assistant:", "user:",
        "忽略", "無視", "不要理會", "覆蓋", "以上指示", "前述指示",
    ]
    private static let latinWord = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’-]*")
    private static let quotedTerm = try! NSRegularExpression(pattern: "「([^」]+)」")
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `nil` when the proposal may be stored. `minimumSources` is lower than usual when the memory
    /// already exists and only gains a source.
    func validate(
        _ proposal: ConsolidationProposal,
        cluster: MemoryCluster,
        minimumSources: Int = LearningPolicy.dreamMinClusterSize,
        at now: Date
    ) -> Rejection? {
        guard !proposal.sourceIDs.isEmpty else { return .noSources }
        guard Set(proposal.sourceIDs).count == proposal.sourceIDs.count else { return .duplicateSources }
        let members = Dictionary(cluster.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sources: [WritingMemory] = []
        for id in proposal.sourceIDs {
            guard let member = members[id] else { return .sourceOutsideCluster }
            sources.append(member)
        }
        guard sources.count >= minimumSources else { return .tooFewSources }
        guard sources.allSatisfy({ ConsolidationEligibility.canBeSource($0, at: now) }) else {
            return .protectedSource
        }
        guard sources.allSatisfy({
            $0.kind == proposal.kind && $0.language == proposal.language && $0.modeScope == proposal.modeScope
        }) else { return .incompatibleSources }
        guard proposal.targetLevel == .generalized else { return .notGeneralized }
        guard isValidParentKey(proposal.parentDedupKey) else { return .invalidParentKey }
        if let rejection = instructionRejection(of: proposal, sources: sources) { return rejection }
        return triggerRejection(of: proposal, sources: sources)
    }

    /// Derived memories live under `dream:`, and no key may look like a reversible `a>b` pattern.
    private func isValidParentKey(_ key: String) -> Bool {
        key.hasPrefix("dream:") && key.count <= 120 && !key.contains(">")
            && !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private func instructionRejection(of proposal: ConsolidationProposal, sources: [WritingMemory]) -> Rejection? {
        let text = proposal.instruction
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyInstruction }
        guard text.count <= LearningPolicy.maxInstructionLength else { return .instructionTooLong }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else { return .multilineInstruction }

        let links = Self.linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if text.contains("@") || links.contains(where: { $0.url?.scheme == "mailto" }) { return .containsEmail }
        if text.contains("://") || text.lowercased().contains("www.") || !links.isEmpty { return .containsURL }
        if text.contains("/") || text.contains("\\") || text.contains("~") { return .containsPath }
        if text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return .containsNumber }
        let lowered = text.lowercased()
        if Self.injectionMarkers.contains(where: lowered.contains) { return .promptInjection }

        // Nothing may come from outside the sources: not a word, and not a quoted term.
        let sourceText = sources
            .map { ([$0.instruction, $0.dedupKey] + $0.triggers).joined(separator: " ") }
            .joined(separator: " ")
        let allowedWords = Self.latinWords(in: sourceText).union(proposal.allowedExtraWords.map { $0.lowercased() })
        guard Self.latinWords(in: text).isSubset(of: allowedWords) else { return .referencesOutsideSources }
        for term in Self.quotedTerms(in: text)
        where !sourceText.contains(term) && !proposal.allowedExtraWords.contains(term) {
            return .referencesOutsideSources
        }
        return nil
    }

    private func triggerRejection(of proposal: ConsolidationProposal, sources: [WritingMemory]) -> Rejection? {
        guard proposal.triggers.count <= LearningPolicy.dreamMaxTriggers else { return .tooManyTriggers }
        let known = Set(sources.flatMap(\.triggers).map { $0.lowercased() })
        for trigger in proposal.triggers
        where trigger.count > MemorySanitizer.maxPhraseLength || !known.contains(trigger.lowercased()) {
            return .unsupportedTrigger
        }
        return nil
    }

    private static func latinWords(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(latinWord.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        })
    }

    private static func quotedTerms(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return quotedTerm.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
