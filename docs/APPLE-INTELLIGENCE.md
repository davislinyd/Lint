# Apple Intelligence (Foundation Models) in Lint

Lint can use Apple's on-device `SystemLanguageModel` (the FoundationModels framework) as a writing
engine, next to its own llama.cpp + Gemma local AI. This page records how it is wired, what it
guarantees, and how it measured against Gemma. **Result: Apple Intelligence stays an optional
engine. New installs still default to Lint Local AI** (`WritingEngineMigration.newInstallDefault`),
whose default model is now Gemma 4 E4B (Gemma 4 12B and Qwen3 4B are optional; 12B carries a memory warning).

## Engines

| Choice | What it does |
|---|---|
| Automatic | Apple Intelligence when it is available; otherwise Lint Local AI if it is already set up. Never starts a download. |
| Apple Intelligence | Only the on-device system model. When it is unavailable, the reason is shown (device not eligible, turned off, model still downloading, macOS too old). No fallback. |
| Lint Local AI | The managed llama.cpp + Gemma path, unchanged. |

Routing is `WritingEngineRouter` (LintCore). When a request goes to Apple Intelligence, llama-server
is not started, no Gemma model is loaded and no localhost health check is made. Existing users keep
their stored provider on upgrade (`WritingEngineMigration`, one-shot, flag
`app.lint.migratedWritingEngine`, it reads no runtime state).

## Privacy

This engine uses only `SystemLanguageModel` (the on-device model). Lint never uses
`PrivateCloudComputeLanguageModel`, never sends text to Apple's servers or any other service through
this engine, adds no API key and never falls back to a remote provider. What other providers in Lint
do is unchanged and not covered by this statement.

## Compatibility

- SDK checked: Xcode 27.0 (Swift 6.4), macOS 27.0 SDK, FoundationModels module 2.0.68.
- Used from macOS 26.0: `SystemLanguageModel(useCase:guardrails:)`, `.availability`,
  `Guardrails.permissiveContentTransformations`, `LanguageModelSession(model:instructions:)`,
  `respond(to:options:)`, `GenerationOptions(samplingMode: .greedy, maximumResponseTokens:)`,
  `contextSize` (back-deployed; reports 4096 before 26.4), `LanguageModelSession.GenerationError`.
- Used from macOS 27.0, and only compiled with the macOS 27 SDK (`#if compiler(>=6.4)`):
  `LanguageModelError`, `SystemLanguageModel.Error`, `LanguageModelSession.Error`, `Response.usage`,
  `SystemLanguageModel.variant`.
- Lint's deployment target stays macOS 14. FoundationModels is weak-linked (`LC_LOAD_WEAK_DYLIB`;
  `Scripts/package-app.sh` fails the build otherwise) and never copied into the app. On macOS 14/15
  every call is behind `#available`, and the engine reports "requires macOS 26".

## Behaviour

- **Sessions:** one new `LanguageModelSession` per request, released when it answers; no transcript
  is carried between texts.
- **Guardrails:** proofreading, translation and tone rewrites use
  `permissiveContentTransformations` (the user's own text can quote anything). A custom prompt, the
  connection test and anything else keep the default guardrails. Responses are plain `String`; no
  `@Generable`.
- **Prompts:** `WritingPromptProfile.english` (`EnglishWritingPrompts`, version `english-11`, see the
  third and fourth rounds below; the same prompts go to Lint's local model, with their own layout
  rule): English instructions with the same product meaning as the standard prompts. Preserve-tone
  proofreading asks for every error an English teacher would mark (grammar, wrong or
  word-for-word-translated words, spelling, punctuation) while keeping every correct word, with four
  examples whose error types the fixtures do not contain. Lint edits English only: nothing asks for
  Chinese to be corrected, and every proofread piece gets one line naming the language of the text,
  which for Chinese-English text says to change only the English. A proofread of text with no English
  letter in it (URLs and paths aside) is not sent to any engine. A user's own prompt override is used
  as is.
- **Checks** (`WritingOutputGuard`, `WritingPipeline`, on-device path only; the Gemma path is
  unchanged): protected literals (URLs, email addresses, code spans, paths, identifiers, numbers,
  IPv4, and in a preserve proofread all-capital acronyms such as PR or CI) must survive; straight
  quotes stay straight when the text has no typographic ones; literals the source does not contain must not appear (made-up content); a
  proofread must stay in its language (including stray Chinese words or punctuation in English); a
  preserve proofread may change at most 50% of the tokens of an 8–400-token text and must keep its
  lines and list markers; the answer must not repeat Lint's instructions. One retry with the problem
  spelled out; if that fails too, a proofread keeps the source (with a note) and a translation shows
  the better attempt, flagged. Never more than two requests per piece. Custom prompts are not checked.
- **Context:** the budget comes from `SystemLanguageModel.contextSize`. Longer text is split
  deterministically between paragraphs, then lines, sentences and words (lossless: the pieces join
  back to the exact text); a piece the model still rejects (`contextSizeExceeded`) is split again, at
  most twice. Custom prompts are sent whole.
- **Prewarm:** not used. `LanguageModelSession.prewarm()` gave no measurable benefit (below).
- **Cancellation:** a new selection, a new request, closing the panel or Cancel cancels the task;
  the provider cancels its framework call, and a request ticket (`WritingRequestTickets`) keeps a
  late answer from ever replacing a newer one.
- **Background work:** Learning, Dreaming, status checks and the prefetch gloss never call the
  on-device model. Availability is a property read and never loads the model.
- **Memory:** a request routed to Apple Intelligence stops a llama-server Lint started, since it is
  not needed. Seen once under memory pressure: while Lint's server held Gemma 4 E4B, the system model
  reported a context size of 0 and failed every request until the server released the model; a
  second attempt did not reproduce it. A reported context size of 0 is never used to split text.
- **Errors** map to `AppleIntelligenceError` with a user message; the framework's own description is
  logged (`app.lint.assistant` / `AppleIntelligence`) and never shown.
- **Learning:** unchanged. A proofread that fell back to the source is not recorded as a suggestion.

## Evaluation (2026-09-23)

Fixtures (first round): `Tests/LintCoreTests/Eval/WritingEvalFixtures.json`, version 3, 116 cases written for this
repository (85 from the earlier local-model work, 31 new): proofreading (grammar, tense, articles,
prepositions, plurals, punctuation, capitals, spelling), 23 already-correct texts (casual, technical,
business, intentional fragments, Chinese, mixed), preservation (names, numbers, dates, currency,
percentages, URLs, email, IPs, paths, shell commands, identifiers, product names, mixed zh/en),
translation both ways (business email, IT/security/networking, casual, Markdown, lists,
placeholders, Taiwan wording) and the four tones.

Environment: MacBook Pro M1 Pro, 16 GB, macOS 27.0 (26A428), Lint 0.3.1 source.
Apple: `SystemLanguageModel`, variant "AFM 3 Core", context 4096, prompt `apple-2`, guard on.
Gemma: **Gemma 4 E4B** (`google/gemma-4-E4B-it-qat-q4_0-gguf`, `gemma-4-E4B_q4_0-it.gguf`, SHA-256
`676c3507…fbaee`), llama.cpp b11046, the arguments Lint used by default at the time
(`--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6 --reasoning off`), standard
prompts, temperature 0.3, no guard. Lint now tunes per model instead (context 3072, q8_0 KV cache,
idle release); Gemma was not re-measured with that tuning. **Gemma 4 12B, Lint's actual quality reference, was not
measured**: loading it drove free memory to 6% on this Mac and the safety monitor stopped it; the
maintainer chose E4B instead. A 12B comparison is still open.

### Objective checks (MEASURED)

| | Apple (apple-2 + guard) | Gemma 4 E4B (app path) |
|---|---|---|
| Clean Sentence Change Rate | **0/23 (0%)** | 11/23 (48%) |
| Fixtures with any failed check | 4 | 15 |
| Protected literal lost | 4 (names transliterated in 2 translations, MFA, "10th"→"tenth") | 3 (`09:15`→`9:15 AM`, `3 pm`→`3 PM`, `5 pm`→`5 p.m.`) |
| List/line structure broken | 0 | 1 |
| Simplified characters / mainland terms (checked list) | 0 / 0 | 0 / 0 |
| Guard retries / kept source | 0 / 0 (apple-2); 10 / 1 with apple-1 | n/a |

### Read by hand (MEASURED, one reviewer, 116 answers each)

| | Apple | Gemma 4 E4B |
|---|---|---|
| Proofreads with a clear error left in | **18** (e.g. "He don't have no time…" untouched, "an university", "which are encouraging", 在→再 missed, mainland terms 服務器/訪問 kept) | ~0 |
| Errors introduced into correct parts | 3 (那邊→Cantonese 嗰邊; stray spaces in mixed text; ", thanks" dropped) | several over-edits: English terms in mixed text translated (edge case→邊緣情況, merge→合併), "u"→"you" |
| Meaning changed / made up | 2 tone rewrites: tone-prof-01 invented a "shipment" and system logs; tone-prof-02 changed the complaint | 0 made up; tone-prof-01 left the insult in (tone not applied) |
| Translation hard errors | 1 mistranslation (敲我 → "knock back"), names transliterated (Alice→艾莉絲), "dark mode"→暗調, certificate→credentials, MFA→雙重驗證 | "Yi" for 怡君; otherwise accurate and natural |
| Taiwan Traditional Chinese | mostly good; 緩存 (mainland) once | good (快取, 深色模式, 林先生您好：) |

### Latency and resources (MEASURED unless marked)

| | Apple | Gemma 4 E4B |
|---|---|---|
| Server/model load | none to manage; system model | 25 s llama-server start to ready |
| First request of a run | 5.2–7.8 s (eval), 2.0–12.5 s (probe, depends on how long the model was idle) | 5.2 s (after the server was up) |
| Warm request, whole fixture incl. retries | median 0.87 s, p90 1.38 s | median 0.78 s, p90 1.75 s |
| Warm request, probe, fresh session each | median 0.49–0.60 s | – |
| Prewarm | same session 2.22 s, other session 3.49 s, none 2.0–4.1 s; cached tokens 0 in all → no benefit | – |
| Tokens per request | prompt median 256 (max 301), output median 27 | prompt median 940 |
| Memory | +1.9–2.2 GB wired while loaded, released within 240 s idle; inference process (`TGOnDeviceInferenceProviderService`) ~7 MB RSS; calling process ~7 MB | llama-server 651–730 MB RSS, +3.3 GB wired, held while the server runs |
| Disk managed by Lint | 0 | 5.15 GB (E4B); 6.98 GB for 12B |
| Thermal, 40 back-to-back requests | nominal throughout, no warning recorded | not measured |

The memory rows are not the same measurement: Apple's model lives in a system service and its
weights are not attributed to any app process; the figures are system-wide wired-memory deltas.

### Gate

| Criterion | Result |
|---|---|
| No meaningful increase in serious grammar errors vs Gemma | **Fails**: 18 proofreads with an error left vs ~0 (vs E4B) |
| Clean Sentence Change Rate within tolerance | Passes (0% vs 48%) |
| No meaningful increase in translation hard errors | Fails narrowly (names, one mistranslation, terms) |
| Meaning preservation strong | Fails for tone rewrites (one invented passage the guard cannot detect: it had no literals) |
| Protected literal failures near zero | Passes for proofreading; translation transliterates names |
| Latency / resources clearly improved | Resources yes (no download, no server, memory released when idle); warm latency about equal |

**Recommendation (first round): Gemma remains the default; Apple Intelligence is optional.** It suits
a user who wants proofreading that never rewrites correct text and no model download, and accepts
that it misses errors. See the second round below.

## Second round (2026-09-23): teacher-level proofreading, Gemma with the guard

A user found Apple Intelligence fixing only typos and basic grammar. What matters for Lint is
editing English text; English-to-Chinese translation is kept as a reference. So the fixtures
(version 5) now hold 102 cases: 88 English proofreading and tone cases and 14 English-to-Traditional-
Chinese translations. Chinese proofreading, mixed-language and Chinese-to-English cases were removed
(the first round above was measured on version 3, which still had them). `mustFix` lists the pieces
of the input that are errors and must not survive (92 pieces), including 12 common unnatural English
phrasings (`english-natural`, e.g. "open the light", "explain you") and 12 held-out cases
(`english-holdout`) written before tuning and never used to tune a prompt.

Removing cases needed no new model runs: every case is sent on its own and Apple samples greedily, so
the stored answers were re-scored on the current set. All numbers MEASURED on the same Mac; Gemma 4 E4B
through Lint's own server with the tuned arguments.

| Run | English errors left (of 92 pieces) | Held-out errors fixed | Correct English texts changed (of 17) | Serious meaning errors seen |
|---|---|---|---|---|
| Apple `apple-2` (fix only clear errors) | 33 | 6 / 12 | 0 | – |
| Apple `apple-3` (teacher + copy editor) | 7 of 80 (held-out not run) | – | 7 (synonym swaps, "ship" → "send") | several |
| Apple `apple-4` (teacher, correct words stay) | 11 | 11 / 12 | 3 | 3 ("give us" → "I give you", "find attach" → "kindly attach", an added "the legal team at") |
| **Apple `apple-5` (shipped)** | **11** | **11 / 12** | **2** | 1 ("find attach the report" → "find the report") |
| Apple `apple-6` (no Chinese example) | 12 | 11 / 12 | 3 | 3 ("PR" → "press release", "find attach" → "kindly attach", an added "the legal team at") |
| Gemma E4B, no guard, t=0.3, three runs | 2, 2, 3 | – | 8, 6, 6 | an English list translated into Chinese in 2 of 3 runs |
| Gemma E4B + guard, t=0.3 | 5 | – | 7 | – |
| Gemma E4B + guard, t=0 | 3 | – | 6 | – |
| **Gemma E4B with the apple-5 prompts** (`LINT_EVAL_PROFILE=onDevice`), one run | **2** | – | **2** | layout: a list lost its "- " markers, a formal email became one line |

- The 11 English errors apple-5 still leaves: present perfect not used (3), "until" for a deadline
  (2), "an university", a lower-case "we" at the start, "reply me", "the server is normal", "the
  price is too expensive", "go to Japan for travel".
- apple-4/5/6 differ mostly in which random mistakes they make; apple-5 made the fewest serious ones.
- Cost: the apple-5 prompt is 534 tokens against 249; measured back to back, median latency 1.35 s
  against 0.84 s per request.
- The guard does not help Gemma: its over-edits are small word swaps below the 50% change limit, so
  correct texts changed about as often, while falling back to the source threw away other corrections
  in the same text (added backticks and "9:15 AM" were the triggers). It stays on the Apple path only.
- Gemma's first request after idle release took 36.9 s (the model reloading), against about 1 s warm.
- Gemma's over-editing comes mostly from its prompt, not the model: with the same English teacher
  prompts Apple gets, Gemma E4B changed 2 of 17 correct texts (6–8 with its own Chinese-language
  prompt) and still left only 2 of 92 errors. One run at t=0.3, so the exact figures move a little;
  the gap is far outside the spread of the three runs with its own prompt.
- Lint does not translate into English any more: translation always goes into Traditional Chinese
  (Taiwan) as a reading aid, and the translation-target setting is gone. The prompts for that
  direction are unchanged, so the translation results above still stand.

**Recommendation (second round):** Gemma 4 E4B stays the default model, and should be given the
English teacher prompts: that combination left the fewest errors (2 of 92) and changed as few correct
texts as Apple (2 of 17). Apple Intelligence (11 of 92 left, 2 of 17 changed) is the choice for no
download and low memory. Before switching Gemma's prompts, the tone rewrites need a check that they
keep line breaks and list markers.

## Third round (2026-09-23): English prompts for Gemma, rules per model

Gemma 4 E4B (Lint Local AI) now gets the English prompts too; OpenAI-compatible endpoints and cloud
providers keep the original Chinese ones, which were never measured against them
(`WritingPromptProfile.for(provider:)`). Tone rewrites were found to merge or reorder lines, so the
prompts gained a layout rule, and one sentence of it did opposite things on the two models:

| Layout rule | Gemma: a formal email's lines, greeting and sign-off (2 runs each) | Apple: formal and professional rewrites |
|---|---|---|
| english-6: "a greeting, paragraphs and a sign-off stay where they are" | kept both times | wrote "Dear [Name]," and a subject line that were not there |
| english-7: "do not add or remove lines, greetings, subject lines or sign-offs" | merged into one line both times | "Dear [Name]," again, caught by the guard, source kept |
| english-8: keep existing ones, never add one or a placeholder | merged into one line both times | no correct text changed, fewest errors left |

So the English prompts are worded per model (`EnglishPromptReader`): Gemma gets the english-6 layout
rule, Apple the english-8 one; everything else is shared (`english-9`). The on-device path also caps
an answer at four times the text's length plus 128 tokens (at least 256), never splits a piece under
256 tokens when the context runs out, and treats template slots such as `[Name]`, `[project name]`,
`{name}` and `%s` that the text did not have as made up.

| Run (102 cases, English + English-to-Chinese) | English errors left (of 92) | Correct texts changed (of 17) | Literals lost | Notes |
|---|---|---|---|---|
| Gemma E4B, old Chinese prompts, 3 runs | 2, 2, 3 | 8, 6, 6 | 4–5 | an English list translated into Chinese in 2 of 3 runs |
| **Gemma E4B, english-9 (its rule = english-6), 2 runs** | **3, 2** | **3, 2** | **1, 1** | lists and emails keep their lines |
| Apple apple-5 (second round) | 11 | 2 | 6 | – |
| **Apple english-9** | **12** | **0** | **6** | 9 plus the 3 rude words of two professional rewrites that invented content and fell back to the source |

Gemma remains the default and is now also the most careful engine for English. Apple stays the
choice for no download and low memory; its professional tone is the weakest part (it invents content,
which the guard now stops, leaving the text unchanged).

## Fourth round (2026-09-24): English only

Lint edits English; English-to-Chinese translation stays as a reading aid. The English prompts lost
their rule and example for correcting Chinese (的/得/地, 在/再, mainland terms), the standard
(Chinese-language) prompts lost their Chinese section and their mixed example (which changed the
Chinese and translated "clear"), and a Chinese-English text is now told to have its English changed
and its Chinese left exactly as written. Five mixed fixtures were added (v6, 107 cases): each has one
English error and a Chinese slip that must survive.

| Run | English errors left (of 92) | Correct English texts changed (of 17) | Mixed cases right (of 5) |
|---|---|---|---|
| Apple english-9 (before) | 12 | 0 | 0 (the guard kept the source; first answers corrected the Chinese) |
| Apple english-10 (Chinese rule and example removed) | 22 | 2 | 1 |
| **Apple english-11** (the unchanged example first, a mixed example last) | **19** | **0** | 1 |
| Gemma E4B english-9 (before), 2 runs | 3, 2 | 3, 2 | 1, 1 (the English translated into Chinese, 軟件 → 軟體) |
| Gemma E4B english-10, 2 runs | 2, 3 | 3, 3 | 1, 0 |
| **Gemma E4B english-11, 2 runs** | **3, 3** | **2, 1** | 1, 2 |
| Gemma E4B, standard prompts without the Chinese section (stands in for cloud), 1 run | 2 | 7 | 0 |

- Removing the fourth example cost Apple's model corrections: with the "leave it unchanged" example
  last it left more errors and changed two correct texts. english-11 recovers the correct texts, not
  all of the corrections: 4 cases are worse than english-9, one of them (4 pieces) an answer that
  began with `- "` and was caught by the guard. Accepted: Apple is optional, and its prompt no longer
  touches Chinese.
- Gemma is unchanged or better on English with english-11, so it stays the default.
- **Mixed text is not solved by the prompt.** Gemma still translates the Chinese tail of a sentence
  into English in some cases ("新的設置流程" → "with the new setup process"); the Gemma path has no
  output check. Apple's guard catches a translation and keeps the source, so it rarely fixes mixed
  text either.

## Re-running after a macOS or Foundation Models update

```sh
LINT_EVAL=1 LINT_EVAL_ENGINE=apple LINT_EVAL_LABEL=apple-<os> swift test --filter WritingEvalRunTests
# optional: a llama-server with Gemma on port 8099
LINT_EVAL=1 LINT_EVAL_ENGINE=llama LINT_EVAL_LABEL=gemma LINT_EVAL_URL=http://127.0.0.1:8099/v1 swift test --filter WritingEvalRunTests
LINT_EVAL_COMPARE=1 swift test --filter WritingEvalReportTests   # .build/eval/comparison.md
```

Each run records the macOS version, the model variant, the context size, the on-device prompt
version, the Lint version and the hardware. Compare only runs whose variant and prompt version match.
On a 16 GB Mac, stop anything else that holds a model before loading Gemma, and watch
`memory_pressure`.
