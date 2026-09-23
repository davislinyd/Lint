#!/bin/bash
# Build, sign, notarize and package Lint as a Developer ID DMG (or, with LINT_PREVIEW_BUILD=1, an
# unsigned preview). Runs on a Mac, locally or in GitHub Actions (.github/workflows/release.yml and
# ci.yml); it does not create the GitHub Release.
#
# Environment (optional unless noted):
#   LINT_RELEASE_TAG       vX.Y.Z; must match CFBundleShortVersionString in Resources/Info.plist.
#   LINT_BUILD_NUMBER      CFBundleVersion stamped on the assembled app (CI: github.run_number).
#   CODESIGN_IDENTITY      "Developer ID Application" identity (name or SHA-1); detected when only one exists.
#   LINT_KEYCHAIN          Keychain file to search and sign with (CI uses a temporary one).
#   APPLE_TEAM_ID          If set, the signature's TeamIdentifier must equal it.
#   APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#                          App Store Connect Team API key for notarytool (required unless skipping).
#   LINT_SKIP_NOTARIZE=1   Packaging-only dry run: nothing is sent to Apple and the DMG is named
#                          "...-unnotarized.dmg" so it cannot be mistaken for a release.
#   LINT_PREVIEW_BUILD=1   Unsigned preview for when no Developer ID exists: ad-hoc signature (with Hardened
#                          Runtime), no Apple services, DMG named "...-preview.dmg". macOS warns on first open
#                          and the Accessibility permission must be granted again after every update. Not a release.
#
# The app bundles the pinned llama.cpp runtime (Resources/LlamaRuntimeManifest.json; fetched and hash-verified by
# Scripts/fetch-llama-runtime.sh, signed inside-out by Scripts/sign-llama-runtime.sh, both driven by
# package-app.sh). Its signatures are checked here, in the built app and again in the app inside the DMG.
#
# Output:
#   default                    dist/release/ (Lint.app, the DMG and its .sha256), wiped first. Previews and
#                              LINT_SKIP_NOTARIZE dry runs only: a notarized build never goes there.
#   LINT_RELEASE_OUTPUT_DIR    An absolute, new or empty directory that holds this one build: the DMG,
#                              release-state.json, the notarytool records and, once finalized, the .sha256.
#                              Required to notarize. It is never wiped or reused, because after submission
#                              the DMG in it is the exact file Apple has a ticket for.
#
# Notarization (formal releases), resumable:
#   LINT_RELEASE_COMMIT    Optional full commit SHA the checkout must be at (Scripts/formal-release.sh sets it).
#   LINT_NOTARY_TIMEOUT    How long to wait for Apple before reporting PENDING (default 45m, notarytool syntax).
#   The DMG is uploaded without waiting, its submission ID and SHA-256 are written to release-state.json at
#   once, and only then does the script wait. Reaching the timeout (notarytool exits 124) is not a rejection:
#   the status is asked again and "In Progress" ends the run as PENDING with the DMG left untouched.
#   Continue later with Scripts/resume-release.sh <release-state.json>, which staples that exact DMG; a
#   rebuilt DMG is a different file and must never be stapled with an old submission ID.
#
# Exit codes: 0 done (finalized, preview or dry run) · 1 error · 65 Apple rejected the submission (Invalid)
#             · 69 a submission exists but its status could not be read (resume later) · 75 PENDING.
#
# Resume mode (what Scripts/resume-release.sh runs): release.sh --resume <release-state.json>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BUNDLE_ID="app.lint.assistant"
IDENTITY_KIND="Developer ID Application"
EXIT_INVALID=65
EXIT_UNREACHABLE=69
EXIT_PENDING=75
STATE_SCHEMA=1
# release-state.json: every value is a string (empty when unknown), plus the integer schemaVersion.
# It never holds keys, certificates, passwords or any other secret.
STATE_KEYS="version tag commit architecture buildNumber dmgFileName dmgPath dmgSHA256 dmgCreatedAt
  submissionID submissionCreatedAt notarizationStatus lastCheckedAt releaseStatus finalSHA256 finalizedAt"

case "${LINT_SKIP_NOTARIZE:-}" in
  ''|0) SKIP_NOTARIZE= ;;
  1) SKIP_NOTARIZE=1 ;;
  *) echo "error: LINT_SKIP_NOTARIZE must be 1 or unset, got '$LINT_SKIP_NOTARIZE'" >&2; exit 1 ;;
esac

case "${LINT_PREVIEW_BUILD:-}" in
  ''|0) PREVIEW= ;;
  1) PREVIEW=1 ;;
  *) echo "error: LINT_PREVIEW_BUILD must be 1 or unset, got '$LINT_PREVIEW_BUILD'" >&2; exit 1 ;;
esac
if [ -n "$PREVIEW" ]; then
  [ -z "$SKIP_NOTARIZE" ] || { echo "error: LINT_PREVIEW_BUILD and LINT_SKIP_NOTARIZE are separate dry runs; set only one" >&2; exit 1; }
  SKIP_NOTARIZE=1 # a preview never uses Apple's services
fi

MODE=build
if [ -n "${LINT_RELEASE_OUTPUT_DIR:-}" ]; then
  OUT=${LINT_RELEASE_OUTPUT_DIR%/}
  DEDICATED_OUT=1
else
  OUT="$ROOT/dist/release"
  DEDICATED_OUT=
fi
NOTARY_TIMEOUT=${LINT_NOTARY_TIMEOUT:-45m}
BUILD_NUMBER=${LINT_BUILD_NUMBER:-}
RES="$ROOT/Resources" # what the app is verified against; in resume mode, the submitted commit's copy

VERSION=""; IDENTITY=""; IDENTITY_NAME=""; ARCH=""; DMG=""; APP=""
STATE_FILE="" # release-state.json; only with LINT_RELEASE_OUTPUT_DIR or in resume mode
WORK=""     # scratch directory, removed on exit
MOUNT=""    # mount point of the DMG while it is attached
for key in $STATE_KEYS; do printf -v "st_$key" '%s' ""; done

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
has() { grep -Eq -- "$1" <<<"$2"; }
stop() { local code="$1"; shift; printf '%s\n' "$@" >&2; exit "$code"; } # exit with a code a caller can act on
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
json_value() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; } # json_value <key> <file>; empty if absent
json_part() { sed -n '/^[[:space:]]*{/,$p' "$1" >"$2"; } # notarytool may print text before its JSON

# Written to a temporary file in the same directory and renamed over the old state, so a reader (or a
# crash) never sees a half-written file.
write_state() {
  [ -n "$STATE_FILE" ] || return 0
  local tmp="$STATE_FILE.tmp.$$" key var value
  {
    printf '{\n  "schemaVersion": %s' "$STATE_SCHEMA"
    for key in $STATE_KEYS; do
      var="st_$key"
      value=${!var}
      case "$value" in *[[:cntrl:]]*) rm -f "$tmp"; die "refusing to write a control character into $key" ;; esac
      value=${value//\\/\\\\}
      value=${value//\"/\\\"}
      printf ',\n  "%s": "%s"' "$key" "$value"
    done
    printf '\n}\n'
  } >"$tmp"
  plutil -convert xml1 -o /dev/null "$tmp" || { rm -f "$tmp"; die "wrote an invalid release state"; }
  mv -f "$tmp" "$STATE_FILE"
}

load_state() {
  local key value
  [ -f "$STATE_FILE" ] || die "no release state at $STATE_FILE"
  [ "$(json_value schemaVersion "$STATE_FILE")" = "$STATE_SCHEMA" ] \
    || die "$STATE_FILE is not a schemaVersion $STATE_SCHEMA release state"
  for key in $STATE_KEYS; do
    value=$(plutil -extract "$key" raw -o - "$STATE_FILE" 2>/dev/null) || die "$STATE_FILE has no '$key'"
    printf -v "st_$key" '%s' "$value"
  done
}

cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

retry() { # retry <attempts> <delay-seconds> <command...>
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    [ "$n" -lt "$attempts" ] || return 1
    printf '   attempt %s/%s failed; retrying in %ss\n' "$n" "$attempts" "$delay" >&2
    n=$((n + 1))
    sleep "$delay"
  done
}

require_tools() {
  [ "$(uname -s)" = "Darwin" ] || die "release.sh must run on macOS"
  local tool missing=""
  for tool in swift security codesign hdiutil ditto shasum lipo plutil spctl xcrun file; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -x /usr/libexec/PlistBuddy ] || missing="$missing PlistBuddy"
  if [ -z "$SKIP_NOTARIZE" ]; then
    xcrun --find notarytool >/dev/null 2>&1 || missing="$missing notarytool"
    xcrun --find stapler >/dev/null 2>&1 || missing="$missing stapler"
  fi
  [ -z "$missing" ] || die "missing required tools:$missing"
  if [ -n "${LINT_KEYCHAIN:-}" ] && [ ! -f "$LINT_KEYCHAIN" ]; then
    die "LINT_KEYCHAIN does not point to a keychain file"
  fi
}

check_output_dir() {
  if [ -n "$DEDICATED_OUT" ]; then
    case "$OUT" in /*) ;; *) die "LINT_RELEASE_OUTPUT_DIR must be an absolute path" ;; esac
    if [ -e "$OUT" ]; then
      [ -d "$OUT" ] || die "LINT_RELEASE_OUTPUT_DIR ($OUT) is not a directory"
      [ -z "$(ls -A "$OUT")" ] || die "LINT_RELEASE_OUTPUT_DIR ($OUT) is not empty. A release directory is never reused or" \
        "overwritten, because it may hold a submitted DMG. Use a new directory, or resume that release:" \
        "Scripts/resume-release.sh $OUT/release-state.json"
    fi
  elif [ -z "$SKIP_NOTARIZE" ]; then
    die "a notarized release needs its own directory: set LINT_RELEASE_OUTPUT_DIR (Scripts/formal-release.sh does)." \
      "dist/release is wiped by every build, so it only takes previews and LINT_SKIP_NOTARIZE=1 dry runs."
  fi
  case "$NOTARY_TIMEOUT" in *[!0-9smh]*|'') die "LINT_NOTARY_TIMEOUT must look like 45m, 2h or 600" ;; esac
}

# The commit being built. A notarized release comes from a clean checkout of exactly that commit (and of
# its tag), recorded in the state before anything else happens; previews and dry runs may come from a
# work in progress, which the state marks with "-dirty".
resolve_source() {
  local commit="" dirty="" tagged
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    commit=$(git -C "$ROOT" rev-parse HEAD)
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ] || dirty=1
  fi
  if [ -n "${LINT_RELEASE_COMMIT:-}" ]; then
    [ "$LINT_RELEASE_COMMIT" = "$commit" ] || die "the checkout is at '${commit:-no git commit}', not LINT_RELEASE_COMMIT $LINT_RELEASE_COMMIT"
  fi
  if [ -z "$SKIP_NOTARIZE" ]; then
    [ -n "$commit" ] || die "a notarized release must be built from a git checkout of its commit"
    [ -z "$dirty" ] || die "the checkout has uncommitted or untracked changes; a notarized release is built from a clean commit"
    if [ -n "${LINT_RELEASE_TAG:-}" ]; then
      tagged=$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$LINT_RELEASE_TAG^{commit}") \
        || die "tag $LINT_RELEASE_TAG does not exist in this checkout"
      [ "$tagged" = "$commit" ] || die "tag $LINT_RELEASE_TAG is $tagged, but the checkout is at $commit"
    fi
  fi
  st_commit="$commit${dirty:+-dirty}"
  st_tag=${LINT_RELEASE_TAG:-}
}

check_notary_inputs() {
  if [ -n "$SKIP_NOTARIZE" ]; then return 0; fi
  [ -n "${APPLE_API_KEY_PATH:-}" ] || die "APPLE_API_KEY_PATH is required to notarize (LINT_SKIP_NOTARIZE=1 does a packaging-only dry run)"
  [ -n "${APPLE_API_KEY_ID:-}" ] || die "APPLE_API_KEY_ID is required to notarize"
  [ -n "${APPLE_API_ISSUER_ID:-}" ] || die "APPLE_API_ISSUER_ID is required to notarize"
  [ -f "$APPLE_API_KEY_PATH" ] || die "APPLE_API_KEY_PATH is not a file"
}

read_version() {
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist") \
    || die "cannot read CFBundleShortVersionString from Resources/Info.plist"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString '$VERSION' is not MAJOR.MINOR.PATCH"
  if [ -n "${LINT_RELEASE_TAG:-}" ]; then
    [[ "$LINT_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "LINT_RELEASE_TAG '$LINT_RELEASE_TAG' must look like v1.2.3"
    [ "${LINT_RELEASE_TAG#v}" = "$VERSION" ] \
      || die "Version mismatch: tag $LINT_RELEASE_TAG is ${LINT_RELEASE_TAG#v}, Resources/Info.plist is $VERSION"
  fi
}

list_identities() { # list_identities [-v]
  if [ -n "${LINT_KEYCHAIN:-}" ]; then
    security find-identity "$@" -p codesigning "$LINT_KEYCHAIN"
  else
    security find-identity "$@" -p codesigning
  fi
}

resolve_identity() {
  local all matches count
  all=$(list_identities -v || true)
  matches=$(grep -E '^ *[0-9]+\) ' <<<"$all" | grep -F "\"$IDENTITY_KIND: " || true)
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    matches=$(grep -i -F -- "$CODESIGN_IDENTITY" <<<"$matches" || true)
  fi
  count=$(grep -c . <<<"$matches" || true)
  if [ "$count" = "0" ]; then
    {
      echo "error: no valid '$IDENTITY_KIND' code signing identity found${LINT_KEYCHAIN:+ in $LINT_KEYCHAIN}."
      echo "Release builds never fall back to another kind of identity. Valid identities present:"
      { grep -E '^ *[0-9]+\) ' <<<"$all" || echo "(none)"; } | sed 's/^/  /'
      echo "'$IDENTITY_KIND' identities that exist but are not valid (untrusted chain, expired or revoked):"
      { list_identities | grep -F "\"$IDENTITY_KIND: " | grep -F '(CSSMERR_' || echo "(none)"; } | sed 's/^/  /'
    } >&2
    exit 1
  elif [ "$count" != "1" ]; then
    {
      echo "error: $count '$IDENTITY_KIND' identities match; set CODESIGN_IDENTITY to the SHA-1 of the one to use:"
      sed 's/^/  /' <<<"$matches"
    } >&2
    exit 1
  fi
  IDENTITY=$(awk '{print $2}' <<<"$matches")
  IDENTITY_NAME=$(sed -E 's/^[^"]*"([^"]*)".*/\1/' <<<"$matches")
}

# dist/release is wiped as before. A dedicated directory is only created: the app is assembled in the
# scratch directory, so the release directory holds nothing but what is kept.
prepare_output() {
  if [ -n "$DEDICATED_OUT" ]; then
    mkdir -p "$OUT"
    STATE_FILE="$OUT/release-state.json"
    APP="$WORK/app/Lint.app"
  else
    rm -rf "$OUT"
    mkdir -p "$OUT"
    APP="$OUT/Lint.app"
  fi
}

build_app() {
  local dist
  dist=$(dirname "$APP")
  if [ -n "$PREVIEW" ]; then
    # LINT_RELEASE_BUILD=0 keeps a stray value in the environment from switching package-app.sh to its
    # strict Developer ID mode. The second signature only adds Hardened Runtime, so the preview
    # runs under the same restrictions as a release.
    LINT_RELEASE_BUILD=0 LINT_DIST_DIR="$dist" CODESIGN_IDENTITY=- ./Scripts/package-app.sh release >/dev/null
    codesign --force --options runtime --sign - --entitlements "$ROOT/Resources/Lint.entitlements" "$APP"
  else
    LINT_RELEASE_BUILD=1 LINT_DIST_DIR="$dist" CODESIGN_IDENTITY="$IDENTITY" ./Scripts/package-app.sh release >/dev/null
  fi
  [ -d "$APP" ] || die "package-app.sh did not produce $APP"
}

detect_arch() {
  local archs suffix=""
  archs=$(lipo -archs "$APP/Contents/MacOS/Lint") || die "cannot read the executable's architectures"
  case " $archs " in
    " arm64 ") ARCH=arm64 ;;
    " x86_64 ") ARCH=x86_64 ;;
    " arm64 x86_64 "|" x86_64 arm64 ") ARCH=universal ;;
    *) die "unsupported executable architectures: '$archs'" ;;
  esac
  if [ -n "$PREVIEW" ]; then suffix="-preview"; elif [ -n "$SKIP_NOTARIZE" ]; then suffix="-unnotarized"; fi
  DMG="$OUT/Lint-$VERSION-macOS-$ARCH$suffix.dmg"
}

# What package-app.sh must have put in the app besides the executable. A missing SwiftPM resource
# bundle crashes the Writing tab at runtime (Bundle.module), and nothing else would notice.
verify_app_resources() {
  local app="$1" lproj
  [ -f "$app/Contents/PkgInfo" ] || die "the app has no PkgInfo"
  [ -f "$app/Contents/Resources/AppIcon.icns" ] || die "the app has no icon"
  for lproj in "$RES"/*.lproj; do
    [ -f "$app/Contents/Resources/$(basename "$lproj")/Localizable.strings" ] \
      || die "the app is missing $(basename "$lproj")/Localizable.strings"
  done
  ls -d "$app"/Contents/Resources/*.bundle >/dev/null 2>&1 || die "the app has no SwiftPM resource bundles (KeyboardShortcuts, GRDB)"
}

# The bundled llama.cpp runtime lives in Contents/Resources, where `codesign --deep` does not look for
# nested code, yet the notary service rejects an app that ships unsigned or differently signed
# executables. So every Mach-O in the app other than the main executable is checked on its own: it
# must be a thin binary of the app's architecture with a valid signature and, for a release, the same
# Developer ID team, Hardened Runtime and a secure timestamp (an ad-hoc one in a preview). The runtime
# must also be the pinned upstream build and carry its license notices.
verify_llama_runtime() {
  local app="$1" rt manifest="$RES/LlamaRuntimeManifest.json"
  local main_team file rel info archs count=0 want got first_authority
  rt="$app/Contents/Resources/LlamaRuntime/$ARCH" # not in the `local` line: bash 3.2 cannot see $app there
  [ -d "$rt" ] || die "the app has no bundled llama.cpp runtime for $ARCH (Contents/Resources/LlamaRuntime/$ARCH)"
  [ -x "$rt/llama-server" ] || die "the bundled llama-server is missing or not executable"
  [ -f "$rt/runtime-info.json" ] || die "the bundled runtime has no runtime-info.json"
  ls "$rt"/licenses/LICENSE* >/dev/null 2>&1 || die "the bundled runtime has no license notice (Contents/Resources/LlamaRuntime/$ARCH/licenses)"
  got=$(plutil -extract architecture raw -o - "$rt/runtime-info.json") || die "cannot read runtime-info.json"
  [ "$got" = "$ARCH" ] || die "runtime-info.json says $got, the app is $ARCH"
  for want in "tag:upstream.tag" "archiveSHA256:runtimes.$ARCH.sha256"; do
    got=$(plutil -extract "${want%%:*}" raw -o - "$rt/runtime-info.json") || die "runtime-info.json has no ${want%%:*}"
    [ "$got" = "$(plutil -extract "${want#*:}" raw -o - "$manifest")" ] \
      || die "the bundled runtime's ${want%%:*} does not match Resources/LlamaRuntimeManifest.json"
  done

  main_team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  while IFS= read -r -d '' file; do
    case "$file" in "$app/Contents/MacOS/"*) continue ;; esac
    file -b "$file" | grep -q 'Mach-O' || continue
    rel=${file#"$app/"}
    count=$((count + 1))
    archs=$(lipo -archs "$file") || die "cannot read the architectures of $rel"
    [ "$archs" = "$ARCH" ] || die "$rel is '$archs' but the app is $ARCH; never mix architectures"
    codesign --verify --strict "$file" || die "nested code has an invalid signature: $rel"
    info=$(codesign -dvv "$file" 2>&1) || die "cannot read the signature of $rel"
    if [ -n "$PREVIEW" ]; then
      has '^Signature=adhoc' "$info" || die "$rel must be ad-hoc signed in a preview build"
    else
      first_authority=$(sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$info")
      case "$first_authority" in
        "$IDENTITY_KIND: "*) ;;
        *) die "$rel is signed by '$first_authority', expected a '$IDENTITY_KIND' certificate" ;;
      esac
      has 'flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' "$info" || die "$rel does not have Hardened Runtime"
      has '^Timestamp=' "$info" || die "$rel has no secure timestamp"
      [ "$(sed -n 's/^TeamIdentifier=//p' <<<"$info")" = "$main_team" ] \
        || die "$rel is signed by a different team than the app"
    fi
  done < <(find "$app/Contents" -type f -print0)
  [ "$count" -ge 2 ] || die "found only $count nested executables; the llama.cpp runtime looks incomplete"
  echo "   bundled llama.cpp runtime: $count nested executables verified"
}

# Hard checks on a signed Lint.app (the build output, and again the copy inside the DMG).
verify_app_signature() {
  local app="$1" info first_authority team want got plist v b who
  codesign --verify --deep --strict --verbose=2 "$app" || die "codesign verification failed for $app"
  info=$(codesign -dvv "$app" 2>&1) || die "cannot read the signature of $app"
  has "^Identifier=$BUNDLE_ID\$" "$info" || die "the signature Identifier is not $BUNDLE_ID"
  has 'flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' "$info" || die "Hardened Runtime is not enabled"
  if [ -n "$PREVIEW" ]; then
    has '^Signature=adhoc' "$info" || die "a preview build must be ad-hoc signed"
    who="ad-hoc signature"
  else
    first_authority=$(sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$info")
    case "$first_authority" in
      "$IDENTITY_KIND: "*) ;;
      *) die "signed by '$first_authority', expected a '$IDENTITY_KIND' certificate" ;;
    esac
    has '^Timestamp=' "$info" || die "the signature has no secure timestamp"
    team=$(sed -n 's/^TeamIdentifier=//p' <<<"$info")
    case "$team" in ''|'not set') die "the signature has no TeamIdentifier" ;; esac
    if [ -n "${APPLE_TEAM_ID:-}" ] && [ "$team" != "$APPLE_TEAM_ID" ]; then
      die "the signature's TeamIdentifier does not match APPLE_TEAM_ID"
    fi
    who="$first_authority · team $team · secure timestamp"
  fi

  # Only the entitlements declared in Resources/Lint.entitlements, and never get-task-allow
  # (the notary service rejects it).
  want=$(grep -o '<key>[^<]*</key>' "$RES/Lint.entitlements" | sort || true)
  got=$(codesign -d --entitlements :- "$app" 2>/dev/null | grep -o '<key>[^<]*</key>' | sort || true)
  [ "$want" = "$got" ] || die "the signed entitlements differ from Resources/Lint.entitlements"
  if grep -q 'get-task-allow' <<<"$got"; then die "the signature carries get-task-allow"; fi

  plist="$app/Contents/Info.plist"
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  [ "$v" = "$VERSION" ] || die "the app's CFBundleShortVersionString is $v, expected $VERSION"
  if [ -n "$BUILD_NUMBER" ]; then
    b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
    [ "$b" = "$BUILD_NUMBER" ] || die "the app's CFBundleVersion is $b, expected $BUILD_NUMBER"
  fi
  verify_app_resources "$app"
  verify_llama_runtime "$app"
  echo "   $who · Hardened Runtime · version $v"
}

sign_dmg() {
  if [ -n "${LINT_KEYCHAIN:-}" ]; then
    codesign --force --timestamp --keychain "$LINT_KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID.dmg" "$DMG"
  else
    codesign --force --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID.dmg" "$DMG"
  fi
}

# Something (Spotlight, XProtect) often holds a freshly mounted volume for a while, so a plain
# detach can fail with "Resource busy". Nothing writes to the volume at that point, so the last
# attempt uses -force.
detach_volume() {
  retry 3 2 hdiutil detach "$1" -quiet && return 0
  hdiutil detach "$1" -force -quiet
}

# `hdiutil create -srcfolder` unmounts its own temporary volume and intermittently fails with
# "Resource busy", so build the image in steps: blank image, copy, detach, compress.
build_dmg() {
  local rw="$WORK/rw.dmg" vol="$WORK/vol" mb
  mkdir "$vol"
  mb=$(( $(du -sk "$APP" | awk '{print $1}') / 1024 + 20 ))
  hdiutil create -size "${mb}m" -fs HFS+ -volname Lint -ov "$rw" >/dev/null || die "hdiutil create failed"
  hdiutil attach "$rw" -nobrowse -noautoopen -mountpoint "$vol" >/dev/null || die "cannot mount the new disk image"
  MOUNT="$vol"
  ditto "$APP" "$vol/Lint.app"
  ln -s /Applications "$vol/Applications"
  rm -rf "$vol/.fseventsd" "$vol/.Spotlight-V100" "$vol/.Trashes"
  sync
  detach_volume "$vol" || die "cannot unmount the new disk image"
  MOUNT=""
  hdiutil convert "$rw" -format UDZO -ov -o "$DMG" >/dev/null || die "hdiutil convert failed"
  if [ -z "$PREVIEW" ]; then
    sign_dmg || die "cannot sign the DMG"
    codesign --verify --verbose=2 "$DMG" || die "the DMG signature does not verify"
  fi
}

notary() { # notary <subcommand> <args...>: the API key is passed as a path, never written anywhere
  xcrun notarytool "$@" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
}

show_notary_errors() { if [ -s "$1" ]; then sed 's/^/   notarytool: /' "$1" >&2; fi; }

# Upload the DMG without waiting, and record the submission before anything can go wrong: once Apple has
# a submission ID, the DMG in the release directory is the file that ID belongs to.
notarize() {
  local raw="$WORK/notary-submit.out" err="$WORK/notary-submit.err" json="$OUT/notarization-submit.json" rc=0 id
  xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --output-format json >"$raw" 2>"$err" || rc=$?
  json_part "$raw" "$json"
  id=$(json_value id "$json")
  if [ -z "$id" ]; then
    show_notary_errors "$err"
    st_releaseStatus=submission-failed
    write_state
    die "the upload to the notary service failed (notarytool exit code $rc) and no submission ID came back," \
      "so nothing is pending at Apple. Check the API key and the network, then start a new release directory."
  fi
  [[ "$id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "notarytool returned an unexpected submission ID; see $json"
  st_submissionID=$id
  st_submissionCreatedAt=$(now)
  st_lastCheckedAt=$st_submissionCreatedAt
  st_notarizationStatus="In Progress"
  st_releaseStatus=pending
  write_state
  echo "   submission $id recorded in $STATE_FILE"
  echo "   submitted DMG SHA-256 $st_dmgSHA256"

  log "Waiting for Apple (up to $NOTARY_TIMEOUT)"
  rc=0
  notary wait "$id" --timeout "$NOTARY_TIMEOUT" --output-format json >"$WORK/notary-wait.out" 2>"$WORK/notary-wait.err" || rc=$?
  if [ "$rc" = 124 ]; then
    echo "   notarytool stopped waiting after $NOTARY_TIMEOUT (client timeout, exit code 124)."
    echo "   A client timeout is not a rejection; asking Apple for the status."
  elif [ "$rc" != 0 ]; then
    show_notary_errors "$WORK/notary-wait.err"
    echo "   notarytool wait ended with exit code $rc; asking Apple for the status."
  fi
  check_notarization
}

# Ask Apple for the status of the recorded submission. Only "Accepted" returns; every other outcome
# leaves the DMG exactly as it is and exits with its own code.
check_notarization() {
  local raw="$WORK/notary-info.out" err="$WORK/notary-info.err" json="$WORK/notary-info.json" rc=0 status
  local resume_hint="Scripts/resume-release.sh $STATE_FILE"
  notary info "$st_submissionID" --output-format json >"$raw" 2>"$err" || rc=$?
  json_part "$raw" "$json"
  status=$(json_value status "$json")
  if [ "$rc" != 0 ] || [ -z "$status" ]; then
    show_notary_errors "$err"
    stop "$EXIT_UNREACHABLE" "STATUS UNAVAILABLE: could not read the status of submission $st_submissionID (notarytool exit code $rc)." \
      "Nothing was deleted and the submission is still recorded. Check the API key and the network, then resume:" \
      "  $resume_hint"
  fi
  echo "   submission $st_submissionID · status $status"
  st_lastCheckedAt=$(now)
  case "$status" in
    Accepted)
      st_notarizationStatus=Accepted
      write_state
      ;;
    "In Progress")
      st_notarizationStatus="In Progress"
      write_state
      stop "$EXIT_PENDING" "NOTARIZATION PENDING: Apple is still processing submission $st_submissionID." \
        "This is not a failure. The submitted DMG and its state are kept unchanged:" \
        "  $DMG" "  SHA-256 $st_dmgSHA256" \
        "Resume later with the same DMG (never rebuild it):" "  $resume_hint"
      ;;
    Invalid|Rejected)
      st_notarizationStatus=$status
      echo "   notarization log for $st_submissionID:" >&2
      if notary log "$st_submissionID" "$OUT/notarization-log.json" >/dev/null 2>"$WORK/notary-log.err"; then
        sed 's/^/   /' "$OUT/notarization-log.json" >&2
      else
        show_notary_errors "$WORK/notary-log.err"
        echo "   (the log is not available yet; run: xcrun notarytool log $st_submissionID ...)" >&2
      fi
      st_releaseStatus=invalid
      write_state
      stop "$EXIT_INVALID" "NOTARIZATION REJECTED: Apple returned '$status' for submission $st_submissionID." \
        "The DMG must never be published. Fix the issues in the log, then release a new build."
      ;;
    *)
      stop "$EXIT_UNREACHABLE" "unexpected notarization status '$status' for submission $st_submissionID; nothing was changed." \
        "Resume later: $resume_hint"
      ;;
  esac
}

# The ticket can take a moment to reach Apple's CDN after "Accepted", so stapling is retried.
staple() {
  retry 5 15 xcrun stapler staple "$1" || die "stapler could not attach the notarization ticket"
  xcrun stapler validate "$1" || die "stapler validate failed"
}

# Verify what users will actually receive: the DMG, and the app inside the mounted DMG.
final_checks() {
  local dmg="$1"
  hdiutil verify "$dmg" >/dev/null || die "hdiutil verify failed"
  if [ -z "$PREVIEW" ]; then
    codesign --verify --verbose=2 "$dmg" || die "the DMG signature does not verify"
  fi
  MOUNT="$WORK/mnt"
  mkdir -p "$MOUNT"
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null || die "cannot mount the DMG"
  [ "$(ls "$MOUNT" | tr '\n' ' ')" = "Applications Lint.app " ] || die "the DMG must contain exactly Lint.app and Applications"
  [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || die "the Applications symlink in the DMG does not point to /Applications"
  verify_app_signature "$MOUNT/Lint.app"
  if [ -z "$SKIP_NOTARIZE" ]; then
    xcrun stapler validate "$dmg" || die "stapler validate failed"
    spctl --assess --type execute --verbose=4 "$MOUNT/Lint.app" || die "Gatekeeper rejects Lint.app inside the DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" || die "Gatekeeper rejects the DMG"
  fi
  detach_volume "$MOUNT" || die "cannot unmount the DMG"
  MOUNT=""
}

write_checksum() {
  local name
  name=$(basename "$DMG")
  (cd "$OUT" && shasum -a 256 "$name" >"$name.sha256" && shasum -a 256 -c "$name.sha256" >/dev/null)
}

# Staple the accepted DMG. The submitted file is copied (and the copy's hash checked) inside the release
# directory; the copy is stapled and fully verified, and only then renamed over the original. So a failed
# staple or check leaves the submitted bytes as they were, and a run interrupted after the rename is
# recognized by the finalSHA256 recorded just before it ("finalizing").
finalize() {
  local stage="$OUT/.finalize" staged
  if [ "$st_releaseStatus" = finalizing ] && [ "$(sha256_of "$DMG")" = "$st_finalSHA256" ]; then
    log "Final verification (the stapled DMG is already in place)"
    final_checks "$DMG"
  else
    rm -rf "$stage"
    mkdir "$stage"
    staged="$stage/$(basename "$DMG")"
    cp "$DMG" "$staged"
    [ "$(sha256_of "$staged")" = "$st_dmgSHA256" ] || die "the copy of the submitted DMG does not match its SHA-256"
    log "Stapling the notarization ticket"
    staple "$staged"
    log "Final verification"
    final_checks "$staged"
    st_finalSHA256=$(sha256_of "$staged")
    st_releaseStatus=finalizing
    write_state
    mv -f "$staged" "$DMG"
    rmdir "$stage"
  fi
  log "Checksum"
  write_checksum || die "the SHA-256 self-check failed"
  [ "$(sha256_of "$DMG")" = "$st_finalSHA256" ] || die "the DMG changed while it was being finalized"
  st_releaseStatus=finalized
  st_finalizedAt=$(now)
  write_state
}

record_built_dmg() {
  st_version=$VERSION
  st_architecture=$ARCH
  st_buildNumber=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
  st_dmgFileName=$(basename "$DMG")
  st_dmgPath=$DMG
  st_dmgSHA256=$(sha256_of "$DMG")
  st_dmgCreatedAt=$(now)
  st_releaseStatus=built
  write_state
  if [ -n "$STATE_FILE" ]; then
    echo "   state: $STATE_FILE"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "state=$STATE_FILE" >>"$GITHUB_OUTPUT"; fi
  fi
}

main_build() {
  log "Checking prerequisites"
  require_tools
  check_output_dir
  check_notary_inputs
  read_version
  resolve_source
  echo "   Lint $VERSION${LINT_RELEASE_TAG:+ (tag $LINT_RELEASE_TAG)}${LINT_BUILD_NUMBER:+, build $LINT_BUILD_NUMBER}"
  echo "   commit ${st_commit:-unknown} -> $OUT"
  if [ -n "$PREVIEW" ]; then
    echo "   LINT_PREVIEW_BUILD=1: unsigned preview (ad-hoc signature), nothing is sent to Apple"
  elif [ -n "$SKIP_NOTARIZE" ]; then
    echo "   LINT_SKIP_NOTARIZE=1: packaging-only dry run, nothing is sent to Apple"
  fi

  if [ -z "$PREVIEW" ]; then
    log "Finding the $IDENTITY_KIND identity"
    resolve_identity
    echo "   $IDENTITY_NAME"
  fi

  WORK=$(mktemp -d -t lint-release)
  prepare_output

  log "Building and signing Lint.app"
  build_app
  detect_arch
  echo "   architecture: $ARCH -> $(basename "$DMG")"

  log "Verifying the app signature"
  verify_app_signature "$APP"

  log "Creating and signing the DMG"
  build_dmg
  record_built_dmg

  if [ -z "$SKIP_NOTARIZE" ]; then
    log "Submitting the DMG for notarization"
    notarize
    finalize
  else
    log "Final verification"
    final_checks "$DMG"
    log "Checksum"
    write_checksum || die "the SHA-256 self-check failed"
    st_finalSHA256=$(sha256_of "$DMG")
    if [ -n "$PREVIEW" ]; then st_releaseStatus=preview; else st_releaseStatus=unnotarized; fi
    write_state
  fi

  log "Done"
  echo "   $DMG"
  echo "   $DMG.sha256"
  if [ -n "$PREVIEW" ]; then
    echo "   PREVIEW BUILD: ad-hoc signed and not notarized, so it is not a release"
  elif [ -n "$SKIP_NOTARIZE" ]; then
    echo "   NOT NOTARIZED: dry run only, do not distribute this DMG"
  else
    echo "   FINALIZED: notarized, stapled and verified (submission $st_submissionID)"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "dmg=$DMG"; echo "sha256=$DMG.sha256"; } >>"$GITHUB_OUTPUT"
  fi
}

# Verification runs against the submitted commit's Resources (entitlements, runtime manifest, languages),
# read from git, so later work in any checkout cannot change what the release is checked against.
use_submitted_resources() {
  local tagged v
  git -C "$ROOT" cat-file -e "$st_commit^{commit}" 2>/dev/null \
    || die "commit $st_commit is not in this repository; fetch it first"
  if [ -n "$st_tag" ]; then
    tagged=$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$st_tag^{commit}") \
      || die "tag $st_tag does not exist in this repository; fetch the tags first"
    [ "$tagged" = "$st_commit" ] || die "tag $st_tag now points to $tagged, but $st_commit was submitted"
  fi
  mkdir "$WORK/source"
  git -C "$ROOT" archive "$st_commit" Resources | tar -x -C "$WORK/source" || die "cannot read Resources from $st_commit"
  RES="$WORK/source/Resources"
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RES/Info.plist")
  [ "$v" = "$VERSION" ] || die "commit $st_commit is version $v, the state says $VERSION"
}

# Resume a submitted release: check that the DMG is still the exact file that was submitted, ask Apple,
# and staple and verify it once it is accepted. Nothing is ever rebuilt or submitted again.
main_resume() {
  local sha
  log "Loading the release state"
  STATE_FILE="$(cd "$(dirname "$STATE_FILE")" && pwd)/$(basename "$STATE_FILE")"
  OUT=$(dirname "$STATE_FILE")
  load_state
  VERSION=$st_version
  ARCH=$st_architecture
  BUILD_NUMBER=$st_buildNumber
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the state has an invalid version '$VERSION'"
  case "$ARCH" in arm64|x86_64|universal) ;; *) die "the state has an invalid architecture '$ARCH'" ;; esac
  [[ "$st_commit" =~ ^[0-9a-f]{40}$ ]] || die "the state has no clean commit ('$st_commit'), so it is not a formal release"
  [ "$st_dmgFileName" = "Lint-$VERSION-macOS-$ARCH.dmg" ] || die "the state names '$st_dmgFileName', not a release DMG"
  [[ "$st_dmgSHA256" =~ ^[0-9a-f]{64}$ ]] || die "the state has no submitted SHA-256"
  DMG="$OUT/$st_dmgFileName"
  echo "   Lint $VERSION${st_tag:+ (tag $st_tag)}, build $st_buildNumber, $ARCH, commit $st_commit"
  echo "   state $STATE_FILE: ${st_releaseStatus:-?}, notarization ${st_notarizationStatus:-not submitted}"
  if [ "$st_dmgPath" != "$DMG" ]; then echo "   the state moved: recorded at $st_dmgPath, now $DMG"; fi

  case "$st_releaseStatus" in
    finalized)
      [ -f "$DMG" ] && [ "$(sha256_of "$DMG")" = "$st_finalSHA256" ] \
        || die "the state says finalized, but $DMG is missing or is not the finalized file (SHA-256 $st_finalSHA256)"
      echo "   already finalized at $st_finalizedAt; nothing to do"
      return 0
      ;;
    invalid)
      stop "$EXIT_INVALID" "Apple rejected submission $st_submissionID ($st_notarizationStatus); this DMG is never stapled or published." \
        "See $OUT/notarization-log.json."
      ;;
    pending|finalizing) ;;
    *) die "there is nothing to resume: release status '$st_releaseStatus' (only a submitted DMG can be resumed)" ;;
  esac
  [ -n "$st_submissionID" ] || die "the state has no submission ID"

  log "Checking the submitted DMG"
  [ -f "$DMG" ] || die "the submitted DMG is missing: $DMG" \
    "Do not rebuild it: a rebuilt DMG is a different file, and submission $st_submissionID cannot be stapled to it." \
    "Restore the exact file (SHA-256 $st_dmgSHA256) or start a new release."
  sha=$(sha256_of "$DMG")
  if [ "$sha" = "$st_dmgSHA256" ]; then
    echo "   SHA-256 $sha matches the submitted DMG"
  elif [ "$st_releaseStatus" = finalizing ] && [ "$sha" = "$st_finalSHA256" ]; then
    echo "   SHA-256 $sha is the stapled DMG from an interrupted finalization"
  else
    die "the DMG was changed or replaced after it was submitted: SHA-256 $sha, submitted $st_dmgSHA256." \
      "Stopping without stapling. Only the exact submitted file can carry the ticket of submission $st_submissionID."
  fi

  log "Checking prerequisites"
  require_tools
  check_notary_inputs
  WORK=$(mktemp -d -t lint-release)
  use_submitted_resources

  log "Asking Apple about submission $st_submissionID"
  check_notarization
  finalize

  log "Done"
  echo "   $DMG"
  echo "   $DMG.sha256"
  echo "   FINALIZED: notarized, stapled and verified (submission $st_submissionID)"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "dmg=$DMG"; echo "sha256=$DMG.sha256"; } >>"$GITHUB_OUTPUT"
  fi
}

case "$#:${1:-}" in
  0:) ;;
  2:--resume) MODE=resume; STATE_FILE=$2 ;;
  *) die "usage: release.sh, or release.sh --resume <release-state.json>" ;;
esac
if [ "$MODE" = resume ]; then
  [ -f "$STATE_FILE" ] || die "no release state at $STATE_FILE"
  [ -z "$PREVIEW" ] && [ -z "$SKIP_NOTARIZE" ] || die "LINT_PREVIEW_BUILD and LINT_SKIP_NOTARIZE do not apply to resuming"
  main_resume
else
  main_build
fi
