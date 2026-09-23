#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CONFIG="${1:-debug}"

fail() { echo "error: $*" >&2; exit 1; }

# CFBundleVersion of the assembled copy only (CI passes github.run_number).
# The source Resources/Info.plist is never rewritten.
if [ -n "${LINT_BUILD_NUMBER:-}" ]; then
  printf '%s' "$LINT_BUILD_NUMBER" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' \
    || fail "LINT_BUILD_NUMBER must be 1-3 dot-separated integers, got '$LINT_BUILD_NUMBER'"
fi

# Distribution build (Scripts/release.sh): LINT_RELEASE_BUILD=1 signs only with a
# "Developer ID Application" identity, with Hardened Runtime and a secure timestamp.
# It never falls back to another identity or to ad-hoc signing, and it is checked
# before building so a wrong identity fails immediately.
# CODESIGN_IDENTITY (name or SHA-1) is required; LINT_KEYCHAIN optionally limits the
# identity search and the signing to one keychain file (CI uses a temporary one).
case "${LINT_RELEASE_BUILD:-}" in
  ''|0) RELEASE_BUILD= ;;
  1) RELEASE_BUILD=1 ;;
  *) fail "LINT_RELEASE_BUILD must be 1 or unset, got '$LINT_RELEASE_BUILD'" ;;
esac
if [ -n "$RELEASE_BUILD" ]; then
  [ "$CONFIG" = "release" ] || fail "LINT_RELEASE_BUILD=1 requires the release configuration"
  [ -n "${CODESIGN_IDENTITY:-}" ] || fail "LINT_RELEASE_BUILD=1 requires CODESIGN_IDENTITY (a 'Developer ID Application' identity)"
  if [ -n "${LINT_KEYCHAIN:-}" ]; then
    FOUND=$(security find-identity -v -p codesigning "$LINT_KEYCHAIN" || true)
  else
    FOUND=$(security find-identity -v -p codesigning || true)
  fi
  MATCHES=$(printf '%s\n' "$FOUND" | grep -E '^ *[0-9]+\) ' | grep -i -F -- "$CODESIGN_IDENTITY" || true)
  MATCH_COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)
  [ "$MATCH_COUNT" = "1" ] || fail "CODESIGN_IDENTITY must match exactly one valid identity, matched $MATCH_COUNT (see: security find-identity -v -p codesigning)"
  case "$MATCHES" in
    *'"Developer ID Application: '*) ;;
    *) fail "CODESIGN_IDENTITY is not a 'Developer ID Application' identity; other identities and ad-hoc signatures cannot be notarized" ;;
  esac
  # Sign with the matched certificate's hash, never with the raw CODESIGN_IDENTITY string.
  IDENTITY=$(printf '%s' "$MATCHES" | awk '{print $2}')
  IDENTITY_NAME=$(printf '%s' "$MATCHES" | sed -E 's/^[^"]*"([^"]*)".*/\1/')
fi

if [ "$CONFIG" = "release" ]; then
  swift build -c release --product Lint >&2
  BIN_DIR=$(swift build -c release --show-bin-path)
else
  swift build --product Lint >&2
  BIN_DIR=$(swift build --show-bin-path)
fi

APP="${LINT_DIST_DIR:-$ROOT/dist}/Lint.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Lint" "$APP/Contents/MacOS/Lint"
# Apple Intelligence (FoundationModels) is a system framework that exists only from macOS 26 on,
# and Lint still runs on older macOS: it must be weak-linked, and nothing of it is ever copied in.
if otool -L "$APP/Contents/MacOS/Lint" 2>/dev/null | grep -q '/FoundationModels.framework/'; then
  otool -l "$APP/Contents/MacOS/Lint" | awk '/ cmd LC_/ { cmd = $2 } /FoundationModels\.framework/ { print cmd }' \
    | grep -qx LC_LOAD_WEAK_DYLIB \
    || fail "FoundationModels is linked strongly: Lint would not launch on macOS before 26"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${LINT_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LINT_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# UI strings (Localizable.strings per language).
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
# SwiftPM package resources (e.g. KeyboardShortcuts.Recorder localization bundle).
# Without these, opening the Writing tab crashes in Bundle.module.
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundled llama.cpp runtime (llama-server + its dylibs + licenses), pinned in
# Resources/LlamaRuntimeManifest.json. It must match the Lint executable's architecture and is
# copied in before anything is signed, so the app's signature and notarization cover it.
APP_ARCH=$(lipo -archs "$APP/Contents/MacOS/Lint") || fail "cannot read the architectures of the Lint executable"
case "$APP_ARCH" in
  arm64|x86_64) ;;
  *) fail "the bundled llama.cpp runtime is per-architecture; the Lint executable is '$APP_ARCH', expected exactly arm64 or x86_64" ;;
esac
RUNTIME_STAGE=$("$ROOT/Scripts/fetch-llama-runtime.sh" --arch "$APP_ARCH") || fail "could not stage the llama.cpp runtime"
RUNTIME_DEST="$APP/Contents/Resources/LlamaRuntime/$APP_ARCH"
mkdir -p "$APP/Contents/Resources/LlamaRuntime"
ditto --norsrc --noextattr --noqtn "$RUNTIME_STAGE" "$RUNTIME_DEST"

if [ -n "$RELEASE_BUILD" ]; then
  echo "codesign identity: $IDENTITY_NAME (Developer ID, Hardened Runtime, secure timestamp)" >&2
  # Inside-out: the runtime's dylibs and llama-server first, with the same identity, then the app.
  if [ -n "${LINT_KEYCHAIN:-}" ]; then
    "$ROOT/Scripts/sign-llama-runtime.sh" "$RUNTIME_DEST" "$IDENTITY" --release --keychain "$LINT_KEYCHAIN"
  else
    "$ROOT/Scripts/sign-llama-runtime.sh" "$RUNTIME_DEST" "$IDENTITY" --release
  fi
  set -- --force --options runtime --timestamp
  if [ -n "${LINT_KEYCHAIN:-}" ]; then
    set -- "$@" --keychain "$LINT_KEYCHAIN"
  fi
  codesign "$@" --sign "$IDENTITY" --entitlements "$ROOT/Resources/Lint.entitlements" "$APP" >&2
  printf '%s\n' "$APP"
  exit 0
fi

# Prefer a stable codesign identity so Accessibility survives rebuilds.
# Override with: CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Apple Development|Developer ID Application|Mac Developer/{print $2; exit}')
fi
if [ -z "$IDENTITY" ] && [ -f "$ROOT/.codesign/identity.txt" ]; then
  IDENTITY=$(cat "$ROOT/.codesign/identity.txt")
fi

if [ -n "$IDENTITY" ]; then
  echo "codesign identity: $IDENTITY" >&2
  "$ROOT/Scripts/sign-llama-runtime.sh" "$RUNTIME_DEST" "$IDENTITY"
  codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/Lint.entitlements" "$APP" >&2
else
  echo "warning: no stable codesign identity; using ad-hoc (-). Accessibility will reset after each rebuild." >&2
  echo "fix: Xcode → Settings → Accounts → Apple ID → Manage Certificates → + Apple Development" >&2
  "$ROOT/Scripts/sign-llama-runtime.sh" "$RUNTIME_DEST" -
  codesign --force --sign - --entitlements "$ROOT/Resources/Lint.entitlements" "$APP" >&2
fi

printf '%s\n' "$APP"
