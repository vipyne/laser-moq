#!/usr/bin/env bash
# Prod Caddyfile must not add CORS/cache headers. MediaMTX already sends
# exactly one Access-Control-Allow-Origin (hlsAllowOrigins in mediamtx.yml)
# and its own Cache-Control; a second ACAO value makes browsers reject every
# HLS response — seen live as hls.js "manifestLoadError" on the prod page
# (ralph/HUMAN.md §5 note, 2026-09-17). curl ignores duplicates, so only a
# browser ever caught it; this keeps the duplicate from coming back.
set -u
cd "$(dirname "$0")/.."
f=hls-origin/Caddyfile
[[ -f "$f" ]] || { echo "missing $f"; exit 1; }
if grep -qi 'access-control-allow-origin' "$f"; then
  echo "Caddyfile must not set Access-Control-Allow-Origin (duplicates mediamtx's; browsers reject multiple values)"
  exit 1
fi
if grep -qi 'cache-control' "$f"; then
  echo "Caddyfile must not set Cache-Control (mediamtx sends 'private, no-cache' itself)"
  exit 1
fi
grep -q 'reverse_proxy mediamtx:8888' "$f" || { echo "Caddyfile must reverse_proxy mediamtx:8888"; exit 1; }
echo "caddyfile ok: no duplicate CORS/cache headers"
exit 0
