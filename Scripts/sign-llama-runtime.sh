#!/bin/sh
# Sign the llama.cpp runtime that is bundled in Lint.app, inside-out: every dylib first, then
# llama-server. The caller signs the outer Lint.app afterwards, so the app's seal covers the
# signed runtime. Never uses codesign --deep.
#
#   Scripts/sign-llama-runtime.sh <runtime-dir> <identity> [--release] [--keychain FILE]
#
# <identity>   a codesign identity (name or SHA-1) or "-" for ad-hoc.
# --release    Developer ID distribution: Hardened Runtime and a secure timestamp on every file,
#              exactly like the outer app. Library validation then requires that llama-server and
#              its dylibs carry the same Team ID, which is why they are all signed with the same
#              identity here.
# without it   development signing (Apple Development or ad-hoc), no Hardened Runtime: an ad-hoc
#              runtime with library validation cannot load its own ad-hoc dylibs, and development
#              builds are not notarized anyway.
set -eu

fail() { echo "error: $*" >&2; exit 1; }

[ $# -ge 2 ] || fail "usage: sign-llama-runtime.sh <runtime-dir> <identity> [--release] [--keychain FILE]"
DIR="$1"; IDENTITY="$2"; shift 2
RELEASE=""; KEYCHAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=1; shift ;;
    --keychain) [ $# -ge 2 ] || fail "--keychain needs a file"; KEYCHAIN="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -d "$DIR" ] || fail "runtime directory not found: $DIR"
[ -f "$DIR/llama-server" ] || fail "no llama-server in $DIR"
[ -n "$IDENTITY" ] || fail "an identity is required"
if [ -n "$RELEASE" ] && [ "$IDENTITY" = "-" ]; then
  fail "a release runtime cannot be ad-hoc signed"
fi

ID_PREFIX="app.lint.assistant"

sign_one() { # sign_one <file> <identifier>
  if [ -n "$RELEASE" ]; then
    if [ -n "$KEYCHAIN" ]; then
      codesign --force --options runtime --timestamp --keychain "$KEYCHAIN" --identifier "$2" --sign "$IDENTITY" "$1" >&2
    else
      codesign --force --options runtime --timestamp --identifier "$2" --sign "$IDENTITY" "$1" >&2
    fi
  else
    codesign --force --identifier "$2" --sign "$IDENTITY" "$1" >&2
  fi
  codesign --verify --strict "$1" >&2 || fail "signature of $1 does not verify"
}

count=0
for lib in "$DIR"/*.dylib; do
  [ -f "$lib" ] || continue
  name=$(basename "$lib" .dylib)
  sign_one "$lib" "$ID_PREFIX.llama-runtime.$name"
  count=$((count + 1))
done
sign_one "$DIR/llama-server" "$ID_PREFIX.llama-server"
count=$((count + 1))

echo "signed $count runtime files in $DIR" >&2
