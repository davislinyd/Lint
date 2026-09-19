#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT/.env.local"
if [ ! -f "$ENV_FILE" ]; then
  echo "missing .env.local (gitignored). Add LINT_API_KEY=..." >&2
  exit 1
fi
KEY=$(awk -F= '/^LINT_API_KEY=/{print substr($0, index($0,"=")+1); exit}' "$ENV_FILE")
if [ -z "$KEY" ]; then
  echo "LINT_API_KEY is empty" >&2
  exit 1
fi
security delete-generic-password -s "app.lint.assistant" -a "openaiCompatible" >/dev/null 2>&1 || true
# -A: local dev item must be readable by ad-hoc signed Lint.app after rebuilds.
security add-generic-password \
  -s "app.lint.assistant" \
  -a "openaiCompatible" \
  -w "$KEY" \
  -A \
  -U >/dev/null
echo "Keychain seeded (service=app.lint.assistant account=openaiCompatible)"
