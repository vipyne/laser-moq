#!/usr/bin/env bash
# Kill ffmpeg mid-stream; the wrapper must restart the pipeline.
set -u
cd "$(dirname "$0")/.."
export SOURCE=test HLS=0 BROADCAST="laserdisc-forever-$$.hang" MAX_RESTARTS=3
scripts/run-forever.sh &
W=$!
trap 'kill $W 2>/dev/null; wait $W 2>/dev/null' EXIT
sleep 5
first="$(pgrep -f 'ffmpeg .*testsrc2' | head -1)"
[[ -n "$first" ]] || { echo "ffmpeg not running"; exit 1; }
kill "$first"
sleep 6
second="$(pgrep -f 'ffmpeg .*testsrc2' | head -1)"
[[ -n "$second" && "$second" != "$first" ]] || { echo "no restart (first=$first second=$second)"; exit 1; }
# TERM, not INT: bash ignores SIGINT in background jobs of non-interactive
# shells, so the wrapper's INT trap can never fire under this test harness.
kill -TERM $W; sleep 2
pgrep -f 'ffmpeg .*testsrc2' >/dev/null && { echo "child survived SIGTERM"; exit 1; }
echo "restart + clean shutdown ok"
exit 0
