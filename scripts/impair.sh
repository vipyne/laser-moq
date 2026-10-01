#!/usr/bin/env bash
# Dummynet impairment for the local stack's viewer-facing legs (HLS :8888,
# relay :4443) — simulates a bad last mile on loopback. The publisher's MoQ
# ingest rides the same :4443, exempted via its pinned source port 44431
# (publish.sh); HLS ingest (:1935) is untouched, so both chains are impaired
# on the viewer leg only. Profile numbers apply per direction (wifi ≈ 100ms
# RTT). Network Link Conditioner has no CLI; this drives the same dummynet
# via dnctl + pfctl.
#   scripts/impair.sh on [profile]   profiles: wifi (50ms, 1% loss), bad (150ms, 5% loss)
#   scripts/impair.sh off            restore /etc/pf.conf, flush pipes
#   scripts/impair.sh status         JSON one-liner; no sudo
# on/off need passwordless sudo for dnctl + pfctl: ralph/HUMAN.md §4.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
mkdir -p logs
STATE=logs/impair.state
ANCHOR=laser-moq
PORTS='{ 8888 4443 }'
PUB_SRC=44431

profile_args() {
  case "$1" in
    wifi) echo "delay 50 plr 0.01";;
    bad)  echo "delay 150 plr 0.05";;
    *) echo "unknown profile '$1' (wifi|bad)" >&2; return 2;;
  esac
}

on() {
  local profile="${1:-wifi}" args
  args="$(profile_args "$profile")"
  # shellcheck disable=SC2086
  sudo -n dnctl pipe 1 config $args
  # pf only evaluates referenced anchors: reload system rules + our hooks.
  { cat /etc/pf.conf
    echo "dummynet-anchor \"$ANCHOR\""
    echo "anchor \"$ANCHOR\""
  } | sudo -n pfctl -q -f -
  sudo -n pfctl -q -a "$ANCHOR" -f - <<EOF
no dummynet in quick proto udp from any port $PUB_SRC to any
no dummynet in quick proto udp from any to any port $PUB_SRC
dummynet in quick proto { tcp udp } from any to any port $PORTS pipe 1
dummynet in quick proto { tcp udp } from any port $PORTS to any pipe 1
EOF
  sudo -n pfctl -E 2>/dev/null || true
  printf '{"active":true,"profile":"%s"}\n' "$profile" > "$STATE"
  echo "impair on: $profile ($args) — ports 8888 + 4443"
}

off() {
  sudo -n pfctl -q -a "$ANCHOR" -F all 2>/dev/null || true
  # pfctl -E refcount is left bumped; pf stays enabled with the default rules.
  sudo -n pfctl -q -f /etc/pf.conf
  sudo -n dnctl -q flush
  printf '{"active":false,"profile":null}\n' > "$STATE"
  echo "impair off"
}

status() { cat "$STATE" 2>/dev/null || printf '{"active":false,"profile":null}\n'; }

case "${1:-}" in
  on)     shift; on "$@";;
  off)    off;;
  status) status;;
  *)      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
