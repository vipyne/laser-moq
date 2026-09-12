# HUMAN.md — things only you can do

Ordered. Each item has the exact command(s). The ralph loop never runs these.
Nothing reaches GitHub until you check the gate in §1 — the loop only commits locally.

The relay endpoint is deliberately nowhere in this repo: `export MOQ_RELAY_URL=…`
in any shell that runs `scripts/` or `tests/`, and set the Actions variable in §1
before the Pages site can deploy.

## 1. GitHub repo + Pages
- [ ] **Gate: review before anything is pushed.** `git log --oneline` + skim the diffs
      (`git diff <last-commit-you-reviewed>..HEAD`). Only proceed when you're happy.
- [ ] `gh repo create vipyne/laser-moq --public --source . --push`
- [ ] `gh variable set MOQ_RELAY_URL --body 'https://<your-relay-host>/anon'` — the Pages
      workflow writes `site/config.js` from this; the run triggered by the first push
      fails without it (rerun afterwards: `gh workflow run pages`)
- [ ] Enable Pages via workflow: `gh api -X POST repos/vipyne/laser-moq/pages -f build_type=workflow`
      (if it says already exists: `gh api -X PUT repos/vipyne/laser-moq/pages -f build_type=workflow`)
- [ ] Custom domain: `gh api -X PUT repos/vipyne/laser-moq/pages -f cname=moq-laserdisc.vanessa-dev.com`
- [ ] Route 53 CNAME `moq-laserdisc.vanessa-dev.com → vipyne.github.io` (AWS_PROFILE=vanessa-dev):

```bash
ZONE=$(AWS_PROFILE=vanessa-dev aws route53 list-hosted-zones-by-name --dns-name vanessa-dev.com \
  --query 'HostedZones[0].Id' --output text)
AWS_PROFILE=vanessa-dev aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
  --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "moq-laserdisc.vanessa-dev.com",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "vipyne.github.io"}]
    }
  }]
}'
```

- [ ] After the cert shows in Settings → Pages: `gh api -X PUT repos/vipyne/laser-moq/pages -F https_enforced=true`
- [ ] Gate: `curl -sI https://moq-laserdisc.vanessa-dev.com/ | head -1` → 200

## 2. HLS origin VM
- [ ] Follow `docs/deploy-hls-origin.md` (new VM, DNS `hls-laserdisc.vanessa-dev.com`, ports 80/443/1935).
- [ ] Gate: `curl -sf https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8 | head -3` while `SOURCE=test RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=$RTMP_PUBLISH_PASS" scripts/publish.sh` runs.

## 3. Hardware
- Pengo not detected on 2026-09-10 (`scripts/list-devices.sh` shows no match); plug in and rerun the loop so Task 7 (capture probe + defaults) can run.
- [ ] Plug LaserDisc → Ocean Matrix → Pengo → Mac. `scripts/list-devices.sh` must show the Pengo in BOTH video and audio lists. Note the exact name and set `VIDEO_DEV`/`AUDIO_DEV` if it isn't "Pengo".
- [ ] `SOURCE=capture scripts/watch.sh` in one terminal, `SOURCE=capture HLS=0 scripts/publish.sh` in another → picture.

## 4. Browser checks
- [ ] With `SOURCE=test HLS=1 scripts/publish.sh` and local MediaMTX running (`docker compose -f hls-origin/compose.local.yml up -d`),
      serve the page (`cd site && python3 -m http.server 8000`) and
      open http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8 in Chrome.
      Expect: both players show the colour bars + burned-in clock; note the MoQ vs HLS delta vs the page clocks.
- [ ] Same URL in Safari: MoQ via WebSocket fallback should connect; HLS via native player.

## 5. Public end-to-end
- [ ] Phone on cellular: https://moq-laserdisc.vanessa-dev.com shows both streams.
- [ ] Read MoQ latency and HLS latency off the clocks; write them into README "Measured latency".
