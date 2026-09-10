#!/usr/bin/env bash
# Encode once, tee to MoQ (relay) and RTMP (MediaMTX → LL-HLS).
#   SOURCE=test|capture  RELAY_URL  BROADCAST  HLS=1|0  RTMP_URL
#   VIDEO_DEV/AUDIO_DEV  (capture: avfoundation index or name substring)
#   SIZE=1280x720 FPS=30
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE="${SOURCE:-capture}"
RELAY_URL="${RELAY_URL:-${MOQ_RELAY_URL}}"
BROADCAST="${BROADCAST:-laserdisc.hang}"
HLS="${HLS:-1}"
RTMP_URL="${RTMP_URL:-rtmp://localhost:1935/laserdisc}"
SIZE="${SIZE:-1280x720}"
FPS="${FPS:-30}"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
command -v moq >/dev/null || { echo "moq-cli not installed: cargo install moq-cli --locked" >&2; exit 1; }

case "$SOURCE" in
  test)
    INPUT=(-re -f lavfi -i "testsrc2=size=${SIZE}:rate=${FPS}"
           -f lavfi -i "sine=frequency=440:sample_rate=48000")
    ;;
  capture)
    DEV="$("$HERE/resolve-device.sh" "${VIDEO_DEV:-Pengo}" "${AUDIO_DEV:-Pengo}")"   # "vidx:aidx"
    INPUT=(-f avfoundation -framerate "$FPS" -video_size "$SIZE" -pixel_format uyvy422
           -i "$DEV")
    ;;
  *) echo "SOURCE must be test or capture" >&2; usage;;
esac

if [[ "$SOURCE" == "test" ]]; then MAP=(-map 0:v -map 1:a); else MAP=(-map 0:v -map 0:a); fi
if [[ "$HLS" == "1" ]]; then TEE="[f=mpegts]pipe:1|[f=flv:onfail=ignore]${RTMP_URL}"; else TEE="[f=mpegts]pipe:1"; fi

echo "publish: source=$SOURCE relay=$RELAY_URL broadcast=$BROADCAST hls=$HLS rtmp=$RTMP_URL" >&2
exec ffmpeg -hide_banner -loglevel warning -nostats "${INPUT[@]}" \
  -filter_script:v "$HERE/overlay.filter" \
  -c:v h264_videotoolbox -realtime 1 -b:v 2500k -g 30 -bf 0 -profile:v main -pix_fmt yuv420p \
  -c:a aac -b:a 128k -ar 48000 -ac 2 -flags +global_header \
  "${MAP[@]}" -f tee "$TEE" \
  | moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" import ts
