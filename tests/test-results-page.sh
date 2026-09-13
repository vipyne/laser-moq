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
grep -q 'TBD by human' README.md && { echo "README still has the placeholder latency table"; exit 1; }
exit 0
