#!/usr/bin/env bash
# MoQ publish auth verification. Skips until HUMAN.md §6 is done (jwt in env).
# Never echoes $MOQ_RELAY_URL or the captured stderr — both carry the token
# (moq logs "connecting url=..." verbatim). grep -q only.
set -u
cd "$(dirname "$0")/.."
[[ -n "${MOQ_RELAY_URL:-}" ]] || { echo "SKIP: MOQ_RELAY_URL not set"; exit 0; }
case "$MOQ_RELAY_URL" in
  *jwt=*) ;;
  *) echo "SKIP: no ?jwt= in MOQ_RELAY_URL (auth not enabled — see ralph/HUMAN.md §6)"; exit 0;;
esac
command -v moq >/dev/null || { echo "SKIP: moq not on PATH"; exit 0; }
B=laserdisc-auth-test.hang
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
# Connect proof: moq's "connected version=moq-lite-04" stderr line ("moq-lite"
# survives the ANSI escapes inside it). Exit codes alone can't tell streaming
# from hanging-on-connect — a down relay times out BOTH halves.
SOURCE=test HLS=0 BROADCAST=$B timeout 8 scripts/publish.sh >/dev/null 2>"$LOG"
grep -q moq-lite "$LOG" || { echo "FAIL: authorized publish never connected (relay down/unreachable? see ralph/HUMAN.md §11)"; exit 1; }
NOJWT="${MOQ_RELAY_URL%%\?*}"
: >"$LOG"
MOQ_RELAY_URL="$NOJWT" SOURCE=test HLS=0 BROADCAST=$B timeout 8 scripts/publish.sh >/dev/null 2>"$LOG"
rc=$?
grep -q moq-lite "$LOG" && { echo "FAIL: tokenless publish was NOT rejected (connected without a token)"; exit 1; }
[[ $rc -ne 124 && $rc -ne 143 ]] || { echo "FAIL: tokenless publish neither connected nor errored within 8s"; exit 1; }
grep -q unauthorized "$LOG" || echo "note: tokenless publish rejected without an explicit unauthorized error"
echo "auth ok: token publishes, no-token rejected"
exit 0
