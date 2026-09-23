#!/bin/bash
# Resume a formal release whose DMG was already submitted for notarization (see Scripts/release.sh and
# docs/RELEASING.md). It checks that the DMG next to the state file is still the exact submitted file
# (SHA-256), asks Apple for the recorded submission's status and, once it is Accepted, staples and verifies
# that same DMG. It never rebuilds or resubmits anything.
#
# Usage: Scripts/resume-release.sh <release-state.json>
# Needs APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER_ID (APPLE_TEAM_ID is checked when set),
# and a git repository that contains the submitted commit.
# Exit codes: 0 finalized · 1 error (missing or changed DMG, failed check) · 65 Invalid · 69 status
# unavailable · 75 still In Progress.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <release-state.json>" >&2; exit 1; }
exec "$(dirname "$0")/release.sh" --resume "$1"
