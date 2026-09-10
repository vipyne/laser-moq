#!/usr/bin/env bash
# Keep publish.sh running. Restarts after 2s on any exit. Ctrl-C stops everything.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/../logs"
LOG="$HERE/../logs/publish-$(date +%Y%m%d-%H%M%S).log"
MAX_RESTARTS="${MAX_RESTARTS:-0}"   # 0 = unlimited
n=0; child=
stop() { echo "stopping" | tee -a "$LOG"; [[ -n "$child" ]] && { pkill -TERM -P "$child" 2>/dev/null; kill -TERM "$child" 2>/dev/null; }; exit 0; }
trap stop INT TERM
while :; do
  n=$((n+1))
  echo "[$(date +%T)] start #$n" | tee -a "$LOG"
  "$HERE/publish.sh" >>"$LOG" 2>&1 &
  child=$!
  wait "$child"; rc=$?
  echo "[$(date +%T)] exited rc=$rc" | tee -a "$LOG"
  [[ "$MAX_RESTARTS" != "0" && "$n" -ge "$MAX_RESTARTS" ]] && exit "$rc"
  sleep 2
done
