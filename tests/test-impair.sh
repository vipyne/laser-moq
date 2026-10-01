#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
[[ -x scripts/impair.sh ]] || { echo "impair.sh missing or not executable"; exit 1; }
bash -n scripts/impair.sh || { echo "impair.sh syntax error"; exit 1; }
[[ -f scripts/impair-server.py ]] || { echo "impair-server.py missing"; exit 1; }
python3 -m py_compile scripts/impair-server.py || { echo "impair-server.py syntax error"; exit 1; }

# status needs no sudo and always prints JSON
out=$(bash scripts/impair.sh status) || { echo "status failed"; exit 1; }
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "active" in d' "$out" \
  || { echo "status is not {active,...} JSON: $out"; exit 1; }

# unknown profile rejected before any sudo happens
bash scripts/impair.sh on bogus-profile 2>/dev/null && { echo "bogus profile accepted"; exit 1; }

# page: button exists, guarded to localhost, pointed at the control server
f=site/index.html
grep -q 'id="impair-btn"' $f  || { echo "impair button missing from page"; exit 1; }
grep -q 'localhost:9900' $f   || { echo "page does not call the impair server"; exit 1; }
grep -q 'location.hostname' $f || { echo "impair button not guarded to the local page"; exit 1; }

# dev stack starts/stops the control server
grep -q 'impair-server.py' scripts/dev.sh || { echo "dev.sh does not manage impair-server"; exit 1; }

# MoQ ingest exempted (pinned source port) so impairment hits viewer legs only
grep -q 'no dummynet' scripts/impair.sh || { echo "ingest exemption missing from impair.sh"; exit 1; }
grep -q '44431' scripts/publish.sh || { echo "publisher MoQ source port not pinned"; exit 1; }

# control server rejects foreign origins
grep -q 'ALLOWED_ORIGINS' scripts/impair-server.py || { echo "origin check missing from impair-server"; exit 1; }
exit 0
