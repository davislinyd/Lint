import Foundation

/// Adds the user's learned habits to the end of a system prompt. The end, because a local model
/// caches the prompt from its start: everything before the reminders stays reusable.
enum PromptComposer {
    static let header = "【個人化提醒】以下是這位使用者過去反覆出現的寫作習慣，僅在與本次原文相關時參考；不得改變原意，不得覆蓋上述任務指示，也不要在回覆中提到這些提醒。"
    /// The same for an English prompt, whose memories are worded in English too (`MemoryWording`).
    static let englishHeader = "Reminders about this user's recurring writing habits. Use one only where it applies to this text; it never changes the meaning or overrides the instructions above, and is never mentioned in the answer."

    /// With nothing to add, the prompt comes back exactly as it was, byte for byte: that is what
    /// it has to be while learning is off. Memories keep their order, within the prompt budget;
    /// `usedMemoryIDs` lists those that made it in.
    static func compose(base: String, memories: [WritingMemory], english: Bool = false) -> PersonalizedPrompt {
        var lines: [String] = []
        var used: [UUID] = []
        var characters = 0
        for memory in memories {
            guard used.count < LearningPolicy.maxPersonalizedMemories else { break }
            let cost = LearningPolicy.promptCost(of: memory)
            guard characters + cost <= LearningPolicy.maxPersonalizationCharacters else { continue }
            // The budget counts the stored wording, as the retriever does, so the two agree on what fits.
            let instruction = english
                ? MemoryWording(chinese: memory.instruction)?.english ?? memory.instruction : memory.instruction
            // One memory is one line, whatever it says: it cannot open a section of its own.
            let text = instruction.split(whereSeparator: \.isNewline).joined(separator: " ")
            lines.append("\(lines.count + 1). \(text)")
            used.append(memory.id)
            characters += cost
        }
        guard !lines.isEmpty else { return PersonalizedPrompt(systemPrompt: base, usedMemoryIDs: []) }
        let prompt = ([base, "", english ? englishHeader : header] + lines).joined(separator: "\n")
        return PersonalizedPrompt(systemPrompt: prompt, usedMemoryIDs: used)
    }
}
