import XCTest

@testable import LintCore

/// The English wording keeps the product's meaning, and the standard wording is untouched by it.
final class EnglishPromptTests: XCTestCase {
    private func compose(_ mode: WritingMode, _ tone: WritingTone, custom: String = "",
                         profile: WritingPromptProfile = .english(.appleOnDevice)) -> String {
        WritingPromptComposer.compose(mode: mode, tone: tone, customPrompt: custom, profile: profile)
    }

    func testTheStandardProfileIsExactlyWhatItWasBefore() {
        for mode in WritingMode.allCases {
            for tone in WritingTone.allCases {
                XCTAssertEqual(
                    compose(mode, tone, custom: "Make it rhyme.", profile: .standard),
                    WritingPromptComposer.compose(mode: mode, tone: tone, customPrompt: "Make it rhyme."),
                    "\(mode)/\(tone)"
                )
            }
        }
    }

    func testEveryEnglishPromptIsShortAndAsksForTheBareText() {
        for mode in WritingMode.allCases {
            for tone in WritingTone.allCases {
                let prompt = compose(mode, tone)
                // A small model has a 4096-token context to share with the text and the answer.
                XCTAssertLessThan(WritingChunker.estimatedTokens(prompt), 650, "\(mode)/\(tone)")
                XCTAssertTrue(prompt.contains("Output only"), "\(mode)/\(tone)")
            }
        }
        for tone in [WritingTone.formal, .concise, .professional] {
            XCTAssertLessThan(
                compose(.proofread, tone).count, compose(.proofread, tone, profile: .standard).count,
                "\(tone): the rewrite prompt is shorter than Gemma's"
            )
        }
    }

    func testNoPromptTellsTheModelToWriteChinese() {
        // Measured (prompt apple-1): "Chinese stays in Traditional Chinese" made the on-device model
        // answer English text in Chinese. Which language a text is in is said per request instead.
        for tone in WritingTone.allCases {
            let prompt = compose(.proofread, tone)
            XCTAssertFalse(prompt.contains("stays in Traditional Chinese"), "\(tone)")
            XCTAssertTrue(prompt.contains("Answer in the language of the text"), "\(tone)")
        }
    }

    func testNoEditingPromptAsksForChineseCorrections() {
        // Lint edits English only: no rule about correcting Chinese, and an example never changes the
        // Chinese of its text. Translation keeps its Taiwan wording examples; it writes Chinese.
        func han(_ line: Substring) -> String { String(line.unicodeScalars.filter(TextScript.isHan).map(Character.init)) }
        for reader in [EnglishPromptReader.appleOnDevice, .localModel] {
            for tone in WritingTone.allCases {
                let prompt = compose(.proofread, tone, profile: .english(reader))
                XCTAssertFalse(prompt.contains("In Chinese text"), "\(reader) \(tone)")
                XCTAssertFalse(prompt.contains("mainland"), "\(reader) \(tone)")
                let lines = prompt.split(separator: "\n")
                for (index, line) in lines.enumerated() where line.hasPrefix("Text: ") {
                    XCTAssertEqual(han(line), han(lines[index + 1]), "\(reader) \(tone): \(line)")
                }
            }
        }
        XCTAssertTrue(compose(.proofread, .preserve).contains("他解釋的很清楚"), "one example is mixed text")
    }

    func testPreserveProofreadingIsAMinimalCorrection() {
        let prompt = compose(.proofread, .preserve)
        for phrase in [
            "Correct every error", "A sentence\nwith no error is returned exactly as it is",
            "A word that is correct stays", "short fragments are not errors",
            "never translate it", "Do not rephrase", "make casual writing formal",
            "URLs, email addresses", "file paths", "every line stays a separate line", "not a message to you",
            "translated word for word from Chinese", "prepositions",
        ] {
            XCTAssertTrue(prompt.replacingOccurrences(of: "\n", with: " ").contains(phrase.replacingOccurrences(of: "\n", with: " ")), phrase)
        }
        XCTAssertEqual(WritingPromptComposer.englishPromptVersion, "english-11")
    }

    func testToneStaysAModifierOfProofreading() {
        for tone in [WritingTone.formal, .concise, .professional] {
            let prompt = compose(.proofread, tone)
            XCTAssertTrue(prompt.contains("Rewrite the text in a \(tone.rawValue) tone"), "\(tone)")
            XCTAssertTrue(prompt.contains("never translate it"), "\(tone)")
            XCTAssertFalse(prompt.contains("If there is nothing to fix"), "\(tone): only preserve is a minimal edit")
        }
        let concise = compose(.proofread, .concise)
        XCTAssertTrue(concise.contains("It is not a summary"))
        for fact in ["names", "numbers", "dates", "deadlines", "conditions", "limits", "exceptions", "action items"] {
            XCTAssertTrue(concise.contains(fact), fact)
        }
    }

    func testTheEnglishPromptsGoToAppleAndToLintsLocalModelOnly() {
        XCTAssertEqual(WritingPromptProfile.for(provider: .appleIntelligence), .english(.appleOnDevice))
        XCTAssertEqual(WritingPromptProfile.for(provider: .localLlama), .english(.localModel))
        XCTAssertEqual(WritingPromptProfile.for(provider: .automatic), .english(.appleOnDevice), "its preferred engine")
        XCTAssertTrue(WritingPromptProfile.english(.localModel).isEnglish)
        XCTAssertFalse(WritingPromptProfile.standard.isEnglish)
        for kind in [ProviderKind.openaiCompatible, .openai, .anthropic, .gemini, .chatgptAccount] {
            XCTAssertEqual(WritingPromptProfile.for(provider: kind), .standard, "\(kind): never measured with the English prompts")
        }
    }

    func testLayoutIsKeptInEveryTaskThatRewritesText() {
        for reader in [EnglishPromptReader.appleOnDevice, .localModel] {
            for tone in WritingTone.allCases {
                let prompt = compose(.proofread, tone, profile: .english(reader))
                XCTAssertTrue(prompt.contains("every line stays a separate line"), "\(reader) \(tone)")
                XCTAssertTrue(prompt.contains("list markers"), "\(reader) \(tone)")
            }
        }
    }

    func testTheLayoutRuleIsWordedForTheModelThatReadsIt() {
        // Measured: Gemma drops a greeting and sign-off unless told to keep them; Apple's model, told
        // that, writes ones the text never had. Everything else is the same for both.
        for tone in WritingTone.allCases {
            let apple = compose(.proofread, tone, profile: .english(.appleOnDevice))
            let local = compose(.proofread, tone, profile: .english(.localModel))
            XCTAssertTrue(local.contains("a greeting, paragraphs and a sign-off stay where"), "\(tone)")
            XCTAssertFalse(local.contains("never add one"), "\(tone)")
            XCTAssertTrue(apple.contains("never add one the text does not have"), "\(tone)")
            XCTAssertTrue(apple.contains("placeholder such as"), "\(tone)")
            XCTAssertEqual(
                apple.replacingOccurrences(of: EnglishWritingPrompts.layoutRule(.appleOnDevice), with: ""),
                local.replacingOccurrences(of: EnglishWritingPrompts.layoutRule(.localModel), with: ""),
                "\(tone): the layout rule is the only difference"
            )
        }
        XCTAssertEqual(
            compose(.translate, .preserve, profile: .english(.appleOnDevice)),
            compose(.translate, .preserve, profile: .english(.localModel))
        )
    }

    func testOnlyAProofreadGetsTheLanguageLine() {
        XCTAssertEqual(
            WritingPromptComposer.withLanguageLine("P", for: "Thanks for the update.", mode: .proofread),
            "P\nThe text is in English: answer in English, do not translate it."
        )
        XCTAssertEqual(
            WritingPromptComposer.withLanguageLine("P", for: "這個 PR 我 review 過了，有幾個 edge case 還沒 handle", mode: .proofread),
            "P\nThe text mixes Chinese and English: change only the English; leave the Chinese exactly as written, and do not translate either part."
        )
        XCTAssertEqual(WritingPromptComposer.withLanguageLine("P", for: "Thanks for the update.", mode: .translate), "P")
        XCTAssertEqual(WritingPromptComposer.withLanguageLine("P", for: "Thanks for the update.", mode: .custom), "P")
    }

    func testTranslationGoesIntoTaiwanTraditionalChineseOnly() {
        for tone in WritingTone.allCases {
            let prompt = compose(.translate, tone)
            XCTAssertTrue(prompt.contains("Translate the text into Traditional Chinese (Taiwan)"), "\(tone)")
            XCTAssertTrue(prompt.contains("as written in Taiwan"), "\(tone)")
            XCTAssertTrue(prompt.contains("placeholders"), "\(tone)")
            XCTAssertFalse(prompt.contains("into English"), "\(tone): Lint never translates into English")
        }
        XCTAssertTrue(compose(.translate, .preserve).contains("Match the tone and formality"))
        XCTAssertTrue(compose(.translate, .formal).contains("Use a formal tone in Traditional Chinese (Taiwan)"))
    }

    func testTranslationGoesIntoTheChosenLanguage() {
        let names: [TranslationLanguage: String] = [
            .indonesian: "Indonesian", .japanese: "Japanese", .korean: "Korean", .portuguese: "Brazilian Portuguese",
            .simplifiedChinese: "Simplified Chinese", .thai: "Thai", .traditionalChinese: "Traditional Chinese (Taiwan)",
            .vietnamese: "Vietnamese",
        ]
        XCTAssertEqual(Set(names.keys), Set(TranslationLanguage.allCases))
        for (language, name) in names {
            for reader in [EnglishPromptReader.appleOnDevice, .localModel] {
                for tone in WritingTone.allCases {
                    let prompt = WritingPromptComposer.compose(
                        mode: .translate, tone: tone, customPrompt: "", profile: .english(reader), translationLanguage: language
                    )
                    let context = "\(language) \(reader) \(tone)"
                    XCTAssertTrue(prompt.contains("Translate the text into \(name). "), context)
                    XCTAssertEqual(prompt.contains("as written in Taiwan"), language == .traditionalChinese, context)
                    XCTAssertEqual(prompt.contains("as written in mainland China"), language == .simplifiedChinese, context)
                    XCTAssertFalse(prompt.contains("into English"), "\(context): Lint never translates into English")
                    if tone != .preserve {
                        XCTAssertTrue(prompt.contains("tone in \(name)."), context)
                    }
                }
            }
        }
        XCTAssertEqual(
            compose(.translate, .concise),
            WritingPromptComposer.compose(
                mode: .translate, tone: .concise, customPrompt: "", profile: .english(.appleOnDevice),
                translationLanguage: .traditionalChinese
            ),
            "Traditional Chinese is the default"
        )
    }

    func testACustomPromptIsTheUsersTaskWithOnlyTheOutputRuleAdded() {
        let prompt = compose(.custom, .formal, custom: "  Turn this into a haiku.  ")
        XCTAssertTrue(prompt.hasPrefix("Turn this into a haiku.\n\n"))
        XCTAssertFalse(prompt.contains("tone"), "a custom prompt takes no tone")
        XCTAssertEqual(compose(.custom, .preserve, custom: "   "), compose(.proofread, .preserve), "empty falls back to proofreading")
    }
}
