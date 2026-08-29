# How to Livestream a LaserDisc (over Media over QUIC) — Design

**Date:** 2026-08-29
**Status:** approved

## Goal

A conference stunt hack: take the analog composite output of a LaserDisc player,
get it into a Mac, and livestream it over **Media over QUIC (MoQ)** to a public URL
that anyone on the internet can open in a browser.

It is intentionally silly. The point is to show the whole MoQ path end to end
(capture → encode → `moq-cli` publish → relay → browser `<moq-watch>`), on a
stage, and have it survive the talk.

## What already exists (verified 2026-08-29)

| Piece | State |
|---|---|
| **MoQ relay** | `${MOQ_RELAY_URL}`. OCI instance `moq-relay` (<moq-relay-ip>), RUNNING. Docker container `moq-relay` built from image `<internal-relay-image>` (repo: `<internal relay repo>`), **`moq-relay 0.13.5`** pinned via `MOQ_TAG`. Let's Encrypt cert. `[auth] public = "anon"` → anonymous publish *and* subscribe under `anon/`. `[web.http] listen = "[::]:443"` → **WebSocket fallback on TCP 443 is already enabled** (Safari works). `[stats] enabled = true`. Shared with the <internal-moq-demo> demo → **do not upgrade or reconfigure it** as part of this project. |
| **Capture chain** | LaserDisc player (RCA composite + stereo) → Ocean Matrix analog→HDMI converter → Pengo HDMI→USB capture card. Pengo is UVC; it shows up as a camera + audio device in `ffmpeg -f avfoundation -list_devices true -i ""`. Not plugged in at design time. |
| **Laptop toolchain** | macOS (Darwin 24.6), ffmpeg 7.1.1 (avfoundation, videotoolbox), cargo/rustc 1.97, node 22 / npm / pnpm / bun, docker, `just`, `gh` (logged in as `vipyne`), `aws` CLI with profile `vanessa-dev` (Route 53 zone `vanessa-dev.com`). `moq-cli` **not** installed. |
| **Local `moq` fork** | `<local moq fork>` (June 2026, moq-cli 0.7.31). Reference only; we install `moq-cli` from crates.io. |

### Version compatibility (the main known risk)

crates.io on 2026-08-29: `moq-cli` 0.9.14, `moq-relay` 0.14.13. The relay runs
0.13.5 (released 2026-07-15). `moq-cli` **0.8.4** was released the same day and is
the "same batch" version. The <internal-relay-image> README warns that relay/client
skew can silently drop streams.

Strategy: try latest `moq-cli` first (moq-lite wire protocol is intended to be
stable); if the round-trip test (M0) fails, `cargo install moq-cli --version 0.8.4
--locked`. Record which version worked in the README.

## Architecture

One ffmpeg process encodes once and **tees** the identical h264/aac stream to two
legs, so the MoQ-vs-HLS latency comparison is apples to apples (same bitrate,
same GOP, same encoder).

```
LaserDisc ─RCA─▶ Ocean Matrix ─HDMI─▶ Pengo ─USB─▶ ffmpeg (avfoundation)
                                                     │ h264_videotoolbox + aac, -f tee
                                    ┌────────────────┴─────────────────┐
                              [f=mpegts]pipe:1                 [f=flv]rtmp://HLS_HOST/laserdisc
                                    │                                  │
                   moq --client-connect ${MOQ_RELAY_URL}   MediaMTX (new VM)
                       --broadcast laserdisc.hang import ts          RTMP in → LL-HLS out
                                    │ QUIC                             │ HTTPS via Caddy
                                    ▼                                  ▼
                       <moq-relay-host> (existing)     https://<hls-host>/laserdisc/index.m3u8
                                    │ WebTransport / WSS               │ hls.js (lowLatencyMode)
                                    └──────────────┬───────────────────┘
                                                   ▼
                          https://laserdisc.vanessa-dev.com — one page, two players side by side
                          (GitHub Pages for this repo + Route 53 CNAME)
```

Broadcast name: `laserdisc.hang` (full path on the relay: `anon/laserdisc.hang`).
The `.hang` suffix selects the JSON catalog format that `@moq/watch` expects.
The HLS leg uses `onfail=ignore` in the tee so the MoQ leg keeps running if the
HLS origin is down.

A wall-clock timestamp is burned into the video with `drawtext` (laptop time,
millisecond resolution). The viewer page shows the browser's clock next to each
player, so glass-to-glass latency per protocol is readable off the screen — the
on-stage "which one is lower" moment.

### Infra boundary (important)

The ralph loop is **laptop-only**. It may: install `moq-cli` with cargo, run
ffmpeg/moq locally, publish to `anon/laserdisc*.hang` on the existing relay, run
MediaMTX in local Docker, serve `site/` locally, and commit to this repo. It must
**never** run `aws`, `oci`, `ssh`, `scp`, `gh repo create`, `gh api`, or modify
the relay. Every infra step (new VM for the HLS origin, DNS records, GitHub repo
+ Pages, opening ports) is written out as exact commands in `HUMAN.md` for the
human to run. The HLS origin is a **new** VM — nothing existing besides the relay
is reused.

## Components

### 1. `scripts/publish.sh` — capture + encode + publish

One bash script; the heart of the demo.

- Inputs (env vars with defaults): `VIDEO_DEV` / `AUDIO_DEV` (avfoundation
  indices or names), `RELAY_URL` (default `${MOQ_RELAY_URL}`),
  `BROADCAST` (default `laserdisc.hang`), `SOURCE=test|capture` (default
  `capture`; `test` uses `-f lavfi testsrc2` + `sine` so everything can be
  exercised with no hardware).
- ffmpeg pipeline: avfoundation input (`-framerate 30`, request the Pengo's native
  size, likely 1920x1080 or 1280x720 — discover, don't assume) →
  `-c:v h264_videotoolbox` with a short GOP (~1 s), no B-frames, `-realtime 1`,
  ~2–3 Mbps; `-c:a aac -b:a 128k -ar 48000`; `-f mpegts -` on stdout.
- Output is `-f tee "[f=mpegts]pipe:1|[f=flv:onfail=ignore]$RTMP_URL"`; stdout is
  piped into `moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" import ts`.
  `RTMP_URL` defaults to `rtmp://localhost:1935/laserdisc` (local MediaMTX); set
  `HLS=0` to drop the second leg entirely.
- `-vf drawtext` burns `%{localtime:%H:%M:%S.%3N}`-style wall clock into the
  top-left corner (both test and capture sources).
- `scripts/watch.sh`: the matching subscriber for local verification —
  `moq … export fmp4 | ffplay -` (or `moq … play` if the `play` feature is built).

### 1b. `hls-origin/` — MediaMTX + Caddy (Docker Compose)

- `hls-origin/mediamtx.yml`: `rtmp: yes` (`:1935`), `hls: yes` (`:8888`),
  `hlsVariant: lowLatency`, `hlsSegmentDuration: 1s`, `hlsPartDuration: 200ms`,
  `hlsSegmentCount: 7`, `hlsAlwaysRemux: yes`, `hlsAllowOrigins: ['*']`, one
  path `laserdisc` with `source: publisher`. Image pinned `bluenviron/mediamtx:1.20.1`.
- `hls-origin/compose.yml` (production: mediamtx + caddy, TLS automatic for
  `$HLS_DOMAIN`, Caddy reverse-proxies `:443 → mediamtx:8888`) and
  `hls-origin/compose.local.yml` (laptop: mediamtx only, ports 1935 + 8888).
- Playback URL: `https://<hls-host>/laserdisc/index.m3u8`.
- Runs on a **new** Ubuntu 24.04 VM the human provisions (`docs/deploy-hls-origin.md`
  has the exact steps, written OCI-flavoured to match the existing runbooks but
  provider-agnostic: any VM with a public IP and 22/80/443/1935 TCP open).
- A `--loop` mode / wrapper (`scripts/run-forever.sh`) that restarts the pipeline
  if either process exits, with a 2 s backoff. Viewers keep the same broadcast
  name, so `<moq-watch>` reconnects on its own.

### 2. `site/index.html` — the public viewer page

A single static HTML file, no build step.

- Loads `@moq/watch` from jsdelivr with a **pinned version** (e.g.
  `https://cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm`).
- Two players side by side: left `<moq-watch url="${MOQ_RELAY_URL}" name="laserdisc.hang" controls><canvas></canvas></moq-watch>`,
  right a `<video>` driven by hls.js (pinned `hls.js@1.7.1`, `lowLatencyMode: true`),
  falling back to native HLS on Safari. Under each player a live browser clock
  (`HH:MM:SS.mmm`) so the burned-in clock can be compared by eye.
- The HLS URL and relay URL are constants at the top of the page's script (and
  overridable via `?hls=` / `?relay=` query params for local testing).
- Header/title: "LIVE from a LaserDisc" plus a one-line "what is this" and a link
  to the repo. A small themed touch is fine; no framework.
- A capability check: if `WebTransport` is missing, show "falling back to
  WebSocket" (the relay supports it) — and if the element fails to connect at
  all, show a plain "stream is offline" message instead of a blank canvas.
- `site/CNAME` containing `laserdisc.vanessa-dev.com` (GitHub Pages custom
  domain).

### 3. Hosting — GitHub Pages + Route 53

All human-run; the loop only prepares files and writes the commands into `HUMAN.md`.

- GitHub repo `vipyne/laser-moq` (public). Pages deploys from a workflow
  (`.github/workflows/pages.yml`, `actions/upload-pages-artifact` with `path: site`)
  because branch-deploy only allows `/` or `/docs`.
- Route 53 (`AWS_PROFILE=vanessa-dev`, hosted zone `vanessa-dev.com`): CNAME
  `laserdisc.vanessa-dev.com → vipyne.github.io`, and an A record for the HLS
  origin host (e.g. `hls.vanessa-dev.com → <new VM IP>`). Then "Enforce HTTPS"
  on Pages once the cert is issued.
- Gate: `curl -sI https://laserdisc.vanessa-dev.com/` → 200 with a valid cert,
  and the page loads both streams in Chrome.

### 4. Docs — `README.md` (top level only)

Sections: what this is; hardware chain; install (`cargo install moq-cli`);
`publish.sh` usage; the stage runbook (plug in → list devices → run
`run-forever.sh` → open URL); measured latency; troubleshooting (device index
changed, relay down, version skew, Safari). No READMEs in subdirectories.

## Milestones (also the ralph-loop plan)

- **M0 — relay round-trip, no hardware.** `moq-cli` installed. `publish.sh`
  with `SOURCE=test` publishes `anon/laserdisc.hang`; `watch.sh` from a second
  process receives video and audio. If it fails on 0.9.14, pin 0.8.4. Record the
  working version.
- **M1 — HLS leg, locally.** MediaMTX up via `hls-origin/compose.local.yml`;
  the tee's RTMP leg lands on it; `curl localhost:8888/laserdisc/index.m3u8`
  contains `#EXT-X-PART` (proves LL-HLS). Killing MediaMTX does not stop the MoQ leg.
- **M2 — viewer page, locally.** `site/index.html` served with
  `python3 -m http.server` plays both legs in Chrome (MoQ from the real relay,
  HLS from local MediaMTX); clocks visible. *Human eyes for the browser check.*
- **M3 — real capture.** Pengo detected in avfoundation; `SOURCE=capture`
  streams it; latency per protocol read off the clocks and recorded in the
  README. *Needs a human to plug the hardware in.*
- **M4 — stage hardening + handoff.** `run-forever.sh` restart wrapper tested by
  killing ffmpeg mid-stream; a 20-minute soak with the test source shows no
  disconnects; README runbook complete; `docs/deploy-hls-origin.md`,
  `.github/workflows/pages.yml`, and `HUMAN.md` (VM, DNS, repo, Pages, ports)
  complete and copy-pasteable.
- **M5 — public (human).** Human runs `HUMAN.md`; both URLs work from a phone
  on cellular. Not part of the loop.

## Error handling

- **Publisher dies** (USB hiccup, encoder stall): `run-forever.sh` restarts it;
  viewers reconnect automatically to the same broadcast name.
- **Relay unreachable**: `publish.sh` fails fast with a clear message; runbook
  says how to check the OCI box (`oci compute instance list`, `ssh ubuntu@<moq-relay-ip> docker ps`).
  We do not auto-restart the relay from this repo.
- **Device index moved** (macOS renumbers avfoundation devices): `publish.sh`
  accepts a device *name* substring and resolves the index at start.
- **Version skew**: M0's round-trip test is the detector; pinned fallback is
  documented.
- **Broadcast squatting**: `anon/` is anonymous by design on this relay. Accepted
  for a demo; the README notes it and the JWT path for later.

## Testing

- M0/M1/M3 are fully automatable without hardware (test source).
- Each script has a `--help` and exits non-zero with a message on bad input.
- Verification commands for every milestone live in `PLAN.md` so the ralph loop
  can check its own work; browser checks that need eyes are marked "human".

- **HLS origin down**: tee leg has `onfail=ignore`; MoQ continues; page shows
  "HLS offline" on the right player.

## Out of scope

Upgrading or reconfiguring the shared relay; JWT auth; Cloudflare relays;
transcoding ladders/ABR; recording; WebRTC/WHEP (MediaMTX could serve it later
with extra UDP ports); anything beyond one broadcast on one page.
