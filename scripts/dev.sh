#!/usr/bin/env bash
# Local dev stack: MediaMTX container + publisher + site server, in one place.
#   scripts/dev.sh up [test|capture]   start everything (default: test source)
#   scripts/dev.sh down                stop everything (incl. ad-hoc strays)
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

up() {
  local src="${1:-test}"
  [[ "$src" == "test" || "$src" == "capture" ]] || { echo "usage: scripts/dev.sh up [test|capture]" >&2; exit 2; }
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
scripts/dev.sh up            # test source (needs MOQ_RELAY_URL exported)
scripts/dev.sh up capture    # real LaserDisc via the Pengo
scripts/dev.sh status        # container / publisher / site / playlist-flowing
scripts/dev.sh measure       # OCR latency run vs this stack's page (extra flags pass through)
scripts/dev.sh map           # live map (relay real, HLS/page localhost by design)
scripts/dev.sh down          # everything, including strays from manual runs
EOF
}

case "${1:-}" in
  up)      shift; up "$@";;
  down)    down;;
  status)  status;;
  measure) shift; measure "$@";;
  map)     shift; map "$@";;
  help)    help;;
  *)       help; exit 2;;
esac
