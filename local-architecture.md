# Local architecture (laptop dev loop)

Same shape as [architecture.md](architecture.md), minus the two cloud boxes'
public plumbing: locally there is **no Caddy/TLS and no GitHub Pages** — just
the `laser-mediamtx` container, plain HTTP, and `python3 -m http.server`. The
one piece that is *never* local is the MoQ relay: the MoQ leg always goes to
the real relay (`$MOQ_RELAY_URL`), even in dev.

```
═══════════════════════════ LAPTOP (everything) ══════════════════════════════

  source: SOURCE=test  → ffmpeg testsrc2 colour bars + 440 Hz sine (720p30)
          SOURCE=capture → Pengo "HDMI to U3 capture" (NTSC 720x480@60)
                                    │
                                    ▼
  scripts/publish.sh   (scripts/preview.sh = eyeball the card, no encode)
  ┌───────────────────────────────────────────────────────────────────┐
  │ ffmpeg — ONE encode, wall clock burned in (overlay.filter)        │
  │   -f tee ─┬─▶ [mpegts] stdout ──▶ moq import ts  (moq-cli)        │
  │           └─▶ [flv] rtmp://localhost:1935/laserdisc               │
  │                       ?user=laserdisc&pass=changeme (dev creds)   │
  └───────────┬───────────────────────────────────┬───────────────────┘
              │  MoQ leg — NOT local              │  HLS leg — local
              │  QUIC · $MOQ_RELAY_URL            │  RTMP · localhost:1935
              ▼                                   ▼
  ┌─────────────────────────────┐   ┌──────────────────────────────────────┐
  │ MoQ relay (remote, real)    │   │ docker: laser-mediamtx               │
  │  the same relay as prod —   │   │  image bluenviron/mediamtx:1.20.1    │
  │  there is no local relay    │   │  compose.local.yml · network         │
  └─────────────┬───────────────┘   │  "hls-origin_default" · no Caddy     │
                │                   │  1935 RTMP in · 8888 LL-HLS out      │
                │                   │  (plain HTTP; curl needs -L + a      │
                │                   │   cookie jar for the cookieCheck)    │
                │                   └──────────────────┬───────────────────┘
                │  WebTransport / WSS                  │  http://localhost:8888
                ▼                                      ▼  /laserdisc/index.m3u8
═══════════════════════════ BROWSER (local page) ═════════════════════════════

  python3 -m http.server 8000   (run from site/)
  http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8
  site/index.html + site/config.js   
  ┌────────────────────────────────────────────────────────────────────┐
  │  timecode strip (stacked burned-in clock crops)                    │
  ├─────────────────────────────────┬──────────────────────────────────┤
  │  <moq-watch> ← remote relay     │  <video>+hls.js ← localhost:8888 │
  └─────────────────────────────────┴──────────────────────────────────┘

  scripts/watch.sh = page-free MoQ check: moq export fmp4 | ffplay
```

## Containers & processes when the dev stack is up

| Thing | What | Port(s) |
|---|---|---|
| `laser-mediamtx` (docker, network `hls-origin_default`) | RTMP ingest → LL-HLS | 1935/tcp, 8888/tcp |
| ffmpeg + `moq` (pipeline from `publish.sh`) | the publisher | outbound only |
| `python3 -m http.server 8000` | serves `site/` | 8000/tcp |

All of this is managed by **`scripts/dev.sh`**: `up [test|capture]` starts the
container + publisher + site server (writing `site/config.js` from
`$MOQ_RELAY_URL` if missing), `down` stops everything including strays from
ad-hoc runs, `status` shows what's running and whether the playlist is flowing.

## Results pathway (dev variant)

Same harness as prod (see [architecture.md](architecture.md)), pointed at the
local page instead — useful for testing the harness and the results page
without touching the public data:

```
  laptop
  ┌──────────────────────────────────────────────────────────────────┐
  │  scripts/dev.sh up                       (stream must be flowing)│
  │  scripts/measure-latency.sh --url http://localhost:8000/ \       │
  │                             --source test --notes "dev run"      │
  │    Playwright + Chrome → screenshot players → OCR burned clock   │
  │    appends ONE run ─▶ site/results/data.json  (working tree)     │
  └──────────────────────────────┬───────────────────────────────────┘
                                 ▼
  view it:   http://localhost:8000/results/   (dev.sh already serves it)
  then either:
    git checkout site/results/data.json   # toss the dev run, or
    commit + push                         # it ships to the PUBLIC results
                                          # page and, being last in the
                                          # file, takes over the headline
                                          # tiles — usually not what you
                                          # want for a test run
```

Prereqs: `brew install tesseract`, node, `npm install` in `tools/measure/`
(`tests/test-measure.sh` self-skips when these are missing).

## Tests share this topology

`tests/run.sh` starts/stops the same compose file and kills stray
`testsrc2`/`moq` processes as cleanup — **don't run the suite while the dev
stack is up**; it will tear your stack down mid-flight (learned the hard way).
`test-hls.sh` also asserts that anonymous RTMP publish is rejected.
