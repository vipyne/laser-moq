#!/usr/bin/env bash
# Missing capture device is permanent: publish.sh exits 69, run-forever stops without retry.
set -u
cd "$(dirname "$0")/.."
command -v moq >/dev/null || { echo "skip: moq-cli not installed"; exit 0; }

export AVF_LIST_FILE=tests/fixtures/avf-no-pengo.txt
export SOURCE=capture MOQ_RELAY_URL=https://example.invalid/anon
export VIDEO_DEV="HDMI to U3 capture" AUDIO_DEV="HDMI to U3 capture"

scripts/publish.sh >/dev/null 2>&1
rc=$?
[[ $rc == 69 ]] || { echo "publish.sh rc=$rc, want 69 on missing device"; exit 1; }

export MAX_RESTARTS=5
out="$(timeout 15 scripts/run-forever.sh 2>&1)"
rc=$?
[[ $rc == 69 ]] || { echo "run-forever rc=$rc, want 69 (timeout = still looping)"; exit 1; }
grep -q 'start #1' <<<"$out"            || { echo "missing first start"; exit 1; }
grep -q 'start #2' <<<"$out" && { echo "retried a permanent error"; exit 1; }
grep -qi 'not retrying' <<<"$out"       || { echo "missing not-retrying message"; exit 1; }
echo "device-missing no-retry ok"
exit 0
