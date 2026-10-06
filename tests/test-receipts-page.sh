#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

# index.html tests
f=site/receipts/index.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'data.json' $f || { echo "page does not load ./data.json"; exit 1; }
grep -Eq '<script[^>]*src=' $f && { echo "external script in receipts page (must be no-library)"; exit 1; }
grep -q 'id="sessions"' $f || { echo "sessions container missing"; exit 1; }
grep -q 'class="stack' $f || { echo "stack badge class missing"; exit 1; }
grep -q '.stack {' $f || { echo "stack style missing"; exit 1; }
grep -q 'class="end-state' $f || { echo "end-state column class missing"; exit 1; }
grep -q 'session.html?id=' $f || { echo "links to session.html?id= missing"; exit 1; }
grep -q '../results/' $f || { echo "link to ../results/ missing from receipts list"; exit 1; }

# session.html tests
f=site/receipts/session.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'sessions/' $f || { echo "does not reference sessions/"; exit 1; }
grep -q 'endpoints.json' $f || { echo "does not reference endpoints.json"; exit 1; }
grep -q '../results/data.json' $f || { echo "does not reference ../results/data.json"; exit 1; }
grep -q 'id="map"' $f && grep -q '<pre' $f || { echo "map pre element missing"; exit 1; }
grep -q 'id="log"' $f && grep -q '<pre' $f || { echo "log pre element missing"; exit 1; }
grep -q 'no such session' $f || { echo "missing error text for unknown id"; exit 1; }

exit 0
