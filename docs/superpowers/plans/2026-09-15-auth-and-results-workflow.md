# MoQ Auth + Results Workflow Improvements Implementation Plan

> **For agentic workers:** This plan is executed by the ralph loop (`ralph/ralph.sh` + `ralph/PROMPT.md`, v2 contract), one task per iteration; `ralph/PLAN.md` is the converted, authoritative copy. When run interactively instead: REQUIRED SUB-SKILL superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the measurement workflow self-diagnosing (preflight + clear warm-up errors), make `/results` legible (what the tiles/chart/table/map each show), wire the ASCII endpoint map into the dev/prod scripts, prove live geo collection end-to-end, and add repo-side verification for MoQ publish auth (relay/token work stays human, gated).

**Architecture:** All changes ride the existing pieces: `tools/measure/measure.mjs` (Playwright + tesseract harness), `site/results/index.html` (no-library static page), `scripts/endpoint_map.py` (stdlib ASCII map), `scripts/dev.sh` / `scripts/prod.sh` (stack runners), bash tests under `tests/` run by `tests/run.sh`.

**Tech Stack:** bash, Node ≥ 20 + playwright (pinned in `tools/measure/package.json`, `channel: "chrome"`), tesseract CLI, Python 3 stdlib, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-29-laserdisc-moq-livestream-design.md` (project) + `ralph/HUMAN.md` §6 (auth flow, verified against moq-relay 0.13.5 / moq-cli 0.11.0) + the four scope decisions recorded in this plan.

## Global Constraints

- **Never push; never run infra** (`aws`, `oci`, `ssh`, `scp`, `rsync`-to-host, `sudo`, any `gh`). Human-only work goes to `ralph/HUMAN.md`.
- **Relay rules:** endpoint only from `$MOQ_RELAY_URL`; never write the relay's URL/hostname/IP (or any token) into any repo file; publish only to `laserdisc*.hang`; never touch the relay box/config/version.
- **Committed data privacy:** `site/results/data.json` may never contain `"ip"`, `"hostname"`, or `"host"` keys — geo stays `{city, region, country, lat, lon}` (enforced by `tests/test-measure.sh`).
- **One README, top level.** No README.md in subdirectories.
- **No new site dependencies:** `site/results/index.html` stays library-free (no external `<script src=`; enforced by `tests/test-results-page.sh`).
- Tests are bash scripts `tests/test-*.sh` run by `tests/run.sh`; exit non-zero on failure.
- Kill every background process you start; `docker compose -f hls-origin/compose.local.yml down` what you brought up.
- Commit each task: `<type>: <what>`, type ∈ feat/fix/docs/test.

## File Structure

| Path | Change |
|---|---|
| `tools/measure/measure.mjs` | Preflight before Chrome launch; richer warm-up failure message. |
| `tests/test-measure.sh` | New offline preflight assertion. |
| `site/results/index.html` | "How to read" intro, latest-run label, dynamic map title, table intro. |
| `tests/test-results-page.sh` | Greps for the new ids/copy. |
| `scripts/dev.sh`, `scripts/prod.sh` | `map` subcommands; prod `measure` prints the from-run map. |
| `tests/test-endpoint-map.sh` | Subcommand presence checks. |
| `tests/test-geo-live.sh` | New: live-geo e2e against the dev stack (network + docker; scratch out-file). |
| `tests/test-auth.sh` | New: auth verification, self-skipping until §6 is done. |
| `README.md` | Auth section expansion; test list update. |

---

### Task 1: Measurement preflight + warm-up diagnostics

**Files:**
- Modify: `tools/measure/measure.mjs`, `tests/test-measure.sh`

**Interfaces:**
- Produces: `measure.mjs` exits 1 with a message starting `measure: preflight:` when the page or derived HLS playlist URL is unreachable/4xx+, *before* importing playwright. Message names the exact URL and points at `scripts/dev.sh measure` vs `scripts/prod.sh up`.

- [ ] **Step 1: Write the failing test** — append to `tests/test-measure.sh` (before the final `exit 0`):

```bash
out=$(node tools/measure/measure.mjs --url "http://127.0.0.1:9/" 2>&1)
[[ $? -ne 0 ]] || { echo "preflight should exit non-zero on unreachable target"; exit 1; }
grep -q "preflight" <<<"$out" || { echo "preflight message missing"; exit 1; }
grep -q "127.0.0.1:9" <<<"$out" || { echo "preflight must name the URL it probed"; exit 1; }
```

Run: `bash tests/test-measure.sh`
Expected: FAIL (today the harness imports playwright and tries to launch Chrome instead of preflighting).

- [ ] **Step 2: Implement preflight** in `measure.mjs`, in the live path *before* `await import("playwright")`:

```js
// Preflight: fail fast, before Chrome, when the target's streams can't exist.
const pageUrl = new URL(opts.url);
const hlsUrl = pageUrl.searchParams.get("hls")
  ?? "https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8";
async function probe(u) {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 8000);
    const r = await fetch(u, { redirect: "follow", signal: ctl.signal });
    clearTimeout(t);
    return r.status;
  } catch { return 0; }
}
if (!opts.skipPreflight) {
  const pageStatus = await probe(pageUrl);
  if (!pageStatus || pageStatus >= 400)
    die(`preflight: page ${pageUrl} → ${pageStatus || "unreachable"}`);
  const hlsStatus = await probe(hlsUrl);
  if (!hlsStatus || hlsStatus >= 400)
    die(`preflight: HLS playlist ${hlsUrl} → ${hlsStatus || "unreachable"}.\n` +
      `  No stream at that origin — is the publisher's RTMP leg pointed there?\n` +
      `  dev stack: scripts/dev.sh measure · prod: scripts/prod.sh up, then scripts/prod.sh measure`);
}
```

Add the flag: `else if (a === "--skip-preflight") opts.skipPreflight = true;` and `skipPreflight: false` in the defaults. Extend the warm-up failure to name what it watched:

```js
die(`warm-up failed: ${dead}\n  page: ${opts.url}\n  hls:  ${hlsUrl}\n` +
  `  (preflight passed, so the origin is up — is the stream flowing? scripts/dev.sh status / scripts/prod.sh status)`);
```

- [ ] **Step 3: Verify**

Run: `bash tests/test-measure.sh && node --check tools/measure/measure.mjs`
Expected: PASS (self-test still green, preflight assertions green).

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: measurement preflight + warm-up diagnostics"`

---

### Task 2: /results legibility — what each element shows

**Files:**
- Modify: `site/results/index.html`, `tests/test-results-page.sh`

**Interfaces:**
- Produces: elements `#how-to-read` (static intro), `#latest-run-label` (JS-filled `Latest run — <date> · <source> · <machine>`), `#map-title` (JS-filled `Where the <date> run ran`, suffixed ` (latest run with geo)` when that run is not the latest run overall).

- [ ] **Step 1: Write the failing test** — append to `tests/test-results-page.sh` (before `exit 0`):

```bash
grep -q 'id="how-to-read"' $f       || { echo "how-to-read intro missing"; exit 1; }
grep -q 'id="latest-run-label"' $f  || { echo "latest-run label missing"; exit 1; }
grep -q 'id="map-title"' $f         || { echo "dynamic map title missing"; exit 1; }
grep -qi 'latest run only' $f       || { echo "tile scope wording missing"; exit 1; }
```

Run: `bash tests/test-results-page.sh` — Expected: FAIL on `how-to-read`.

- [ ] **Step 2: Implement.** In `site/results/index.html`:
  - Under `<header>`'s existing `<p>`, add:
    ```html
    <p id="how-to-read">How to read this page: each <em>run</em> is one invocation of
    <code>scripts/measure-latency.sh</code> on the publisher machine, reviewed and committed by a
    human. The tiles summarize the <strong>latest run only</strong>; the chart and table show
    <strong>every committed run</strong>; the map shows the single run named in its title.</p>
    ```
  - Above `<div class="tiles"...>`, add `<h2 id="latest-run-label" hidden></h2>`; in the `fetch` handler set it:
    ```js
    const latest = runs[runs.length - 1];
    const lbl = document.getElementById("latest-run-label");
    lbl.textContent = `Latest run — ${latest.started_utc.slice(0, 10)} · ${latest.source} · ${latest.machine ?? "?"}`;
    lbl.hidden = false;
    ```
  - Change the map section's `<h2>` to `<h2 id="map-title">Where the last run ran</h2>` and in `drawMap(run)` set:
    ```js
    document.getElementById("map-title").textContent =
      `Where the ${run.started_utc.slice(0, 10)} run ran` +
      (run === latestRun ? "" : " (latest run with geo)");
    ```
    passing `latestRun = runs[runs.length - 1]` in from the fetch handler (`drawMap(geoRun, runs[runs.length - 1])`).
  - Above the runs `<table>`, add a one-line `<p class="sub">` : "Every committed run; p50/min/max are that run's clock-ocr samples. <code>hlsjs-api</code> rows are player-reported latency, shown for cross-checking."

- [ ] **Step 3: Verify**

Run: `bash tests/test-results-page.sh && bash tests/test-site.sh`
Expected: both PASS.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: results page explains tiles/chart/table/map scope"`

---

### Task 3: endpoint-map subcommands in dev.sh / prod.sh

**Files:**
- Modify: `scripts/dev.sh`, `scripts/prod.sh`, `tests/test-endpoint-map.sh`

**Interfaces:**
- Produces: `scripts/dev.sh map` (live map of the dev stack: real relay, localhost HLS/page shown as location-unknown), `scripts/prod.sh map` (live map of prod), and `scripts/prod.sh measure` printing the just-recorded run's `--from-run` map after a successful measurement (best-effort).

- [ ] **Step 1: Write the failing test** — append to `tests/test-endpoint-map.sh` (before `exit 0`):

```bash
scripts/dev.sh help | grep -q 'map'  || { echo "dev.sh map missing from help"; exit 1; }
scripts/prod.sh help | grep -q 'map' || { echo "prod.sh map missing from help"; exit 1; }
grep -q 'from-run' scripts/prod.sh   || { echo "prod.sh measure does not print the from-run map"; exit 1; }
```

Run: `bash tests/test-endpoint-map.sh` — Expected: FAIL on dev.sh help.

- [ ] **Step 2: Implement.**
  - `scripts/dev.sh`: add subcommand + help line + case arm:
    ```bash
    map() {
      # Live map of THIS stack: relay is real; HLS/page are localhost (location unknown by design).
      python3 scripts/endpoint_map.py --hls localhost --page localhost "$@"
    }
    ```
  - `scripts/prod.sh`: add `map() { python3 scripts/endpoint_map.py "$@"; }` + help + case arm, and at the end of `measure()`:
    ```bash
    scripts/measure-latency.sh --url "$PAGE_URL" --source capture "$@" \
      && python3 scripts/endpoint_map.py --from-run || true
    ```

- [ ] **Step 3: Verify**

Run: `bash tests/test-endpoint-map.sh && bash -n scripts/dev.sh && bash -n scripts/prod.sh`
Expected: PASS, both syntax-clean.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: map subcommands for dev/prod stacks"`

---

### Task 4: Live-geo verification (e2e, network + Docker)

**Files:**
- Create: `tests/test-geo-live.sh`

**Interfaces:**
- Consumes: `scripts/measure-latency.sh --out <file>` (file must pre-exist with `{"schema":1,"runs":[]}`), `scripts/endpoint_map.py --from-run --data <file>`.
- Produces: proof that a real measurement records coarse geo (publisher + relay non-null) and that the from-run map renders from it. Uses a scratch out-file — **never** `site/results/data.json`.

- [ ] **Step 1: Write the test** — `tests/test-geo-live.sh` (needs `$MOQ_RELAY_URL`, Docker, network; self-skips otherwise like `test-roundtrip.sh` does):

```bash
#!/usr/bin/env bash
# e2e: dev stack up → one short measurement to a SCRATCH file → geo recorded → map renders.
set -u
cd "$(dirname "$0")/.."
[[ -n "${MOQ_RELAY_URL:-}" ]] || { echo "SKIP: MOQ_RELAY_URL not set"; exit 0; }
command -v docker >/dev/null && command -v node >/dev/null && command -v tesseract >/dev/null \
  || { echo "SKIP: docker/node/tesseract missing"; exit 0; }
OUT=logs/test-geo-live.json
echo '{"schema":1,"runs":[]}' > "$OUT"
scripts/dev.sh up test >/dev/null || exit 1
trap 'scripts/dev.sh down >/dev/null' EXIT
sleep 10
scripts/measure-latency.sh \
  --url 'http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8' \
  --samples 3 --interval-ms 3000 --out "$OUT" --notes "geo e2e" || exit 1
python3 - "$OUT" <<'PY' || exit 1
import json, sys
r = json.load(open(sys.argv[1]))["runs"][-1]
g = r.get("geo") or {}
assert g.get("publisher"), "publisher geo missing"
assert g.get("relay"), "relay geo missing"
assert not g.get("hls") and not g.get("page"), "localhost endpoints must record null geo"
for v in (g["publisher"], g["relay"]):
    assert set(v) <= {"city","region","country","lat","lon"}
print("geo ok:", g["publisher"].get("city"), "/", g["relay"].get("city"))
PY
python3 scripts/endpoint_map.py --from-run --data "$OUT" | grep -q '┌' || { echo "from-run map failed"; exit 1; }
exit 0
```

- [ ] **Step 2: Run it for real**

Run: `bash tests/test-geo-live.sh`
Expected: `geo ok: <city> / <city>` and exit 0; dev stack torn down by the trap. If Chrome renders nothing headless, retry once via `--headed` before recording a blocker.

- [ ] **Step 3: Full suite + commit**

Run: `bash tests/run.sh` (dev stack must be DOWN first — its cleanup tears the stack down)
Expected: no previously-passing test broken (`test-geo-live.sh` may print SKIP without env).
Commit: `git add -A && git commit -m "test: live-geo e2e against the dev stack"`

---

### Task 5: MoQ auth — repo-side tests + docs (verification gated on HUMAN.md §6)

**Files:**
- Create: `tests/test-auth.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ralph/HUMAN.md` §6 (key generation, relay config, minted tokens, flipped endpoints — all human).
- Produces: `tests/test-auth.sh` that self-skips until auth is live (no `?jwt=` in `$MOQ_RELAY_URL`), then verifies: token-bearing publish stays up 5 s; token-stripped publish is rejected. Never prints or stores the URL/token.

- [ ] **Step 1: Write the test** — `tests/test-auth.sh`:

```bash
#!/usr/bin/env bash
# MoQ publish auth verification. Skips until HUMAN.md §6 is done (jwt in env).
# Never echoes $MOQ_RELAY_URL — it carries a token once auth is enabled.
set -u
cd "$(dirname "$0")/.."
[[ -n "${MOQ_RELAY_URL:-}" ]] || { echo "SKIP: MOQ_RELAY_URL not set"; exit 0; }
case "$MOQ_RELAY_URL" in
  *jwt=*) ;;
  *) echo "SKIP: no ?jwt= in MOQ_RELAY_URL (auth not enabled — see ralph/HUMAN.md §6)"; exit 0;;
esac
command -v moq >/dev/null || { echo "SKIP: moq not on PATH"; exit 0; }
B=laserdisc-auth-test.hang
SOURCE=test HLS=0 BROADCAST=$B timeout 5 scripts/publish.sh >/dev/null 2>&1
rc=$?
[[ $rc -eq 124 || $rc -eq 143 ]] || { echo "FAIL: authorized publish died early (rc=$rc)"; exit 1; }
NOJWT="${MOQ_RELAY_URL%%\?*}"
MOQ_RELAY_URL="$NOJWT" SOURCE=test HLS=0 BROADCAST=$B timeout 5 scripts/publish.sh >/dev/null 2>&1
rc=$?
[[ $rc -ne 124 && $rc -ne 143 ]] || { echo "FAIL: tokenless publish was NOT rejected"; exit 1; }
echo "auth ok: token publishes, no-token rejected"
exit 0
```

- [ ] **Step 2: Verify the skip path (auth not yet enabled)**

Run: `bash tests/test-auth.sh`
Expected: `SKIP: no ?jwt= ...` (or `SKIP: MOQ_RELAY_URL not set`), exit 0; `bash tests/run.sh` still green.

- [ ] **Step 3: README** — in the Run section, extend the existing token paragraph: name `tests/test-auth.sh` as the check that auth is correctly enabled, and point at `ralph/HUMAN.md` §6 as the enablement runbook. Add the test to the Tests section (self-skipping).

Run: `bash tests/test-results-page.sh && grep -q 'test-auth' README.md`
Expected: PASS.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "test: MoQ auth verification, self-skipping until enabled"`

- [ ] **Step 5: Real verification** — *gated: HUMAN.md §6.* After the human completes §6 (key on relay, tokens minted, endpoints flipped), run `bash tests/test-auth.sh` with the publisher token in `$MOQ_RELAY_URL`.
Expected: `auth ok: token publishes, no-token rejected`. Also confirm the pipecat demo on `anon/` still works (human, §6 gate).

---

## Verification (whole plan)

1. `bash tests/run.sh` — all green (network tests need `$MOQ_RELAY_URL`; e2e/auth self-skip without their prerequisites).
2. `scripts/dev.sh up && scripts/dev.sh measure && scripts/dev.sh map && scripts/dev.sh down` — the trap from 2026-09-16 (prod page + dev origin) is now impossible to hit silently.
3. Human path: complete HUMAN.md §6 → `bash tests/test-auth.sh` prints `auth ok`.
