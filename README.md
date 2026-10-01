# laser-moq
everything is cooler with lasers.

## What this is
a demo 'benchmarking' MoQ and HLS. it's more about the journey than the destination.

### tl;dr (no physical / hardware / media required)

1. do setup / installation stuff (see below)
2.

```bash
./scripts/dev.sh
==>
scripts/dev.sh up            # publish → local relay + local HLS (source: test colorbars)
scripts/dev.sh up test       # same as `up`
scripts/dev.sh up capture    # publish → local relay + local HLS (source: real physical media via capture card)
scripts/dev.sh up receipts   # :8000 site server only (browse receipts/results, no publishing)
scripts/dev.sh down          # measure latency, then stop (down fast / SKIP_MEASURE=1 / FORCE=1 skips)
scripts/dev.sh downdown      # fast full teardown: no measure, publisher + :8000 receipts site down
scripts/dev.sh status        # relay / container / publisher / site / playlist-flowing
scripts/dev.sh measure       # OCR latency run vs this stack's page (extra flags pass through)
scripts/dev.sh map           # live map (everything localhost by design)
```

typically:

`./scripts/dev.sh up` 
<see colorbars; watch until bored>
`./scripts/dev.sh down`
<wait for measuremnts>
<open http://localhost:8000/receipts>
<see info and stuff>
`./scripts/dev.sh downdown`
<profi†‡>

†not really.
‡typo intentional.

### Architecture

One ffmpeg process encodes once and **tees** the identical h264/aac stream to two
legs, so the MoQ-vs-HLS comparison is apples to apples (same bitrate, same GOP,
same encoder).

```
LaserDisc ─RCA─▶ Ocean Matrix ─HDMI─▶ Pengo ─USB─▶ ffmpeg (avfoundation)
                                                     │ h264_videotoolbox + aac, -f tee
                                    ┌────────────────┴─────────────────┐
                              [f=mpegts]pipe:1                 [f=flv]rtmp://HLS_HOST/laserdisc
                                    │                                  │
                   moq --client-connect $MOQ_RELAY_URL    MediaMTX (new VM)
                       --broadcast laserdisc.hang import ts          RTMP in → LL-HLS out
                                    │ QUIC                             │ HTTPS via Caddy
                                    ▼                                  ▼
                       MoQ relay ($MOQ_RELAY_URL)      https://<hls-host>/laserdisc/index.m3u8
                                    │ WebTransport / WSS               │ hls.js (lowLatencyMode)
                                    └──────────────┬───────────────────┘
                                                   ▼
                          https://moq-laserdisc.vanessa-dev.com — one page, two players side by side
                          (GitHub Pages for this repo + Route 53 CNAME)
```

### Hardware chain

LaserDisc player / VHS player / DVD player (RCA composite + stereo)
→ Ocean Matrix analog→HDMI converter
→ Pengo HDMI→USB capture card 
→ Mac.

## Setup

### Dependencies
- ffmpeg 7.1.1 (with avfoundation + videotoolbox)
- Docker
- rust
  - moq-cli 0.11.0
  - moq-relay 0.13.5
- Google Chrome (for playwright stuff)
- node/npm (>=20)

### Installation
```bash
cargo install moq-cli --locked
cargo install moq-relay --locked --version 0.13.5
```

for latency measurement-ing
```bash
brew install tesseract
cd tools/measure
npm install
```

## Run
### Dev
see #tl;dr-(no-physical-/-hardware-/-media-required)

### "Prod"
deploy a moq relay.

```bash
export MOQ_RELAY_URL=https://your-relay.example.com/anon
```

The exception is `scripts/dev.sh`: the dev stack is **fully local** (its own
moq-relay on :4443, self-signed cert pinned by fingerprint via the `http://`
URL scheme) and forces `MOQ_RELAY_URL=http://localhost:4443/anon` itself — on
loopback the latency difference is protocol architecture alone, the isolation
run the WAN numbers get contrasted against. See
[local-architecture.md](local-architecture.md).

(The public page gets it from `site/config.js`, written at deploy time by the
Pages workflow from the `MOQ_RELAY_URL` repo Actions variable; locally, copy
`site/config.example.js` to `site/config.js`, or pass `?relay=<url>`.)

If the relay requires tokens, they ride inside the same value — e.g.
`https://relay.example.com/laserdisc?jwt=<token>` — a publish-capable token in
the shell env, a subscribe-only token in the Actions variable. Setup:
`ralph/HUMAN.md` §6. Once enabled, `bash tests/test-auth.sh` verifies the token
protects publish while viewing stays anonymous.

Quick start with the built-in test source (colour bars + 440 Hz tone), MoQ leg only:

```bash
SOURCE=test HLS=0 scripts/publish.sh
```

Both legs (start local MediaMTX first: `docker compose -f hls-origin/compose.local.yml up -d`):

```bash
SOURCE=test scripts/publish.sh
```

Real capture: `SOURCE=capture scripts/publish.sh` (resolves the Pengo — "HDMI to U3 capture" — by name; sanity-check the card first with `scripts/preview.sh`).
Watch the MoQ leg locally with `scripts/watch.sh`.

| Env var | Default | Meaning |
|---|---|---|
| `SOURCE` | `capture` | `test` (testsrc2 + sine) or `capture` (avfoundation) |
| `MOQ_RELAY_URL` | *(required, no default)* | MoQ relay endpoint |
| `BROADCAST` | `laserdisc.hang` | broadcast name on the relay |
| `HLS` | `1` | `1` = tee to RTMP too, `0` = MoQ only |
| `RTMP_URL` | `rtmp://localhost:1935/laserdisc?user=laserdisc&pass=changeme` | MediaMTX RTMP ingest. Publishing needs credentials (user `laserdisc`); `changeme` is the local-dev password, prod's comes from `.env` on the VM |
| `VIDEO_DEV` | `HDMI to U3 capture` | capture video device (name substring or index) — the Pengo announces itself as "HDMI to U3 capture" |
| `AUDIO_DEV` | `HDMI to U3 capture` | capture audio device (name substring or index) |
| `SIZE` | capture `720x480`, test `1280x720` | frame size (the card only does NTSC 720x480) |
| `FPS` | capture `60`, test `30` | frame rate |

## Stage runbook

1. Plug in: LaserDisc → Ocean Matrix → Pengo → Mac.
2. `scripts/list-devices.sh` — confirm the Pengo appears in both video and audio
   lists (set `VIDEO_DEV`/`AUDIO_DEV` if its name differs).
3. HLS origin up: prod VM per `docs/deploy-hls-origin.md`, or locally
   `docker compose -f hls-origin/compose.local.yml up -d`.
4. `SOURCE=capture RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=$RTMP_PUBLISH_PASS" scripts/run-forever.sh`
   (restart wrapper; logs to `logs/`).
5. Open https://moq-laserdisc.vanessa-dev.com — both players, clocks under each.
6. If it dies: Ctrl-C the wrapper and rerun it; viewers auto-reconnect.

## Measured latency

Live numbers: **https://moq-laserdisc.vanessa-dev.com/results/** — measured
programmatically (Playwright screenshots the players, tesseract OCRs the
burned-in publisher clock; see `tools/measure/`).

How a run gets there: run `scripts/measure-latency.sh` on the publisher machine
(both clocks are one clock, no NTP skew), review the run it appended to
`site/results/data.json`, then commit + push — Pages redeploys the page.
Each clock-ocr sample records `encoder_to_glass_ms` plus `shot_spread_ms`
(screenshot window; the timestamp is its midpoint).

## Known caveats — why this benchmark is also bs

The same list ships at the bottom of the live page. For a talk about how most
benchmarks are bs, these are the slides:

- **Buffer asymmetry.** MoQ runs a 150 ms jitter buffer; HLS "typical" targets
  1.5 s and "ragged" 300 ms — and ~300 ms (3× the origin's 100 ms parts) is
  LL-HLS's floor, while MoQ's floor is zero. The matched-buffer comparison is
  `?moqlatency=300&hlspreset=ragged`.
- **The 150 ms is a handicap, not a gift.** `<moq-watch>` defaults to
  `real-time` (zero buffer); reload with `?moqlatency=real-time` to watch MoQ
  drop lower still — and stutter on any jitter. Latency is a buffer-policy dial
  on both protocols; what differs is where each protocol's floor sits.
- **Chain vs chain, not protocol vs protocol.** The "HLS" number includes
  FLV/RTMP ingest + MediaMTX remux + Caddy TLS; the "MoQ" number includes
  moq-cli repackaging + relay fanout. Each is a representative single-hop
  deployment (no CDN on either leg) — not isolated egress-protocol overhead.
- **Encoder-to-glass, not glass-to-glass.** The clock is burned at encode, so
  LaserDisc→capture-card latency is invisible — identically for both legs.
- **The measured numbers are Chrome numbers.** The harness drives Chrome:
  WebTransport + hls.js/MSE. Safari would be WSS fallback + native HLS —
  different pipelines entirely.
- **Harness limits.** Samples are midpoint-timestamped screenshots
  (±`shot_spread_ms`/2); publisher, browser, and OCR share one machine; ~12
  samples per run; OCR misreads are filtered only by plausibility; runs are
  human-curated and the results tiles headline the latest run.
- **Video only.** Audio latency, A/V sync, startup time, and rebuffering are
  unmeasured.
- **Local vs WAN.** The all-local dev stack isolates protocol architecture but
  hides QUIC's loss-recovery advantages; WAN runs add network + geography.
  The page's "impair network" button (local stack only; `scripts/impair.sh`,
  dummynet on viewer ports :8888 + :4443, delay/loss applied per direction;
  the MoQ ingest leg is exempted via its pinned source port) puts the network
  variable back under test.

## Tests

`bash tests/run.sh` runs every `tests/test-*.sh`. `test-roundtrip.sh` and
`test-run-forever.sh` need network (the relay) + moq-cli; `test-hls.sh` needs
Docker too. `test-resolve-device.sh`, `test-site.sh`, `test-results-page.sh`,
`test-endpoint-map.sh`, and `test-auth.sh` are offline. `test-measure.sh` self-skips its OCR
self-test when tesseract, node, or `tools/measure/node_modules` is missing. `test-auth.sh`
self-skips until MoQ auth is enabled (see `ralph/HUMAN.md` §6).

## Troubleshooting

- **Device index moved** (USB replug renumbers avfoundation): use name
  substrings — `VIDEO_DEV="HDMI to U3 capture"` — not indices.
- **Relay down**: human-only — check the relay host per your own infra notes
  (kept outside this repo on purpose).
- **Version skew** (publish works but export/watch is silent): install the
  relay-matched CLI — `cargo install moq-cli --version 0.8.4 --locked --force`.
- **Safari**: no WebTransport; the relay speaks WebSocket on 443, `<moq-watch>`
  falls back automatically.
- **HLS origin offline**: the tee uses `onfail=ignore` — the MoQ leg keeps
  going; fix the origin and restart the publisher to resume the HLS leg.

## Layout

| Path | Responsibility |
|---|---|
| `scripts/publish.sh` | The demo: ffmpeg (test or capture source) → tee → `moq import ts` + RTMP. |
| `scripts/overlay.filter` | drawtext filter (wall clock, ms). |
| `scripts/resolve-device.sh` | Turn a device-name substring into avfoundation `video:audio` indices. |
| `scripts/list-devices.sh` | Wrapper around `ffmpeg -f avfoundation -list_devices`. |
| `scripts/watch.sh` | Local subscriber: `moq … export fmp4 \| ffplay -`. |
| `scripts/preview.sh` | Eyeball the capture card locally (ffplay, no encode/network); `FRAME=x.png` grabs a still. |
| `scripts/dev.sh` | Local dev stack in one command (relay + HLS + publisher + site, all localhost): `up [test\|capture]` / `down` / `status` / `help`. |
| `scripts/impair.sh` | Dummynet impairment (dnctl + pfctl) for the local stack's viewer legs: `on [wifi\|bad]` / `off` / `status`. |
| `scripts/impair-server.py` | :9900 localhost endpoint behind the page's "impair network" button (started by `dev.sh`). |
| `scripts/prod.sh` | Publisher runner for the stage x86 Mac: `up` / `down` / `status` / `measure` (needs `MOQ_RELAY_URL` + `RTMP_PUBLISH_PASS`). |
| `scripts/run-forever.sh` | Restart wrapper around `publish.sh` with backoff + log. |
| `scripts/measure-latency.sh` | Wrapper around the OCR latency harness; appends a run to `site/results/data.json`. |
| `scripts/endpoint_map.py` | ASCII world map of the deployment (publisher, relay, HLS origin, page CDN) + path diagrams; `--demo` for offline. |
| `tools/measure/` | The harness: Playwright drives installed Chrome, tesseract reads the burned-in clock. |
| `hls-origin/mediamtx.yml` | MediaMTX config (RTMP in, LL-HLS out). |
| `hls-origin/compose.local.yml` | Laptop: mediamtx only. |
| `hls-origin/compose.yml` | Prod: mediamtx + caddy (TLS for `$HLS_DOMAIN`). |
| `hls-origin/Caddyfile` | `HLS_DOMAIN → mediamtx:8888`. |
| `site/index.html` | Public page: `<moq-watch>` + hls.js side by side, clocks. |
| `site/results/index.html` | `/results`: summary tiles + SVG chart + runs table from `data.json`; no libraries. |
| `site/results/data.json` | Committed, append-only history of measured runs (schema v1). |
| `site/CNAME` | `moq-laserdisc.vanessa-dev.com`. |
| `site/config.example.js` | Template for gitignored `site/config.js` (`window.MOQ_RELAY_URL`). |
| `.github/workflows/pages.yml` | Publish `site/` to GitHub Pages (writes `config.js` from the `MOQ_RELAY_URL` Actions variable). |
| `tests/` | Bash tests (`run.sh` + `test-*.sh` + fixtures). |
| `docs/deploy-hls-origin.md` | Human runbook for the new HLS VM. |
| `ralph/HUMAN.md` | Everything the human must do (infra, DNS, hardware, browser checks). |
| `ralph/PROGRESS.md` | Ralph loop's running notes (what worked, what failed, versions). |
