# PROGRESS.md — ralph loop notes

Append-only. Newest at the bottom. Each iteration adds a dated entry.

## Versions
- relay: `moq-relay 0.13.5` at `${MOQ_RELAY_URL}` (do not touch)
- moq-cli: `0.11.0` (crates.io latest on 2026-09-10; newer than the 0.9.14 the plan expected). **Round-trip against relay 0.13.5 works** — no need for the 0.8.4 fallback. Binary at `~/.cargo/bin/moq`; PATH may need `export PATH="$HOME/.cargo/bin:$PATH"` in non-login shells.

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

### 2026-09-10 — Task 1 complete
- Prior iteration had written `scripts/publish.sh`, `scripts/overlay.filter`, `scripts/watch.sh`, `tests/run.sh`, `tests/test-roundtrip.sh` (Steps 2–6) but not committed. This iteration did Step 1 (`cargo install moq-cli --locked` → 0.11.0, ~1m17s build) and Step 7.
- `bash tests/test-roundtrip.sh` → `codecs: aac h264`, exit 0. `bash tests/run.sh` → PASS.
- moq 0.11.0 CLI matches the plan's invocation exactly (`moq --client-connect URL --broadcast NAME import ts` / `export ts`); no script changes needed.
- **Quirk:** `tests/test-roundtrip.sh`'s `trap kill $PUB` kills the publish.sh shell but orphans the `ffmpeg | moq` pipeline children — each test run leaks one ffmpeg + one moq. Clean up after running tests: `pkill -f 'ffmpeg .*testsrc2'; pkill -f 'moq --client-connect'`. (Left the test as written per plan; consider fixing if it causes trouble in Task 3/5.)
