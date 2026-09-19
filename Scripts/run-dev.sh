#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if pgrep -x Lint >/dev/null 2>&1; then
  pkill -9 -x Lint || true
  sleep 0.3
fi
APP=$("$ROOT/Scripts/package-app.sh" debug)
open "$APP"
