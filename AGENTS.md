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

## `dist/` is not scratch space

`dist/Lint.app` and `dist/release/` hold builds the maintainer keeps. Do not delete or regenerate them unless
asked: `package-app.sh` wipes `dist/Lint.app` and `release.sh` without `LINT_RELEASE_OUTPUT_DIR` wipes
`dist/release/`. For a check, build into a scratch directory (`LINT_DIST_DIR=…`, `LINT_RELEASE_OUTPUT_DIR=…`).

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
- Agents do not push release tags, publish GitHub Releases or submit to Apple unless explicitly asked.
