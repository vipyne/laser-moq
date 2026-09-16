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
- 2026-09-10: `SOURCE=test HLS=0 BROADCAST=laserdisc-soak.hang timeout 1200 scripts/run-forever.sh` → `logs/publish-20260910-154015.log` shows exactly one `start #1`, zero `exited rc` lines (no unplanned restarts over 20 min), `stopping` from the TERM trap, wrapper rc=124 from `timeout`. No leaked ffmpeg/moq after (`pgrep` clean — the stop() trap got both pipeline children).

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

### 2026-09-10 — Task 4 complete
- Wrote `tests/test-site.sh` first (failed as expected: `missing site/index.html`), then `site/CNAME` (exactly `laserdisc.vanessa-dev.com`, no trailing newline) and `site/index.html` verbatim from the plan. `bash tests/test-site.sh && echo OK` → `OK`. No deviations.
- Appended the two browser checks to `ralph/HUMAN.md` §4 (Chrome with `?hls=http://localhost:8888/laserdisc/index.m3u8`, then Safari). Did not leave a `python3 -m http.server` running — the serve command is in the HUMAN.md entry instead (unattended loop shouldn't leave servers up).
- Full suite `bash tests/run.sh` → PASS all 4 (hls, resolve-device, roundtrip, site). Cleaned up the leaked ffmpeg/moq from roundtrip (Task 1 quirk) and confirmed `docker compose down`.
- Next: Task 5 (`run-forever.sh` + soak — the soak step alone is a 20-minute `timeout 1200` run; budget for it).

### 2026-09-10 — Task 5 complete (across two iterations)
- A prior iteration did Steps 1–4 (wrote `tests/test-run-forever.sh` + `scripts/run-forever.sh`, ticked them in the plan) but stopped before the soak and **did not commit or log here** — this iteration found the files untracked. Re-ran `bash tests/test-run-forever.sh` to re-verify before trusting the ticks: `restart + clean shutdown ok`, exit 0.
- **Test deviation (already in the file):** shutdown is tested with `kill -TERM`, not `-INT` — bash ignores SIGINT in background jobs of non-interactive shells, so the wrapper's INT trap can't fire under the test harness; Ctrl-C in a real terminal still works (same trap handles both).
- Step 5 soak: see `## Soak` above — 20 min, zero unplanned restarts, clean TERM shutdown, no leaks.
- **Task 1 quirk fixed for real.** First full-suite run FAILED `test-run-forever.sh` ("child survived SIGTERM"): the leaked `ffmpeg|moq` pipelines from `test-hls.sh` and `test-roundtrip.sh` polluted `pgrep -f 'ffmpeg .*testsrc2'` — the test killed a *leaked* ffmpeg (restart check passed spuriously against the second leak) and the final pgrep found a leak, not the wrapper's child. The wrapper itself never misbehaved. Fix (the one Task 1's note anticipated): both tests' cleanup traps now do `pkill -TERM -P $PUB` before `kill $PUB`, same as run-forever's `stop()`. Re-ran `bash tests/run.sh` from a clean state → PASS all 5, and the post-suite leak check (`pgrep` ffmpeg/moq, `docker ps`) is empty. **The manual `pkill` after test runs is no longer needed.**
- **Quirk for future iterations:** the interactive shell aliases `ls`→`ls -l`-style output and `grep`→`ugrep`; command substitutions like `$(ls -t …)` come back mangled. Use `/bin/ls` and `/usr/bin/grep` (or `command grep`) in ad-hoc shell one-liners. Scripts run via `bash script.sh` are unaffected (aliases don't expand in non-interactive shells).
- Next: Task 6 (prod compose/Caddyfile, Pages workflow, deploy runbook, HUMAN.md rewrite, README).

### 2026-09-10 — Task 6 complete
- Wrote `hls-origin/compose.yml` + `Caddyfile` + `env.example` verbatim from the plan; `HLS_DOMAIN=example.test docker compose -f compose.yml config` → `COMPOSE_OK`. Wrote `.github/workflows/pages.yml` verbatim.
- `docs/deploy-hls-origin.md`: modelled on <internal-bench-repo> `deploy-oci.md` §1–§3 with new names (`hls-vcn`/`hls-subnet`/`hls-igw`/`hls-ip`, instance `hls-origin`), VCN CIDR `10.1.0.0/16` (not 10.0/16, to avoid ambiguity with relay-vcn if ever peered), security list 22(YOUR_IP)/80/443/1935 TCP + the two ICMP path-MTU rules, and the OCI iptables gotcha section. DNS section copies the <internal-moq-demo> Route 53 UPSERT shape.
- `ralph/HUMAN.md`: rewrote to the plan's template; folded the two Task-4 browser checks into §4 unchanged; added the Route 53 CNAME change-batch JSON (`Type: CNAME`, value `vipyne.github.io`) inline in §1.
- `README.md`: all plan sections; ASCII diagram copied from the spec; env table matches publish.sh defaults; moq-cli version recorded as 0.11.0; "Measured latency" left TBD-by-human (the one allowed placeholder).
- `bash tests/run.sh` → PASS all 5; post-suite leak check clean (no ffmpeg/moq, no containers).
- Next: Task 7 (capture — hardware-gated; Pengo not expected to be plugged in).

### 2026-09-10 — Task 7 blocked: hardware
- `scripts/list-devices.sh | grep -i pengo` → no match (card not plugged in). Marked Task 7 `blocked: hardware` in the plan and noted it in `ralph/HUMAN.md` §3. Steps 2–4 (mode probe, capture stream, latency numbers) wait for the card; plug it in and rerun the loop.
- Completion condition met: Tasks 1–6 fully checked, `bash tests/run.sh` PASS all 5, Task 7 blocked with a HUMAN.md entry. Everything left is in `ralph/HUMAN.md` (push + Pages, HLS VM, hardware, browser checks, latency numbers).

### 2026-09-12 — domain rename (human-requested, outside the loop)
- `laserdisc.vanessa-dev.com` → `moq-laserdisc.vanessa-dev.com` (Pages site) and `hls.vanessa-dev.com` → `hls-laserdisc.vanessa-dev.com` (HLS origin), everywhere: `site/CNAME`, `site/index.html` default HLS URL, `tests/test-site.sh`, `hls-origin/env.example`, `README.md`, `docs/deploy-hls-origin.md`, spec, plan, `ralph/HUMAN.md`. Relay URL unchanged.
- Earlier entries above mention the old names; they were correct at the time. `bash tests/test-site.sh` passes with the new CNAME.

### 2026-09-12 — relay endpoint scrubbed (human-requested, outside the loop)
- The relay URL/hostname/IP and other infra identifiers no longer appear anywhere in the repo **or its git history** (rewritten with `git filter-repo --replace-text`; every commit hash changed; backup bundle kept outside the repo).
- Everything now takes the relay from the `MOQ_RELAY_URL` env var: `scripts/publish.sh` + `scripts/watch.sh` + `tests/test-roundtrip.sh` require it (clear error if unset); the site reads `window.MOQ_RELAY_URL` from gitignored `site/config.js` (`site/config.example.js` is the template; the Pages workflow generates the real one from the `MOQ_RELAY_URL` Actions variable); `?relay=` still overrides.
- Rule added to `ralph/PROMPT.md` + plan Global Constraints: never write the relay's URL/host/IP into any file in this repo.
- To run anything relay-touching: `export MOQ_RELAY_URL=…` first.

### 2026-09-12 — RTMP publish credentials (human-requested, outside the loop)
- MediaMTX now requires credentials to publish; viewing stays anonymous. `authInternalUsers` in `hls-origin/mediamtx.yml`: `any` → read/playback only; `laserdisc`/`changeme` → publish. Prod overrides the password via `MTX_AUTHINTERNALUSERS_1_PASS=${RTMP_PUBLISH_PASS}` in `compose.yml` (value from `.env` on the VM, never committed) — verified with a standalone container: old pass rejected, env pass streams.
- **Gotcha:** MediaMTX takes RTMP credentials as query params, not URL userinfo — `rtmp://host:1935/laserdisc?user=laserdisc&pass=…`; the `rtmp://user:pass@host/…` form fails auth with ffmpeg. All docs/defaults use the query form.
- `scripts/publish.sh` default RTMP_URL carries the local-dev creds; `tests/test-hls.sh` also asserts an anonymous publish is rejected. Full suite: PASS all 5.

### 2026-09-12 — MoQ auth specced + verified (human-requested, outside the loop)
- Verified against sources: relay 0.13.5 (`[auth] key = "<jwk>"` + `public` stay independent — adding a key does NOT affect anonymous `anon/` access) and moq-token wire format is identical between the relay's verifier (moq-token 0.6.x) and moq-cli 0.11.0's signer (0.7.3): claims `root`/`put`/`get`/`exp`/`iat`. Relay parses the token from the `?jwt=` query param on the connect URL.
- Dry-ran locally with moq 0.11.0: `moq token generate --out root.jwk` (HS256), `moq token sign --key … --root laserdisc [--publish ""] [--subscribe ""] --expires <unix>`, `moq token verify` round-trips.
- Design: keep `public = "anon"` (pipecat demo untouched); laserdisc moves to the token-gated `laserdisc/` prefix. Publisher gets a pub+sub token (secret, in `MOQ_RELAY_URL` env); page gets a subscribe-only token (public by design, in the Actions variable). Zero repo code changes — the MOQ_RELAY_URL plumbing already carries it. Full runbook: `ralph/HUMAN.md` §6. `.gitignore` now excludes `*.jwk`.
- `@moq/watch@0.5.2` appears to pass the url attr's query through (`new URL(...)`, no stripping) — confirmed in bundled source, final confirmation is the §6 browser gate.

### 2026-09-13 — Safari WebSocket fallback root-caused (human §4)
- The relay's `wss://` fallback never worked: TCP 443 is the plain `[web.http]` listener (verified: `http://relay.…:443/anon` returns the landing page in cleartext; TLS handshake → "wrong version number"). Chrome was fine because WebTransport is QUIC/UDP 443 with its own certs. Spec's "WebSocket fallback already enabled" was wrong in practice.
- Fix (relay box): swap to `[web.https]` with `listen`/`cert`/`key` (field names confirmed in moq-relay 0.13.5 `src/web.rs`; same LE cert files as QUIC). WS polyfill (`web-ws`) is on by default. Runbook: `ralph/HUMAN.md` §4.

### 2026-09-13 — Task 7 steps 1–3 done by hand; capture defaults folded in
- Card detected as **"HDMI to U3 capture"** (the Pengo's UVC name); only mode: NTSC **720x480@60** (`SIZE=720x480 FPS=60` verified streaming; `FPS=60.000240` also accepted). `uyvy422` pixel format fine as-is.
- `publish.sh`: capture now defaults to 720x480@60 and device "HDMI to U3 capture" (test source keeps 1280x720@30); `preview.sh` (new: local ffplay eyeball of the card, `FRAME=x.png` for a still) same device default. README env table updated.
- End-to-end seen by human: LaserDisc playing via MoQ + HLS in Safari from the localhost page.
- Task 7 step 4 (Measured latency) deliberately open — the human wants to revamp that section first. Safari support pinned/deferred (relay `[web.https]` runbook remains in HUMAN.md §4).

### 2026-09-13 — timecode strip on the viewer page (human-requested)
- New panel above the players live-crops the burned-in clock out of both streams and stacks them (MoQ over HLS, magnified) so the timecode delta is readable at a glance. Crop rect (10,10,360,70) is resolution-independent because overlay.filter draws at absolute x=20,y=20 fontsize=48.
- Sources: `#moq canvas` and the hls `<video>`, copied via drawImage in the existing rAF tick; rows paint black when a stream isn't flowing. No getImageData/toDataURL (avoids tainted-canvas errors with cross-origin native HLS).
- `tests/test-site.sh` now requires `tc-moq`/`tc-hls` (written first, seen failing, then passing). Suite 5/5.

### 2026-09-13 — scripts/dev.sh (human-requested)
- One command for the local stack: `dev.sh up [test|capture]` (compose up, publisher backgrounded with pidfile + logs/dev-publish.log, `python3 -m http.server 8000 --directory site`, writes site/config.js from $MOQ_RELAY_URL if absent), `dev.sh down` (pidfile kills with child-pkill for the ffmpeg|moq pipeline, stray-pattern cleanup, compose down), `dev.sh status` (incl. playlist-flowing check via cookie-jar curl). Verified: down→status(all DOWN)→up(playlist flowing) cycle.
- README Layout + local-architecture.md updated to point at it.

### 2026-09-13 — Task 8 complete (OCR latency harness)
- `tools/measure/measure.mjs` (playwright **1.63.0** pinned, installed Chrome via `channel: "chrome"`, no browser download) + `scripts/measure-latency.sh` + `tests/test-measure.sh` + seeded `site/results/data.json`; `site/index.html` got `window.__hls` + a footer `results/` link. TDD order followed; self-test passed first try (720x120 render → crop path → tesseract → `12:34:56.789`).
- **Local e2e ran twice.** First run exposed an OCR failure mode: a misread digit can put the burned clock *ahead* of local time, and the mod-24h wrap turns that into a ~86,400,000ms delta. Fix (deviation from the contract): a parsed delta > 10 min is dropped as a misread (crop kept in `--debug-dir`), and the `hlsjs-api` read was moved before the OCR branch so a dropped OCR sample doesn't lose it. `data.json` was re-seeded and the e2e re-run clean before committing.
- **Result (test source, this M-series Mac):** moq clock-ocr n=5 p50=672ms (563–706); hls clock-ocr n=5 p50=1413ms (1404–1427); hlsjs-api ≈1047ms. MoQ p50 < HLS p50 ✓. OCR hit rate ~10/12 crops; failures were unparseable, not silently wrong (except the wrap case above, now guarded).
- **moq-watch probe (plan Task 8 Step 4):** prototype has `latency latencyMin latencyMax jitter reset catalog catalogFormat …`, but `latency`/`latencyMin`/`latencyMax` getters return the **string** `"real-time"` (jitter=100) on a live stream — no numeric latency stat exists in 0.5.2, so no moq api sample is emitted (schema v1 wouldn't allow the method anyway).
- **Quirk:** port 8000 was already held by dev.sh's `http.server` (pid in `logs/dev-site.pid`) — it serves `site/` so the harness just used it; the e2e doesn't need its own server if dev.sh's is up. Left it running (it's the human's). Suite is now 6 tests: `bash tests/run.sh` → PASS all 6, no ffmpeg/moq/container leaks.
- Next: Task 9 (`/results` page + README/HUMAN.md plumbing).

### 2026-09-13 — Task 9 complete (/results page + docs plumbing)
- TDD order: `tests/test-results-page.sh` first (`missing site/results/index.html`, exit 1), then `site/results/index.html` per the Page contract — one file, no external scripts, dark look copied from the live page. Tiles = latest run's clock-ocr p50 (MoQ blue `#8ab4ff`, HLS warm `#ffb74d`); hand-rolled SVG dot chart (linear y, 1/2/5-step gridlines — today's 563–1427ms range reads fine linear); runs table gets one row per transport per run plus an `hlsjs-api` row marked "player-reported"; caveats block; back-link.
- Beyond the grep test, smoke-ran the page's inline JS in node with a stubbed DOM against the real `data.json`: tiles print 672/1,413 ms (matches Task 8's recorded p50s), 10 dots, 3 table rows, no exceptions. Browser eyeball is in HUMAN.md §4.
- README: "Measured latency" placeholder table → pointer to `/results/` + the 3-line publish flow; Layout/Install/Tests updated. HUMAN.md: §5 second item rewritten (measure-latency on the publisher machine → review → commit+push → tick plan Task 7 Step 4), new §7 x86-Mac prep (tesseract/node/Chrome/npm-install, no-SKIP gate, dropped-frames caveat), §4 gets a `/results` browser check.
- **Rule fix:** HUMAN.md §4's relay-TLS gate contained the relay hostname (left over from the 2026-09-13 Safari runbook) — replaced with the `<relay-host>` placeholder the rest of the file uses; the no-relay-identifiers rule is repo-wide, not just `site/`.
- **Quirk:** this iteration's shell had no `MOQ_RELAY_URL` (first suite run: 3 network tests failed on the missing env, remaining 4 passed). Loaded it from gitignored `site/config.js` via node (`window.MOQ_RELAY_URL`) without echoing it. Full suite then PASS all 7; leak check clean (no ffmpeg/moq/containers). One benign wobble: test-run-forever's first publish exited rc=255 after ~5s (relay connect hiccup) — the wrapper restarted it, which is the behavior under test.

### 2026-09-13 — scripts/prod.sh (human-requested)
- Publisher runner for the x86 stage Mac (Pengo + media assumed connected): `up` exports SOURCE=capture and a credentialed prod RTMP_URL (built from $RTMP_PUBLISH_PASS; HLS_HOST/PAGE_URL/RTMP_URL overridable) and backgrounds run-forever.sh with a pidfile; `down` TERMs run-forever (its trap stops the pipeline) plus stray-pattern cleanup; `status` checks publisher pid, public playlist (cookie-jar curl), and the public page; `measure` wraps scripts/measure-latency.sh with --url <public page> --source capture. `help` mirrors dev.sh.

### 2026-09-15 — v2 scaffold (by hand, not a loop iteration)
Converted ralph/ to the v2 contract (create-ralph-loop skill): new PLAN.md
(auth + results workflow, 5 tasks), PROMPT.md/ralph.sh with the two-promise
protocol (LASER_MOQ_V2_COMPLETE / HUMAN_GATE), Status table drives --model.
v1 plan archived at docs/superpowers/specs/ralph-v1-plan.md (Tasks 1-9 done
except Task 7 Step 4, now covered by HUMAN.md §5/§7). Source plan:
docs/superpowers/plans/2026-09-15-auth-and-results-workflow.md

### 2026-09-15 — Task 1 complete (measurement preflight + warm-up diagnostics)
- Checked `ralph/HUMAN.md` first: the only unchecked item with a dated note is
  §4's relay-TLS fix (already root-caused/logged 2026-09-13, human-only —
  touches the relay box, not something this loop can act on) and the pinned
  Safari deferral; neither is a fresh bug report needing a PLAN.md amendment.
  §1's "review the v2 loop's commits" is a plain pending gate, not a bug note.
  Picked Task 1, the first task with unchecked steps.
- TDD exactly per plan: appended the 3-line preflight assertion block to
  `tests/test-measure.sh` before `exit 0`, ran it — failed on "preflight
  message missing" (measure.mjs went straight into `chromium.launch`, as
  expected). Implemented the preflight block (URL/HLS-URL derivation, `probe()`
  with an 8s AbortController timeout, `--skip-preflight` flag wired into the
  defaults + arg loop) verbatim from the plan, inserted immediately before
  `await import("playwright")`. Extended the warm-up failure `die()` to name
  `opts.url`/`hlsUrl` and point at `dev.sh status` / `prod.sh status`.
- `bash tests/test-measure.sh && node --check tools/measure/measure.mjs` →
  both green (self-test still parses `12:34:56.789`, no syntax errors). No
  deviations from the plan's snippet.
- Did **not** run the full `tests/run.sh`: the dev stack was already up
  outside this iteration (`docker ps` showed `laser-mediamtx` +
  `<internal-relay-image-dev>`, and a `python -m http.server 8000 --directory site`
  was running under `logs/dev-site.pid`) — running the suite risked tearing
  down state the human is using, per the prompt's rule. `test-measure.sh`
  doesn't touch Docker so it was safe to run standalone; that plus the exact
  verify command the plan specifies is sufficient for this task's step 2.
- No background processes started this iteration, so nothing to kill.
- Next: Task 2 (/results legibility — static intro + dynamic labels in
  `site/results/index.html`).
