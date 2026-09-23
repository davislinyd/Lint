#!/bin/bash
# Formal releases on this Mac, built from an immutable tag (or, for local testing, an explicit commit) in
# a dedicated git worktree, with a persistent directory per release that survives a long notarization.
# Normal development in the repository this is run from continues untouched: the release never reads its
# working tree, and nothing here changes its branches, files or tags.
#
#   Scripts/formal-release.sh start vX.Y.Z             build, sign, submit; finalize if Apple answers in time
#   Scripts/formal-release.sh start --commit <rev>     the same from an untagged commit (local testing)
#   Scripts/formal-release.sh status [vX.Y.Z]          what is recorded locally (does not contact Apple)
#   Scripts/formal-release.sh resume <vX.Y.Z | release-state.json>
#   Scripts/formal-release.sh cleanup vX.Y.Z [--commit <sha>] [--worktree-only] [--discard-pending]
#
# Layout ($LINT_RELEASE_ROOT, default ~/Library/Application Support/LintRelease):
#   vX.Y.Z/<commit>/worktree/    detached checkout of the commit; the build runs here
#   vX.Y.Z/<commit>/artifacts/   the DMG, release-state.json, notarytool records, the final .sha256
#   vX.Y.Z/<commit>/logs/        one log per start or resume
#
# The build and the resume run the scripts of the release commit (in its worktree), with the environment
# Scripts/release.sh documents (CODESIGN_IDENTITY, APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID,
# APPLE_TEAM_ID, LINT_BUILD_NUMBER, LINT_NOTARY_TIMEOUT, LINT_SKIP_NOTARIZE, LINT_PREVIEW_BUILD).
# Exit codes are those of release.sh: 0 done, 1 error, 65 Invalid, 69 status unavailable, 75 PENDING.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
RELEASE_ROOT=${LINT_RELEASE_ROOT:-$HOME/Library/Application Support/LintRelease}
RELEASE_ROOT=${RELEASE_ROOT%/}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
field() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; } # field <key> <release-state.json>

usage() {
  sed -n '/^#   Scripts/p' "$0" | sed 's/^#   /usage: /' >&2
  exit 1
}

git_repo() { git -C "$REPO" "$@"; }

valid_name() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

version_at() { # version_at <commit>: CFBundleShortVersionString of that commit, read from git
  git_repo show "$1:Resources/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null \
    || die "cannot read Resources/Info.plist at $1"
}

# A release that Apple may still hold a ticket for, or that is being stapled.
unfinished() { case "$(field releaseStatus "$1")" in built|pending|finalizing) return 0 ;; *) return 1 ;; esac; }

# The worktree is a detached checkout of exactly the release commit. It is recreated from git when it is
# missing, and refused when it is at another commit or has local changes.
ensure_worktree() { # ensure_worktree <dir> <commit>
  local dir="$1/worktree" commit="$2"
  if [ ! -e "$dir" ]; then
    git_repo worktree add --detach "$dir" "$commit" >&2 || die "cannot create the release worktree at $dir"
  fi
  [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ] || die "$dir is not a checkout of $commit"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=normal)" ] || die "$dir has local changes; a release worktree is never edited"
  grep -q 'LINT_RELEASE_OUTPUT_DIR' "$dir/Scripts/release.sh" 2>/dev/null \
    || die "commit $commit predates resumable releases (its Scripts/release.sh has no LINT_RELEASE_OUTPUT_DIR)"
}

run_logged() { # run_logged <log> <command...>: the command's exit code, with its output also in <log>
  local log="$1" rc
  shift
  set +e
  "$@" 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

report() { # report <exit code> <state file>
  case "$1" in
    0) echo "==> release finished: $(field releaseStatus "$2")" ;;
    75) echo "==> NOTARIZATION PENDING. Nothing was deleted. Check again later with:"
        echo "    Scripts/formal-release.sh resume $2" ;;
    69) echo "==> the notarization status could not be read; the submission is recorded. Resume later with:"
        echo "    Scripts/formal-release.sh resume $2" ;;
    65) echo "==> Apple rejected the submission; see $(dirname "$2")/notarization-log.json" ;;
    *) echo "==> the release stopped with an error (exit code $1); see the log above" ;;
  esac
}

cmd_start() {
  local tag="" commit version name dir state other rc log
  case "${1:-}" in
    --commit)
      [ $# -eq 2 ] || usage
      commit=$(git_repo rev-parse --verify --quiet "$2^{commit}") || die "'$2' is not a commit in $REPO"
      ;;
    v*)
      [ $# -eq 1 ] || usage
      tag=$1
      valid_name "$tag" || die "'$tag' is not a release tag (expected vMAJOR.MINOR.PATCH)"
      commit=$(git_repo rev-parse --verify --quiet "refs/tags/$tag^{commit}") \
        || die "tag $tag does not exist in $REPO (git fetch --tags)"
      git_repo rev-parse --verify --quiet refs/remotes/origin/main >/dev/null \
        || die "origin/main is unknown in $REPO; run git fetch origin"
      git_repo merge-base --is-ancestor "$commit" refs/remotes/origin/main \
        || die "$tag ($commit) is not reachable from origin/main; releases are only cut from main (git fetch origin?)"
      ;;
    *) usage ;;
  esac
  version=$(version_at "$commit")
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Resources/Info.plist at $commit has version '$version'"
  if [ -n "$tag" ] && [ "${tag#v}" != "$version" ]; then
    die "Version mismatch: tag $tag is ${tag#v}, Resources/Info.plist at $commit is $version"
  fi
  name="v$version"
  dir="$RELEASE_ROOT/$name/$commit"

  # One submission per version at a time, and a release directory is never reused.
  for other in "$RELEASE_ROOT/$name"/*/artifacts/release-state.json; do
    [ -f "$other" ] || continue
    if [ "$other" != "$dir/artifacts/release-state.json" ] && unfinished "$other"; then
      die "$name already has an unfinished release ($(field releaseStatus "$other")): $other." \
        "Resume it (Scripts/formal-release.sh resume $other) or clean it up explicitly first."
    fi
  done
  if [ -d "$dir/artifacts" ] && [ -n "$(ls -A "$dir/artifacts")" ]; then
    die "$dir/artifacts already holds a release. Check it with: Scripts/formal-release.sh status $name;" \
      "resume it, or remove it with: Scripts/formal-release.sh cleanup $name --commit $commit"
  fi

  mkdir -p "$dir/logs"
  ensure_worktree "$dir" "$commit"
  # The pinned llama.cpp archives are verified by hash on every use, so a copy of the development cache
  # only saves the download; the development checkout's cache itself is only read.
  if [ -d "$REPO/.build/llama-runtime/cache" ] && [ ! -e "$dir/worktree/.build/llama-runtime/cache" ]; then
    mkdir -p "$dir/worktree/.build/llama-runtime"
    ditto "$REPO/.build/llama-runtime/cache" "$dir/worktree/.build/llama-runtime/cache"
  fi

  state="$dir/artifacts/release-state.json"
  log="$dir/logs/start-$(date -u +%Y%m%dT%H%M%SZ).log"
  echo "==> $name${tag:+ (tag $tag)} from $commit"
  echo "    worktree  $dir/worktree"
  echo "    artifacts $dir/artifacts"
  echo "    log       $log"
  rc=0
  run_logged "$log" env LINT_RELEASE_OUTPUT_DIR="$dir/artifacts" LINT_RELEASE_TAG="$tag" LINT_RELEASE_COMMIT="$commit" \
    "$dir/worktree/Scripts/release.sh" || rc=$?
  report "$rc" "$state"
  return "$rc"
}

find_state() { # find_state <vX.Y.Z | release-state.json>
  local matches=() f
  if [ -f "$1" ]; then
    (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")")
    return 0
  fi
  valid_name "$1" || die "'$1' is neither a release-state.json nor a version like v1.2.3"
  for f in "$RELEASE_ROOT/$1"/*/artifacts/release-state.json; do
    if [ -f "$f" ]; then matches+=("$f"); fi
  done
  [ "${#matches[@]}" -gt 0 ] || die "no release of $1 under $RELEASE_ROOT"
  [ "${#matches[@]}" -eq 1 ] || die "$1 has several releases; pass the release-state.json to use: ${matches[*]}"
  printf '%s\n' "${matches[0]}"
}

cmd_resume() {
  [ $# -eq 1 ] || usage
  local state dir commit rc log
  state=$(find_state "$1")
  dir=$(dirname "$(dirname "$state")")
  commit=$(field commit "$state")
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$state has no clean commit"
  git_repo cat-file -e "$commit^{commit}" 2>/dev/null || die "commit $commit is not in $REPO"
  mkdir -p "$dir/logs"
  ensure_worktree "$dir" "$commit"
  log="$dir/logs/resume-$(date -u +%Y%m%dT%H%M%SZ).log"
  echo "==> resuming $state"
  echo "    log $log"
  rc=0
  run_logged "$log" "$dir/worktree/Scripts/resume-release.sh" "$state" || rc=$?
  report "$rc" "$state"
  return "$rc"
}

cmd_status() {
  local pattern="*" f found=""
  if [ $# -eq 1 ]; then
    valid_name "$1" || die "'$1' is not a version like v1.2.3"
    pattern=$1
  elif [ $# -gt 1 ]; then
    usage
  fi
  for f in "$RELEASE_ROOT"/$pattern/*/artifacts/release-state.json; do
    [ -f "$f" ] || continue
    found=1
    printf '%s  %s  %-17s notarization: %-12s submission: %s  checked: %s\n    %s\n' \
      "$(field version "$f")" "$(field commit "$f" | cut -c1-12)" "$(field releaseStatus "$f")" \
      "$(field notarizationStatus "$f")" "$(field submissionID "$f")" "$(field lastCheckedAt "$f")" "$f"
  done
  [ -n "$found" ] || echo "no releases under $RELEASE_ROOT"
}

remove_worktree() { # remove_worktree <release dir>
  local wt="$1/worktree"
  [ -e "$wt" ] || return 0
  git_repo worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  git_repo worktree prune
  echo "    removed $wt"
}

cmd_cleanup() {
  local name="" commit="" worktree_only="" discard="" dirs=() d state
  [ $# -ge 1 ] || usage
  name=$1
  shift
  valid_name "$name" || die "'$name' is not a version like v1.2.3"
  while [ $# -gt 0 ]; do
    case "$1" in
      --commit) [ $# -ge 2 ] || usage; commit=$2; shift ;;
      --worktree-only) worktree_only=1 ;;
      --discard-pending) discard=1 ;;
      *) usage ;;
    esac
    shift
  done
  case "$RELEASE_ROOT" in /?*) ;; *) die "LINT_RELEASE_ROOT must be an absolute path" ;; esac
  if [ -n "$commit" ]; then
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "--commit takes the full 40-character commit SHA"
    [ -d "$RELEASE_ROOT/$name/$commit" ] || die "no release directory $RELEASE_ROOT/$name/$commit"
    dirs=("$RELEASE_ROOT/$name/$commit")
  else
    for d in "$RELEASE_ROOT/$name"/*; do
      if [ -d "$d" ]; then dirs+=("$d"); fi
    done
    [ "${#dirs[@]}" -gt 0 ] || die "no release directories for $name under $RELEASE_ROOT"
  fi
  # Refuse before touching anything.
  if [ -z "$worktree_only" ] && [ -z "$discard" ]; then
    for d in "${dirs[@]}"; do
      state="$d/artifacts/release-state.json"
      if [ -f "$state" ] && unfinished "$state"; then
        die "$d is $(field releaseStatus "$state") (submission $(field submissionID "$state"))." \
          "Its DMG and state are kept until it is finalized. Resume it, or pass --discard-pending to abandon it."
      fi
    done
  fi
  for d in "${dirs[@]}"; do
    echo "==> $d"
    remove_worktree "$d"
    if [ -z "$worktree_only" ]; then
      rm -rf "$d"
      echo "    removed $d"
    fi
  done
  rmdir "$RELEASE_ROOT/$name" 2>/dev/null || true
}

git_repo rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"
command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  start) cmd_start "$@" ;;
  resume) cmd_resume "$@" ;;
  status) cmd_status "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  *) usage ;;
esac
