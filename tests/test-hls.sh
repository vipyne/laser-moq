#!/usr/bin/env bash
# Starts local MediaMTX, publishes the test source with the RTMP leg on,
# and asserts the playlist is Low-Latency HLS. Then proves killing MediaMTX
# does not kill the MoQ leg.
set -u
cd "$(dirname "$0")/.."
docker compose -f hls-origin/compose.local.yml up -d >/dev/null || exit 1
export SOURCE=test HLS=1 BROADCAST="laserdisc-hls-$$.hang"
OUT="$(mktemp -d)"
scripts/publish.sh >"$OUT/pub.log" 2>&1 &
PUB=$!
# pkill -P first: publish.sh is `ffmpeg | moq`; killing only $PUB orphans both.
cleanup() { pkill -TERM -P $PUB 2>/dev/null; kill $PUB 2>/dev/null; wait $PUB 2>/dev/null; docker compose -f hls-origin/compose.local.yml down >/dev/null 2>&1; }
trap cleanup EXIT
# MediaMTX 1.20.1 gates HLS behind a cookieCheck redirect (Secure cookie; curl
# accepts it on localhost) — every fetch needs -L plus the shared cookie jar.
CURL=(curl -sfL -c "$OUT/jar" -b "$OUT/jar")
for i in $(seq 1 20); do
  "${CURL[@]}" http://localhost:8888/laserdisc/index.m3u8 -o "$OUT/index.m3u8" && break; sleep 1
done
[[ -s "$OUT/index.m3u8" ]] || { echo "no playlist"; tail -20 "$OUT/pub.log"; exit 1; }
# variant URI is the first non-comment line (#EXT-X-MEDIA's quoted URI is audio-only)
media="$(grep -m1 -E '^[^#].*\.m3u8' "$OUT/index.m3u8")"
[[ -n "$media" ]] || media="index.m3u8"
sleep 3
"${CURL[@]}" "http://localhost:8888/laserdisc/$media" -o "$OUT/media.m3u8" || { echo "no media playlist $media"; exit 1; }
grep -q '#EXT-X-PART' "$OUT/media.m3u8" || { echo "not LL-HLS (no EXT-X-PART)"; head -30 "$OUT/media.m3u8"; exit 1; }
echo "LL-HLS ok"
# publish auth: an anonymous publisher must be rejected (rc 124 = timeout hit,
# meaning ffmpeg was still happily streaming → auth is not enforced)
timeout 8 ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=320x180:rate=15 \
  -c:v h264_videotoolbox -f flv rtmp://localhost:1935/laserdisc >/dev/null 2>&1
rc=$?
[[ $rc -ne 124 && $rc -ne 0 ]] || { echo "anonymous RTMP publish was NOT rejected (rc=$rc)"; exit 1; }
echo "anonymous publish rejected"
# resilience: HLS origin dies, MoQ leg must keep running
docker compose -f hls-origin/compose.local.yml stop >/dev/null
sleep 5
kill -0 $PUB 2>/dev/null || { echo "publisher died when MediaMTX stopped"; tail -20 "$OUT/pub.log"; exit 1; }
echo "publisher survived HLS origin loss"
exit 0
