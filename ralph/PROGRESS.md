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

### 2026-09-10 — Task 2 complete
- Wrote `tests/fixtures/avfoundation-list.txt`, `tests/test-resolve-device.sh` (failed as expected: No such file), then `scripts/list-devices.sh` + `scripts/resolve-device.sh` exactly as in the plan. `bash tests/test-resolve-device.sh && echo OK` → `OK`.
- Full suite `bash tests/run.sh` → PASS both tests (roundtrip still good against relay with moq-cli 0.11.0). Cleaned up leaked ffmpeg/moq afterwards per the Task 1 quirk note.
- No deviations from the plan; BSD-awk `RSTART/RLENGTH` form works as pre-verified. Next: Task 3 (local MediaMTX / LL-HLS leg — needs Docker running).

### 2026-09-10 — Task 3 complete
- Docker 28.4.0 running; `bluenviron/mediamtx:1.20.1` pulled clean. Wrote `tests/test-hls.sh` first (failed as expected: compose file missing), then `hls-origin/mediamtx.yml` + `hls-origin/compose.local.yml` exactly per plan.
- **Deviation 1 (publish.sh):** first run failed "no playlist"; `docker logs laser-mediamtx` showed `[RTMP] closed: unable to parse H264 config: EOF` and pub.log showed `Slave muxer #1 failed: Broken pipe`. Cause: FLV needs global headers (avcC extradata) and ffmpeg's tee muxer does not propagate `AV_CODEC_FLAG_GLOBAL_HEADER` to slaves. Fix: added `-flags +global_header` to the encode line in `scripts/publish.sh`. Verified empirically with a direct `-f flv` publish before touching the script; MoQ roundtrip re-verified after (mpegts muxer re-inserts SPS/PPS in-band, `codecs: aac h264` still passes). The plan's suggested `aac_adtstoasc` was NOT needed — the failure was video, not audio.
- **Deviation 2 (test-hls.sh):** MediaMTX 1.20.1 gates HLS behind a 302 `?cookieCheck=1` redirect + `Secure` session cookie; bare `curl -sf` gets an empty 302 on the index and **401** on media playlists. Fix: all fetches use `curl -sfL -c jar -b jar` (curl accepts Secure cookies on localhost). Also the plan's sed for the variant URI can't parse the `#EXT-X-MEDIA` line (URI= isn't the first quoted string); replaced with `grep -m1 -E '^[^#].*\.m3u8'` → `video1_stream.m3u8`.
- Note: MediaMTX 1.20.1 also starts a MoQ listener (:8892/:8893) by default — harmless, left as is.
- `bash tests/test-hls.sh` → `LL-HLS ok` + `publisher survived HLS origin loss` (EXT-X-PART with 200ms parts confirmed). `bash tests/run.sh` → PASS all 3. Cleaned up ffmpeg/moq leaks and `docker compose down` after.
- Committing the human's pending edits to ralph/{HUMAN,PROMPT,plan}.md and .claude/settings.json along with this (per `git add -A` rule). Next: Task 4 (viewer page).
