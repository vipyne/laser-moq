# PROGRESS.md — ralph loop notes

Append-only. Newest at the bottom. Each iteration adds a dated entry.

## Versions
- relay: `moq-relay 0.13.5` at `${MOQ_RELAY_URL}` (do not touch)
- moq-cli: _not installed yet_ (latest on crates.io 2026-08-29: 0.9.14; fallback pin 0.8.4)

## Facts verified before the loop started (2026-08-29, by hand)
- `ffmpeg 7.1.1` has `tee`, `hls`, `drawtext`, `h264_videotoolbox`, `aac`.
- `scripts/overlay.filter` content + `-filter_script:v` renders a ms wall clock (`15:03:37.725` seen in a frame).
- tee to `[f=mpegts]…|[f=flv:onfail=ignore]…` produces h264+aac in both outputs.
- macOS awk is BSD awk 20200816: `match(s, re, arr)` is a syntax error; the `RSTART/RLENGTH` form in the plan works.
- `@moq/watch@0.5.2` exposes `./element`; jsdelivr `…/element/+esm` returns 200.
- `bluenviron/mediamtx:1.20.1` exists on Docker Hub. `hls.js` latest is 1.7.1.

## Soak
(filled by Task 5)

## Blockers
(none yet)

## Iterations
