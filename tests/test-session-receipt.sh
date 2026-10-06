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

# --- close: marks clean, fills at_close, updates index ---
RECEIPTS_DIR="$D" python3 scripts/session_receipt.py close --stack dev \
  || { echo "close exited non-zero"; exit 1; }

python3 - "$SESSION_FILE" "$D/data.json" <<'PY' || { echo "close schema check failed"; exit 1; }
import json, sys
session_path, data_path = sys.argv[1], sys.argv[2]
s = json.load(open(session_path))
assert s["end"] == "clean", f"expected clean, got {s['end']}"
assert s.get("ended_utc"), "ended_utc missing/empty"
at_close = s["publisher_hw"].get("at_close") or {}
assert at_close.get("model") or at_close.get("cpu"), "publisher_hw.at_close has no model/cpu"

d = json.load(open(data_path))
row = next(r for r in d["sessions"] if r["id"] == s["id"])
assert row["end"] == "clean", f"index row not updated to clean: {row['end']}"
print("ok")
PY
echo "session-receipt close ok"

# --- close with no open session for the stack: exit 0, warning on stderr ---
RECEIPTS_DIR="$D" python3 scripts/session_receipt.py close --stack dev 1>/dev/null 2>"$D/close-warn.stderr"
rc=$?
[[ $rc -eq 0 ]] || { echo "close with no open session should exit 0, got $rc"; exit 1; }
[[ -s "$D/close-warn.stderr" ]] || { echo "close with no open session printed no warning"; exit 1; }
echo "session-receipt close-noop ok"

# --- open twice (same stack): first becomes dirty, second is the only null row ---
SID_A="$(RECEIPTS_DIR="$D" python3 scripts/session_receipt.py open --stack dev --source test)"
SID_B="$(RECEIPTS_DIR="$D" python3 scripts/session_receipt.py open --stack dev --source test)"
[[ -n "$SID_A" && -n "$SID_B" && "$SID_A" != "$SID_B" ]] || { echo "expected two distinct dev session ids"; exit 1; }

python3 - "$D" "$SID_A" "$SID_B" <<'PY' || { echo "dirty-sweep (same stack) check failed"; exit 1; }
import json, sys
d, sid_a, sid_b = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(f"{d}/data.json"))
row_a = next(r for r in data["sessions"] if r["id"] == sid_a)
row_b = next(r for r in data["sessions"] if r["id"] == sid_b)
assert row_a["end"] == "dirty", f"first dev session should be dirty, got {row_a['end']}"
assert row_b["end"] is None, f"second dev session should still be open, got {row_b['end']}"
null_dev_rows = [r for r in data["sessions"] if r["stack"] == "dev" and r["end"] is None]
assert len(null_dev_rows) == 1 and null_dev_rows[0]["id"] == sid_b, "expected exactly one open dev row (the second)"
session_a = json.load(open(f"{d}/sessions/{sid_a}.json"))
assert session_a["end"] == "dirty", "session file for first dev session not marked dirty"
print("ok")
PY
echo "session-receipt dirty-sweep same-stack ok"

# --- open dev then open prod: dev stays open (dirty sweep is per-stack) ---
SID_C="$(RECEIPTS_DIR="$D" python3 scripts/session_receipt.py open --stack dev --source test)"
SID_D="$(RECEIPTS_DIR="$D" python3 scripts/session_receipt.py open --stack prod --source test)"

python3 - "$D" "$SID_C" "$SID_D" <<'PY' || { echo "dirty-sweep (cross-stack) check failed"; exit 1; }
import json, sys
d, sid_c, sid_d = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(f"{d}/data.json"))
row_c = next(r for r in data["sessions"] if r["id"] == sid_c)
row_d = next(r for r in data["sessions"] if r["id"] == sid_d)
assert row_c["end"] is None, f"dev session should stay open across a prod open, got {row_c['end']}"
assert row_d["end"] is None, f"prod session should be open, got {row_d['end']}"
print("ok")
PY
echo "session-receipt dirty-sweep cross-stack ok"

exit 0
