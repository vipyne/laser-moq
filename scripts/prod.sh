#!/usr/bin/env bash
# Production publisher, for the x86 Mac wired to the LaserDisc (Pengo + media
# assumed connected). Publishes SOURCE=capture to the real relay + HLS origin
# via run-forever.sh, and runs the latency measurement from the same machine.
#   scripts/prod.sh up        start publishing (capture → relay + prod RTMP;
#                             SOURCE=test smoke-tests the same path pre-hardware)
#   scripts/prod.sh down      measure latency, then stop publishing
#                             (down fast / SKIP_MEASURE=1 / FORCE=1 skips measure)
#   scripts/prod.sh status    publisher / public playlist / public page
#   scripts/prod.sh measure   OCR latency run against the public page
# Needs: MOQ_RELAY_URL exported; moq on PATH (~/.cargo/bin). RTMP_PUBLISH_PASS
# is read from hls-origin/.env automatically (an exported value wins).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
PID=logs/prod-publish.pid
HLS_HOST="${HLS_HOST:-hls-laserdisc.vanessa-dev.com}"
PAGE_URL="${PAGE_URL:-https://moq-laserdisc.vanessa-dev.com/}"
mkdir -p logs

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

# Serve site/ on :8000 so the session's receipt is browsable right after down.
serve_receipts() {
  [[ "${RECEIPTS_SITE:-1}" == 0 ]] && return 0
  pkill -f 'http.server 8000' 2>/dev/null
  (python3 -m http.server 8000 --directory site >/dev/null 2>&1 &)
  echo
  echo "open: http://localhost:8000/receipts/"
}

up() {
  [[ "${1:-}" == "receipts" ]] && { serve_receipts; return; }   # site server only, nothing else
  : "${MOQ_RELAY_URL:?export MOQ_RELAY_URL first}"
  if [[ -z "${RTMP_PUBLISH_PASS:-}" && -f hls-origin/.env ]]; then
    set -a; source hls-origin/.env; set +a
  fi
  : "${RTMP_PUBLISH_PASS:?not exported and no hls-origin/.env (matches .env on the HLS VM)}"
  if alive "$PID"; then echo "already publishing (pid $(cat "$PID"))"; status; return; fi
  export SOURCE="${SOURCE:-capture}"   # SOURCE=test smoke-tests the prod path pre-hardware
  export RTMP_URL="${RTMP_URL:-rtmp://${HLS_HOST}:1935/laserdisc?user=laserdisc&pass=${RTMP_PUBLISH_PASS}}"
  scripts/run-forever.sh &
  echo $! > "$PID"
  echo "publishing started (pid $(cat "$PID"); run-forever logs in logs/)"
  python3 scripts/session_receipt.py open --stack prod --source "$SOURCE" || true
  sleep 5
  status
}

down() {
  # Measure while stream still up → run lands inside session window on receipt.
  local skip="${SKIP_MEASURE:-${FORCE:-}}"
  [[ "${1:-}" == "fast" ]] && skip=1
  if [[ -z "$skip" ]] && alive "$PID"; then
    echo "latency measure before teardown ('down fast', SKIP_MEASURE=1, or FORCE=1 to skip)"
    measure || true
  fi
  python3 scripts/session_receipt.py close --stack prod || true
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
  serve_receipts
}

# Fast full teardown: down without measure, then kill the receipts site.
downdown() {
  RECEIPTS_SITE=0 SKIP_MEASURE=1 down "$@"
  pkill -f 'http.server 8000' 2>/dev/null
  echo "receipts site down"
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
  # Source: $SOURCE, else open prod session's recorded source, else capture.
  local src="${SOURCE:-}"
  [[ -z "$src" ]] && src="$(python3 -c "
import json
s = json.load(open('site/receipts/data.json'))['sessions']
print(next((x['source'] for x in s if x['stack'] == 'prod' and x['end'] is None), ''))" 2>/dev/null)"
  scripts/measure-latency.sh --url "$PAGE_URL" --source "${src:-capture}" "$@" \
    && python3 scripts/endpoint_map.py --from-run || true
}

map() {
  python3 scripts/endpoint_map.py "$@"
}

help() {
  cat <<'EOF'
scripts/prod.sh up         # publish capture → relay + prod HLS (run-forever)
scripts/prod.sh up receipts # :8000 site server only (browse receipts/results, no publishing)
scripts/prod.sh down       # measure latency, then stop (down fast / SKIP_MEASURE=1 / FORCE=1 skips)
scripts/prod.sh downdown   # fast full teardown: no measure, publisher + :8000 receipts site down
scripts/prod.sh status     # publisher / public playlist / public page
scripts/prod.sh measure    # OCR latency run vs the public page (extra flags pass through)
scripts/prod.sh map        # live prod map
EOF
}

case "${1:-}" in
  up)      shift; up "$@";;
  down)     shift; down "$@";;
  downdown) shift; downdown "$@";;
  status)  status;;
  measure) shift; measure "$@";;
  map)     shift; map "$@";;
  help)    help;;
  *)       help; exit 2;;
esac
