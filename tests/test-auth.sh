#!/usr/bin/env bash
# MoQ publish auth verification. Skips until HUMAN.md §6 is done (jwt in env).
# Never echoes $MOQ_RELAY_URL — it carries a token once auth is enabled.
set -u
cd "$(dirname "$0")/.."
[[ -n "${MOQ_RELAY_URL:-}" ]] || { echo "SKIP: MOQ_RELAY_URL not set"; exit 0; }
case "$MOQ_RELAY_URL" in
  *jwt=*) ;;
  *) echo "SKIP: no ?jwt= in MOQ_RELAY_URL (auth not enabled — see ralph/HUMAN.md §6)"; exit 0;;
esac
command -v moq >/dev/null || { echo "SKIP: moq not on PATH"; exit 0; }
B=laserdisc-auth-test.hang
SOURCE=test HLS=0 BROADCAST=$B timeout 5 scripts/publish.sh >/dev/null 2>&1
rc=$?
[[ $rc -eq 124 || $rc -eq 143 ]] || { echo "FAIL: authorized publish died early (rc=$rc)"; exit 1; }
NOJWT="${MOQ_RELAY_URL%%\?*}"
MOQ_RELAY_URL="$NOJWT" SOURCE=test HLS=0 BROADCAST=$B timeout 5 scripts/publish.sh >/dev/null 2>&1
rc=$?
[[ $rc -ne 124 && $rc -ne 143 ]] || { echo "FAIL: tokenless publish was NOT rejected"; exit 1; }
echo "auth ok: token publishes, no-token rejected"
exit 0
