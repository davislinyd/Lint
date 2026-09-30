# GEC T5 Small as the proofreading model: evaluated, not adopted

On 2026-09-28 Lint measured whether `Unbabel/gec-t5_small`, a 60M-parameter T5 model trained only for
grammatical error correction, could replace Gemma 4 E4B (5.15 GB) for **Proofread with the tone
kept**. The appeal was a model under 100 MB with no server and a small memory footprint.
**Result: not adopted.** It left 22 of 86 errors, against 4 for Gemma. It also made six wrong or
meaning-changing edits that Gemma did not, and it never corrects English inside Chinese text. Gemma 4 E4B stays the default,
and nothing was added to the app, the model catalog or the bundled runtime.

What is kept: an evaluation engine (`LINT_EVAL_ENGINE=gec`, code in `Tests/LintCoreTests/Eval/GEC/`),
so a future GEC model can be measured the same way. Read this page before proposing a GEC or other
encoder-decoder model again.

## Why it cannot simply be a catalog entry

- **`llama-server` cannot run T5.** Its request path, which the new `llama-cli` shares, only calls
  `llama_decode`, never `llama_encode`. An encoder-decoder model needs both, so the server asserts
  (`llama_encode must be called first`) or produces garbage. This holds at the pinned b11046
  (`60081bb`) and on upstream master; ggml-org/llama.cpp#26565 was closed as not planned, and a
  server patch (ggml-org/llama.cpp#17956) was still unmerged. Upgrading llama.cpp does not help.
- **`llama-completion` can.** It is in the same pinned release archive and calls `llama_encode` plus
  the decoder start token. Adopting a GEC model would therefore mean bundling, signing and verifying
  a second binary: `fetch-llama-runtime.sh`, `sign-llama-runtime.sh`, `release.sh`'s
  `verify_llama_runtime`, and `LlamaRuntimeVerifier`. It would also start one short process per
  sentence, not a server.
- **Metal must be kept off.** Every `llama-completion` process that opens a Metal device has the
  system compile ggml's shaders first, which took up to 30 s with a cold shader cache. With
  `GGML_METAL_DEVICES=0` it runs on the CPU in 0.2–0.3 s per sentence, faster than with Metal for a
  model this small.
- **The T5 tokenizer loses text.** Its SentencePiece vocabulary turns line breaks, tabs and repeated
  spaces into one space. It has no CJK and none of `< \ ^ ` { } ~` (these become `⁇`, checked
  character by character with its `spiece.model`). When it writes back something it does not know as
  a word, it splits it: `Q4` → `Q 4`, `p95` → `p 95`, `HTTP/2` → `HTTP /2`,
  `config/settings.prod.yaml` → `config / settings. prod. yaml`, `NT$3,500` → `NT $3,500`.
- **Decoding is greedy only.** The model card uses beam search (5 beams); `llama-completion` has none.
- **Learned habits have no effect.** GEC takes no prompt, so the reminders Lint learns
  (`MemoryCoordinator.personalize`) cannot reach it.

## How the evaluation engine works

`GrammarCorrector` (`Tests/LintCoreTests/Eval/GEC/GrammarCorrector.swift`) is what the app would have
needed, reduced to the evaluation:

1. The text is split into lines. Leading space and a list marker (`- `, `* `, `• `, `1. `) are kept
   aside, and the rest is cut into sentences with `WritingChunker`'s Latin sentence break.
2. A sentence is sent only if it has English and every character is one the vocabulary writes back.
   Chinese, code in backticks and braces are never sent.
3. Each sentence becomes one `llama-completion` call (`LlamaCompletionGECProvider`):
   `-p "gec: <sentence>" --temp 0 --top-k 1 -no-cnv --no-display-prompt --no-escape -c 512 -ngl 0`
   with `GGML_METAL_DEVICES=0`. The answer is read up to ` [end of text]`, and a missing marker counts
   as truncated.
4. `keepingSpacing` undoes the spaces T5 puts inside words. It compares words, not characters, and
   still allows the spacing changes a proofread makes: splitting letters (`alot` → `a lot`) and moving
   a space from before a punctuation mark to after it (`fix ,tested` → `fix, tested`).
5. `WritingOutputGuard.tidy` and `assess(…, .proofread, .preserve)` run per sentence. A sentence that
   fails keeps its source text; there is no retry, because greedy decoding would give the same answer.

## Results

Fixtures: `WritingEvalFixtures.json` version 6, plus `clean-casual-02` (`yep, grabbed the keys.
gonna head out now`), which was added for this run. Only the proofread/preserve cases were run for
GEC (83 cases, 86 `mustFix` pieces, 19 already-correct texts). Gemma 4 E4B was measured through the
app's own running `llama-server` (the app's arguments, temperature 0.3, no guard, English prompts
english-11). Hardware: MacBook Pro M1 Pro, 16 GB, macOS 27.

| | Gemma 4 E4B | GEC T5 Q8_0 (as described above) | GEC T5 Q8_0, raw output |
|---|---|---|---|
| Errors left, proofread/preserve (of 86 pieces) | **4** | **22** (4 of them in mixed Chinese-English text, never sent) | 23 |
| Already-correct texts changed (of 19) | 2 | **0** | 2 |
| Protected literals lost, proofread/preserve cases | 4 (3 of them in mixed text) | **0** | 6 |
| Warm latency, median / p90 | 1.05 / 2.17 s | 0.26 / 0.52 s | 0.30 / 0.66 s |
| Model on disk | 5.15 GB | 83 MB | 83 MB |
| Memory | 651–730 MB RSS + 3.3 GB wired while the server runs (APPLE-INTELLIGENCE.md) | ~177 MB peak per call, released when the call ends | same |

Quantization: F16 (155 MB) gave the same scores as Q8_0 and differed in one answer. Q4_K_M (51 MB)
made new grammar errors (`has grew`, `it works` for `it worked`). Q6_K and Q5_K_M were built but not
evaluated.

**Errors GEC left in** (18 English pieces; Gemma's are marked):

| Kind | Examples |
|---|---|
| Chinese-influenced wording | `open the light`, `server is normal` (Gemma also), `price is too expensive` (Gemma also), `was very busy these days`, `apply until Friday` |
| Agreement | `team have`, `logs is`, `we postpone` (tense, after a past clause) |
| Countable/uncountable | `feedbacks` |
| Capitals | `i talked to sarah from apple about the ios release on monday`: all five fixed, but the change ratio exceeded the guard's 0.5, so the source was kept |
| Not sent or kept by the guard | `and than` next to backticks, `getUserConfig() return null` (identifier) |
| Word form | `He is used to work` |

**Wrong or meaning-changing edits** (GEC only; Gemma made none of these):

- `I will go to Japan for travel next month.` → `I am coming to Japan for a holiday next month.`
- `He is used to work late at night.` → `He used to work late at night.`
- `approval from legal` → `approval from the legal`
- `failing on main` → `failing on the main` (a branch name)
- `explain you the details in tomorrow's meeting` → `explain to you the details of tomorrow's meeting`
- `I have two informations` → `I have two information`

What it does well: classic errors (tense, articles, spelling, agreement, `reply me`,
`discuss about`, `since three years`, `looking forward to hear`). It also leaves casual English
alone: both `lol yeah, that bug got me too…` and `yep, grabbed the keys. gonna head out now` came
back unchanged.

## License

The Hugging Face metadata at the pinned revision says `license: apache-2.0`, but the repository has
no LICENSE file. The model was trained on cLang-8, which is derived from the Lang-8 corpus, and on
CoNLL-13/14 (NUCLE). The terms of those datasets are, as far as we know, research-oriented.
Whether that restricts the weights was not settled; it would need legal review before any
company or commercial use.

## Decision

1. Not the default proofreading model: 22 errors left against a gate of at most 10, and meaning
   changes that Gemma does not make.
2. Not an optional lightweight model either. Apple Intelligence already covers "no download, little
   memory" (11 of 92 errors left, 2 of 17 correct texts changed; see APPLE-INTELLIGENCE.md) without
   a second runtime binary, a self-hosted GGUF or a license review.
3. Gemma 4 E4B stays the default.
4. The next thing worth trying is not another GEC checkpoint. Most public English GEC models are
   trained on the same Lang-8/NUCLE-derived data, and none was checked for this page. A smaller
   instruct model runs on the existing `llama-server` and keeps the learned reminders.

## Reproducing

Model preparation (maintainer machine only; nothing here goes into the app):

```sh
R=c958d53bfbce19c87342b69fc6bcaba7303d076f
for f in config.json pytorch_model.bin spiece.model special_tokens_map.json tokenizer.json tokenizer_config.json; do
  curl -fL -o hf/$f "https://huggingface.co/Unbabel/gec-t5_small/resolve/$R/$f"
done
shasum -a 256 hf/pytorch_model.bin   # 5767cb48bbfa86288b1bcb4db8b15d798ad72bb23e4db695f2e4394882fa7766
# llama.cpp source at the pinned commit 60081bb2b5b3294165a4d67c5cbeebe74c868014, in a scratch venv:
uv venv -p 3.12 venv && . venv/bin/activate && uv pip install -r src/requirements/requirements-convert_hf_to_gguf.txt
PYTHONPATH=src/gguf-py python src/convert_hf_to_gguf.py hf --outtype f32 --outfile gec-t5_small-f32.gguf
# llama-quantize and llama-completion come from the pinned archive in .build/llama-runtime/cache
llama-b11046/llama-quantize gec-t5_small-f32.gguf gec-t5_small-q8_0.gguf Q8_0
```

The files this produced: Q8_0 82,844,064 bytes, SHA-256
`73f213a6f8bd343b2a29d1cd3c6bd5268ab5a588eab460d91a689a5afe000d6c`; F16 154,973,600 bytes, SHA-256
`723bacda9b4c97c6bf4273415bb3cb85d5f8ea190da70e6c6a4fa170cceeaf84`.

Running the evaluation:

```sh
LINT_EVAL=1 LINT_EVAL_ENGINE=gec LINT_EVAL_LABEL=gec-t5-q8_0 \
  LINT_EVAL_GEC_BIN=<dir>/llama-b11046/llama-completion LINT_EVAL_GEC_MODEL=<dir>/gec-t5_small-q8_0.gguf \
  swift test --filter WritingEvalRunTests
LINT_EVAL_COMPARE=1 swift test --filter WritingEvalReportTests   # .build/eval/comparison.md
```

The comparison table has a column for the proofread/preserve subset, so a GEC run and a full Gemma
run are compared on the same pieces.
