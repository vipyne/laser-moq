#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
f=site/index.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm' $f || { echo "moq/watch not pinned"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/hls.js@1.7.1' $f                 || { echo "hls.js not pinned"; exit 1; }
grep -q '<moq-watch' $f                                          || { echo "no <moq-watch>"; exit 1; }
grep -q 'window.MOQ_RELAY_URL' $f                                 || { echo "relay config hook missing"; exit 1; }
# config.js is gitignored and deliberately holds the real URL locally — skip it
grep -rq --exclude=config.js 'relay\.vanessa-dev\.com' site/ && { echo "hardcoded relay url in site/"; exit 1; }
[[ -f site/config.example.js ]]                                   || { echo "missing site/config.example.js"; exit 1; }
grep -q 'laserdisc.hang' $f                                       || { echo "broadcast name missing"; exit 1; }
grep -q 'lowLatencyMode' $f                                       || { echo "hls.js lowLatencyMode missing"; exit 1; }
grep -q 'id="clock-moq"' $f && grep -q 'id="clock-hls"' $f        || { echo "clocks missing"; exit 1; }
grep -q 'id="tc-moq"' $f && grep -q 'id="tc-hls"' $f              || { echo "timecode strip missing"; exit 1; }
[[ "$(cat site/CNAME)" == "moq-laserdisc.vanessa-dev.com" ]]          || { echo "CNAME wrong"; exit 1; }
exit 0
