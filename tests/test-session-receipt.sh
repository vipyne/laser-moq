#!/usr/bin/env bash
# scripts/session_receipt.py: `open` writes a session file + index row.
# Everything runs against RECEIPTS_DIR=$(mktemp -d) — repo files untouched.
set -u
cd "$(dirname "$0")/.."
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

MOQ_RELAY_URL='https://relay.example.com/livestream?jwt=FAKESECRET' \
  RECEIPTS_DIR="$D" python3 scripts/session_receipt.py open --stack dev --source test \
  || { echo "open exited non-zero"; exit 1; }

mapfile -t sessions < <(find "$D/sessions" -maxdepth 1 -name '[0-9]*Z-dev.json' 2>/dev/null)
[[ ${#sessions[@]} -eq 1 ]] || { echo "expected exactly one session file, found ${#sessions[@]}"; exit 1; }
SESSION_FILE="${sessions[0]}"

python3 - "$SESSION_FILE" "$D/data.json" <<'PY' || { echo "schema check failed"; exit 1; }
import json, re, sys
session_path, data_path = sys.argv[1], sys.argv[2]

s = json.load(open(session_path))
assert re.match(r'^\d{8}-\d{6}Z-dev$', s["id"]), f"bad id: {s['id']}"
assert s["stack"] == "dev"
assert s["source"] == "test"
assert s["end"] is None
assert s.get("started_utc"), "started_utc missing/empty"
for key in ("config", "versions", "publisher_hw", "probes", "endpoint_map",
            "timeline", "log_excerpt", "viewer_note"):
    assert key in s, f"missing key: {key}"
at_open = s["publisher_hw"].get("at_open") or {}
assert at_open.get("model") or at_open.get("cpu"), "publisher_hw.at_open has no model/cpu"

d = json.load(open(data_path))
assert d["schema"] == 1
assert len(d["sessions"]) == 1
row = d["sessions"][0]
assert row["id"] == s["id"]
assert row["end"] is None
print("ok")
PY

grep -rq FAKESECRET "$D" && { echo "jwt leaked into receipts dir"; exit 1; }
grep -rq 'relay.example.com/livestream' "$D" || { echo "relay host+path stripped too aggressively"; exit 1; }

echo "session-receipt open ok"
exit 0
