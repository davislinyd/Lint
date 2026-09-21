#!/bin/bash
# Fetch, verify and stage the pinned llama.cpp runtime that Scripts/package-app.sh bundles into
# Lint.app (Contents/Resources/LlamaRuntime/<arch>/). No Homebrew, no network beyond the two
# pinned HTTPS URLs in the manifest, and nothing downloaded is ever executed here: only
# curl, tar, shasum, plutil, lipo, otool, file and cp touch it.
#
#   Scripts/fetch-llama-runtime.sh --arch arm64|x86_64 [--out DIR]
#
# Stdout is the staging directory (and nothing else); progress and errors go to stderr.
#
# What it does: read the pinned manifest -> download the exact archive over HTTPS -> verify its
# SHA-256 (a cached copy is verified again, never trusted) -> extract into a scratch directory ->
# check llama-server's architecture -> follow its non-system dylib dependencies (otool -L) inside
# the archive and fail on anything unresolved -> copy exactly those files, plus every license
# notice, into the staging directory -> write runtime-info.json.
#
# Environment (all optional; the tests use them):
#   LINT_LLAMA_MANIFEST        manifest to read (default Resources/LlamaRuntimeManifest.json)
#   LINT_LLAMA_CACHE_DIR       where downloads are kept (default .build/llama-runtime/cache)
#   LINT_LLAMA_STAGE_DIR       parent of the per-arch staging directory (default .build/llama-runtime/stage)
#   LINT_LLAMA_ALLOW_FILE_URLS=1   accept file:// URLs (fixtures only; the real manifest is https only)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST="${LINT_LLAMA_MANIFEST:-$ROOT/Resources/LlamaRuntimeManifest.json}"
CACHE_DIR="${LINT_LLAMA_CACHE_DIR:-$ROOT/.build/llama-runtime/cache}"
STAGE_PARENT="${LINT_LLAMA_STAGE_DIR:-$ROOT/.build/llama-runtime/stage}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: Scripts/fetch-llama-runtime.sh --arch arm64|x86_64 [--out DIR]

Downloads the llama.cpp release pinned in Resources/LlamaRuntimeManifest.json, verifies its
SHA-256, and stages llama-server with the dylibs it needs and the license notices.
Prints the staging directory on stdout.
EOF
}

ARCH=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || { usage; exit 2; }; ARCH="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { usage; exit 2; }; OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
[ -n "$ARCH" ] || { usage; die "--arch is required (the runtime must match the Lint executable it is bundled with)"; }
case "$ARCH" in
  arm64|x86_64) ;;
  *) die "unsupported architecture '$ARCH' (expected arm64 or x86_64)" ;;
esac

for tool in curl tar shasum plutil lipo otool file cp awk sed realpath; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

mget() { plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null; }
need() { # need <keypath> -> value, or die
  local v
  v=$(mget "$1") || die "manifest $MANIFEST has no '$1'"
  [ -n "$v" ] || die "manifest value '$1' is empty"
  printf '%s' "$v"
}

SCHEMA=$(need schemaVersion)
[ "$SCHEMA" = "1" ] || die "unsupported manifest schemaVersion $SCHEMA"
TAG=$(need upstream.tag)
BUILD=$(need upstream.build)
COMMIT=$(need upstream.commit)
UPSTREAM=$(need upstream.project)
mget "runtimes.$ARCH" >/dev/null || die "the manifest pins no llama.cpp runtime for $ARCH (add a runtimes.$ARCH entry with a verified asset and SHA-256)"
ASSET=$(need "runtimes.$ARCH.assetName")
URL=$(need "runtimes.$ARCH.url")
SHA=$(need "runtimes.$ARCH.sha256")
ARCHIVE_ROOT=$(mget "runtimes.$ARCH.archiveRoot" || true)

# Everything that ends up in a path, a URL or the JSON below is checked to be plain.
plain() { case "$2" in *[!A-Za-z0-9._+-]*|'') die "$1 contains unexpected characters: '$2'" ;; esac; }
plain "upstream.tag" "$TAG"
plain "upstream.build" "$BUILD"
plain "upstream.commit" "$COMMIT"
plain "assetName" "$ASSET"
[ -z "$ARCHIVE_ROOT" ] || plain "archiveRoot" "$ARCHIVE_ROOT"
case "$UPSTREAM" in *[!A-Za-z0-9._/-]*|'') die "upstream.project contains unexpected characters" ;; esac
case "$SHA" in *[!0-9a-f]*) die "sha256 must be 64 lowercase hex digits" ;; esac
[ "${#SHA}" = 64 ] || die "sha256 must be 64 lowercase hex digits"

ALLOWED_PROTO='=https'
if [ "${LINT_LLAMA_ALLOW_FILE_URLS:-}" = 1 ]; then ALLOWED_PROTO='=https,file'; fi
check_url() { # check_url <what> <url>
  case "$2" in
    https://*) ;;
    file://*) [ "${LINT_LLAMA_ALLOW_FILE_URLS:-}" = 1 ] || die "$1 is a file:// URL; only https is allowed" ;;
    *) die "$1 must be an https:// URL, got '$2'" ;;
  esac
  case "$2" in
    */latest|*/latest/*|*/latest\?*) die "$1 points at 'latest'; releases must be pinned to an exact tag" ;;
  esac
}
check_url "runtimes.$ARCH.url" "$URL"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# fetch_verified <url> <dest> <sha256> <label>: the file at <dest> is verified whether it was just
# downloaded or already cached, and is only ever used after that check passes.
fetch_verified() {
  local url="$1" dest="$2" want="$3" label="$4" tmp got
  if [ -f "$dest" ]; then
    if [ "$(sha256_of "$dest")" = "$want" ]; then
      log "   $label: cached copy verified"
      return 0
    fi
    log "   $label: cached copy fails its SHA-256 check; discarding it"
    rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.download.$$"
  log "   $label: downloading $url"
  if ! curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
        --proto "$ALLOWED_PROTO" --proto-redir "$ALLOWED_PROTO" --output "$tmp" "$url"; then
    rm -f "$tmp"
    die "could not download $url"
  fi
  got=$(sha256_of "$tmp")
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    die "SHA-256 mismatch for $label: expected $want, got $got"
  fi
  mv "$tmp" "$dest"
  log "   $label: SHA-256 verified"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lint-llama-runtime.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

log "==> Pinned llama.cpp $TAG ($ARCH)"
ARCHIVE="$CACHE_DIR/$ASSET"
fetch_verified "$URL" "$ARCHIVE" "$SHA" "$ASSET"

# --- Extract (only after the hash check) -------------------------------------------------------
EXTRACT="$WORK/extract"
mkdir "$EXTRACT"
tar -tzf "$ARCHIVE" >"$WORK/members.txt" || die "$ASSET is not a readable tar.gz"
while IFS= read -r member; do
  case "$member" in
    /*|..|../*|*/..|*/../*) die "unsafe path in $ASSET: $member" ;;
  esac
done <"$WORK/members.txt"
tar -xzf "$ARCHIVE" -C "$EXTRACT" || die "could not extract $ASSET"
EXTRACT_REAL=$(realpath "$EXTRACT")
if [ -n "$ARCHIVE_ROOT" ]; then ARCHIVE_DIR="$EXTRACT/$ARCHIVE_ROOT"; else ARCHIVE_DIR="$EXTRACT"; fi
[ -d "$ARCHIVE_DIR" ] || die "$ASSET has no top-level directory '$ARCHIVE_ROOT'"

# in_archive <path> -> the real path, provided it stays inside the extracted archive.
in_archive() {
  local real
  real=$(realpath "$1" 2>/dev/null) || return 1
  case "$real" in "$EXTRACT_REAL"/*) printf '%s' "$real" ;; *) return 1 ;; esac
}

STAGE="$WORK/stage"
STAGED="$WORK/staged.txt"
mkdir -p "$STAGE/licenses"
: >"$STAGED"

check_macho() { # check_macho <file> <label>: a Mach-O of exactly the requested architecture
  local archs
  file -b "$1" | grep -q 'Mach-O' || die "$2 is not a Mach-O file"
  archs=$(lipo -archs "$1" 2>/dev/null) || die "cannot read the architectures of $2"
  [ "$archs" = "$ARCH" ] || die "$2 is '$archs', expected exactly '$ARCH' (never mix architectures in one app)"
}

check_rpaths() { # only @loader_path / @executable_path may be searched
  local rpath
  while IFS= read -r rpath; do
    [ -n "$rpath" ] || continue
    case "$rpath" in
      @loader_path|@loader_path/|@loader_path/.|@executable_path|@executable_path/|@executable_path/.) ;;
      *) die "$2 has an rpath outside the bundle: $rpath" ;;
    esac
  done < <(otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" {f = 1; next} f && $1 == "path" {print $2; f = 0}')
}

# stage_binary <real path in the archive> <file name to install it as>
stage_binary() {
  local src="$1" name="$2" deps dep base dep_src dep_real
  if grep -qxF -- "$name" "$STAGED"; then return 0; fi
  check_macho "$src" "$name"
  check_rpaths "$src" "$name"
  cp -LX "$src" "$STAGE/$name"
  chmod 755 "$STAGE/$name"
  printf '%s\n' "$name" >>"$STAGED"
  deps=$(otool -L "$src") || die "otool -L failed for $name"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      /usr/lib/*|/System/Library/*) ;;   # part of macOS
      @rpath/*|@loader_path/*|@executable_path/*)
        base=${dep##*/}
        case "${dep#@*/}" in */*) die "$name depends on $dep, which is in a subdirectory; only a flat runtime is supported" ;; esac
        dep_src="$ARCHIVE_DIR/$base"
        [ -e "$dep_src" ] || die "unresolved dependency: $name needs $dep, which is not in $ASSET"
        dep_real=$(in_archive "$dep_src") || die "$dep resolves outside the archive"
        stage_binary "$dep_real" "$base"
        ;;
      *) die "$name depends on $dep, which is neither part of macOS nor shipped in the archive" ;;
    esac
  done < <(printf '%s\n' "$deps" | tail -n +2 | awk '{print $1}')
}

log "==> Collecting llama-server and the libraries it needs"
SERVER_SRC="$ARCHIVE_DIR/llama-server"
[ -f "$SERVER_SRC" ] || die "llama-server is not in $ASSET"
SERVER_REAL=$(in_archive "$SERVER_SRC") || die "llama-server resolves outside the archive"
stage_binary "$SERVER_REAL" llama-server
sort -o "$STAGED" "$STAGED"
log "   $(wc -l <"$STAGED" | tr -d ' ') files: $(tr '\n' ' ' <"$STAGED")"

# --- Licenses ----------------------------------------------------------------------------------
log "==> License notices"
found=0
for f in "$ARCHIVE_DIR"/LICENSE* "$ARCHIVE_DIR"/NOTICE* "$ARCHIVE_DIR"/COPYING*; do
  if [ -f "$f" ]; then
    cp -X "$f" "$STAGE/licenses/$(basename "$f")"
    found=$((found + 1))
  fi
done
[ "$found" -gt 0 ] || die "$ASSET contains no LICENSE/NOTICE/COPYING file; refusing to redistribute it without one"

n=$(mget licenses || true)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
i=0
while [ "$i" -lt "$n" ]; do
  lname=$(need "licenses.$i.name"); lurl=$(need "licenses.$i.url"); lsha=$(need "licenses.$i.sha256")
  plain "licenses.$i.name" "$lname"
  case "$lname" in .*) die "licenses.$i.name must not start with a dot" ;; esac
  case "$lsha" in *[!0-9a-f]*) die "licenses.$i.sha256 must be lowercase hex" ;; esac
  [ "${#lsha}" = 64 ] || die "licenses.$i.sha256 must be 64 hex digits"
  check_url "licenses.$i.url" "$lurl"
  fetch_verified "$lurl" "$CACHE_DIR/$TAG-$lname" "$lsha" "$lname"
  cp -X "$CACHE_DIR/$TAG-$lname" "$STAGE/licenses/$lname"
  i=$((i + 1))
done

cat >"$STAGE/licenses/NOTICE-Lint.txt" <<EOF
This directory ships with the llama.cpp runtime bundled in Lint.app.

llama-server and the libraries next to it are the unmodified upstream binaries of
$UPSTREAM release $TAG (build $BUILD, commit $COMMIT),
re-signed with Lint's code signature. Source code and the full set of third-party notices:
  https://github.com/$UPSTREAM/tree/$COMMIT

The upstream license texts that accompany the binary release are the LICENSE files in this directory.
EOF

# --- runtime-info.json (read by the app; the files list has no sizes or hashes because signing changes them)
{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "upstream": "%s",\n' "$UPSTREAM"
  printf '  "tag": "%s",\n' "$TAG"
  printf '  "build": %s,\n' "$BUILD"
  printf '  "commit": "%s",\n' "$COMMIT"
  printf '  "architecture": "%s",\n' "$ARCH"
  printf '  "assetName": "%s",\n' "$ASSET"
  printf '  "archiveSHA256": "%s",\n' "$SHA"
  printf '  "binary": "llama-server",\n'
  printf '  "files": ['
  first=1
  while IFS= read -r name; do
    if [ "$first" = 1 ]; then first=0; else printf ','; fi
    printf '\n    "%s"' "$name"
  done <"$STAGED"
  printf '\n  ]\n}\n'
} >"$STAGE/runtime-info.json"
plutil -extract files raw -o - "$STAGE/runtime-info.json" >/dev/null 2>&1 || die "generated runtime-info.json is not valid JSON"

# --- Publish the staging directory --------------------------------------------------------------
[ -n "$OUT" ] || OUT="$STAGE_PARENT/$ARCH"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$STAGE" "$OUT"
log "==> Staged $TAG ($ARCH) in $OUT"
printf '%s\n' "$OUT"
