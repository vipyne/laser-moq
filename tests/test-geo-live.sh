#!/usr/bin/env bash
# e2e: dev stack up → one short measurement to a SCRATCH file → geo recorded → map renders.
set -u
cd "$(dirname "$0")/.."
[[ -n "${MOQ_RELAY_URL:-}" ]] || { echo "SKIP: MOQ_RELAY_URL not set"; exit 0; }
command -v docker >/dev/null && command -v node >/dev/null && command -v tesseract >/dev/null \
  || { echo "SKIP: docker/node/tesseract missing"; exit 0; }
OUT=logs/test-geo-live.json
echo '{"schema":1,"runs":[]}' > "$OUT"
scripts/dev.sh up test >/dev/null || exit 1
trap 'scripts/dev.sh down >/dev/null' EXIT
sleep 10
scripts/measure-latency.sh \
  --url 'http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8' \
  --samples 3 --interval-ms 3000 --out "$OUT" --notes "geo e2e" || exit 1
python3 - "$OUT" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1]))["runs"][-1]
g = r.get("geo") or {}
assert g.get("publisher"), "publisher geo missing"
assert g.get("relay"), "relay geo missing"
assert not g.get("hls") and not g.get("page"), "localhost endpoints must record null geo"
for v in (g["publisher"], g["relay"]):
    assert set(v) <= {"city","region","country","lat","lon"}
print("geo ok:", g["publisher"].get("city"), "/", g["relay"].get("city"))
PY
python3 scripts/endpoint_map.py --from-run --data "$OUT" | grep -q '┌' || { echo "from-run map failed"; exit 1; }
exit 0
