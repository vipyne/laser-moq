#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
f=site/index.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm' $f || { echo "moq/watch not pinned"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/hls.js@1.7.1' $f                 || { echo "hls.js not pinned"; exit 1; }
grep -q '<moq-watch' $f                                          || { echo "no <moq-watch>"; exit 1; }
grep -q '<moq-relay-host>/anon' $f                           || { echo "relay url missing"; exit 1; }
grep -q 'laserdisc.hang' $f                                       || { echo "broadcast name missing"; exit 1; }
grep -q 'lowLatencyMode' $f                                       || { echo "hls.js lowLatencyMode missing"; exit 1; }
grep -q 'id="clock-moq"' $f && grep -q 'id="clock-hls"' $f        || { echo "clocks missing"; exit 1; }
[[ "$(cat site/CNAME)" == "laserdisc.vanessa-dev.com" ]]          || { echo "CNAME wrong"; exit 1; }
exit 0
