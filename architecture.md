# Architecture

One encode, two transports, one page. The whole point is that the MoQ and LL-HLS
legs carry the *identical* stream (same encoder, bitrate, GOP, burned-in clock),
so the latency difference a viewer reads off the page is attributable to the
protocol path alone.

```
                            ANALOG CHAIN (stage)

  LaserDisc player ──RCA──▶ Ocean Matrix ──HDMI──▶ Pengo capture card
  (composite + stereo)      (analog → HDMI)        ("HDMI to U3 capture", UVC)
                                                        │  USB · NTSC 720x480@60
                                                        ▼
═══════════════════════════ LAPTOP (publisher) ═══════════════════════════════

  scripts/run-forever.sh ──▶ scripts/publish.sh          (restart wrapper, logs)
  ┌───────────────────────────────────────────────────────────────────┐
  │ ffmpeg — ONE encode, so both legs are apples-to-apples:           │
  │   avfoundation in → wall clock burned in (scripts/overlay.filter) │
  │   h264_videotoolbox 2500k + aac 128k                              │
  │   -f tee ─┬─▶ [mpegts] stdout ──▶ moq import ts   (moq-cli)       │
  │           └─▶ [flv] rtmp://…/laserdisc?user=laserdisc&pass=…      │
  └───────────┬───────────────────────────────────┬───────────────────┘
              │  MoQ leg                          │  HLS leg
              │  QUIC · $MOQ_RELAY_URL            │  RTMP · TCP 1935
              │                                   │  (password-gated publish)
              ▼                                   ▼
  ┌─────────────────────────────┐   ┌──────────────────────────────────────┐
  │ MoQ relay (existing box)    │   │ HLS origin VM (new box, OCI)         │
  │  moq-relay 0.13.5           │   │  hls-laserdisc.vanessa-dev.com       │
  │  anonymous pub/sub (anon/)  │   │  MediaMTX 1.20.1 ──▶ Caddy (LE TLS)  │
  │  UDP 443 WebTransport       │   │  RTMP in → LL-HLS out                │
  │  TCP 443 WSS fallback *     │   │  …/laserdisc/index.m3u8              │
  └─────────────┬───────────────┘   └──────────────────┬───────────────────┘
                │  WebTransport (Chrome)               │  HTTPS 443
                │  WSS (Safari) *                      │  hls.js lowLatencyMode
                ▼                                      ▼  (or Safari native HLS)
═══════════════════════════ VIEWER (any browser) ═════════════════════════════

  https://moq-laserdisc.vanessa-dev.com     (GitHub Pages + Route 53 CNAME)
  site/index.html
  ┌────────────────────────────────────────────────────────────────────┐
  │  timecode strip: live drawImage crops of the burned-in clocks,     │
  │  stacked MoQ-over-HLS and magnified — the delta IS the demo        │
  ├─────────────────────────────────┬──────────────────────────────────┤
  │  <moq-watch> (canvas)           │  <video> + hls.js                │
  │  page clock under player        │  page clock under player         │
  └─────────────────────────────────┴──────────────────────────────────┘

  * Safari's WSS fallback requires the relay's TCP 443 listener to be
    [web.https] (TLS) instead of [web.http]; runbook in ralph/HUMAN.md §4.
```

## Config & secrets (nothing sensitive lives in the repo or its history)

```
  MOQ_RELAY_URL ──── shell env ──────────▶ scripts/*, tests/*
       │
       └──── GitHub Actions variable ────▶ .github/workflows/pages.yml
                                              └─▶ writes site/config.js
                                                  (gitignored locally;
                                                   copy config.example.js)

  RTMP_PUBLISH_PASS ── .env on the HLS VM ─▶ compose.yml
                                              └─▶ MTX_AUTHINTERNALUSERS_1_PASS
                                                  (mediamtx.yml: publish needs
                                                   user laserdisc; reads open;
                                                   'changeme' = local dev only)

  Planned (ralph/HUMAN.md §6): JWT tokens ride inside MOQ_RELAY_URL —
  publish-capable token stays in the shell env, subscribe-only token ships
  publicly in config.js; relay keeps public = "anon" so the other demo on the
  relay is untouched.
```

## Results pathway (measured latency)

Runs happen on the **x86 publisher Mac** — the same machine that burns the
clock into the picture, so "burned-in clock" and "local clock" are one clock
and there is no NTP skew. Nothing writes to git automatically; publishing a
run is always a human commit.

```
  x86 publisher Mac (off-site, its own clone of this repo)
  ┌──────────────────────────────────────────────────────────────────┐
  │  scripts/prod.sh measure                                         │
  │    └─▶ scripts/measure-latency.sh ─▶ tools/measure/measure.mjs   │
  │         Playwright drives the installed Chrome:                  │
  │           open https://moq-laserdisc.vanessa-dev.com/            │
  │           (the real public page — full prod path end to end)     │
  │           warm up both players → every ~5s, per player:          │
  │             screenshot pane → crop top-left corner →             │
  │             tesseract OCRs the burned-in publisher clock         │
  │             glass_to_glass_ms = local now − burned clock         │
  │           (+ hls.js self-reported latency, kept as cross-check)  │
  │                                                                  │
  │    appends ONE run ─▶ site/results/data.json                     │
  │                       append-only · working-tree edit only —     │
  │                       nothing touches git automatically          │
  └──────────────────────────┬───────────────────────────────────────┘
                             │  human: review the run →
                             │  git commit → git push
                             ▼
  GitHub main ── site/** changed ─▶ pages.yml ─▶ GitHub Pages redeploy
                             ▼
  https://moq-laserdisc.vanessa-dev.com/results/
    tiles  = latest run only (p50 per transport)
    chart  = every run ever, one dot per sample
    table  = every run, newest first (+ hlsjs-api rows)
```

Because `data.json` is append-only and the tiles headline the *last* run,
make sure the real capture run is the final entry at push time — a stray
`--source test` run committed after it would take over the headline.

## Where things are decided

| Concern | Decided by |
|---|---|
| Source & format (`SOURCE`, `SIZE`, `FPS`, devices) | `scripts/publish.sh` env vars; capture defaults to the card's NTSC 720x480@60 |
| Encode parameters | Verified line in `scripts/publish.sh` — do not "improve" without re-testing |
| Relay endpoint | `MOQ_RELAY_URL` only (env / Actions variable), never a file in the repo |
| HLS origin deploy | `hls-origin/` + `docs/deploy-hls-origin.md` (human-run) |
| Page deploy | Push to `main` touching `site/**` → Pages workflow |
| Human-only steps & gates | `ralph/HUMAN.md` (ordered checklist) |
