# Agent guide: Lint

Rules for coding agents working in this repository. The human runbook for releases is
[docs/RELEASING.md](docs/RELEASING.md); this file only lists what an agent must know to avoid damage.

## Build and test

- `swift build`, `swift test` (XCTest in `Tests/LintCoreTests`). Script behavior is tested from Swift:
  `InstallScriptTests`, `RuntimeScriptTests`, `ReleaseScriptTests` (with `ReleaseFixture`, which runs the real
  release scripts against fake Apple tools; no test may contact Apple or need a signing identity).
- `Scripts/package-app.sh [debug|release]` assembles `dist/Lint.app` (it `rm -rf`s that app first).
  `LINT_DIST_DIR=<dir>` builds elsewhere.
- No script may use Homebrew; the install path (`install.sh`, `fetch-llama-runtime.sh`, `sign-llama-runtime.sh`,
  `package-app.sh`) must not need `.git`.

## Sensitive data: everything pushed is public

The repository, its GitHub Pages site and its Releases are public. Files, commit messages, PR and issue text,
release notes, screenshots and Actions logs are published the moment they are pushed, and a pushed commit cannot
be taken back without rewriting history and deleting releases.

- Never commit keys, certificates (`.p8`, `.p12`), passwords, tokens, notarization credentials, `.env` files or
  signing material; they belong in the keychain or in GitHub secrets.
- Names: the maintainer appears only as `Davis Lin`. Never write the maintainer's or anyone's Chinese (or other
  non-Latin) real name, and no other real person's name, handle, email, phone number, address or ID number. Use
  made-up names (Alice, Bob, `example.com`) in code, tests, fixtures, eval data and screenshots.
- No real chats, emails, documents or work content, and nothing about an employer's internal matters. Test, eval
  and screenshot text is written for this repository.
- No `/Users/<name>` paths, private links (such as claude.ai session URLs), local logs or diagnostics from the
  maintainer's Mac. Look at the whole screenshot (menu bar, notifications, file names, other apps) before adding it.
- Before every push, read the diff and the commit messages for the above. If something like this is already
  pushed, stop and tell the user; do not rewrite history or delete releases on your own.

## `dist/` is not scratch space

`dist/Lint.app` and `dist/release/` hold builds the maintainer keeps. Do not delete or regenerate them unless
asked: `package-app.sh` wipes `dist/Lint.app` and `release.sh` without `LINT_RELEASE_OUTPUT_DIR` wipes
`dist/release/`. For a check, build into a scratch directory (`LINT_DIST_DIR=…`, `LINT_RELEASE_OUTPUT_DIR=…`).

## Local model access (do not weaken)

- llama-server and Lint's API port (`Sources/LintCore/LocalAPI`) bind to `127.0.0.1` only, never another address.
- llama-server always takes a key: `--api-key-file /dev/stdin`, fed a random key made once per Lint process
  (`LocalLlamaServerManager.serverKey`). Keys never go into arguments, the diagnostic log, Settings text, release
  state or tests' fixtures; `LocalAPIKey` prints as redacted. `splitArguments` drops `--host`, `--api-key*` and
  `--cors-*` from the extra arguments, and `LlamaServerEnvironment` drops `LLAMA_API_KEY` and `LLAMA_ARG_*`.
- The API port never shares llama-server's port: `stop(port:)` kills every listener there, Lint included.
- Other apps' keys (`LocalAPIKeyring`) are values in the Keychain only. The list in UserDefaults holds IDs, names,
  dates and Keychain accounts, never a key, and the diagnostic log names a key only by `shortID`. Origin `null` and
  other schemes are refused even with **Allow any website** on; browser-extension origins (`chrome-extension`,
  `moz-extension`, `safari-web-extension`) only with **Allow browser extensions**, which is off by default.
- Every Lint request to its local model goes through `ModelPriorityGate` (`OpenAICompatibleProvider` for
  `.localLlama`); Lint's side never waits. External requests are interrupted when Lint starts one.
- The proxy forwards only `/v1/chat/completions`, `/v1/completions` and `/v1/models`, checks Host, Origin (allow
  list) and the key before reading the body, and logs no body, key or origin.

## Two separate concepts: development and formal release

- **Development** happens in the primary checkout. Previews and dry runs
  (`LINT_PREVIEW_BUILD=1` / `LINT_SKIP_NOTARIZE=1 ./Scripts/release.sh`) may use `dist/release/`.
- **A formal release** is built from an immutable `vX.Y.Z` tag (or an explicit commit for local testing) in a
  detached git worktree, with its own persistent directory, and never reads the primary working tree:

```text
~/Library/Application Support/LintRelease/        ($LINT_RELEASE_ROOT)
  vX.Y.Z/<commit-sha>/
    worktree/    detached checkout of the release commit
    artifacts/   Lint-X.Y.Z-macOS-<arch>.dmg, .dmg.sha256 (after finalizing), release-state.json,
                 notarization-submit.json, notarization-log.json (Invalid only)
    logs/        start-*.log, resume-*.log
```

Entry points:

| Command | What it does |
|---|---|
| `Scripts/formal-release.sh start vX.Y.Z` | checks the tag (format, on `origin/main`, matches `Info.plist`), creates the worktree, runs that commit's `release.sh` |
| `Scripts/formal-release.sh status [vX.Y.Z]` | prints the local state files; never contacts Apple |
| `Scripts/formal-release.sh resume <vX.Y.Z or state>` | runs the release commit's `resume-release.sh` |
| `Scripts/formal-release.sh cleanup vX.Y.Z [--commit sha] [--worktree-only] [--discard-pending]` | explicit removal; refuses unfinished releases |
| `Scripts/release.sh` | build, sign, DMG, submit; notarizing requires `LINT_RELEASE_OUTPUT_DIR` (absolute, new or empty) |
| `Scripts/resume-release.sh <release-state.json>` | `release.sh --resume`: SHA check, `notarytool info`, staple, verify |

## Notarization invariants (do not weaken)

- The DMG is submitted without `--wait`; the submission ID and the DMG's SHA-256 are written to
  `release-state.json` **before** waiting. A notarytool client timeout (exit 124) is **not** a rejection.
- Exit codes of `release.sh` / `resume-release.sh` / `formal-release.sh`: `0` done, `75` PENDING (In Progress),
  `65` Invalid/Rejected, `69` submission exists but its status could not be read, `1` error.
- After submission the DMG is immutable. Never delete it while pending, never rebuild a DMG to resume a
  submission, never staple a file whose SHA-256 differs from `dmgSHA256`. Resume checks the hash before asking
  Apple and staples a verified copy in `artifacts/.finalize/`, renamed into place only after every check.
- `release-state.json` (schemaVersion 1): string values only, written atomically; it never holds keys,
  certificates or passwords, and `.p8`/`.p12` files never go into a release directory.
- Keep every existing check: Developer ID Application only, TeamIdentifier, Hardened Runtime, secure timestamp,
  entitlements equal `Resources/Lint.entitlements` without `get-task-allow`, nested llama.cpp signing, runtime
  manifest, DMG signature, `hdiutil verify`, Gatekeeper (`spctl`), `stapler validate`, SHA-256.
  `InstallScriptTests.testReleaseScriptStillEnforcesTheExistingChecks` guards the strings.
- Local signing on the maintainer's Mac: the one Developer ID identity is listed several times, so pass
  `LINT_KEYCHAIN=~/Library/Keychains/login.keychain-db`.

## GitHub Actions

- `ci.yml`: PRs and `main`; tests and an unsigned preview DMG; no secrets, read-only. Never add release secrets.
- `release.yml`: exact `vX.Y.Z` tags only (suffixed tags are hand-published previews). If Apple answers in time it
  drafts the release; if still In Progress it uploads the exact DMG + state as `pending-release-<tag>`, checks
  the round trip with `cmp`, reports NOTARIZATION PENDING and exits successfully. It refuses to rebuild a tag
  that has a pending artifact.
- `resume-release.yml`: `workflow_dispatch` with `tag`, `run_id`, `dmg_sha256`; downloads that run's artifact,
  ties the state to the tag, commit and hash, then resumes. It never builds, signs or submits.
- Concurrency is per tag (`release-<tag>`), shared by both workflows; other tags and CI are never blocked.
- The in-app updater (`Sources/LintCore/Update`, since 0.5.2) reads `/releases/latest`, so publishing a release (not a
  Draft or Pre-release) ships it to installed copies. It only accepts `Lint-X.Y.Z-macOS-<arch>.dmg` whose SHA-256
  matches GitHub's asset digest and the `.sha256` asset, containing `app.lint.assistant` signed by team `N964GDJY6A`
  (Developer ID, Hardened Runtime). Each release also carries the same DMG as `Lint-macOS-<arch>.dmg` for the
  fixed link `/releases/latest/download/Lint-macOS-arm64.dmg`; it has no version, so the updater ignores it. Keep the
  asset names, and publish only after the DMG was checked.
- Agents do not push release tags, publish GitHub Releases or submit to Apple unless explicitly asked.

## Models already evaluated and not adopted

- **GEC T5 Small (`Unbabel/gec-t5_small`) for Proofread**, 2026-09-28: `llama-server` cannot run encoder-decoder
  models, it left 22 of 86 errors against Gemma 4 E4B's 4, and it changed meanings. Not added to the app. Read
  [docs/GEC-T5-EVALUATION.md](docs/GEC-T5-EVALUATION.md) before proposing a GEC or T5-style model again; its
  evaluation engine (`LINT_EVAL_ENGINE=gec`) is kept for measuring one.
