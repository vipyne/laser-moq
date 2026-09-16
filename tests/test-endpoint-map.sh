#!/usr/bin/env bash
# Offline checks for scripts/endpoint_map.py (no network: --help, --demo, env guard).
set -u
cd "$(dirname "$0")/.."
f=scripts/endpoint_map.py
[[ -f $f ]] || { echo "missing $f"; exit 1; }
python3 -m py_compile "$f"                                        || { echo "py_compile failed"; exit 1; }
python3 "$f" --help >/dev/null                                    || { echo "--help failed"; exit 1; }
grep -q 'relay\.vanessa-dev\.com' "$f" && { echo "hardcoded relay url in $f"; exit 1; }
env -u MOQ_RELAY_URL python3 "$f" 2>&1 | grep -q 'MOQ_RELAY_URL not set' || { echo "env guard message missing"; exit 1; }
env -u MOQ_RELAY_URL python3 "$f" >/dev/null 2>&1 && { echo "should exit non-zero without MOQ_RELAY_URL"; exit 1; }
out=$(python3 "$f" --demo) || { echo "--demo failed"; exit 1; }
for m in P R H S; do
  grep -q "^  $m  " <<<"$out" || { echo "marker $m missing from --demo legend"; exit 1; }
done
grep -q '┌' <<<"$out" || { echo "map border missing from --demo"; exit 1; }
out=$(python3 "$f" --from-run --data tests/fixtures/results-geo.json) || { echo "--from-run failed"; exit 1; }
for m in P R H S; do
  grep -q "^  $m  " <<<"$out" || { echo "marker $m missing from --from-run legend"; exit 1; }
done
grep -q '2026-09-15' <<<"$out" || { echo "run date missing from --from-run output"; exit 1; }
grep -q 'New Orleans' <<<"$out" || { echo "stored geo missing from --from-run output"; exit 1; }
scripts/dev.sh help | grep -q 'map'  || { echo "dev.sh map missing from help"; exit 1; }
scripts/prod.sh help | grep -q 'map' || { echo "prod.sh map missing from help"; exit 1; }
grep -q 'from-run' scripts/prod.sh   || { echo "prod.sh measure does not print the from-run map"; exit 1; }
exit 0
