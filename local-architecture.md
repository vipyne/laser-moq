# Local architecture (laptop dev loop)

Same shape as [architecture.md](architecture.md), minus the two cloud boxes'
public plumbing: locally there is **no Caddy/TLS and no GitHub Pages** — just
a local `moq-relay`, the `laser-mediamtx` container, plain HTTP, and
`python3 -m http.server`. **Everything is local**, both legs: on loopback
there is no loss, no RTT, no geography, so the latency difference is the
protocol/player architecture alone — the isolation run the prod WAN numbers
get contrasted against. `dev.sh` forces
`MOQ_RELAY_URL=http://localhost:4443/anon`; the `http://` scheme makes
moq-cli and `<moq-watch>` fetch `/certificate.sha256` and pin the relay's
self-signed cert fingerprint (no trust-store changes needed).

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
              │  MoQ leg — local                  │  HLS leg — local
              │  QUIC · localhost:4443            │  RTMP · localhost:1935
              ▼                                   ▼
  ┌─────────────────────────────┐   ┌──────────────────────────────────────┐
  │ moq-relay (local binary)    │   │ docker: laser-mediamtx               │
  │  0.13.5 (= prod's version)  │   │  image bluenviron/mediamtx:1.20.1    │
  │  UDP 4443 WebTransport ·    │   │  compose.local.yml · network         │
  │  TCP 4443 /certificate      │   │  "hls-origin_default" · no Caddy     │
  │  .sha256 + WS · self-signed │   │  1935 RTMP in · 8888 LL-HLS out      │
  │  cert, fingerprint-pinned   │   │  (plain HTTP; curl needs -L + a      │
  └─────────────┬───────────────┘   │   cookie jar for the cookieCheck)    │
                │                   └──────────────────┬───────────────────┘
                │  WebTransport                        │  http://localhost:8888
                ▼                                      ▼  /laserdisc/index.m3u8
═══════════════════════════ BROWSER (local page) ═════════════════════════════

  python3 -m http.server 8000   (run from site/)
  http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8
  site/index.html + site/config.js   
  ┌────────────────────────────────────────────────────────────────────┐
  │  timecode strip (stacked burned-in clock crops)                    │
  ├─────────────────────────────────┬──────────────────────────────────┤
  │  <moq-watch> ← localhost:4443   │  <video>+hls.js ← localhost:8888 │
  └─────────────────────────────────┴──────────────────────────────────┘

  scripts/watch.sh = page-free MoQ check: moq export fmp4 | ffplay
```

## Containers & processes when the dev stack is up

| Thing | What | Port(s) |
|---|---|---|
| `moq-relay` (local binary, 0.13.5) | MoQ relay, self-signed cert | 4443/udp QUIC, 4443/tcp fingerprint+WS |
| `laser-mediamtx` (docker, network `hls-origin_default`) | RTMP ingest → LL-HLS | 1935/tcp, 8888/tcp |
| ffmpeg + `moq` (pipeline from `publish.sh`) | the publisher | outbound only |
| `python3 -m http.server 8000` | serves `site/` | 8000/tcp |
| `scripts/impair-server.py` (started by `dev.sh`) | network-impair toggle for the page | 9900/tcp |

All of this is managed by **`scripts/dev.sh`**: `up [test|capture]` starts the
relay + container + publisher + site server (always rewriting `site/config.js`
to the local relay), `down` stops everything including strays from
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
