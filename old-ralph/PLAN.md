# MoQ Auth + Results Workflow (v2) Implementation Plan

> **For agentic workers:** Executed by a ralph loop (`ralph/ralph.sh` +
> `ralph/PROMPT.md`), one task per iteration. Tick checkboxes in this file as you
> go; keep the Status table below current every iteration.

## Status
<!-- The loop refreshes this table and the Updated line EVERY iteration. -->
<!-- Done tasks pruned 2026-09-23 (were: 1–4, 6–10, all done). -->
| # | Task | Status | Model |
|---|------|--------|-------|
| 5 | MoQ auth repo-side + gated verification | gated: HUMAN.md §6 | haiku |
| 11 | Prod HLS: single CORS header (fixes §5 manifestLoadError) | gated: HUMAN.md §9 | sonnet |
| 12 | MoQ jitter buffer: latency attr + receipt (fixes §5 choppy MoQ) | gated: HUMAN.md §10 | sonnet |
| 13 | Relay outage after §6 auth restart: diagnosed, recovery runbook | gated: HUMAN.md §11 | sonnet |
| 14 | §6 gate FAIL root-caused: test exit-code heuristic; test rewritten | gated: HUMAN.md §6 | sonnet |

_Updated: 2026-09-23 (Task 14 added from §6's FAIL note and resolved repo-side: test-auth.sh now judges by moq's connected line; gate re-verified passing from this machine. All remaining work is human-gated. Gates: Task 5 Step 4 →§6, Task 11 Step 5 →§9, Task 12 Step 5 →§10, Task 13 Step 3 →§11, Task 14 Step 3 →§6.)_


**Goal:** The measurement workflow diagnoses its own misconfiguration (preflight names the URL that has no stream and which script to use); `/results` states what the tiles/chart/table/map each show and which run the map depicts; `dev.sh`/`prod.sh` grow `map` subcommands; live geo collection is proven end-to-end against the dev stack; MoQ publish auth gets a repo-side test that self-skips until the human completes `ralph/HUMAN.md` §6.

**Tech stack:** bash; Node ≥ 20 + playwright pinned in `tools/measure/package.json` (`channel: "chrome"` — never `npx playwright install`); tesseract CLI; Python 3 stdlib; MediaMTX via `hls-origin/compose.local.yml`. No new dependencies anywhere.

**Source plan/spec:** `docs/superpowers/plans/2026-09-15-auth-and-results-workflow.md` (this plan, with rationale); project spec `docs/superpowers/specs/2026-08-29-laserdisc-moq-livestream-design.md`; v1 plan archived at `docs/superpowers/specs/ralph-v1-plan.md`.

## Global Constraints

- **Never push; never run infra** (`aws`, `oci`, `ssh`, `scp`, `rsync` to a host, `sudo`, any `gh`). Human-only work goes to `ralph/HUMAN.md`.
- **Relay rules:** endpoint only from `$MOQ_RELAY_URL`; never write the relay's URL, hostname, IP, or any token into any repo file or log line you author; publish only to broadcast names matching `laserdisc*.hang`; never touch the relay box/config/version.
- **Committed-data privacy:** `site/results/data.json` must never contain `"ip"`, `"hostname"`, or `"host"` keys; geo stays `{city, region, country, lat, lon}` (`tests/test-measure.sh` enforces).
- **One README, top level only.** Never create README.md in a subdirectory.
- **`site/results/index.html` stays library-free** — no external `<script src=` (`tests/test-results-page.sh` enforces).
- Installs: nothing global except `brew install tesseract`; `npm install` only inside `tools/measure/`.
- Tests are bash scripts `tests/test-*.sh` run by `tests/run.sh`; PASS/FAIL per file, non-zero on failure. Don't run `tests/run.sh` while the dev stack is up — cleanup tears the stack down.
- Kill every background process you started; `docker compose -f hls-origin/compose.local.yml down` what you brought up.
- Commit every iteration: `git add -A && git commit -m "<type>: <what>"`, type ∈ feat/fix/docs/test.

---

### Task 5: MoQ auth — repo-side tests + docs (real verification gated)

Repo side done: `tests/test-auth.sh` exists (self-skips until `$MOQ_RELAY_URL`
carries `?jwt=`; never echoes the URL) and README points at `ralph/HUMAN.md` §6
as the enablement runbook.

- [ ] **Step 4: Real verification** — gated: HUMAN.md §6
After the human completes §6, they run `bash tests/test-auth.sh` with the publisher token in `$MOQ_RELAY_URL` and tick §6's gates. Expected: `auth ok: token publishes, no-token rejected`, and the pipecat demo on `anon/` still works.

---

### Task 11: Prod HLS — single CORS header (HUMAN.md §5 note, 2026-09-17)

Repo side done: duplicate CORS/cache header lines removed from
`hls-origin/Caddyfile` (guarded by `tests/test-caddyfile.sh`); committed as
"fix: drop Caddy CORS/cache headers duplicating MediaMTX's".

- [ ] **Step 5: Redeploy + re-check** — gated: HUMAN.md §9
Human copies the new Caddyfile to the HLS VM, recreates the caddy container, verifies `curl -sI https://<hls-host>/laserdisc/index.m3u8` shows exactly ONE `access-control-allow-origin` line, then re-tests the prod page in a browser with a publisher up (and re-observes MoQ choppiness after pushing the pending commits).

---

### Task 12: MoQ jitter buffer — latency attribute + receipt (HUMAN.md §5 note, 2026-09-18)

Repo side done: `site/index.html` sets a 150 ms `latency` jitter buffer on
`<moq-watch>` (`?moqlatency=<ms>` or `?moqlatency=real-time` to override;
receipt in `#status-moq`, `window.__moqlatency` harness hook); committed as
"fix: 150ms MoQ jitter buffer + receipt".

- [ ] **Step 5: Prod re-check** — gated: HUMAN.md §10

---

### Task 13: Relay outage after the §6 auth restart (HUMAN.md §6 note, 2026-09-20)

Diagnosed repo-side 2026-09-20: the relay is not listening at all (TCP 443
refused; QUIC times out) since the §6 auth-config restart at 19:35Z — not a
token or repo problem. Recovery runbook written to HUMAN.md §11.

- [ ] **Step 3: Verify after recovery** — gated: HUMAN.md §11
      After the human restores the relay: `SOURCE=test HLS=0 scripts/publish.sh`
      logs `connected version=moq-lite-04` within a few seconds, then the §6
      gates (`bash tests/test-auth.sh` with the publisher-token URL) proceed.

---

### Task 14: §6 gate FAIL — tokenless publish not rejected (HUMAN.md §6 note, 2026-09-23)

Human ran `bash tests/test-auth.sh` (relay evidently back up — the authorized
half passed) and got `FAIL: tokenless publish was NOT rejected`. Two candidate
causes: (a) relay-side — the gated prefix accepts anonymous connects (auth key
inactive/rolled back, or `public` misconfigured); (b) test-side — the relay
rejects the *broadcast* silently but `moq import` doesn't exit, so
`test-auth.sh`'s exit-code heuristic (pipeline must die within `timeout 5`)
reads "still running" as "accepted".

- [x] **Step 1: Reproduce + discriminate.** With the publisher-token URL in
      `$MOQ_RELAY_URL`, run both halves of the test manually with moq/ffmpeg
      stderr captured to a tmpfile OUTSIDE the repo; grep only for
      `connected version=` (never echo the log wholesale — publish.sh line 48
      prints the URL). Tokenless run logs `connected` → cause (a), relay-side.
      Tokenless run shows a rejection/timeout but the pipeline outlives 5s →
      cause (b), test bug.
- [x] **Step 2: Fix what's repo-side.** Cause (b): rewrite `tests/test-auth.sh`
      to judge by the `connected version=` stderr line (present for jwt run,
      absent for tokenless) instead of raw exit codes; keep the no-echo rule
      (grep patterns only, tmpfiles deleted). Cause (a): no repo change —
      write the relay-side findings + exact checks into `ralph/HUMAN.md` §6
      (dated loop reply) and re-gate. Either way verify:
      `bash tests/test-auth.sh` (with the token URL exported).
- [ ] **Step 3: Re-gate** — gated: HUMAN.md §6
      The human reruns `bash tests/test-auth.sh` →
      `auth ok: token publishes, no-token rejected`, ticks §6's first gate.
