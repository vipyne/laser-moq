#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
export AVF_LIST_FILE=tests/fixtures/avfoundation-list.txt
r="$(scripts/resolve-device.sh Pengo Pengo)"        || { echo "expected exit 0"; exit 1; }
[[ "$r" == "2:2" ]]                                 || { echo "got '$r' want 2:2"; exit 1; }
r="$(scripts/resolve-device.sh "MacBook Pro Camera" Loom)"
[[ "$r" == "0:1" ]]                                 || { echo "got '$r' want 0:1"; exit 1; }
r="$(scripts/resolve-device.sh 3 0)"
[[ "$r" == "3:0" ]]                                 || { echo "numeric passthrough got '$r'"; exit 1; }
scripts/resolve-device.sh Nope Pengo >/dev/null 2>&1 && { echo "expected failure for missing device"; exit 1; }
exit 0
