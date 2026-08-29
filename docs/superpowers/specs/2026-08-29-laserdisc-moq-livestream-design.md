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

```
LaserDisc ─RCA─▶ Ocean Matrix ─HDMI─▶ Pengo ─USB─▶ ffmpeg (avfoundation)
                                                     │ h264_videotoolbox + aac → mpegts (stdout)
                                                     ▼
                                       moq --client-connect ${MOQ_RELAY_URL} \
                                           --broadcast laserdisc.hang import ts
                                                     │ QUIC (WebTransport)
                                                     ▼
                                          <moq-relay-host>  (existing, untouched)
                                                     │ WebTransport, or WSS fallback (Safari)
                                                     ▼
                         https://laserdisc.vanessa-dev.com  — static page with <moq-watch>
                         (GitHub Pages for this repo + Route 53 CNAME)
```

Broadcast name: `laserdisc.hang` (full path on the relay: `anon/laserdisc.hang`).
The `.hang` suffix selects the JSON catalog format that `@moq/watch` expects.

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
- Piped into `moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" import ts`.
- `scripts/watch.sh`: the matching subscriber for local verification —
  `moq … export fmp4 | ffplay -` (or `moq … play` if the `play` feature is built).
- A `--loop` mode / wrapper (`scripts/run-forever.sh`) that restarts the pipeline
  if either process exits, with a 2 s backoff. Viewers keep the same broadcast
  name, so `<moq-watch>` reconnects on its own.

### 2. `site/index.html` — the public viewer page

A single static HTML file, no build step.

- Loads `@moq/watch` from jsdelivr with a **pinned version** (e.g.
  `https://cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm`).
- `<moq-watch url="${MOQ_RELAY_URL}" name="laserdisc.hang" controls><canvas></canvas></moq-watch>`.
- Header/title: "LIVE from a LaserDisc" plus a one-line "what is this" and a link
  to the repo. A small themed touch is fine; no framework.
- A capability check: if `WebTransport` is missing, show "falling back to
  WebSocket" (the relay supports it) — and if the element fails to connect at
  all, show a plain "stream is offline" message instead of a blank canvas.
- `site/CNAME` containing `laserdisc.vanessa-dev.com` (GitHub Pages custom
  domain).

### 3. Hosting — GitHub Pages + Route 53

- GitHub repo `vipyne/laser-moq` (public), Pages source = `main` branch, `/site`
  folder (or a Pages workflow that publishes `site/`).
- Route 53 (`AWS_PROFILE=vanessa-dev`, hosted zone `vanessa-dev.com`): CNAME
  `laserdisc.vanessa-dev.com → vipyne.github.io`. Then enable "Enforce HTTPS" on
  the Pages settings once the cert is issued.
- Gate: `curl -sI https://laserdisc.vanessa-dev.com/` → 200 with a valid cert,
  and the page loads the stream in Chrome.

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
- **M1 — public viewer.** `site/index.html` plays the test pattern in Chrome
  locally (`python3 -m http.server` in `site/`), then on
  `https://laserdisc.vanessa-dev.com`. Safari via WSS fallback verified (or the
  failure documented).
- **M2 — real capture.** Pengo detected in avfoundation; `SOURCE=capture`
  streams it; end-to-end latency measured (burn a clock into the test source
  with `drawtext`, or photograph player vs. browser) and recorded in the README.
  *Needs a human to plug the hardware in.*
- **M3 — stage hardening.** `run-forever.sh` restart wrapper tested by killing
  ffmpeg mid-stream; README runbook complete; a 20-minute soak with the test
  source shows no memory growth or disconnects.

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

## Out of scope

Upgrading or reconfiguring the shared relay; JWT auth; Cloudflare relays;
transcoding ladders/ABR; recording; anything beyond one broadcast on one page.
