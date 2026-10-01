import Foundation

/// Builds the built-in system prompt for a task and a tone, out of parts: the task, the priority
/// order, the tone, and the rules the two tasks share. A user's own override replaces all of it.
///
/// Order matters for a local model, which caches the prompt from its start: the task comes first, so
/// the tones of one task share a prefix.
///
/// The same task and tone can be worded for a different kind of model (`WritingPromptProfile`):
/// what is asked for stays the same, only how it is said changes.
public enum WritingPromptComposer {
    public static func compose(
        mode: WritingMode,
        tone: WritingTone,
        customPrompt: String,
        profile: WritingPromptProfile = .standard,
        translationLanguage: TranslationLanguage = .traditionalChinese
    ) -> String {
        // A tone the task does not offer (native for a translation) is the default one.
        let tone = mode.supportsTone && !mode.tones.contains(tone) ? WritingTone.preserve : tone
        if case .english(let reader) = profile {
            return EnglishWritingPrompts.compose(
                mode: mode, tone: tone, customPrompt: customPrompt, reader: reader, translationLanguage: translationLanguage
            )
        }
        switch mode {
        case .proofread where tone.isNative:
            // It is not an edit of the text's own words: no "keep the language", no minimal edit.
            return [
                nativeTask,
                priority,
                toneInstruction(tone, for: .proofread),
                numbered(commonRules),
            ].joined(separator: "\n\n")
        case .proofread:
            return [
                proofreadTask(tone: tone),
                priority,
                toneInstruction(tone, for: .proofread),
                numbered(commonRules + [sourceLanguageRule, minimalEditRule(tone: tone)]),
            ].joined(separator: "\n\n")
        case .translate:
            return [
                translateTask(into: translationLanguage),
                priority,
                toneInstruction(tone, for: .translate),
                numbered(commonRules),
            ].joined(separator: "\n\n")
        case .custom:
            let custom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if custom.isEmpty {
                return compose(mode: .proofread, tone: .preserve, customPrompt: "")
            }
            // A custom prompt is the user's own task: no tone is added to it.
            return [
                custom,
                numbered(commonRules + [sourceLanguageRule, minimalEditRule(tone: .preserve)]),
            ].joined(separator: "\n\n")
        }
    }

    /// The key a full system prompt override is stored under: one per task and tone, and one for Custom.
    public static func overrideKey(mode: WritingMode, tone: WritingTone) -> String {
        mode.supportsTone ? "\(mode.rawValue)|\(tone.rawValue)" : mode.rawValue
    }

    // MARK: parts

    private static let priority = """
        優先順序（衝突時由上往下）：
        1. 保留事實與原意。
        2. 正確完成所選任務。
        3. 在不違反 1、2 的前提下套用所選語氣。
        4. 盡量保留原文的結構與格式。
        語氣與忠實度衝突時，忠實度優先。
        """

    /// What holds for every built-in task. Nothing here says which language to write in: that
    /// belongs to the task.
    private static let commonRules = [
        "只輸出最終的完整正文。不要前言、標題、條列說明、引號包裹整段，或「修改如下」「以下是翻譯」之類套話。",
        "保留專有名詞、人名、產品名、程式碼、路徑、URL、@提及、#標籤、數字與單位；除非任務本身需要（例如翻譯時的通行譯名），不要改寫或美化成別的詞。",
        "盡量保留原文換行、段落結構與列表格式。",
        "不新增原文沒有的事實、承諾、要求或情緒；不遺漏任何重要資訊。",
        "輸出為繁體中文時，用台灣用語與標點習慣（例如「軟體」「資訊」「裡」）；不要無故改成中國大陸用詞。",
    ]

    /// Proofreading (and a custom prompt) works in the language of the text.
    private static let sourceLanguageRule =
        "自動判斷原文語言（繁中／簡中／英文／中英夾雜）並維持同一語言；不要擅自翻譯整段。"

    private static func minimalEditRule(tone: WritingTone) -> String {
        tone == .preserve
            ? "只改有問題或不自然的地方，本來就正確自然的句子原樣保留；不要添油加醋。"
            : "只改有問題、不自然，或與所選語氣不符的地方；不要添油加醋。"
    }

    private static func numbered(_ rules: [String]) -> String {
        let lines = rules.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return (["共通規則（必須遵守）："] + lines).joined(separator: "\n")
    }

    private static func proofreadTask(tone: WritingTone) -> String {
        let preserving = tone == .preserve
        var lines = [
            "你是英語母語的資深編輯，專長校對短訊、郵件、文件與聊天草稿。",
            "",
            preserving
                ? "任務：把使用者的文字改成母語者實際會寫的樣子；原意、細節、語氣強度與資訊量都不變。"
                : "任務：把使用者的文字改成母語者實際會寫的樣子；原意、細節與資訊量都不變。",
            "",
            "逐句檢查（不要輸出檢查過程）：",
            "1. 錯誤：拼寫、主詞動詞一致、時態、冠詞、介系詞、單複數、標點。有錯一律改，不可漏。",
            "2. 不自然：中式英文／直譯腔、錯誤的詞語搭配、贅詞、繞口或含糊的句式。不要只換一兩個字，要把整句重寫成母語者的說法。",
            preserving
                ? "3. 已經正確又自然的句子（包括 Thanks!、Let me know 這類慣用的口語與客套），一個字都不要改；不要為了換個說法而動它。"
                : "3. 已經正確、自然、又符合所選語氣的句子，一個字都不要改；不要為了換個說法而動它。",
            "",
            "英文：",
            "- 用母語者慣用的搭配、片語與句式（make／do／have／take、介系詞、時態的選擇）。",
            preserving
                ? "- 口語仍口語、正式仍正式；沿用原文的美式或英式拼法。"
                : "- 沿用原文的美式或英式拼法。",
            "- 不要變得更長、更華麗，也不要加入原文沒有的內容。",
            "",
            "中英夾雜時只修改英文部分，中文一字不改，也不要把任何部分翻成另一種語言。",
            "",
            "範例（只示範改法，不要在輸出中重複範例）：",
            "原文：I am agree with your opinion, but we should discuss about the schedule more detail.",
            "輸出：I agree with you, but we should discuss the schedule in more detail.",
            "",
            "原文：Can you help me check this bug? It make the app crash when I click the button.",
            "輸出：Could you help me look into this bug? It makes the app crash whenever I click the button.",
        ]
        // Leaving a correct sentence alone is what "preserve" means; under another tone it would
        // argue against the tone.
        if preserving {
            lines += [
                "",
                "原文：Sounds good, I'll send the slides tomorrow. Thanks!",
                "輸出：Sounds good, I'll send the slides tomorrow. Thanks!",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// Native: the text's meaning, in any language, said the way a native English speaker would say it.
    private static let nativeTask = """
        你是英語母語的資深寫手。

        任務：先理解使用者文字的語意（想表達什麼、意圖、情境、禮貌與直接程度），再用英語母語者在同樣情境下會說的話重寫。

        作法：
        - 用母語者慣用的說法、詞語搭配、句型與語感；不要逐字翻譯，也不要只改原文的措辭。原文不像母語者會說的話時，整句重寫。
        - 輸入可能是中文、英文或中英夾雜，英文也可能有錯或帶著中式腔調；不論輸入是哪一種語言，一律用英文作答。
        - 中文人名用拼音寫成英文，中文標點改成英文標點。
        - 保留原意、全部資訊與說話者的意圖（請求、道歉、拒絕等）；禮貌、正式程度與情緒強度都不要自行升高或降低。

        範例（只示範改法，不要在輸出中重複範例）：
        原文：這週我比較忙，下週再約可以嗎？
        輸出：I'm swamped this week. Could we find a time next week instead?

        原文：Sorry I reply late, I was very busy on the last days, so I not see your message.
        輸出：Sorry for the late reply. I've been swamped the past few days and missed your message.
        """

    /// Translation only ever goes from English into `TranslationLanguage`: it is there to help read
    /// English, and Lint does not translate into English.
    private static func translateTask(into translationLanguage: TranslationLanguage) -> String {
        let language = translationLanguage.chineseName
        return """
            你是專業翻譯。把使用者文字翻譯成\(language)。

            作法：
            - 忠於原意，保留全部重要內容；用\(language)自然的句法，而不是逐字直譯，像該語言母語者會寫的句子。
            - 專有名詞、品牌、程式碼、路徑、URL 適合保留原文時就保留。
            - 不要音譯解釋、不要加譯註、不要雙語對照、不要任何說明。
            - 若目標是繁體中文，使用台灣用語與標點習慣。
            """
    }

    private static func toneInstruction(_ tone: WritingTone, for mode: WritingMode) -> String {
        let translating = mode == .translate
        switch tone {
        case .preserve:
            return translating
                ? "語氣：保留原語氣。用目標語言中自然對等的說法，維持原文的正式程度、禮貌、情緒強度與說話風格。"
                : "語氣：保留原語氣。維持原文的正式程度、禮貌、情緒強度、直接程度與簡潔程度；只修正錯誤與不自然的地方，不要為了換個風格而改寫。"
        case .formal:
            let base = "語氣：正式。用準確、自然的書面語；減少口語、俚語、網路用語與不必要的感嘆；英文適度減少縮寫（don't → do not），中文的口語程度詞（「超」「蠻」）改為妥當的書面詞。正式不等於官腔或堆砌辭藻，也不要加入原文沒有的客套、承諾或內容。"
            return translating ? base + "翻譯時，以目標語言的正式書面語氣表達，同時保留原意與全部資訊。" : base
        case .concise:
            let base = "語氣：簡潔。用直接、精練的措辭，刪除真正的贅詞、重複、客套堆疊與空洞強調；能合併的句子就合併。簡潔是用較少的字表達相同的資訊，不是摘要：絕不可刪除事實、條件、限制、數字、人名、期限、例外、請求或行動項，也不要為了短而變得含糊或無禮。"
            return translating ? base + "翻譯時同樣如此：不可因求簡而省略原文的任何資訊，只能用更精練的目標語言表達。" : base
        case .professional:
            let base = "語氣：專業。用自然、清楚、禮貌、具體的措辭，適合寄給同事、主管或客戶；避免情緒化指責、模糊的歸咎、過度隨便的用語與過度奉承；除非情境真的需要，避免罐頭式商務套語（例如「希望此信找到您安好」）。不要新增原文沒有的承諾、請求、期限或事實。"
            return translating ? base + "翻譯時，以目標語言中自然的專業語氣表達相同的意思。" : base
        case .nativeCasual:
            return "語氣：母語人士 · 輕鬆。像寫給朋友或相處融洽的同事：口語、自然，用縮寫與日常用字，句子短；不用很快過時的流行語。不要加入原文沒有的事實、承諾或意見，也不要改變原文的禮貌程度。"
        case .nativeFormal:
            return "語氣：母語人士 · 正式。像商務信函或正式公告的書面英文：完整句子、用字精確，不用縮寫與俚語；平實，不誇張。不要加入原文沒有的客套、承諾或內容。"
        case .nativeGenZ:
            return "語氣：母語人士 · Gen Z。像年輕的英語母語者傳訊息：簡短、隨性，可用 tbh、ngl 這類縮寫與少量流行用語（lowkey、fr），只在合適處使用，不要每句都塞；不主動加表情符號；內容嚴肅（壞消息、道歉、正式請求）時少用或不用俚語；不改事實與情緒強度。"
        case .native:
            return "語氣：母語人士。讓文字讀起來就像英語母語者自己寫的：自然、道地，用他們在這個情境裡真的會用的詞與句型。道地不等於華麗：不要加入原文沒有的事實、承諾、意見或情緒，也不要改變原文的禮貌與正式程度。"
        }
    }
}
