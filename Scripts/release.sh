#!/bin/bash
# Build, sign, notarize and package Lint as a Developer ID DMG. Runs on a Mac, locally or in
# GitHub Actions (.github/workflows/release.yml); it does not create the GitHub Release.
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
#
# Output: dist/release/ (Lint.app, the DMG, its .sha256 and notarization.json).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUT="$ROOT/dist/release"
APP="$OUT/Lint.app"
BUNDLE_ID="app.lint.assistant"
IDENTITY_KIND="Developer ID Application"

case "${LINT_SKIP_NOTARIZE:-}" in
  ''|0) SKIP_NOTARIZE= ;;
  1) SKIP_NOTARIZE=1 ;;
  *) echo "error: LINT_SKIP_NOTARIZE must be 1 or unset, got '$LINT_SKIP_NOTARIZE'" >&2; exit 1 ;;
esac

VERSION=""; IDENTITY=""; IDENTITY_NAME=""; ARCH=""; DMG=""
WORK=""     # scratch directory, removed on exit
MOUNT=""    # mount point of the DMG while it is attached

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
has() { grep -Eq -- "$1" <<<"$2"; }

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
  for tool in swift security codesign hdiutil ditto shasum lipo plutil spctl xcrun; do
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

build_app() {
  rm -rf "$OUT"
  mkdir -p "$OUT"
  LINT_RELEASE_BUILD=1 LINT_DIST_DIR="$OUT" CODESIGN_IDENTITY="$IDENTITY" ./Scripts/package-app.sh release >/dev/null
  [ -d "$APP" ] || die "package-app.sh did not produce $APP"
}

detect_arch() {
  local archs
  archs=$(lipo -archs "$APP/Contents/MacOS/Lint") || die "cannot read the executable's architectures"
  case " $archs " in
    " arm64 ") ARCH=arm64 ;;
    " x86_64 ") ARCH=x86_64 ;;
    " arm64 x86_64 "|" x86_64 arm64 ") ARCH=universal ;;
    *) die "unsupported executable architectures: '$archs'" ;;
  esac
  DMG="$OUT/Lint-$VERSION-macOS-$ARCH${SKIP_NOTARIZE:+-unnotarized}.dmg"
}

# Hard checks on a signed Lint.app (the build output, and again the copy inside the DMG).
verify_app_signature() {
  local app="$1" info first_authority team want got plist v b
  codesign --verify --deep --strict --verbose=2 "$app" || die "codesign verification failed for $app"
  info=$(codesign -dvv "$app" 2>&1) || die "cannot read the signature of $app"
  has "^Identifier=$BUNDLE_ID\$" "$info" || die "the signature Identifier is not $BUNDLE_ID"
  first_authority=$(sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$info")
  case "$first_authority" in
    "$IDENTITY_KIND: "*) ;;
    *) die "signed by '$first_authority', expected a '$IDENTITY_KIND' certificate" ;;
  esac
  has 'flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' "$info" || die "Hardened Runtime is not enabled"
  has '^Timestamp=' "$info" || die "the signature has no secure timestamp"
  team=$(sed -n 's/^TeamIdentifier=//p' <<<"$info")
  case "$team" in ''|'not set') die "the signature has no TeamIdentifier" ;; esac
  if [ -n "${APPLE_TEAM_ID:-}" ] && [ "$team" != "$APPLE_TEAM_ID" ]; then
    die "the signature's TeamIdentifier does not match APPLE_TEAM_ID"
  fi

  # Only the entitlements declared in Resources/Lint.entitlements, and never get-task-allow
  # (the notary service rejects it).
  want=$(grep -o '<key>[^<]*</key>' "$ROOT/Resources/Lint.entitlements" | sort || true)
  got=$(codesign -d --entitlements :- "$app" 2>/dev/null | grep -o '<key>[^<]*</key>' | sort || true)
  [ "$want" = "$got" ] || die "the signed entitlements differ from Resources/Lint.entitlements"
  if grep -q 'get-task-allow' <<<"$got"; then die "the signature carries get-task-allow"; fi

  plist="$app/Contents/Info.plist"
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  [ "$v" = "$VERSION" ] || die "the app's CFBundleShortVersionString is $v, expected $VERSION"
  if [ -n "${LINT_BUILD_NUMBER:-}" ]; then
    b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
    [ "$b" = "$LINT_BUILD_NUMBER" ] || die "the app's CFBundleVersion is $b, expected $LINT_BUILD_NUMBER"
  fi
  echo "   $first_authority · team $team · Hardened Runtime · secure timestamp · version $v"
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
  WORK=$(mktemp -d -t lint-release)
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
  sign_dmg || die "cannot sign the DMG"
  codesign --verify --verbose=2 "$DMG" || die "the DMG signature does not verify"
}

notarize() {
  local raw="$WORK/notary.out" err="$WORK/notary.err" json="$OUT/notarization.json" rc=0 id status
  xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --wait --timeout 45m --output-format json >"$raw" 2>"$err" || rc=$?
  sed -n '/^[[:space:]]*{/,$p' "$raw" >"$json"
  id=$(plutil -extract id raw -o - "$json" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - "$json" 2>/dev/null || true)
  echo "   submission ${id:-<none>} · status ${status:-<none>}"
  if [ "$status" != "Accepted" ]; then
    if [ -s "$err" ]; then sed 's/^/   notarytool: /' "$err" >&2; fi
    if [ -n "$id" ]; then
      echo "   notarization log for $id:" >&2
      xcrun notarytool log "$id" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" >&2 || true
    fi
    rm -f "$DMG" # never leave a DMG that Apple did not accept among the release files
    die "notarization failed: status '${status:-unknown}' (notarytool exit code $rc)"
  fi
}

# The ticket can take a moment to reach Apple's CDN after "Accepted", so stapling is retried.
staple() {
  retry 5 15 xcrun stapler staple "$DMG" || die "stapler could not attach the notarization ticket"
  xcrun stapler validate "$DMG" || die "stapler validate failed"
}

# Verify what users will actually receive: the DMG, and the app inside the mounted DMG.
final_checks() {
  hdiutil verify "$DMG" >/dev/null || die "hdiutil verify failed"
  codesign --verify --verbose=2 "$DMG" || die "the DMG signature does not verify"
  MOUNT="$WORK/mnt"
  mkdir "$MOUNT"
  hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null || die "cannot mount the DMG"
  [ "$(ls "$MOUNT" | tr '\n' ' ')" = "Applications Lint.app " ] || die "the DMG must contain exactly Lint.app and Applications"
  [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || die "the Applications symlink in the DMG does not point to /Applications"
  verify_app_signature "$MOUNT/Lint.app"
  if [ -z "$SKIP_NOTARIZE" ]; then
    xcrun stapler validate "$DMG" || die "stapler validate failed"
    spctl --assess --type execute --verbose=4 "$MOUNT/Lint.app" || die "Gatekeeper rejects Lint.app inside the DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || die "Gatekeeper rejects the DMG"
  fi
  detach_volume "$MOUNT" || die "cannot unmount the DMG"
  MOUNT=""
}

write_checksum() {
  local name
  name=$(basename "$DMG")
  (cd "$OUT" && shasum -a 256 "$name" >"$name.sha256" && shasum -a 256 -c "$name.sha256" >/dev/null)
}

main() {
  log "Checking prerequisites"
  require_tools
  check_notary_inputs
  read_version
  echo "   Lint $VERSION${LINT_RELEASE_TAG:+ (tag $LINT_RELEASE_TAG)}${LINT_BUILD_NUMBER:+, build $LINT_BUILD_NUMBER}"
  if [ -n "$SKIP_NOTARIZE" ]; then echo "   LINT_SKIP_NOTARIZE=1: packaging-only dry run, nothing is sent to Apple"; fi

  log "Finding the $IDENTITY_KIND identity"
  resolve_identity
  echo "   $IDENTITY_NAME"

  log "Building and signing Lint.app"
  build_app
  detect_arch
  echo "   architecture: $ARCH -> $(basename "$DMG")"

  log "Verifying the app signature"
  verify_app_signature "$APP"

  log "Creating and signing the DMG"
  build_dmg

  if [ -z "$SKIP_NOTARIZE" ]; then
    log "Notarizing the DMG (this waits for Apple)"
    notarize
    log "Stapling the notarization ticket"
    staple
  fi

  log "Final verification"
  final_checks

  log "Checksum"
  write_checksum || die "the SHA-256 self-check failed"

  log "Done"
  echo "   $DMG"
  echo "   $DMG.sha256"
  if [ -n "$SKIP_NOTARIZE" ]; then echo "   NOT NOTARIZED: dry run only, do not distribute this DMG"; fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "dmg=$DMG"; echo "sha256=$DMG.sha256"; } >>"$GITHUB_OUTPUT"
  fi
}

main
