#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
f=site/results/index.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'data.json' $f || { echo "page does not load ./data.json"; exit 1; }
grep -Eq '<script[^>]*src=' $f && { echo "external script in results page (must be no-library)"; exit 1; }
grep -q 'id="tile-moq"' $f && grep -q 'id="tile-hls"' $f || { echo "summary tiles missing"; exit 1; }
grep -qi 'glass' $f || { echo "no glass-to-glass wording"; exit 1; }
grep -q 'results/' site/index.html || { echo "live page does not link to results/"; exit 1; }
grep -q 'id="map"' $f || { echo "ascii map element missing"; exit 1; }
grep -q 'TBD by human' README.md && { echo "README still has the placeholder latency table"; exit 1; }
grep -q 'id="how-to-read"' $f       || { echo "how-to-read intro missing"; exit 1; }
grep -q 'id="latest-run-label"' $f  || { echo "latest-run label missing"; exit 1; }
grep -q 'id="map-title"' $f         || { echo "dynamic map title missing"; exit 1; }
grep -qi 'latest run only' $f       || { echo "tile scope wording missing"; exit 1; }
exit 0
