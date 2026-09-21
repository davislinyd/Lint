#!/bin/bash
# Build Lint from source and install it, without Homebrew. Works from a git clone and from GitHub's
# "Download ZIP" (nothing here needs .git).
#
#   ./Scripts/install.sh              build, install to ~/Applications/Lint.app (no sudo), and open it
#   ./Scripts/install.sh --system     install to /Applications/Lint.app instead (sudo only if that folder is not writable)
#   ./Scripts/install.sh --no-open    do not launch Lint afterwards
#   ./Scripts/install.sh --dry-run    check the prerequisites and print the plan; build and install nothing
#
# Needs: macOS 14+, and Apple's Command Line Tools (Swift 6.1+). It does NOT need Homebrew, Python,
# CMake or a llama.cpp of your own: the pinned llama.cpp runtime is downloaded over HTTPS, its
# SHA-256 is verified (Resources/LlamaRuntimeManifest.json), and it is bundled into the app.
# The AI model is not part of the build; Lint's first-run screen downloads it after asking you.
#
# A source build is signed with your Apple Development identity if you have one, otherwise ad-hoc.
# It is not the notarized release: macOS may ask you to allow Accessibility again after a rebuild.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEST_KIND=user
OPEN_AFTER=1
DRY_RUN=
MIN_MACOS_MAJOR=14
MIN_SWIFT="6.1"

log() { printf '\n==> %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --system) DEST_KIND=system ;;
    --no-open) OPEN_AFTER= ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
  shift
done

# --- Platform -----------------------------------------------------------------------------------
check_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "Lint is a macOS app; this installer only runs on macOS"
  local version major
  version=$(sw_vers -productVersion)
  major=${version%%.*}
  [ "$major" -ge "$MIN_MACOS_MAJOR" ] 2>/dev/null || die "macOS $version is too old; Lint needs macOS $MIN_MACOS_MAJOR or newer"
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64|x86_64) ;;
    *) die "unsupported CPU architecture: $ARCH" ;;
  esac
  MACOS_VERSION=$version
}

# --- Swift toolchain (Apple's Command Line Tools) -----------------------------------------------
# `swift` on a Mac without the tools is a stub that pops up Apple's installer, so look for the
# tools first instead of just running it.
check_toolchain() {
  if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    {
      echo "error: Apple's Command Line Tools (which include Swift) are not installed."
      echo "       Lint is built with Swift, and Apple's tools are the only thing you need to install."
      echo "       Homebrew is NOT needed."
    } >&2
    if [ -n "$DRY_RUN" ]; then
      echo "       (dry run: nothing was started)" >&2
    elif [ -t 0 ] && [ -t 1 ]; then
      printf "       Start Apple's installer now (xcode-select --install)? [y/N] " >&2
      local answer=""
      read -r answer || true
      case "$answer" in
        y|Y|yes|YES) xcode-select --install || true ;;
      esac
      echo "       When Apple's installer has finished, run ./Scripts/install.sh again." >&2
    else
      echo "       Run:  xcode-select --install" >&2
      echo "       and wait for Apple's installer to finish, then run ./Scripts/install.sh again." >&2
    fi
    exit 2
  fi
  local line version
  line=$(swift --version 2>&1 | head -n 1) || die "swift did not run; reinstall the Command Line Tools (xcode-select --install)"
  version=$(sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' <<<"$line")
  [ -n "$version" ] || die "cannot read the Swift version from: $line"
  local have_major=${version%%.*} have_minor=${version#*.} want_major=${MIN_SWIFT%%.*} want_minor=${MIN_SWIFT#*.}
  if [ "$have_major" -lt "$want_major" ] || { [ "$have_major" -eq "$want_major" ] && [ "$have_minor" -lt "$want_minor" ]; }; then
    die "Swift $version is too old; Lint needs Swift $MIN_SWIFT or newer. Update the Command Line Tools in System Settings → General → Software Update."
  fi
  SWIFT_VERSION=$version
}

# --- Destination --------------------------------------------------------------------------------
resolve_destination() {
  if [ "$DEST_KIND" = system ]; then
    DEST_DIR=/Applications
  else
    DEST_DIR="$HOME/Applications"
  fi
  DEST="$DEST_DIR/Lint.app"
  USE_SUDO=
  if [ "$DEST_KIND" = system ]; then
    # Only the explicit --system install may ask for a password, and only if the folder needs it.
    if [ -w "$DEST_DIR" ] && { [ ! -e "$DEST" ] || [ -w "$DEST" ]; }; then :; else USE_SUDO=1; fi
  fi
}

run_priv() { if [ -n "$USE_SUDO" ]; then sudo "$@"; else "$@"; fi; }

# Only a Lint running from the very folder that is about to be replaced is asked to quit; a copy
# running from anywhere else (say /Applications when installing to ~/Applications) is left alone.
running_from_destination() { pgrep -f -- "$DEST/Contents/MacOS/Lint" >/dev/null 2>&1; }

quit_running_lint() {
  if running_from_destination; then
    info "the Lint at $DEST is running; asking it to quit so it can be replaced"
    osascript -e "tell application \"$DEST\" to quit" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      running_from_destination || break
      sleep 0.5
    done
    running_from_destination && die "Lint is still running from $DEST. Quit it from its menu-bar icon, then run this installer again."
  fi
  if pgrep -x Lint >/dev/null 2>&1; then
    info "another copy of Lint is running and was left alone; quit it before you open the new one (both use the same settings)"
  fi
  return 0
}

install_app() {
  local built="$1" trash_name
  mkdir -p "$DEST_DIR" 2>/dev/null || run_priv mkdir -p "$DEST_DIR"
  if [ -e "$DEST" ]; then
    # Recoverable: the previous copy goes to the Trash, not straight to oblivion.
    trash_name="$HOME/.Trash/Lint-$(date +%Y%m%d-%H%M%S).app"
    info "moving the existing $DEST to the Trash"
    mv "$DEST" "$trash_name" 2>/dev/null || run_priv mv "$DEST" "$trash_name" \
      || die "cannot move the existing $DEST out of the way"
  fi
  run_priv ditto "$built" "$DEST"
}

# --- Plan ---------------------------------------------------------------------------------------
check_macos
check_toolchain
resolve_destination
[ -f "$ROOT/Resources/LlamaRuntimeManifest.json" ] || die "Resources/LlamaRuntimeManifest.json is missing; this does not look like a Lint source folder"
plutil -extract "runtimes.$ARCH.sha256" raw -o - "$ROOT/Resources/LlamaRuntimeManifest.json" >/dev/null 2>&1 \
  || die "the bundled-runtime manifest pins no llama.cpp build for $ARCH"

log "Lint source install"
info "macOS $MACOS_VERSION ($ARCH), Swift $SWIFT_VERSION"
info "destination: $DEST${USE_SUDO:+ (will ask for your password)}"
info "Homebrew is not required and is never used"
if [ -n "$DRY_RUN" ]; then
  info "dry run: prerequisites are fine. It would fetch and verify the pinned llama.cpp runtime, build Lint in release mode, install it and open it."
  exit 0
fi

# --- Build and install --------------------------------------------------------------------------
log "Fetching and verifying the pinned llama.cpp runtime"
"$ROOT/Scripts/fetch-llama-runtime.sh" --arch "$ARCH" >/dev/null

log "Building Lint (release) and packaging the app"
APP=$("$ROOT/Scripts/package-app.sh" release) || die "the build failed (see the messages above)"
[ -d "$APP" ] || die "package-app.sh did not produce an app"

log "Installing"
quit_running_lint
install_app "$APP"
codesign --verify --deep --strict "$DEST" 2>/dev/null || die "the installed app's signature does not verify"

RUNTIME_INFO="$DEST/Contents/Resources/LlamaRuntime/$ARCH/runtime-info.json"
RUNTIME_TAG=$(plutil -extract tag raw -o - "$RUNTIME_INFO" 2>/dev/null || echo "unknown")
SIGNER=$(codesign -dvv "$DEST" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
info "installed: $DEST"
info "bundled llama.cpp: $RUNTIME_TAG (SHA-256 verified)"
info "signed by: ${SIGNER:-ad-hoc}"

if [ -n "$OPEN_AFTER" ]; then
  log "Opening Lint"
  open "$DEST"
fi

cat <<EOF

Done. Lint's first-run screen guides the rest: it asks before downloading the AI model
(about 4.7 GB, stored under ~/Library/Application Support/Lint/Models) and then the
Accessibility permission.

This is a source build, not the notarized release. If macOS asks for Accessibility again
after a rebuild, allow it again (a stable Apple Development signing identity avoids that).
EOF
