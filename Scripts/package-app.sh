#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CONFIG="${1:-debug}"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product Lint >&2
  BIN_DIR=$(swift build -c release --show-bin-path)
else
  swift build --product Lint >&2
  BIN_DIR=$(swift build --show-bin-path)
fi

APP="$ROOT/dist/Lint.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Lint" "$APP/Contents/MacOS/Lint"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# SwiftPM package resources (e.g. KeyboardShortcuts.Recorder localization bundle).
# Without these, opening the Writing tab crashes in Bundle.module.
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

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
  codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/Lint.entitlements" "$APP" >&2
else
  echo "warning: no stable codesign identity; using ad-hoc (-). Accessibility will reset after each rebuild." >&2
  echo "fix: Xcode → Settings → Accounts → Apple ID → Manage Certificates → + Apple Development" >&2
  codesign --force --sign - --entitlements "$ROOT/Resources/Lint.entitlements" "$APP" >&2
fi

printf '%s\n' "$APP"
