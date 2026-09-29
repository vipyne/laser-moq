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
| 4 | Live-geo verification (e2e) | done | sonnet |
| 5 | MoQ auth repo-side + gated verification | gated: HUMAN.md §6 | haiku |
| 6 | LL-HLS tuning: parts/segments/GOP | done | sonnet |
| 7 | Viewer page: Mode A/B HLS presets + receipt in UI | done | sonnet |
| 8 | Measure harness: per-run tuning receipts (incl. preset) | done | sonnet |
| 9 | Results page: display tuning receipts | done | sonnet |
| 10 | Measure Mode A + Mode B runs + full suite (also clears Task 4) | done | sonnet |
| 11 | Prod HLS: single CORS header (fixes §5 manifestLoadError) | gated: HUMAN.md §9 | sonnet |
| 12 | MoQ jitter buffer: latency attr + receipt (fixes §5 choppy MoQ) | gated: HUMAN.md §10 | sonnet |
| 13 | Relay outage after §6 auth restart: diagnosed, recovery runbook | gated: HUMAN.md §11 | sonnet |

_Updated: 2026-09-20, iteration 15 (Answered the fresh 2026-09-20 §11 note: the human found `moq-root.jwk` is `-rw------- ubuntu:ubuntu` on the relay box and asked how to chown it to root. Loop reply in §11 corrects the framing — the blocker is the 600 **mode**, not the owner (a root-running container would read it regardless; the failure proves a non-root uid, so chown-root alone with mode 600 fixes nothing) — with the exact commands: match the working certs (`chown root:root` + `chmod 644`, restart), or the tighter container-uid + 400 variant. Statuses unchanged; all remaining work gated. Prior context: iteration 14 root-caused the relay outage (down since the 19:35Z §6 auth restart; TCP 443 refused). Gates: Task 5 Step 4 →§6, Task 11 Step 5 →§9, Task 12 Step 5 →§10, Task 13 Step 3 →§11.)_


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

- [x] **Step 1: Write the failing test** — append to `tests/test-endpoint-map.sh` before `exit 0`:

```bash
scripts/dev.sh help | grep -q 'map'  || { echo "dev.sh map missing from help"; exit 1; }
scripts/prod.sh help | grep -q 'map' || { echo "prod.sh map missing from help"; exit 1; }
grep -q 'from-run' scripts/prod.sh   || { echo "prod.sh measure does not print the from-run map"; exit 1; }
```

Run: `bash tests/test-endpoint-map.sh`
Expected: FAIL on dev.sh help.

- [x] **Step 2: Implement.** In `scripts/dev.sh` add (plus a help line and a `map) shift; map "$@";;` case arm):

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

- [x] **Step 3: Commit**

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

- [x] **Step 1: Create `tests/test-geo-live.sh`** (self-skips without env/tools, like `test-roundtrip.sh`):

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

- [x] **Step 2: Full suite** (dev stack must be DOWN first)

Run: `bash tests/run.sh`
Expected: nothing previously green is broken; `test-geo-live.sh` prints SKIP when env/tools are absent.

- [x] **Step 3: Commit**

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

- [x] **Step 1: Create `tests/test-auth.sh`:**

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

- [x] **Step 2: README** — in the Run section's token paragraph, name `tests/test-auth.sh` as the check that auth is correctly enabled and point at `ralph/HUMAN.md` §6 as the enablement runbook; list the test (self-skipping) in the Tests section.

Run: `grep -q 'test-auth' README.md && bash tests/run.sh`
Expected: grep passes; suite green (auth test SKIPs).

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "test: MoQ auth verification, self-skipping until enabled"
```

- [ ] **Step 4: Real verification** — gated: HUMAN.md §6
After the human completes §6, they run `bash tests/test-auth.sh` with the publisher token in `$MOQ_RELAY_URL` and tick §6's gates. Expected: `auth ok: token publishes, no-token rejected`, and the pipecat demo on `anon/` still works.

---

### Task 6: LL-HLS tuning — smaller parts, shorter segments, matched GOP

**Why:** committed runs show HLS clock-ocr p50 1712–1862 ms vs MoQ 655–672 ms on near-default LL-HLS tuning. The LL-HLS latency floor ≈ ~3× part duration; segments can't be shorter than the keyframe interval, so GOP must shrink with them (today `-g 30` = 1 s keyframes at the test source's 30 fps, silently defeating 500 ms segments).

**Files:**
- Modify: `hls-origin/mediamtx.yml`, `scripts/publish.sh`, `tests/test-hls.sh`

**Interfaces:**
- Produces: `hlsPartDuration: 100ms`, `hlsSegmentDuration: 500ms` (segmentCount stays 7); `publish.sh` gains `GOP` env var defaulting to a 0.5 s keyframe interval for BOTH sources: `GOP="${GOP:-$(( ${FPS%%.*} / 2 ))}"` (test 30→15, capture 60→30; integer-truncates `60.000240`), encoder line uses `-g "$GOP"`.

- [x] **Step 1: Write the failing test** — in `tests/test-hls.sh`, directly after the existing `grep -q '#EXT-X-PART'` assertion, add:

```bash
grep -q 'PART-TARGET=0.1' "$OUT/media.m3u8" || { echo "part target is not 100ms"; head -5 "$OUT/media.m3u8"; exit 1; }
```

Run: `bash tests/test-hls.sh` (Docker + network; dev stack must be down)
Expected: FAIL on `part target is not 100ms` (today PART-TARGET is 0.2).

- [x] **Step 2: Implement** — `hls-origin/mediamtx.yml`: `hlsPartDuration: 200ms` → `100ms`, `hlsSegmentDuration: 1s` → `500ms`, with a one-line comment (latency floor ≈ 3× part). `scripts/publish.sh`: add `GOP` default beside the SIZE/FPS block and change `-g 30` → `-g "$GOP"`; update the "verified encode line" comment to say GOP is FPS-coupled and re-verified by this task.

Run: `bash -n scripts/publish.sh && bash tests/test-hls.sh`
Expected: PASS (`LL-HLS ok`, `anonymous publish rejected`, publisher survives origin loss).

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: LL-HLS 100ms parts, 500ms segments, FPS-coupled GOP"
```

---

### Task 7: Viewer page — Mode A/B HLS presets, toggle in the UI, live receipt

**Why:** the demo needs both stories on one page: **Mode A "typical"** (HLS as commonly deployed — clearly loses to MoQ) and **Mode B "ragged"** (HLS's genuine best shot at MoQ's ~0.65 s: near-zero jitter buffer; a network hiccup visibly stalls the pane, which is part of the point). Same stream, same origin — the only difference is the client buffer policy, and the page says so.

**Files:**
- Modify: `site/index.html`, `tests/test-site.sh`

**Interfaces:**
- Produces: a `PRESETS` const with exactly two entries feeding `new Hls({...})`:
  - `typical` (Mode A): `{ lowLatencyMode: true, liveSyncDuration: 1.5, liveMaxLatencyDuration: 3, backBufferLength: 10 }`
  - `ragged` (Mode B): `{ lowLatencyMode: true, liveSyncDuration: 0.3, liveMaxLatencyDuration: 1, maxLiveSyncPlaybackRate: 1.15, backBufferLength: 10 }`
- A visible toggle in the HLS pane header (`id="hls-preset"`, two buttons or a segmented control labeled `typical` / `ragged`); switching destroys the current Hls instance and recreates it with the other preset — no page reload. Initial preset from `?hlspreset=` (default `typical`).
- `window.__hls` is reassigned on every recreate; `window.__hlspreset` always holds the active preset name (harness reads both).
- `#status-hls` shows the live receipt, e.g. `hls.js typical · sync 1.5s · part 100ms` / `hls.js ragged · sync 0.3s · ≤1.15x · part 100ms` — part target read off the wire from hls.js level details (`partTarget`), omitted gracefully when unavailable. Keep the literal `lowLatencyMode` in the file (test-site pins it).
- A `// TODO(sneaky)` comment documents the beyond-ragged stunt not implemented: `maxLiveSyncPlaybackRate: 1.25` (chipmunk catch-up).

- [x] **Step 1: Write the failing test** — append to `tests/test-site.sh` before the CNAME check:

```bash
grep -q 'maxLiveSyncPlaybackRate' $f                              || { echo "hls.js catch-up rate missing"; exit 1; }
grep -q "liveSyncDuration: 0.3" $f                                || { echo "ragged preset missing"; exit 1; }
grep -q "liveSyncDuration: 1.5" $f                                || { echo "typical preset missing"; exit 1; }
grep -q 'hlspreset' $f                                            || { echo "preset param/toggle missing"; exit 1; }
grep -q 'id="hls-preset"' $f                                      || { echo "preset toggle UI missing"; exit 1; }
grep -q 'TODO(sneaky)' $f                                         || { echo "sneaky-mode TODO note missing"; exit 1; }
```

Run: `bash tests/test-site.sh`
Expected: FAIL on `hls.js catch-up rate missing`.

- [x] **Step 2: Implement** in `site/index.html`: `PRESETS` const + `TODO(sneaky)` comment; factor HLS setup into `startHls(presetName)` (destroys any prior instance via `hls.destroy()`, creates `new Hls(PRESETS[presetName])`, reattaches, sets `window.__hls` and `window.__hlspreset`, updates the receipt on MANIFEST_PARSED/LEVEL_UPDATED); toggle buttons call it and reflect the active preset; initial call uses `q.get("hlspreset") ?? "typical"` (unknown values fall back to `typical`). The timecode strip and clocks need no changes (they read the `<video>` element, which persists).

Run: `bash tests/test-site.sh` and syntax-check the module script (extract `<script type="module">` body to a temp `.mjs`, `node --check` it).
Expected: both green.

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: Mode A/B HLS presets with UI toggle + live tuning receipt"
```

---

### Task 8: Measure harness — per-run tuning receipts

**Files:**
- Modify: `tools/measure/measure.mjs`, `tests/test-measure.sh`

**Interfaces:**
- Produces: each appended run carries a top-level `tuning` object harvested in-page after warm-up (never hand-typed): `preset` from `window.__hlspreset` (string or null); from `window.__hls.config` → `live_sync_s`, `max_latency_s`, `max_catchup_rate`, `low_latency`; from the current level's details → `part_target_s`, `target_duration_s`. All values nullable; the field is `null` when nothing could be read (e.g. native-Safari path). Run shape otherwise unchanged: `{started_utc, target, source, machine, notes, samples, geo, tuning}`.
- Constraint (enforced by `tests/test-measure.sh`): no new per-SAMPLE `method` strings; no key or quoted string containing `"ip"`, `"hostname"`, `"host"` — the chosen key names avoid all three.

- [x] **Step 1: Write the failing test** — in `tests/test-measure.sh`, extend the embedded Python schema check: for each run, `t = r.get("tuning")` must be `None` or a dict whose keys ⊆ `{"preset","live_sync_s","max_latency_s","max_catchup_rate","low_latency","part_target_s","target_duration_s"}`; then add after the schema check:

```bash
grep -q '"tuning"' tools/measure/measure.mjs || { echo "harness does not record tuning receipts"; exit 1; }
```

Run: `bash tests/test-measure.sh`
Expected: FAIL on `harness does not record tuning receipts` (existing runs without `tuning` must still pass the schema part).

- [x] **Step 2: Implement** in `tools/measure/measure.mjs`, after warm-up (near the moq-stats probe):

```js
const tuning = await page.evaluate(() => {
  const h = window.__hls;
  if (!h) return null;
  const cfg = h.config ?? {};
  const det = h.levels?.[h.currentLevel]?.details ?? h.levels?.[0]?.details ?? {};
  const num = v => (typeof v === "number" && Number.isFinite(v) ? v : null);
  return {
    preset: typeof window.__hlspreset === "string" ? window.__hlspreset : null,
    live_sync_s: num(cfg.liveSyncDuration),
    max_latency_s: num(cfg.liveMaxLatencyDuration),
    max_catchup_rate: num(cfg.maxLiveSyncPlaybackRate),
    low_latency: cfg.lowLatencyMode === true,
    part_target_s: num(det.partTarget),
    target_duration_s: num(det.targetduration),
  };
});
```

and add `tuning` to the pushed run object.

Run: `bash tests/test-measure.sh && node --check tools/measure/measure.mjs`
Expected: PASS (self-test still green).

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: measurement runs record hls tuning receipts"
```

---

### Task 9: Results page — display tuning receipts

**Files:**
- Modify: `site/results/index.html`, `tests/test-results-page.sh`

**Interfaces:**
- Produces: a `tuningLabel(run)` helper (`ragged · part 100ms · sync 0.3s · ≤1.15x` — preset name first when present, then values from `run.tuning`; empty string when absent); appended to `#hls-sub` on the latest-run tile; a `title` tooltip on each hls table row and the preset name visible in the table's notes-adjacent hls rows; one Caveats sentence saying tuning is recorded per run by the harness and naming the Mode A/B presets. Runs without `tuning` (the three committed untuned runs) render exactly as before — they are the visible "before".

- [x] **Step 1: Write the failing test** — append to `tests/test-results-page.sh` before `exit 0`:

```bash
grep -q 'tuningLabel' $f || { echo "tuning receipt display missing"; exit 1; }
grep -qi 'tuning' $f     || { echo "caveats do not mention tuning"; exit 1; }
```

Run: `bash tests/test-results-page.sh`
Expected: FAIL on `tuning receipt display missing`.

- [x] **Step 2: Implement** in `site/results/index.html` (stays library-free). `tuningLabel(run)` formats from `run.tuning` (`part_target_s`→ms, `live_sync_s`, `max_catchup_rate`); use it in `tiles()` and in `table()`'s hls rows as `title="..."`.

Run: `bash tests/test-results-page.sh`
Expected: PASS.

- [x] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: results page shows per-run hls tuning receipts"
```

---

### Task 10: Measure Mode A + Mode B + full suite (also clears Task 4)

**Files:**
- Modify: `site/results/data.json` (two appended runs — the human reviews before push), `ralph/PROGRESS.md`

**Interfaces:**
- Consumes: `scripts/dev.sh up|down|status`, `scripts/measure-latency.sh`, `$MOQ_RELAY_URL` in env.
- Produces: two local runs in `data.json` — Mode A (`?hlspreset=typical`) then Mode B (`?hlspreset=ragged`, deliberately last so it headlines the tiles) — each with `tuning` receipts recording its preset. Expected: A's HLS p50 stays non-trivially above MoQ (~1.5 s vs ~0.65 s); B's HLS p50 lands in MoQ's neighborhood (~0.5–0.8 s) — record honestly whichever side wins. Plus a green full suite from a stack-down state (which is exactly Task 4's deferred Step 2 — tick it and set Task 4's Status accordingly).

- [x] **Step 1: Full suite from clean state** — ensure the dev stack is DOWN (`scripts/dev.sh down`), then:

Run: `bash tests/run.sh`
Expected: all PASS/SKIP, nothing red. This satisfies Task 4 Step 2 (and Task 5 Step 2's deferred suite run): tick those boxes and update the Status table rows (Task 4 → done if `test-geo-live.sh` ran or SKIPped cleanly per its own rules).

- [x] **Step 2: Measure both modes** — requires `$MOQ_RELAY_URL`; skip to Step 4 with a Blockers note if it is unset. Mode A first, Mode B last (last run headlines the tiles).

```bash
scripts/dev.sh up test
sleep 10
scripts/measure-latency.sh \
  --url 'http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8&hlspreset=typical' \
  --source test --notes "Mode A typical: tuned origin, sync 1.5s"
scripts/measure-latency.sh \
  --url 'http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8&hlspreset=ragged' \
  --source test --notes "Mode B ragged: sync 0.3s rate 1.15"
scripts/dev.sh down
```

Verify with python3 on the last two runs: `tuning.preset` == `typical` / `ragged` respectively, both have `tuning.part_target_s` ≈ 0.1, and ragged's hls clock-ocr p50 < typical's. Record both p50s (and MoQ's) in PROGRESS — including which transport won Mode B; do NOT massage the numbers.

- [x] **Step 3: PROGRESS entry** — dated: what changed (parts/segments/GOP, presets), Mode A / Mode B / MoQ p50s, who won Mode B, the TODO(sneaky) pointer, and that data.json ordering is the human's call (see HUMAN.md §8).

- [x] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: Mode A/B LL-HLS measurement runs with receipts"
```

---

### Task 11: Prod HLS — single CORS header (HUMAN.md §5 note, 2026-09-17)

**Why:** the human's 2026-09-17 note under §5: prod page shows "HLS offline:
manifestLoadError" (no HLS at all) while MoQ plays (choppy). Root cause found
2026-09-17: `hls-origin/Caddyfile` adds `header Access-Control-Allow-Origin *`
on top of MediaMTX's own ACAO header (`hlsAllowOrigins: ['*']` in mediamtx.yml),
so the prod origin serves the header **twice** (verified live:
`curl -sI https://<hls-host>/laserdisc/index.m3u8` shows two
`access-control-allow-origin: *` lines). The CORS spec forbids multiple values —
browsers reject the response outright, which is exactly hls.js
`manifestLoadError`. curl ignores duplicates, so §2's curl gate passed; the §4
browser checks hit local MediaMTX directly on :8888 (no Caddy → single header),
so prod HLS in a real browser was never actually exercised. Caddy's
`Cache-Control "no-cache"` line is likewise redundant (MediaMTX sends
`Cache-Control: private, no-cache` itself — verified against local MediaMTX
1.20.1) though harmless; both lines go. Choppy MoQ is not reproducible
repo-side (the deployed page predates the tuning/preset commits; re-observe
after redeploy + push).

**Files:**
- Create: `tests/test-caddyfile.sh`
- Modify: `hls-origin/Caddyfile`, `docs/deploy-hls-origin.md` (if it inlines the Caddyfile), `ralph/HUMAN.md` (new §9 redeploy runbook + reply under the §5 note)

**Interfaces:**
- Produces: a Caddyfile that only does TLS + compression + reverse_proxy — every HLS response header (CORS, cache) comes from MediaMTX exactly once. Static regression test so the duplicate never comes back.

- [x] **Step 1: Write the failing test** — create `tests/test-caddyfile.sh` (static, no Docker): FAIL if the Caddyfile contains `access-control-allow-origin` (case-insensitive) or `cache-control`; also assert `reverse_proxy mediamtx:8888` is still present.

Run: `bash tests/test-caddyfile.sh`
Expected: FAIL on the ACAO assertion (line 3 of today's Caddyfile).

- [x] **Step 2: Implement** — delete the two `header` lines from `hls-origin/Caddyfile`, leaving a comment explaining MediaMTX sends its own single ACAO + Cache-Control and that Caddy must not add more (browsers reject duplicate ACAO). Mirror the change in `docs/deploy-hls-origin.md` if the Caddyfile is inlined there.

Run: `bash tests/test-caddyfile.sh && docker run --rm -v "$PWD/hls-origin/Caddyfile:/etc/caddy/Caddyfile:ro" -e HLS_DOMAIN=example.test caddy:2 caddy validate --config /etc/caddy/Caddyfile`
Expected: test PASSes; caddy reports the config is valid.

- [x] **Step 3: Full suite from a stack-down state** (`scripts/dev.sh status` all DOWN first)

Run: `bash tests/run.sh`
Expected: all PASS/SKIP, nothing red (new test included in the glob).

- [x] **Step 4: Commit**

```bash
git add -A && git commit -m "fix: drop Caddy CORS/cache headers duplicating MediaMTX's (prod HLS manifestLoadError)"
```

- [ ] **Step 5: Redeploy + re-check** — gated: HUMAN.md §9
Human copies the new Caddyfile to the HLS VM, recreates the caddy container, verifies `curl -sI https://<hls-host>/laserdisc/index.m3u8` shows exactly ONE `access-control-allow-origin` line, then re-tests the prod page in a browser with a publisher up (and re-observes MoQ choppiness after pushing the pending commits).

---

### Task 12: MoQ jitter buffer — latency attribute + receipt (HUMAN.md §5 note, 2026-09-18)

**Why:** the human's 2026-09-18 note under §5: prod HLS now plays (the §9
Caddyfile redeploy worked) but MoQ is still choppy — second report (first
2026-09-17). Root cause (verified in the @moq/watch@0.5.2 bundle, 2026-09-18):
the `<moq-watch>` element's `latency` control defaults to `"real-time"` — a
ZERO jitter buffer; frames render the instant they arrive, so any late frame
is a visible stutter — and `site/index.html` never sets the attribute. HLS
looks smooth on the same network because hls.js buffers ≥1.5 s (typical).
Local measurement runs were smooth because that machine's path to the relay
had negligible jitter; the human's prod viewing doesn't. The element observes
a `latency` attribute (milliseconds via `Number.parseFloat`, or the literal
`real-time`; garbage falls back to 100 ms) plus `latency-min`/`latency-max`.
Pushing the pending commits alone cannot fix this — none touch the MoQ pane.

**Files:**
- Modify: `site/index.html`, `tests/test-site.sh`, `ralph/HUMAN.md` (reply under the §5 note + new §10 re-check gate)

**Interfaces:**
- Produces: the page sets `latency` on `<moq-watch>` — default **150 ms**
  (smooths real-network jitter; keeps MoQ ~0.8 s glass-to-glass, still well
  under Mode A HLS ~2.2 s and under Mode B ~1.06 s), overridable via
  `?moqlatency=<ms>` or `?moqlatency=real-time` (the old behavior, for A/B
  eyeballing). `#status-moq` shows a receipt (`… · buffer 150ms` /
  `… · real-time`); `window.__moqlatency` holds the active value (future
  harness hook — the measure schema's `tuning` keys stay HLS-only for now).

- [x] **Step 1: Write the failing test** — append to `tests/test-site.sh` before `exit 0`:

```bash
grep -q 'moqlatency' $f                                           || { echo "moq latency param missing"; exit 1; }
grep -q 'setAttribute("latency"' $f                               || { echo "moq jitter buffer never set"; exit 1; }
grep -q '__moqlatency' $f                                         || { echo "moq latency harness hook missing"; exit 1; }
```

Run: `bash tests/test-site.sh`
Expected: FAIL on `moq latency param missing`.

- [x] **Step 2: Implement** in `site/index.html`'s MoQ section: read
`q.get("moqlatency") ?? "150"`, set the `latency` attribute alongside
`url`/`name`, set `window.__moqlatency`, and append the buffer receipt to the
`#status-moq` transport line. Comment explains the element's `real-time`
default and why a buffer is needed on real networks.

Run: `bash tests/test-site.sh` and node-check the module script (extract `<script type="module">` body to a temp `.mjs`, `node --check`).
Expected: both green.

- [x] **Step 3: HUMAN.md** — dated loop reply under the §5 2026-09-18 note
(root cause + what changed) and a new **§10** re-check gate: push, hard-reload
the prod page, expect smooth MoQ with `· buffer 150ms` in the status line;
compare `?moqlatency=real-time` to confirm the cause; note the browser used
and leave a dated note if still choppy.

- [x] **Step 4: Commit**

```bash
git add -A && git commit -m "fix: 150ms MoQ jitter buffer + receipt (prod choppy MoQ)"
```

- [ ] **Step 5: Prod re-check** — gated: HUMAN.md §10

---

### Task 13: Relay outage after the §6 auth restart (HUMAN.md §6 note, 2026-09-20)

**Why:** the human's 2026-09-20 note under §6: `SOURCE=test HLS=0
scripts/publish.sh` fails with `WebSocket connection failed`, on both the
`/livestream?jwt=…` URL **and** `/anon`. Root-caused 2026-09-20 (repo-side
evidence only; no infra touched): **the relay is not listening at all.**
- `logs/publish-20260920-140522.log`: 19:05:22Z connect to `/anon` succeeded
  over QUIC (`connected version=moq-lite-04`), streamed ~30 min with live
  subscribers; 19:35:39Z the session dropped from the RELAY side
  (`web_transport_quinn: failed to read capsule e=UnexpectedEnd`) — the moment
  of the §6 relay restart; the reconnect then timed out (QUIC) with the WS
  fallback failing alongside.
- `logs/dev-publish.log` (20:01Z, `/livestream?jwt=…`): initial connect never
  succeeds — same QUIC timeout + WS-fallback WARNs. So it is not the token.
- Client probes from this machine (curl/python sockets, status codes only):
  DNS resolves; TCP 443 → **connection refused** (host up, no listener).
- The `WebSocket connection failed` WARN lines the human quoted are the
  fallback failing after the primary QUIC path also failed — a red herring.

Most likely cause: the relay container didn't come back up after the §6
config change (`[auth] key = …`) — e.g. the jwk path in the TOML is the host
path rather than the in-container mount path, or a TOML error. That is
relay-box work the loop must not touch; runbook written to HUMAN.md §11.
Side effect worth knowing: the pipecat demo on `anon/` is down too.

**Files:**
- Modify: `ralph/HUMAN.md` (reply under the §6 note + new §11 recovery runbook)

- [x] **Step 1: Diagnose repo-side** — logs + client-only probes (never ssh/infra;
      never echo the relay URL). Done 2026-09-20; evidence above.
- [x] **Step 2: HUMAN.md** — dated loop reply under the §6 2026-09-20 note
      (what the logs show, why it's not the token, WS warns are noise) + new
      **§11** runbook: check/fix the relay container on its box, or roll back
      the `key =` line to restore both demos, then re-gate.
- [ ] **Step 3: Verify after recovery** — gated: HUMAN.md §11
      After the human restores the relay: `SOURCE=test HLS=0 scripts/publish.sh`
      logs `connected version=moq-lite-04` within a few seconds, then the §6
      gates (`bash tests/test-auth.sh` with the publisher-token URL) proceed.
