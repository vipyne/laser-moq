#!/usr/bin/env bash
# resolve-device.sh <video-name-or-index> <audio-name-or-index>  → "V:A"
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
want_v="${1:?video device}"; want_a="${2:?audio device}"
if [[ -n "${AVF_LIST_FILE:-}" ]]; then list="$(cat "$AVF_LIST_FILE")"; else list="$("$HERE/list-devices.sh")"; fi
section() {  # section <video|audio> → lines "idx<TAB>name"  (BSD-awk safe — verified on macOS awk 20200816)
  awk -v want="$1" '
    /AVFoundation video devices/ {cur="video"; next}
    /AVFoundation audio devices/ {cur="audio"; next}
    cur==want { if (match($0, /\[[0-9]+\] /)) { idx=substr($0, RSTART+1, RLENGTH-3); name=substr($0, RSTART+RLENGTH); print idx "\t" name } }' <<<"$list"
}
find_idx() {  # find_idx <video|audio> <query>
  local q="$2"
  [[ "$q" =~ ^[0-9]+$ ]] && { echo "$q"; return 0; }
  section "$1" | awk -F'\t' -v q="$q" 'index(tolower($2), tolower(q)) {print $1; exit}'
}
v="$(find_idx video "$want_v")"; a="$(find_idx audio "$want_a")"
if [[ -z "$v" || -z "$a" ]]; then
  echo "device not found (video='$want_v' → '${v:-}', audio='$want_a' → '${a:-}'). Available:" >&2
  echo "$list" >&2
  exit 1
fi
echo "$v:$a"
