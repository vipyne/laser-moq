# LIVE from a LaserDisc — over Media over QUIC

## What this is

A conference stunt hack: the analog output of a LaserDisc player, captured into a
Mac and livestreamed over **Media over QUIC** to a public URL, with an identical
**LL-HLS** stream beside it so the audience can read the latency difference off
two clocks. Design and rationale: [the spec](docs/superpowers/specs/2026-08-29-laserdisc-moq-livestream-design.md).

## Architecture

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

## Hardware chain

LaserDisc player (RCA composite + stereo) → Ocean Matrix analog→HDMI converter →
Pengo HDMI→USB capture card (UVC: shows up as camera + audio device in
avfoundation) → Mac.

## Install

```bash
cargo install moq-cli --locked
```

`moq-cli 0.11.0` (crates.io, 2026-09-10) round-trips cleanly against the relay's
`moq-relay 0.13.5`. ffmpeg 7.1.1 (with avfoundation + videotoolbox) and Docker
are also required.

## Run

Everything needs `MOQ_RELAY_URL` — the MoQ relay endpoint, deliberately not
hardcoded anywhere in this repo:

```bash
export MOQ_RELAY_URL=https://your-relay.example.com/anon
```

(The public page gets it from `site/config.js`, written at deploy time by the
Pages workflow from the `MOQ_RELAY_URL` repo Actions variable; locally, copy
`site/config.example.js` to `site/config.js`, or pass `?relay=<url>`.)

Quick start with the built-in test source (colour bars + 440 Hz tone), MoQ leg only:

```bash
SOURCE=test HLS=0 scripts/publish.sh
```

Both legs (start local MediaMTX first: `docker compose -f hls-origin/compose.local.yml up -d`):

```bash
SOURCE=test scripts/publish.sh
```

Real capture: `SOURCE=capture scripts/publish.sh` (resolves the Pengo by name).
Watch the MoQ leg locally with `scripts/watch.sh`.

| Env var | Default | Meaning |
|---|---|---|
| `SOURCE` | `capture` | `test` (testsrc2 + sine) or `capture` (avfoundation) |
| `MOQ_RELAY_URL` | *(required, no default)* | MoQ relay endpoint |
| `BROADCAST` | `laserdisc.hang` | broadcast name on the relay |
| `HLS` | `1` | `1` = tee to RTMP too, `0` = MoQ only |
| `RTMP_URL` | `rtmp://localhost:1935/laserdisc?user=laserdisc&pass=changeme` | MediaMTX RTMP ingest. Publishing needs credentials (user `laserdisc`); `changeme` is the local-dev password, prod's comes from `.env` on the VM |
| `VIDEO_DEV` | `Pengo` | capture video device (name substring or index) |
| `AUDIO_DEV` | `Pengo` | capture audio device (name substring or index) |
| `SIZE` | `1280x720` | capture/test frame size |
| `FPS` | `30` | frame rate |

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

| Leg | Glass-to-glass |
|---|---|
| MoQ | TBD by human |
| LL-HLS | TBD by human |

(Read off the burned-in publisher clock vs the browser clock on the viewer page.)

## Tests

`bash tests/run.sh` runs every `tests/test-*.sh`. `test-roundtrip.sh` and
`test-run-forever.sh` need network (the relay) + moq-cli; `test-hls.sh` needs
Docker too. `test-resolve-device.sh` and `test-site.sh` are offline.

## Troubleshooting

- **Device index moved** (USB replug renumbers avfoundation): use name
  substrings — `VIDEO_DEV=Pengo AUDIO_DEV=Pengo` — not indices.
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
| `scripts/run-forever.sh` | Restart wrapper around `publish.sh` with backoff + log. |
| `hls-origin/mediamtx.yml` | MediaMTX config (RTMP in, LL-HLS out). |
| `hls-origin/compose.local.yml` | Laptop: mediamtx only. |
| `hls-origin/compose.yml` | Prod: mediamtx + caddy (TLS for `$HLS_DOMAIN`). |
| `hls-origin/Caddyfile` | `HLS_DOMAIN → mediamtx:8888`. |
| `site/index.html` | Public page: `<moq-watch>` + hls.js side by side, clocks. |
| `site/CNAME` | `moq-laserdisc.vanessa-dev.com`. |
| `site/config.example.js` | Template for gitignored `site/config.js` (`window.MOQ_RELAY_URL`). |
| `.github/workflows/pages.yml` | Publish `site/` to GitHub Pages (writes `config.js` from the `MOQ_RELAY_URL` Actions variable). |
| `tests/` | Bash tests (`run.sh` + `test-*.sh` + fixtures). |
| `docs/deploy-hls-origin.md` | Human runbook for the new HLS VM. |
| `ralph/HUMAN.md` | Everything the human must do (infra, DNS, hardware, browser checks). |
| `ralph/PROGRESS.md` | Ralph loop's running notes (what worked, what failed, versions). |
