#!/usr/bin/env bash
# Local dev stack: moq-relay + MediaMTX container + publisher + site server.
#   scripts/dev.sh up [test|capture]   start everything (default: test source)
#   scripts/dev.sh down                measure latency, then stop everything
#                                      (SKIP_MEASURE=1 or FORCE=1 skips measure)
#   scripts/dev.sh status              what's running right now
#   scripts/dev.sh measure             OCR latency run against THIS stack's page
# Fully local by design: both legs run on this machine, isolating protocol
# architecture from network/geography. Relay is moq-relay on :4443 with a
# self-signed cert; the http:// URL makes moq-cli and <moq-watch> fetch
# /certificate.sha256 and pin the fingerprint (needs: cargo install moq-relay
# --locked --version 0.13.5, see ralph/HUMAN.md §3).
# Don't run tests/run.sh while the stack is up — its cleanup tears this down.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
COMPOSE=(docker compose -f hls-origin/compose.local.yml)
RELAY_PID=logs/dev-relay.pid
PUB_PID=logs/dev-publish.pid
WEB_PID=logs/dev-site.pid
IMPAIR_PID=logs/dev-impair.pid
PAGE_URL='http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8'
# Dev stack is always fully local — overrides any inherited relay env.
export MOQ_RELAY_URL='http://localhost:4443/anon'
mkdir -p logs

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

relay_up() {
  if alive "$RELAY_PID"; then
    echo "relay already running (pid $(cat "$RELAY_PID"))"
    return
  fi
  command -v moq-relay >/dev/null || {
    echo "moq-relay not installed: cargo install moq-relay --locked --version 0.13.5 (ralph/HUMAN.md §3)" >&2
    exit 1
  }
  # QUIC on UDP :4443; web listener on TCP :4443 serves /certificate.sha256 + WS fallback.
  moq-relay --server-bind '[::]:4443' --tls-generate localhost \
    --web-http-listen '[::]:4443' --auth-public anon > logs/dev-relay.log 2>&1 &
  echo $! > "$RELAY_PID"
  sleep 1
  if ! alive "$RELAY_PID"; then
    echo "moq-relay died at start (port taken? bad flags?) — logs/dev-relay.log:" >&2
    tail -5 logs/dev-relay.log >&2
    rm -f "$RELAY_PID"
    exit 1
  fi
  echo "moq-relay started on :4443 (log: logs/dev-relay.log)"
}

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

  relay_up
  "${COMPOSE[@]}" up -d || exit 1

  # Always point the local page at the local relay (gitignored; CI writes prod's).
  printf 'window.MOQ_RELAY_URL = "%s";\n' "$MOQ_RELAY_URL" > site/config.js
  echo "wrote site/config.js → $MOQ_RELAY_URL"

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

  if alive "$IMPAIR_PID"; then
    echo "impair server already running (pid $(cat "$IMPAIR_PID"))"
  else
    python3 scripts/impair-server.py > logs/dev-impair.log 2>&1 &
    echo $! > "$IMPAIR_PID"
    echo "impair server started on :9900 (page button; sudo rule: ralph/HUMAN.md §4)"
  fi

  sleep 3
  status
  echo
  echo "open: $PAGE_URL"
}

down() {
  [[ -n "${1:-}" ]] && { echo "usage: scripts/dev.sh down  (skip measure: SKIP_MEASURE=1, FORCE=1, or downdown)" >&2; exit 2; }
  # Measure while stream still up → run lands inside session window on receipt.
  local skip="${SKIP_MEASURE:-${FORCE:-}}"
  if [[ -z "$skip" ]] && alive "$PUB_PID"; then
    echo "latency measure before teardown (SKIP_MEASURE=1 / FORCE=1 / downdown to skip)"
    measure || true
  fi
  python3 scripts/session_receipt.py close --stack dev || true
  # Restore the network if an impair profile is still active.
  if grep -q '"active":true' logs/impair.state 2>/dev/null; then
    bash scripts/impair.sh off || echo "impair off failed — run scripts/impair.sh off manually" >&2
  fi
  for f in "$PUB_PID" "$WEB_PID" "$RELAY_PID" "$IMPAIR_PID"; do
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
  pkill -f 'moq-relay' 2>/dev/null
  pkill -f 'impair-server.py' 2>/dev/null
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
  if alive "$RELAY_PID" && curl -sf --max-time 3 http://localhost:4443/certificate.sha256 -o /dev/null; then
    echo "relay:      up (moq-relay :4443; log logs/dev-relay.log)"
  else
    echo "relay:      DOWN"; ok=0
  fi
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
  # Live map of THIS stack: relay, HLS, and page are all localhost by design.
  python3 scripts/endpoint_map.py --hls localhost --page localhost "$@"
}

help() {
  cat <<'EOF'
scripts/dev.sh up            # publish → local relay + local HLS (source: test colorbars)
scripts/dev.sh up test       # same as `up`
scripts/dev.sh up capture    # publish → local relay + local HLS (source: real physical media via capture card)
scripts/dev.sh up receipts   # :8000 site server only (browse receipts/results, no publishing)
scripts/dev.sh down          # measure latency, then stop (SKIP_MEASURE=1 or FORCE=1 skips measure)
scripts/dev.sh downdown      # fast full teardown: no measure, publisher + :8000 receipts site down
scripts/dev.sh status        # relay / container / publisher / site / playlist-flowing
scripts/dev.sh measure       # OCR latency run vs this stack's page (extra flags pass through)
scripts/dev.sh map           # live map (everything localhost by design)
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
