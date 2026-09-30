#!/usr/bin/env bash
# Local dev stack: MediaMTX container + publisher + site server, in one place.
#   scripts/dev.sh up [test|capture]   start everything (default: test source)
#   scripts/dev.sh down                measure latency, then stop everything
#                                      (down fast / SKIP_MEASURE=1 / FORCE=1 skips measure)
#   scripts/dev.sh status              what's running right now
#   scripts/dev.sh measure             OCR latency run against THIS stack's page
# `up` needs MOQ_RELAY_URL; writes site/config.js from it if the file is missing.
# Don't run tests/run.sh while the stack is up — its cleanup tears this down.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
COMPOSE=(docker compose -f hls-origin/compose.local.yml)
PUB_PID=logs/dev-publish.pid
WEB_PID=logs/dev-site.pid
PAGE_URL='http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8'
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
  local src="${1:-${SOURCE:-test}}"   # positional wins; $SOURCE honored; default test
  [[ "$src" == "receipts" ]] && { serve_receipts; return; }   # site server only, nothing else
  [[ "$src" == "test" || "$src" == "capture" ]] || { echo "usage: scripts/dev.sh up [test|capture|receipts] (or SOURCE=…)" >&2; exit 2; }
  : "${MOQ_RELAY_URL:?export MOQ_RELAY_URL first (the relay endpoint is deliberately not in the repo)}"

  "${COMPOSE[@]}" up -d || exit 1

  if [[ ! -f site/config.js ]]; then
    printf 'window.MOQ_RELAY_URL = "%s";\n' "$MOQ_RELAY_URL" > site/config.js
    echo "wrote site/config.js from \$MOQ_RELAY_URL (gitignored)"
  fi

  if alive "$PUB_PID"; then
    echo "publisher already running (pid $(cat "$PUB_PID"))"
  else
    SOURCE="$src" scripts/publish.sh > logs/dev-publish.log 2>&1 &
    echo $! > "$PUB_PID"
    echo "publisher started: SOURCE=$src (log: logs/dev-publish.log)"
    python3 scripts/session_receipt.py open --stack dev --source "$src" || true
  fi

  if alive "$WEB_PID"; then
    echo "site server already running (pid $(cat "$WEB_PID"))"
  else
    python3 -m http.server 8000 --directory site > /dev/null 2>&1 &
    echo $! > "$WEB_PID"
    echo "site server started on :8000"
  fi

  sleep 3
  status
  echo
  echo "open: $PAGE_URL"
}

down() {
  # Measure while stream still up → run lands inside session window on receipt.
  local skip="${SKIP_MEASURE:-${FORCE:-}}"
  [[ "${1:-}" == "fast" ]] && skip=1
  if [[ -z "$skip" ]] && alive "$PUB_PID"; then
    echo "latency measure before teardown ('down fast', SKIP_MEASURE=1, or FORCE=1 to skip)"
    measure || true
  fi
  python3 scripts/session_receipt.py close --stack dev || true
  for f in "$PUB_PID" "$WEB_PID"; do
    if [[ -f "$f" ]]; then
      pid="$(cat "$f")"
      pkill -TERM -P "$pid" 2>/dev/null   # publish.sh is `ffmpeg | moq`; kill the children too
      kill "$pid" 2>/dev/null
      rm -f "$f"
    fi
  done
  # strays from ad-hoc runs outside this script
  pkill -f 'ffmpeg .*overlay.filter' 2>/dev/null
  pkill -f 'moq --client-connect' 2>/dev/null
  pkill -f 'http.server 8000' 2>/dev/null
  "${COMPOSE[@]}" down 2>/dev/null
  echo "dev stack down"
  serve_receipts
}

# Fast full teardown: down without measure, then kill the receipts site.
downdown() {
  RECEIPTS_SITE=0 SKIP_MEASURE=1 down "$@"
  pkill -f 'http.server 8000' 2>/dev/null
  echo "receipts site down"
}

status() {
  local ok=1
  if [[ -n "$("${COMPOSE[@]}" ps --status running -q 2>/dev/null)" ]]; then
    echo "mediamtx:   up (laser-mediamtx; RTMP :1935, LL-HLS :8888)"
  else
    echo "mediamtx:   DOWN"; ok=0
  fi
  if alive "$PUB_PID"; then
    echo "publisher:  up (pid $(cat "$PUB_PID"); log logs/dev-publish.log)"
  else
    echo "publisher:  DOWN"; ok=0
  fi
  if alive "$WEB_PID"; then
    echo "site:       up (http://localhost:8000)"
  else
    echo "site:       DOWN"; ok=0
  fi
  if [[ $ok == 1 ]]; then
    J="$(mktemp)"
    if curl -sfL -c "$J" -b "$J" --max-time 5 http://localhost:8888/laserdisc/index.m3u8 -o /dev/null; then
      echo "playlist:   flowing (http://localhost:8888/laserdisc/index.m3u8)"
    else
      echo "playlist:   not yet (publisher warming up? see logs/dev-publish.log)"
    fi
    rm -f "$J"
  fi
}

measure() {
  # Measure the dev stack's own page — not the public one — so the HLS pane
  # points at the local MediaMTX this stack is actually publishing to.
  scripts/measure-latency.sh --url "$PAGE_URL" --notes "dev stack" "$@"
}

map() {
  # Live map of THIS stack: relay is real; HLS/page are localhost (location unknown by design).
  python3 scripts/endpoint_map.py --hls localhost --page localhost "$@"
}

help() {
  cat <<'EOF'
scripts/dev.sh up            # publish → relay + HLS (source: test colorbars)
scripts/dev.sh up test       # same as `up`
scripts/dev.sh up capture    # publish → relay + HLS (source: real physical media via capture card)
scripts/dev.sh up receipts   # :8000 site server only (browse receipts/results, no publishing)
scripts/dev.sh down          # measure latency, then stop (down fast / SKIP_MEASURE=1 / FORCE=1 skips)
scripts/dev.sh downdown      # fast full teardown: no measure, publisher + :8000 receipts site down
scripts/dev.sh status        # container / publisher / site / playlist-flowing
scripts/dev.sh measure       # OCR latency run vs this stack's page (extra flags pass through)
scripts/dev.sh map           # live map (relay real, HLS/page localhost by design)
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
