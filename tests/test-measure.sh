#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
f=site/results/data.json
[[ -f $f ]] || { echo "missing $f"; exit 1; }
python3 -m json.tool "$f" >/dev/null 2>&1 || { echo "data.json is not valid JSON"; exit 1; }
python3 - "$f" <<'PY' || { echo "data.json schema check failed"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == 1 and isinstance(d.get("runs"), list)
for r in d["runs"]:
    assert "?" not in r["target"], "target must be query-stripped"
    for s in r["samples"]:
        assert s["transport"] in ("moq", "hls") and s["method"] in ("clock-ocr", "hlsjs-api")
PY
[[ -f tools/measure/package.json ]] || { echo "missing tools/measure/package.json"; exit 1; }
grep -q '"playwright"' tools/measure/package.json || { echo "playwright not pinned"; exit 1; }
[[ -x scripts/measure-latency.sh ]] || { echo "measure-latency.sh missing or not executable"; exit 1; }
grep -q 'window.__hls' site/index.html || { echo "window.__hls hook missing from site/index.html"; exit 1; }
command -v tesseract >/dev/null || { echo "SKIP: tesseract not installed"; exit 0; }
command -v node >/dev/null || { echo "SKIP: node not installed"; exit 0; }
[[ -d tools/measure/node_modules ]] || { echo "SKIP: npm install not run in tools/measure"; exit 0; }
node tools/measure/measure.mjs --self-test || { echo "self-test failed"; exit 1; }
exit 0
