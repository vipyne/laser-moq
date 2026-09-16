#!/usr/bin/env bash
# Production publisher, for the x86 Mac wired to the LaserDisc (Pengo + media
# assumed connected). Publishes SOURCE=capture to the real relay + HLS origin
# via run-forever.sh, and runs the latency measurement from the same machine.
#   scripts/prod.sh up        start publishing (capture → relay + prod RTMP;
#                             SOURCE=test smoke-tests the same path pre-hardware)
#   scripts/prod.sh down      stop publishing
#   scripts/prod.sh status    publisher / public playlist / public page
#   scripts/prod.sh measure   OCR latency run against the public page
# Needs: MOQ_RELAY_URL and RTMP_PUBLISH_PASS exported; moq on PATH (~/.cargo/bin).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
PID=logs/prod-publish.pid
HLS_HOST="${HLS_HOST:-hls-laserdisc.vanessa-dev.com}"
PAGE_URL="${PAGE_URL:-https://moq-laserdisc.vanessa-dev.com/}"
mkdir -p logs

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

up() {
  : "${MOQ_RELAY_URL:?export MOQ_RELAY_URL first}"
  : "${RTMP_PUBLISH_PASS:?export RTMP_PUBLISH_PASS first (matches .env on the HLS VM)}"
  if alive "$PID"; then echo "already publishing (pid $(cat "$PID"))"; status; return; fi
  export SOURCE="${SOURCE:-capture}"   # SOURCE=test smoke-tests the prod path pre-hardware
  export RTMP_URL="${RTMP_URL:-rtmp://${HLS_HOST}:1935/laserdisc?user=laserdisc&pass=${RTMP_PUBLISH_PASS}}"
  scripts/run-forever.sh &
  echo $! > "$PID"
  echo "publishing started (pid $(cat "$PID"); run-forever logs in logs/)"
  sleep 5
  status
}

down() {
  if [[ -f "$PID" ]]; then
    pid="$(cat "$PID")"
    kill -TERM "$pid" 2>/dev/null      # run-forever traps TERM and stops its child
    sleep 1
    pkill -TERM -P "$pid" 2>/dev/null  # belt and braces for the ffmpeg|moq pipeline
    rm -f "$PID"
  fi
  pkill -f 'ffmpeg .*overlay.filter' 2>/dev/null
  pkill -f 'moq --client-connect' 2>/dev/null
  echo "publisher down"
}

status() {
  if alive "$PID"; then
    echo "publisher:  up (pid $(cat "$PID"); newest log: $(/bin/ls -t logs/publish-*.log 2>/dev/null | head -1))"
  else
    echo "publisher:  DOWN"
  fi
  J="$(mktemp)"
  if curl -sfL -c "$J" -b "$J" --max-time 8 "https://${HLS_HOST}/laserdisc/index.m3u8" -o /dev/null; then
    echo "hls origin: playlist flowing (https://${HLS_HOST}/laserdisc/index.m3u8)"
  else
    echo "hls origin: playlist NOT flowing"
  fi
  rm -f "$J"
  code="$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' "$PAGE_URL")"
  echo "page:       $PAGE_URL → HTTP $code"
}

measure() {
  # Both clocks are this machine's clock — run it here, not on a viewer machine.
  scripts/measure-latency.sh --url "$PAGE_URL" --source capture "$@" \
    && python3 scripts/endpoint_map.py --from-run || true
}

map() {
  python3 scripts/endpoint_map.py "$@"
}

help() {
  cat <<'EOF'
scripts/prod.sh up         # publish capture → relay + prod HLS (run-forever)
scripts/prod.sh down       # stop publishing
scripts/prod.sh status     # publisher / public playlist / public page
scripts/prod.sh measure    # OCR latency run vs the public page (extra flags pass through)
scripts/prod.sh map        # live prod map
EOF
}

case "${1:-}" in
  up)      up;;
  down)    down;;
  status)  status;;
  measure) shift; measure "$@";;
  map)     shift; map "$@";;
  help)    help;;
  *)       help; exit 2;;
esac
