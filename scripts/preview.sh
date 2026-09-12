#!/usr/bin/env bash
# Eyeball the capture card locally: no encode, no relay, no MediaMTX.
#   VIDEO_DEV/AUDIO_DEV  (name substring or index, default the Pengo's "HDMI to U3 capture")
#   SIZE=720x480 FPS=60 PIXFMT=uyvy422   (unset SIZE/FPS to let the card pick)
#   AUDIO=1   also play the card's audio (default video-only)
#   FRAME=/path/out.png   grab a single frame instead of opening a window
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DEV="$("$HERE/resolve-device.sh" "${VIDEO_DEV:-HDMI to U3 capture}" "${AUDIO_DEV:-HDMI to U3 capture}")"
VIDX="${DEV%%:*}"; AIDX="${DEV##*:}"

IN=(-f avfoundation)
[[ -n "${FPS:-}"  ]] && IN+=(-framerate "$FPS")
[[ -n "${SIZE:-}" ]] && IN+=(-video_size "$SIZE")
IN+=(-pixel_format "${PIXFMT:-uyvy422}")
if [[ "${AUDIO:-0}" == "1" ]]; then IN+=(-i "$VIDX:$AIDX"); else IN+=(-i "$VIDX:none"); fi

if [[ -n "${FRAME:-}" ]]; then
  ffmpeg -hide_banner -loglevel warning "${IN[@]}" -frames:v 1 -y "$FRAME"
  echo "wrote $FRAME"
else
  exec ffplay -hide_banner -loglevel warning -fflags nobuffer -flags low_delay "${IN[@]}"
fi
