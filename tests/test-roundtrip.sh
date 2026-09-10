#!/usr/bin/env bash
# Publishes the test source to the relay for a few seconds and checks that a
# second moq process can export h264+aac back out. Needs network + moq-cli.
set -u
cd "$(dirname "$0")/.."
export SOURCE=test HLS=0 BROADCAST="laserdisc-test-$$.hang"
OUT="$(mktemp -d)"
scripts/publish.sh >"$OUT/pub.log" 2>&1 &
PUB=$!
# pkill -P first: publish.sh is `ffmpeg | moq`; killing only $PUB orphans both.
trap 'pkill -TERM -P $PUB 2>/dev/null; kill $PUB 2>/dev/null; wait $PUB 2>/dev/null' EXIT
sleep 4
timeout 20 moq --client-connect "${RELAY_URL:-${MOQ_RELAY_URL}}" \
  --broadcast "$BROADCAST" export ts 2>"$OUT/sub.log" | head -c 400000 >"$OUT/out.ts"
codecs="$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$OUT/out.ts" | sort -u | tr '\n' ' ')"
echo "codecs: $codecs"
case "$codecs" in *h264*aac*|*aac*h264*) exit 0;; esac
echo "--- pub.log"; tail -20 "$OUT/pub.log"; echo "--- sub.log"; tail -20 "$OUT/sub.log"
exit 1
