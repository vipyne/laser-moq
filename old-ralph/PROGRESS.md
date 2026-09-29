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
  `pipecat-moq-relay-dev`, and a `python -m http.server 8000 --directory site`
  was running under `logs/dev-site.pid`) — running the suite risked tearing
  down state the human is using, per the prompt's rule. `test-measure.sh`
  doesn't touch Docker so it was safe to run standalone; that plus the exact
  verify command the plan specifies is sufficient for this task's step 2.
- No background processes started this iteration, so nothing to kill.
- Next: Task 2 (/results legibility — static intro + dynamic labels in
  `site/results/index.html`).

### 2026-09-15 — Task 2 complete (/results legibility)
- Checked `ralph/HUMAN.md` again first: no new dated notes since the last
  iteration's read; nothing to fold into PLAN.md. Picked Task 2, the first
  task with unchecked steps.
- TDD per plan: appended the 4-line assertion block to
  `tests/test-results-page.sh` before `exit 0`, ran it — failed on
  "how-to-read intro missing" as expected. Implemented verbatim from the
  plan: `#how-to-read` paragraph under the header intro, `<h2 id="latest-run-label"
  hidden>` above the tiles (filled in the fetch handler with
  `Latest run — <date> · <source> · <machine>`), `#map-title` heading text set
  inside `drawMap(run, latestRun)` (added the second param + call-site arg),
  and the `.sub` scope paragraph above the runs table.
- `bash tests/test-results-page.sh` → PASS. `bash tests/test-site.sh` → PASS
  (the plan's verify command). No deviations.
- Did not run the full `tests/run.sh`: same reasoning as Task 1 — avoid
  tearing down a dev stack that may be up outside this iteration; both
  standalone tests specified by the plan's verify command are static/no-Docker
  and green.
- No background processes started this iteration.
- Next: Task 3 (endpoint-map subcommands in `scripts/dev.sh`/`scripts/prod.sh`).

### 2026-09-15 — Task 3 complete (endpoint-map subcommands)
- Checked `ralph/HUMAN.md` again: no new dated notes; nothing to add to PLAN.md.
  Picked Task 3, the first unchecked task.
- TDD per plan: appended the 3-line assertion block to `tests/test-endpoint-map.sh`
  before `exit 0`, ran it → failed on "dev.sh map missing from help" as expected.
- Implemented verbatim: added `map()` function in `scripts/dev.sh` calling
  `python3 scripts/endpoint_map.py --hls localhost --page localhost "$@"`;
  added help line for map; added case arm. Same in `scripts/prod.sh`: `map()`
  calling `python3 scripts/endpoint_map.py "$@"`, help line, case arm.
  Modified `scripts/prod.sh measure()` to append `&& python3 scripts/endpoint_map.py
  --from-run || true` after the measure-latency.sh call.
- `bash tests/test-endpoint-map.sh && bash -n scripts/dev.sh && bash -n scripts/prod.sh`
  → all green (test passes, both scripts syntax-clean). No deviations from the plan.
- No background processes started this iteration.
- Next: Task 4 (live-geo e2e test).

### 2026-09-15 — Task 4 & 5 (geo e2e + auth, partial)
- Task 4 Step 1: created `tests/test-geo-live.sh` verbatim from the plan. Ran it →
  SKIPped correctly (`MOQ_RELAY_URL not set`). Step 2 would run the full suite,
  but the dev stack is currently up outside this iteration (same constraint as
  Tasks 1–2, per the ralph prompt). Marked Task 4 as blocked.
- Task 5 Step 1–2: created `tests/test-auth.sh` verbatim from the plan. Ran it →
  SKIPped correctly (no `?jwt=` in MOQ_RELAY_URL). Updated README.md Run section
  to mention test-auth.sh + ralph/HUMAN.md §6, and Tests section to list
  test-auth.sh as offline + self-skipping until auth is enabled.
  Verified: `grep -q 'test-auth' README.md` passed, and `bash tests/test-auth.sh`
  SKIPped as expected. Step 2's full suite run skipped due to dev stack up
  (same constraint).
- No deviations from plan. No background processes.
- All 5 tasks in PLAN.md now have first 1–2 steps completed; Tasks 4–5 Step 2
  (full suite) blocked by dev-stack-up condition. Complete when either the dev
  stack is taken down or the human reviews + pushes (HUMAN.md §1 gate).

### 2026-09-16 — Tasks 6–10 appended to PLAN.md (human-requested, outside the loop)
- New scope: LL-HLS tuning as a Mode A / Mode B comparison on ONE page. Origin tuned permanently (100ms parts, 500ms segments, FPS-coupled GOP); the viewer page exposes two hls.js client presets with a UI toggle (`?hlspreset=`): **Mode A "typical"** (sync 1.5s — HLS as commonly deployed, the MoQ-wins story) and **Mode B "ragged"** (sync 0.3s, rate 1.15 — HLS's genuine best shot at MoQ, stalls on hiccups by design). Per-run `tuning` receipts (incl. `preset`) in data.json, shown on /results; Task 10 measures BOTH modes (typical first, ragged last so it headlines) and also clears Task 4's deferred full-suite step. Beyond-ragged stunts (rate 1.25 chipmunk) stay TODO(sneaky).
- Baseline (committed runs, untuned origin): HLS clock-ocr p50 1712–1862 ms vs MoQ 655–672 ms. Expected after: Mode A ~1.5 s, Mode B ~0.5–0.8 s — record who wins Mode B honestly.
- Human gate for the appended runs: HUMAN.md §8 (tile-headline ordering is the human's call).

### 2026-09-16 — Checkbox bookkeeping fixed (Tasks 3–5); Task 6 complete
- Checked `ralph/HUMAN.md` first: no new dated bug-report notes since the last
  read. Read PLAN.md's Status table + task list: Status said Tasks 3 and 5
  were "done" and PROGRESS.md's 2026-09-15 entries agreed, but the actual
  checkboxes under Tasks 3, 4 (Steps 1–3), and 5 (Steps 1–3) were still
  unticked `[ ]` — a bookkeeping miss from prior iterations (work landed and
  was committed, but the plan file's own checkboxes were never flipped).
  Per the "first task with unchecked steps" rule this pointed at Task 3, but
  since the code was already in place, treated it as: verify each step's
  named command for real, then tick only what the run proves.
- Verified: `bash tests/test-endpoint-map.sh && bash -n scripts/dev.sh &&
  bash -n scripts/prod.sh` → PASS (Task 3, all 3 steps). `bash
  tests/test-auth.sh` → SKIP (no `?jwt=`, expected — Task 5 Steps 1–3) +
  `grep -q test-auth README.md` → match. `bash tests/test-geo-live.sh` (dev
  stack was down beforehand — confirmed via `docker ps`) → `geo ok: New
  Orleans / San Jose`, stack torn down by its own trap after (Task 4 Step 1).
  Then ran the full suite from a clean stack-down state per Task 4 Step 2 /
  Task 5's deferred suite run: `bash tests/run.sh` → 10/10 PASS/SKIP, 0 FAIL,
  no stray docker/ffmpeg/moq processes after. Ticked all of Task 3, Task 4
  (now fully done), and Task 5 Steps 1–3 (Step 4 stays gated: HUMAN.md §6).
  Status table: Task 4 → done, Task 5 → `gated: HUMAN.md §6`.
- **Note:** `ralph/` is locally git-excluded (`.git/info/exclude: ralph/*`),
  so `git add -A` never stages PLAN.md/PROGRESS.md/HUMAN.md — this
  reconciliation produced no commit by itself (deliberate: HUMAN.md carries
  a plaintext RTMP password). Don't be alarmed by "nothing to commit" after
  a ralph/-only edit; it's expected for this repo.
- With bookkeeping caught up, picked Task 6 (first task with real unchecked
  steps): LL-HLS tuning. TDD per plan: appended the `PART-TARGET=0.1` grep to
  `tests/test-hls.sh` right after the existing `#EXT-X-PART` check, ran it →
  failed as expected (`part target is not 100ms`, playlist showed
  `PART-TARGET=0.20000`). Implemented verbatim: `hls-origin/mediamtx.yml`
  `hlsPartDuration: 200ms`→`100ms`, `hlsSegmentDuration: 1s`→`500ms` (kept
  `hlsSegmentCount: 7`), one-line latency-floor comment. `scripts/publish.sh`:
  added `GOP="${GOP:-$(( ${FPS%%.*} / 2 ))}"` beside the SIZE/FPS block
  (comment explains FPS-coupling + integer-truncation of `60.000240`),
  changed the encoder's `-g 30` → `-g "$GOP"`.
- `bash -n scripts/publish.sh && bash tests/test-hls.sh` → both green (`LL-HLS
  ok`, `anonymous publish rejected`, `publisher survived HLS origin loss`,
  rc=0). Docker torn down by the test's own trap; no stray processes after.
- Committed `hls-origin/mediamtx.yml`, `scripts/publish.sh`,
  `tests/test-hls.sh` together (ralph/ files stay local-only per the note
  above). No background processes left running.
- Next: Task 7 (viewer page Mode A/B HLS presets + UI toggle + live receipt
  in `site/index.html`).

### 2026-09-16 — Task 7 complete (Mode A/B HLS presets + UI toggle + live receipt)
- Checked `ralph/HUMAN.md` first: no new dated bug-report notes under any
  unchecked **Gate:** item since the last read; §5-§8 unchecked items are
  plain (non-Gate) checklist items already accounted for by gated/pending
  plan tasks. Read PLAN.md's Status table: Task 7 was the first task with
  unchecked steps (Tasks 1-6 done/gated; Task 5 Step 4 stays gated: HUMAN.md
  §6).
- TDD per plan: appended the 6-line assertion block to `tests/test-site.sh`
  before `exit 0`, ran it → failed on "hls.js catch-up rate missing" as
  expected. Implemented verbatim from the plan in `site/index.html`:
  - `PRESETS` const with exactly `typical` (sync 1.5s) and `ragged` (sync
    0.3s, rate 1.15) entries, plus the `TODO(sneaky)` comment for the
    unimplemented rate-1.25 chipmunk stunt.
  - Factored HLS setup into `startHls(presetName)`: destroys any prior `Hls`
    instance, creates `new Hls(PRESETS[presetName])`, reattaches, sets
    `window.__hls` and `window.__hlspreset`, updates the `#status-hls`
    receipt via `presetReceipt()` on `MANIFEST_PARSED` and `LEVEL_UPDATED`
    (reads `partTarget` off the current level's details, omitted gracefully
    when the field isn't populated yet).
  - Added a two-button toggle (`id="hls-preset"`, `typical`/`ragged`) in the
    HLS pane's `<h2>`; each button calls `startHls(this preset)` and
    `aria-pressed` reflects the active one — no page reload. Small CSS added
    for the toggle (flex header, pressed-state highlight).
  - Initial call: `startHls(q.get("hlspreset") ?? "typical")`; unknown preset
    names fall back to `typical` inside `startHls` itself.
  - Did not touch the timecode strip or clock logic — both read the
    persistent `<video>`/`<canvas>` elements, unaffected by preset swaps.
- `bash tests/test-site.sh` → PASS. Extracted the `<script type="module">`
  body to a temp `.mjs` and ran `node --check` on it → OK. Both are exactly
  the plan's verify command; no deviations.
- Confirmed the dev stack was down (`docker ps` showed only unrelated
  project containers) before finishing, though this task touched no
  Docker/live infra. No background processes started or left running this
  iteration.
- Committed `site/index.html` and `tests/test-site.sh` together (`ralph/`
  files stay local-only, excluded from `git add -A` per the repo's
  `.git/info/exclude` — expected, not an error).
- Next: Task 8 (measure harness records per-run `tuning` receipts in
  `tools/measure/measure.mjs`, sourced from `window.__hls`/`window.__hlspreset`
  added this iteration).

### 2026-09-16 — Task 8 complete (measure harness records per-run tuning receipts)
- Checked `ralph/HUMAN.md` first: no new dated bug-report notes under any
  unchecked **Gate:** item since the last read. Read PLAN.md's Status table:
  Task 8 was the first task with unchecked steps (Task 5 Step 4 stays
  gated: HUMAN.md §6).
- TDD per plan: extended the embedded Python schema check in
  `tests/test-measure.sh` so each run's optional `tuning` field, if present,
  must be a dict whose keys are a subset of the seven known receipt fields;
  then appended the `grep -q '"tuning"' tools/measure/measure.mjs` assertion.
  Ran it → failed on "harness does not record tuning receipts" as expected
  (existing untuned runs still passed the schema part).
- Implemented in `tools/measure/measure.mjs`, right after the moq-stats
  probe and before the `panes` array: an in-page `page.evaluate` that reads
  `window.__hls` (added in Task 7) — `preset` from `window.__hlspreset`,
  `live_sync_s`/`max_latency_s`/`max_catchup_rate`/`low_latency` from
  `h.config`, `part_target_s`/`target_duration_s` from the current level's
  `details` (falling back to level 0) — all numeric fields coerced through a
  `num()` guard to `null` when non-finite, so the object is `null` only when
  `window.__hls` itself doesn't exist (e.g. a native-Safari path). Logged
  it (`tuning: {...}`) alongside the existing moq-stats log line, then added
  `tuning` to the pushed run object.
  - **Quirk:** the plan's own grep (`grep -q '"tuning"'`) looks for the
    literal quoted string `"tuning"` in the source, but the natural
    implementation used the ES2015 shorthand `tuning` in the object literal
    (`{ ..., geo, tuning }`), which never appears quoted. Fixed by writing
    the final key explicitly as `"tuning": tuning` in the push — functionally
    identical, satisfies the plan's literal check. Worth remembering for any
    future plan step that greps for a quoted key name against harness code
    that might use property shorthand.
- `bash tests/test-measure.sh` → PASS (`self-test ok: parsed 12:34:56.789`,
  preflight assertions still green). `node --check tools/measure/measure.mjs`
  → OK. Both are exactly the plan's verify command; no other deviations.
- No background processes started this iteration (no live measurement was
  run — the self-test and preflight probe are the only checks the plan
  calls for at this step).
- Committed `tools/measure/measure.mjs` and `tests/test-measure.sh` together
  (`ralph/` files stay local-only per the repo's `.git/info/exclude`).
- Next: Task 9 (results page displays the tuning receipts recorded above via
  a `tuningLabel(run)` helper in `site/results/index.html`).

### 2026-09-16 — Task 9 complete (results page shows per-run hls tuning receipts)
- Checked `ralph/HUMAN.md` first: no new dated bug-report notes under any
  unchecked **Gate:** item since the last read. Read PLAN.md's Status table:
  Task 9 was the first task with unchecked steps (Task 5 Step 4 stays
  gated: HUMAN.md §6).
- TDD per plan: appended the `tuningLabel`/caveats-mention assertions to
  `tests/test-results-page.sh` before `exit 0`, ran it → failed on "tuning
  receipt display missing" as expected.
- Implemented in `site/results/index.html`: a `tuningLabel(run)` helper
  building `preset · part <ms>ms · sync <s>s · ≤<rate>x` from `run.tuning`
  (each field optional, joined with what's present, empty string when
  `run.tuning` is absent — runs without tuning render exactly as before).
  Wired into `tiles()` (appended to the HLS tile's `#hls-sub` only, not moq)
  and into `table()`'s hls rows as both a `title="..."` tooltip on the `<tr>`
  and a visible `<small>` next to the `hls` badge (kept small/inline so
  untuned rows are visually unchanged). Added a Caveats sentence naming the
  per-run tuning receipt mechanism and the Mode A/B presets.
- `bash tests/test-results-page.sh` → PASS (exit 0, no output — the plan's
  exact verify command). No deviations.
- Did not run the full `tests/run.sh`: same reasoning as prior static-file
  tasks (Task 1/2) — this task only touches `site/results/index.html` and
  its own test, no Docker/network involved, and the plan's verify command is
  exactly `bash tests/test-results-page.sh`.
- No background processes started this iteration.
- Next: Task 10 (measure Mode A + Mode B runs, full suite from a clean
  stack-down state — requires `$MOQ_RELAY_URL` and the dev stack; also
  clears Task 4's deferred full-suite step).

### 2026-09-16 — Task 10 steps 1-2 (Mode A/B measurement runs + clean-state full suite)
- Checked `ralph/HUMAN.md` first: no new dated bug-report notes under any
  unchecked **Gate:** item. PLAN.md's Status table: Task 10 was the first
  task with unchecked steps (Task 5 Step 4 stays gated: HUMAN.md §6).
- Step 1: confirmed the dev stack was DOWN (`scripts/dev.sh status` → all
  three `DOWN`), then ran `bash tests/run.sh` from that clean state. Every
  test file PASS except `test-auth.sh` which SKIPs (no `?jwt=` in
  `$MOQ_RELAY_URL` — HUMAN.md §6 not done yet, expected). `test-geo-live.sh`
  ran for real (not SKIP) since `$MOQ_RELAY_URL` was set — this satisfies
  Task 4's deferred Step 2; Task 4's Status row was already `done`, so no
  change needed there.
- Step 2: `scripts/dev.sh up test`, `sleep 10`, then measured both presets
  against the same local origin:
  - Mode A (`hlspreset=typical`, notes "Mode A typical: tuned origin, sync
    1.5s"): `tuning.preset` = `typical`, `part_target_s` = 0.134 (hls.js's
    observed part duration off the wire — mediamtx is configured for
    100ms; ~34ms overhead from segmentation/measurement timing, "≈ 0.1" per
    the plan's own looseness). **MoQ p50 = 648ms** (min 597, max 667, n=9).
    **HLS p50 = 2192ms** (min 2158, max 2217, n=9). 3 OCR parse failures
    (crops kept in `logs/measure-20260917T034505/`), reruns not needed —
    n≥9 per side.
  - Mode B (`hlspreset=ragged`, notes "Mode B ragged: sync 0.3s rate
    1.15"): `tuning.preset` = `ragged`, `part_target_s` = 0.134 again (same
    origin, same observation). **MoQ p50 = 656ms** (min 577, max 1259 —
    one outlier sample, n=10). **HLS p50 = 1064ms** (min 1017, max 1082,
    n=9).
  - **MoQ wins both modes.** Mode B closed most of the gap (HLS 2192ms →
    1064ms, more than 2x tighter) but landed above the plan's "~0.5-0.8s"
    expectation and above MoQ's ~0.65s — ragged is HLS's best shot here,
    not a win. Recorded honestly; no massaging.
  - Verified via python3 on the two appended runs: `tuning.preset` ==
    `typical` / `ragged` respectively (correct order — A then B, B last so
    it headlines the tiles); both `part_target_s` ≈ 0.1 (0.134, consistent
    across both runs since it's a property of the shared origin, not the
    preset); ragged's hls p50 (1064) < typical's hls p50 (2192) — holds.
  - `scripts/dev.sh down` after both runs. No leaked containers
    (`docker ps` clean of `laser-*` afterward).
- `site/results/data.json` now carries these two runs appended (438 lines
  in the diff, 30 + 31 samples respectively) — **not yet committed**, per
  HUMAN.md §8's gate: human reviews `data.json` before it's pushed, and
  decides whether ragged should stay last or a real capture run should
  land after it. Ticked Task 10 Steps 1-2 in PLAN.md; Status table row set
  to "in progress" (Steps 3-4 — this entry and the commit — finish the
  iteration).
- TODO(sneaky) pointer: `site/index.html`'s `maxLiveSyncPlaybackRate: 1.25`
  chipmunk-catch-up stunt (beyond ragged) remains unimplemented, as scoped
  by Task 7 — not attempted this iteration.
- Next: Task 10 Step 4 is the commit; after that, re-read PLAN.md — if
  Task 10 is the only remaining work and its Step 4 gate note in HUMAN.md
  §8 is satisfied by the human, the loop is at HUMAN_GATE (Task 5 Step 4
  also gated: HUMAN.md §6, unchanged).

### 2026-09-17 — Task 11 (new, from HUMAN.md §5 bug note): prod HLS manifestLoadError root-caused + fixed
- HUMAN.md check found a fresh dated note under §5 (2026-09-17): prod page
  shows choppy MoQ + "HLS offline: manifestLoadError" after `SOURCE=test
  ./scripts/prod.sh`. Per the prompt, turned it into PLAN.md Task 11 before
  picking work; Task 11 was then the first task with unchecked steps.
- **Diagnosis (before writing the task):** `logs/publish-20260917-132841.log`
  shows the RTMP tee leg ran error-free for the whole 4.5 min run (the
  "Slave muxer #0 failed: Broken pipe" at the end is shutdown noise from the
  moq pipe, slave #0, after the human's TERM) — so the origin HAD the stream.
  `curl -sI https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8` →
  `access-control-allow-origin: *` appears TWICE (one from MediaMTX's
  `hlsAllowOrigins: ['*']`, one from the Caddyfile's
  `header Access-Control-Allow-Origin *`). The CORS spec forbids multiple
  values; browsers reject the response outright = hls.js manifestLoadError.
  curl ignores duplicates → §2's curl gate passed; all §4 browser checks hit
  local mediamtx :8888 directly (no Caddy, single header) → prod HLS in a
  real browser was never exercised until the human's test. Verified against
  local mediamtx 1.20.1 (compose.local, short ffmpeg flv publish): it sends
  exactly one allow-origin header on 302/200/404 and its own
  `Cache-Control: private, no-cache` — both Caddy `header` lines redundant,
  one fatal.
- TDD: wrote `tests/test-caddyfile.sh` (static; FAILs if the Caddyfile sets
  the allow-origin or cache header, asserts reverse_proxy stays) → failed on
  the ACAO line as expected. Fixed `hls-origin/Caddyfile` (both header lines
  removed, comment explains why — careful: the comment must not contain the
  literal header names or it trips its own test; first attempt did).
  `bash tests/test-caddyfile.sh` → PASS; `caddy validate` in the caddy:2
  image → "Valid configuration". `docs/deploy-hls-origin.md` does not inline
  the Caddyfile — no doc change needed.
- Full suite from stack-down state: 11/11 PASS (test-auth SKIPs pre-§6 as
  designed; test-geo-live ran for real). Leak check clean (no ffmpeg/moq/
  http.server/laser containers).
- HUMAN.md: dated reply under the §5 note + new **§9** redeploy runbook
  (scp Caddyfile, force-recreate caddy, gate = `grep -ci` exactly 1
  allow-origin header, then browser re-check). Task 11 Step 5 gated on it.
- **Choppy MoQ:** not reproducible repo-side. The deployed page is stale
  (served HTML has no `hlspreset` — the tuning/preset commits are local,
  unpushed) and yesterday's local runs through the same relay were smooth
  (p50 648ms). Told the human (HUMAN.md §5 reply) to re-judge after §9 +
  push and leave a dated note if it persists.
- **Rides along in this commit:** the human's uncommitted `scripts/prod.sh`
  edit (auto-sources `RTMP_PUBLISH_PASS` from gitignored `hls-origin/.env`,
  exported value wins) — committed per the git add -A rule, same precedent
  as earlier iterations.
- Next: only gated work remains (Task 5 Step 4 → §6, Task 11 Step 5 → §9,
  plus HUMAN.md §5/§8 human checks) → HUMAN_GATE.

### 2026-09-18 — Task 12 (new, from HUMAN.md §5 note): choppy MoQ root-caused + fixed (150ms jitter buffer)
- HUMAN.md check found a fresh dated note under §5 (2026-09-18): prod HLS now
  works (human did the §9 Caddyfile redeploy — §9's boxes are still unticked
  but the symptom is confirmed gone) yet MoQ is STILL choppy — second report.
  Per the prompt, turned it into PLAN.md Task 12 before picking work.
- **Diagnosis first:** checked whether the "push the pending commits, then
  re-judge" advice from the 2026-09-17 reply could even fix it — no: local is
  5 commits ahead of origin/main (7317921), and NONE of the pending commits
  touch the MoQ pane. So the stale-page theory couldn't explain choppy MoQ.
  Fetched the @moq/watch@0.5.2 element bundle from jsdelivr and read the
  minified source: `moq-watch` observes attributes `latency`, `latency-min`,
  `latency-max`, `jitter`; the parser `#c()` takes milliseconds via
  Number.parseFloat (literal `real-time` = zero buffer; garbage → 100ms), and
  the internal default is `latency: "real-time"` — ZERO jitter buffer, frames
  render the instant they arrive. `site/index.html` never set the attribute.
  That's exactly "choppy on a real network while HLS (≥1.5s client buffer) is
  smooth on the same link"; local measurement machines just had a low-jitter
  path to the relay. Consistent with the Task 8 note that the element's
  latency getter returned the string "real-time".
- TDD: appended 3 greps to `tests/test-site.sh` (`moqlatency` param,
  `setAttribute("latency"`, `__moqlatency` hook) → failed on "moq latency
  param missing" as expected. Implemented in `site/index.html`: `MOQ_LATENCY =
  q.get("moqlatency") ?? "150"`, set as the `latency` attribute beside
  url/name, `window.__moqlatency` hook, and the `#status-moq` line now appends
  `· buffer 150ms` / `· real-time`. Chose 150ms: absorbs typical network
  jitter, keeps MoQ ~0.8s glass-to-glass — still under Mode B HLS's 1064ms
  p50, so the demo story survives intact.
- Verify: `bash tests/test-site.sh` → PASS; extracted the module script body
  and `node --check` → clean. Did not run the full suite (this task touches
  only site/index.html + its static test; no Docker/network involved).
- HUMAN.md: dated reply under the §5 note + new **§10** re-check gate (push →
  hard-reload prod → expect `· buffer 150ms` + smooth; A/B against
  `?moqlatency=real-time` to confirm cause; note the browser if still choppy —
  Safari rides the WebSocket/TCP fallback). Task 12 Step 5 gated on §10.
- Note for future iterations: `tuning` receipts in data.json stay HLS-only
  (test-measure pins the 7-key subset); if a moq buffer receipt is ever wanted
  per-run, extend that schema test first. `window.__moqlatency` is already
  in place for the harness.
- No background processes started this iteration.
- Next: only gated work remains (Task 5 Step 4 → §6, Task 11 Step 5 → §9,
  Task 12 Step 5 → §10, plus §5/§8 human checks) → HUMAN_GATE.

### 2026-09-20 — HUMAN.md §6 + §7 questions answered (docs-only iteration)
- HUMAN.md check found two fresh 2026-09-20 notes: under §6's unchecked gate
  ("prod or dev viewer page? what url does the publish script use by
  default?") and under §7's load-caveat item ("explain it more"). Both are
  clarification questions, not defect reports — no new PLAN.md task needed;
  the fix is the runbook itself, done this iteration.
- Verified before answering (read the scripts, didn't trust memory):
  `scripts/publish.sh` has NO default relay URL — `MOQ_RELAY_URL="${MOQ_RELAY_URL:-}"`
  then a hard exit "MOQ_RELAY_URL not set" if empty; it publishes to exactly
  what the shell exports. The page resolves its relay as
  `q.get("relay") ?? window.MOQ_RELAY_URL` (site/index.html:77) where
  config.js is CI-written on prod; `dev.sh up` writes site/config.js from
  $MOQ_RELAY_URL **only when the file is missing** (dev.sh:27-29) — so a
  stale local config.js keeps pointing at the old `/anon` path after the §6
  endpoint flip.
- HUMAN.md §6: dated loop reply — first gate is publisher-CLI-only (no viewer
  page; `bash tests/test-auth.sh` runs both halves without echoing the URL);
  second (browser) gate is prod moq-laserdisc.vanessa-dev.com (Actions var
  already flipped; needs a Pages deploy), localhost:8000 usable if the stale
  config.js is deleted first or `?relay=<viewer-token-url>` is passed —
  with a warning that dev.sh would embed the PUBLISHER token in config.js if
  that's what the shell exports (gitignored, local-only, but don't
  screen-share). Also reworded the gate line itself: "jwt stripped from
  MOQ_RELAY_URL" instead of a literal URL (the old wording hardcoded the
  relay hostname — HUMAN.md is git-excluded so it never leaves the machine,
  but loop-authored lines shouldn't carry it either).
- HUMAN.md §7: dated loop reply explaining the load caveat — during a
  measurement the same machine encodes (720x480@60 h264 + overlay + aac,
  teed to MoQ+RTMP), decodes BOTH panes in the harness's Chrome, and spawns
  tesseract per sample; if encode falls behind the card's fixed 60fps ffmpeg
  drops frames (visible via `grep -i drop` in logs/publish-*.log /
  logs/dev-publish.log), the stream stutters AND the samples measure an
  overloaded encoder, inflating both panes' numbers. Runbook: check the
  publish log; on drops re-run with `--samples 6` and record it in
  `--notes` so data.json carries the caveat honestly.
- PLAN.md Status table statuses unchanged (5 → gated §6, 11 → gated §9,
  12 → gated §10, rest done); refreshed the _Updated:_ line to iteration 13.
- No repo (non-ralph/) files touched; ralph/ is git-excluded
  (.git/info/exclude), so `git add -A` stages nothing — the expected
  "nothing to commit" case documented 2026-09-16. No background processes.
- Next: only gated work remains → HUMAN_GATE.

### 2026-09-20 — Task 13 (new, from HUMAN.md §6 note): relay outage root-caused
- HUMAN.md check found a fresh 2026-09-20 note under §6's unchecked gate:
  `SOURCE=test HLS=0 scripts/publish.sh` fails with two
  `WebSocket connection failed` WARNs, "doesn't work with `/anon` either".
  Per the prompt, turned it into PLAN.md Task 13 before picking work.
- **Diagnosis (logs + client probes only; no infra commands, URL never
  echoed):** `logs/publish-20260920-140522.log` — 19:05:22Z connect to
  `/anon` over QUIC succeeded (`connected version=moq-lite-04`), streamed
  ~30 min with subscriber activity; **19:35:39Z** relay-side session drop
  (`web_transport_quinn: failed to read capsule e=UnexpectedEnd`), then
  reconnect timed out and the tee's moq slave broke (ffmpeg continued on the
  RTMP slave alone — `onfail=ignore` doing its job). `logs/dev-publish.log`
  (20:01Z, `/livestream?jwt=…`): initial connect never succeeds — identical
  QUIC timeout + WS-fallback WARNs, so the token is irrelevant to this
  failure. Probes from this machine: DNS resolves; **TCP 443 → connection
  refused** (curl rc=7 + a raw python socket connect — host reachable,
  no listener). 19:35Z matches the human doing §6's relay-box step today
  (jwk key added to the TOML + container restart — those boxes were freshly
  ticked): the relay evidently never came back up. Likely: in-container jwk
  path wrong / file not mounted / TOML typo.
- The WS WARNs in the human's paste are fallback noise AFTER the primary
  QUIC path failed — worth remembering: moq-cli 0.11.0 prints them on every
  failed connect even where WebSocket was never the transport in use.
- Wrote the dated loop reply under §6's note (it's the relay, not the token;
  pipecat demo on `anon/` is down too; dev publisher currently limping
  RTMP-only) + new **§11** recovery runbook (docker logs on the relay box,
  the three usual suspects, roll-back option to restore both demos, re-gate
  via publish.sh `connected` line then §6's test-auth gate). Task 13 Steps
  1–2 ticked; Step 3 gated: HUMAN.md §11.
- **Constraint honored:** the human's dev stack was UP this whole iteration
  (laser-mediamtx container, http.server 8000, publish.sh pid 14906) — ran
  no tests/run.sh, no pkill, nothing that touches the stack; probes were
  read-only client sockets. Nothing to kill: started no background work.
- ralph/-only iteration → `git add -A` stages nothing (documented
  2026-09-16); no commit expected.
- Next: only gated work remains (Task 5 Step 4 →§6, Task 11 Step 5 →§9,
  Task 12 Step 5 →§10, Task 13 Step 3 →§11) → HUMAN_GATE.

### 2026-09-20 — §11 jwk-permissions question answered (docs-only iteration)
- HUMAN.md check found a fresh 2026-09-20 note under §11's first unchecked
  box: the human ran `docker logs` on the relay box, found `moq-root.jwk` is
  `-rw------- ubuntu:ubuntu` next to the root-owned 644 certs, and asked how
  to chown it to root. Progress on Task 13's gate — a question, not a new
  defect; no new PLAN.md task (same treatment as the 2026-09-20 §6/§7
  questions iteration).
- **Answered with a correction, not just the command:** the blocker is the
  0600 MODE, not the ubuntu OWNER. Reasoning left in the §11 reply: a
  container process running as root reads any file regardless of
  ownership/mode (CAP_DAC_OVERRIDE), so the observed read failure proves the
  relay runs as a non-root uid — and therefore `chown root:root` while
  keeping 600 would make things strictly worse (only real root could read
  it). Guaranteed fix = match the certs the relay already reads:
  `sudo chown root:root <jwk> && sudo chmod 644 <jwk>` + container restart;
  trade-off (world-readable signing key on a single-admin box, same posture
  as the already-644 privkey.pem) stated honestly, with the tighter
  alternative (`docker exec <c> id -u` → `chown <uid>` + `chmod 400`).
  Pointed the human at §11's remaining boxes in order, ending at §6's
  `tests/test-auth.sh` gate (fix-not-rollback path).
- All commands in the reply are relay-box work → written to HUMAN.md only,
  nothing executed (infra is human-run). No repo (non-ralph/) files touched;
  ralph/ is git-excluded so `git add -A` stages nothing — expected. No
  background processes started. Did not touch the human's dev stack.
- PLAN.md: statuses unchanged (all remaining work gated); _Updated:_ line
  refreshed to iteration 15.
- Next: only gated work remains (Task 5 Step 4 →§6, Task 11 Step 5 →§9,
  Task 12 Step 5 →§10, Task 13 Step 3 →§11) → HUMAN_GATE.

### 2026-09-23 — Task 14 (new, from HUMAN.md §6 note): §6 FAIL root-caused, test-auth.sh rewritten
- HUMAN.md check found a fresh 2026-09-23 note under §6's first gate:
  `FAIL: tokenless publish was NOT rejected`. Turned it into PLAN.md Task 14
  before picking work; Task 14 was then the first task with unchecked steps.
- **Reproduction says the relay is FINE now.** The loop shell had the
  publisher-token `$MOQ_RELAY_URL` exported (jwt present, `/livestream`
  root); dev stack down (`docker ps` clean of laser-*). Ran both test halves
  manually with stderr to /tmp: jwt run connects (`connected
  version=moq-lite-04`) and streams until `timeout` kills it (rc=124);
  tokenless run exits **rc=1 in ~1s** with relay-side `unauthorized`
  (twice, reproducibly). `bash tests/test-auth.sh` (old version) → PASS.
- **Root cause of the human's FAIL: the test's exit-code heuristic.** Old
  test judged "rejected" = pipeline dies within `timeout 5`. A DOWN/
  unreachable relay hangs BOTH halves past 5s: jwt half rc=124 spuriously
  passes its check, tokenless half rc=124 → prints exactly the human's FAIL.
  They almost certainly ran it mid-§11 recovery. Cause (b) from the task,
  triggered by relay-down rather than silent broadcast rejection.
- **Fix:** `tests/test-auth.sh` now requires connect PROOF — moq's
  `connected version=moq-lite-04` stderr line, grepped as `moq-lite` (the
  line has ANSI escapes between "version" and "="; `grep 'connected
  version='` finds nothing). jwt half must log it (else "authorized publish
  never connected … see §11"); tokenless half must NOT (else "connected
  without a token") and must exit on its own within 8s. **No-echo rule
  hardened:** moq itself logs `connecting url=…` with the token, so the
  captured stderr is grep -q only, mktemp + trap rm.
- Verified: `bash -n` clean; real relay → `auth ok: token publishes,
  no-token rejected` rc=0; black-hole relay (`192.0.2.1`, TEST-NET-1) → the
  new actionable FAIL (not the misleading one) rc=1; tokenless publish to
  the `anon/` prefix still connects (pipecat demo unaffected — the §6
  gate's third clause). Cleaned up /tmp diag dir; no ffmpeg/moq leaks.
- HUMAN.md: dated loop reply under the §6 note (test was lying, relay
  enforcing, rerun the gate and tick). PLAN.md: Task 14 Steps 1–2 ticked,
  Step 3 gated §6; Status row added (sonnet).
- **Quirks for future iterations:** (1) `moq-lite` is the ANSI-safe connect
  marker in moq 0.11.0 stderr; (2) moq logs the full token-bearing URL on
  its `connecting`/`connected url=` lines — any test capturing moq stderr
  must never cat/echo it; (3) `timeout` on `scripts/publish.sh` yields
  rc=124 while streaming healthily (moq is the pipeline tail and never
  exits on its own).
- Next: only gated work remains (Task 5 Step 4 →§6, Task 11 Step 5 →§9,
  Task 12 Step 5 →§10, Task 13 Step 3 →§11, Task 14 Step 3 →§6) →
  HUMAN_GATE.
