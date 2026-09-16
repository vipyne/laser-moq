# MoQ Auth + Results Workflow (v2) Implementation Plan

> **For agentic workers:** Executed by a ralph loop (`ralph/ralph.sh` +
> `ralph/PROMPT.md`), one task per iteration. Tick checkboxes in this file as you
> go; keep the Status table below current every iteration.

## Status
<!-- The loop refreshes this table and the Updated line EVERY iteration. -->
| # | Task | Status | Model |
|---|------|--------|-------|
| 1 | Measurement preflight + warm-up diagnostics | done | sonnet |
| 2 | /results legibility | done | sonnet |
| 3 | endpoint-map subcommands in dev/prod | done | haiku |
| 4 | Live-geo verification (e2e) | pending | sonnet |
| 5 | MoQ auth repo-side + gated verification | pending | sonnet |

_Updated: 2026-09-15, iteration 3 (Task 3 done)_

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

### Task 1: Measurement preflight + warm-up diagnostics

**Files:**
- Modify: `tools/measure/measure.mjs`, `tests/test-measure.sh`

**Interfaces:**
- Produces: `measure.mjs` exits 1 with a message containing `preflight` and the probed URL when the page or derived HLS playlist is unreachable/4xx+, *before* `await import("playwright")`. New flag `--skip-preflight`.

- [x] **Step 1: Write the failing test** — append to `tests/test-measure.sh` immediately before its final `exit 0`:

```bash
out=$(node tools/measure/measure.mjs --url "http://127.0.0.1:9/" 2>&1)
[[ $? -ne 0 ]] || { echo "preflight should exit non-zero on unreachable target"; exit 1; }
grep -q "preflight" <<<"$out" || { echo "preflight message missing"; exit 1; }
grep -q "127.0.0.1:9" <<<"$out" || { echo "preflight must name the URL it probed"; exit 1; }
```

Run: `bash tests/test-measure.sh`
Expected: FAIL — today the harness imports playwright and tries to launch Chrome instead.

- [x] **Step 2: Implement preflight** in `tools/measure/measure.mjs`, in the live path BEFORE `await import("playwright")` (and add `skipPreflight: false` to the defaults plus `else if (a === "--skip-preflight") opts.skipPreflight = true;` to the arg loop):

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

Extend the existing warm-up failure `die` to name what it watched:

```js
die(`warm-up failed: ${dead}\n  page: ${opts.url}\n  hls:  ${hlsUrl}\n` +
  `  (preflight passed, so the origin is up — is the stream flowing? scripts/dev.sh status / scripts/prod.sh status)`);
```

Run: `bash tests/test-measure.sh && node --check tools/measure/measure.mjs`
Expected: PASS (OCR self-test still green, preflight assertions green).

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: measurement preflight + warm-up diagnostics"
```

---

### Task 2: /results legibility — what each element shows

**Files:**
- Modify: `site/results/index.html`, `tests/test-results-page.sh`

**Interfaces:**
- Produces: `#how-to-read` (static intro under the header), `#latest-run-label` (JS-filled `Latest run — <date> · <source> · <machine>`), `#map-title` (JS-filled `Where the <date> run ran`, suffixed ` (latest run with geo)` when that run is not the overall latest).

- [x] **Step 1: Write the failing test** — append to `tests/test-results-page.sh` before `exit 0`:

```bash
grep -q 'id="how-to-read"' $f       || { echo "how-to-read intro missing"; exit 1; }
grep -q 'id="latest-run-label"' $f  || { echo "latest-run label missing"; exit 1; }
grep -q 'id="map-title"' $f         || { echo "dynamic map title missing"; exit 1; }
grep -qi 'latest run only' $f       || { echo "tile scope wording missing"; exit 1; }
```

Run: `bash tests/test-results-page.sh`
Expected: FAIL on `how-to-read intro missing`.

- [x] **Step 2: Implement** in `site/results/index.html`:
- Under the header's existing `<p>`, add:

```html
<p id="how-to-read">How to read this page: each <em>run</em> is one invocation of
<code>scripts/measure-latency.sh</code> on the publisher machine, reviewed and committed by a
human. The tiles summarize the <strong>latest run only</strong>; the chart and table show
<strong>every committed run</strong>; the map shows the single run named in its title.</p>
```

- Above `<div class="tiles" ...>`, add `<h2 id="latest-run-label" hidden></h2>` and set it in the fetch handler:

```js
const latest = runs[runs.length - 1];
const lbl = document.getElementById("latest-run-label");
lbl.textContent = `Latest run — ${latest.started_utc.slice(0, 10)} · ${latest.source} · ${latest.machine ?? "?"}`;
lbl.hidden = false;
```

- Change the map section's heading to `<h2 id="map-title">Where the last run ran</h2>`; give `drawMap` a second parameter and call it as `drawMap(geoRun, runs[runs.length - 1])`; inside `drawMap(run, latestRun)` set:

```js
document.getElementById("map-title").textContent =
  `Where the ${run.started_utc.slice(0, 10)} run ran` +
  (run === latestRun ? "" : " (latest run with geo)");
```

- Above the runs `<table>`, add: `<p class="sub">Every committed run; p50/min/max are that run's clock-ocr samples. <code>hlsjs-api</code> rows are player-reported latency, shown for cross-checking.</p>`

Run: `bash tests/test-results-page.sh && bash tests/test-site.sh`
Expected: both PASS.

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: results page explains tiles/chart/table/map scope"
```

---

### Task 3: endpoint-map subcommands in dev.sh / prod.sh

**Files:**
- Modify: `scripts/dev.sh`, `scripts/prod.sh`, `tests/test-endpoint-map.sh`

**Interfaces:**
- Produces: `scripts/dev.sh map` (live map, localhost HLS/page shown location-unknown by design), `scripts/prod.sh map` (live prod map), `scripts/prod.sh measure` printing the just-recorded run's `--from-run` map (best-effort).

- [ ] **Step 1: Write the failing test** — append to `tests/test-endpoint-map.sh` before `exit 0`:

```bash
scripts/dev.sh help | grep -q 'map'  || { echo "dev.sh map missing from help"; exit 1; }
scripts/prod.sh help | grep -q 'map' || { echo "prod.sh map missing from help"; exit 1; }
grep -q 'from-run' scripts/prod.sh   || { echo "prod.sh measure does not print the from-run map"; exit 1; }
```

Run: `bash tests/test-endpoint-map.sh`
Expected: FAIL on dev.sh help.

- [ ] **Step 2: Implement.** In `scripts/dev.sh` add (plus a help line and a `map) shift; map "$@";;` case arm):

```bash
map() {
  # Live map of THIS stack: relay is real; HLS/page are localhost (location unknown by design).
  python3 scripts/endpoint_map.py --hls localhost --page localhost "$@"
}
```

In `scripts/prod.sh` add `map() { python3 scripts/endpoint_map.py "$@"; }` (help line + case arm), and change `measure()`'s body to:

```bash
scripts/measure-latency.sh --url "$PAGE_URL" --source capture "$@" \
  && python3 scripts/endpoint_map.py --from-run || true
```

Run: `bash tests/test-endpoint-map.sh && bash -n scripts/dev.sh && bash -n scripts/prod.sh`
Expected: PASS; both scripts syntax-clean.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: map subcommands for dev/prod stacks"
```

---

### Task 4: Live-geo verification (e2e, network + Docker)

**Files:**
- Create: `tests/test-geo-live.sh`

**Interfaces:**
- Consumes: `scripts/measure-latency.sh --out <file>` (the file must pre-exist with `{"schema":1,"runs":[]}`); `scripts/endpoint_map.py --from-run --data <file>`.
- Produces: proof that a real measurement records coarse geo (publisher + relay non-null; localhost endpoints null) and the from-run map renders. Writes ONLY to a scratch file under `logs/` — never `site/results/data.json`.

- [ ] **Step 1: Create `tests/test-geo-live.sh`** (self-skips without env/tools, like `test-roundtrip.sh`):

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

Run: `bash tests/test-geo-live.sh`
Expected: `geo ok: <city> / <city>`, exit 0, dev stack down afterwards (the trap). If Chrome renders nothing headless, retry the measurement once with `--headed` appended before recording a blocker.

- [ ] **Step 2: Full suite** (dev stack must be DOWN first)

Run: `bash tests/run.sh`
Expected: nothing previously green is broken; `test-geo-live.sh` prints SKIP when env/tools are absent.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: live-geo e2e against the dev stack"
```

---

### Task 5: MoQ auth — repo-side tests + docs (real verification gated)

**Files:**
- Create: `tests/test-auth.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ralph/HUMAN.md` §6 (key, relay config, minted tokens, flipped endpoints — all human).
- Produces: `tests/test-auth.sh` that self-skips until `$MOQ_RELAY_URL` carries `?jwt=`, then verifies token publish stays up and tokenless publish is rejected. It must never echo `$MOQ_RELAY_URL` (it carries a token once auth is on).

- [ ] **Step 1: Create `tests/test-auth.sh`:**

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

Run: `bash tests/test-auth.sh`
Expected: a `SKIP:` line and exit 0 (auth is not enabled yet).

- [ ] **Step 2: README** — in the Run section's token paragraph, name `tests/test-auth.sh` as the check that auth is correctly enabled and point at `ralph/HUMAN.md` §6 as the enablement runbook; list the test (self-skipping) in the Tests section.

Run: `grep -q 'test-auth' README.md && bash tests/run.sh`
Expected: grep passes; suite green (auth test SKIPs).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: MoQ auth verification, self-skipping until enabled"
```

- [ ] **Step 4: Real verification** — gated: HUMAN.md §6
After the human completes §6, they run `bash tests/test-auth.sh` with the publisher token in `$MOQ_RELAY_URL` and tick §6's gates. Expected: `auth ok: token publishes, no-token rejected`, and the pipecat demo on `anon/` still works.
