# /receipts — per-session receipts for the publishing stacks

Approved in chat 2026-09-23. Sessions are delimited by `up`/`down` in
`scripts/prod.sh` and `scripts/dev.sh`. Each session gets a static page under
`/receipts` recording everything knowable about that session: config, versions,
hardware, endpoint probes, the ASCII endpoint map, timeline events, and a log
excerpt. Measurement runs stay in `/results`; session pages reference them by
time window.

## Goals

- One place to answer "what exactly was running, on what hardware, when X
  happened?" — for post-mortems and for the conference-story receipts.
- Zero risk to publishing: receipt collection must never block or break
  `up`/`down`.
- Static-site native: works at `localhost:8000/receipts/` immediately; appears
  on the public page whenever the data files are committed and pushed (human
  does git, per repo convention).

## Non-goals

- Remote viewer hardware. The site is static; nothing phones home. Viewer
  details exist only when the viewer is the measuring machine itself (a
  `measure` run). The schema records this limitation rather than faking it.
- Probing the relay or HLS-origin boxes from inside sessions (infra is
  human-run). Live probes are limited to what the publisher can see from
  outside: RTT, HTTP server headers, version banners. Box specs come from a
  hand-maintained facts file.
- Time-series hardware sampling. Snapshots at `open` and `close` only
  (explicitly chosen over a periodic sampler).

## Data layout (`site/receipts/`)

All files are committed to the repo (not gitignored).

### `data.json` — session index

```json
{
  "schema": 1,
  "sessions": [
    {
      "id": "20260929-031205Z-prod",
      "stack": "prod",
      "source": "test",
      "started_utc": "2026-09-29T03:12:05Z",
      "ended_utc": "2026-09-29T04:02:11Z",
      "end": "clean",
      "machine": "MacBookPro16,1",
      "relay_host": "relay.vanessa-dev.com"
    }
  ]
}
```

- `end`: `"clean"` (via `down`), `"dirty"` (dangling session closed by a later
  `up`; `ended_utc` is then the newest publish-log mtime), or `null` (session
  currently open).
- Newest sessions first. Index rows carry ONLY what the list page renders.

### `sessions/<id>.json` — full receipt

`id` = `YYYYMMDD-HHMMSSZ-<stack>` from `started_utc`. Top-level shape:

```json
{
  "schema": 1,
  "id": "…",
  "stack": "prod",
  "source": "test",
  "started_utc": "…",
  "ended_utc": "…",
  "end": "clean",
  "config": {},
  "versions": {},
  "publisher_hw": { "at_open": {}, "at_close": {} },
  "probes": {},
  "endpoint_map": "ascii text",
  "timeline": [],
  "log_excerpt": [],
  "viewer_note": "remote viewers unknowable; see measure runs in this window"
}
```

Field groups (all best-effort — a failed probe records `null`, never aborts):

- `config`: source, resolved `SIZE`/`FPS`/`GOP`, relay URL host+path (**JWT
  query param stripped — tokens never land in receipts**), RTMP host (no
  credentials), HLS playlist URL, page URL; hls.js / @moq/watch / tesseract.js
  pins grepped from `site/index.html`; MediaMTX tuning keys parsed from
  `hls-origin/mediamtx.yml`.
- `versions`: `moq --version`, `ffmpeg -version` first line, MediaMTX image
  tag from `hls-origin/compose.yml` (dev: `compose.local.yml`), macOS version.
- `publisher_hw.at_open` / `.at_close`: model identifier (`hw.model`), CPU
  brand string, arch, RAM bytes, macOS build, uptime, load averages, thermal
  state (`pmset -g therm`), and at close only: ffmpeg CPU% (sampled before the
  pipeline is killed).
- `probes`: relay and HLS origin — ping avg RTT (3 pings), HTTPS server
  header, HTTP status of the landing/playlist URL. Run at `open`.
- `endpoint_map`: captured stdout of `scripts/endpoint_map.py` (prod flags for
  prod, `--hls localhost --page localhost` for dev).
- `timeline`: events parsed from the session's log files, each
  `{at_utc, event, detail}`: publisher start/restart (`run-forever` `start #N`
  lines), exits (`exited rc=` lines), close reason.
- `log_excerpt`: last ≤40 lines matching warning/error patterns from the
  session's publish log(s), plus the log's first and final line. Strings are
  sanitized with the same JWT-stripping rule as `config`.

### `endpoints.json` — hand-edited facts (human fills; template checked in)

```json
{
  "schema": 1,
  "relay":      { "host": "relay.vanessa-dev.com", "provider": "OCI",
                  "shape": "FILL_ME", "region": "FILL_ME", "software": "moq-relay 0.13.5" },
  "hls_origin": { "host": "hls-laserdisc.vanessa-dev.com", "provider": "FILL_ME",
                  "shape": "FILL_ME", "region": "FILL_ME", "software": "MediaMTX (see compose tag)" }
}
```

Pages merge these into every session view. `FILL_ME` values render as
"not recorded" with a hint pointing at this file. Values live in the
`pcc-transport-latency-bench` repo's deploy notes.

## Collector — `scripts/session_receipt.py`

One Python 3 file, stdlib only, importing `endpoint_map.py` for the map.
Subcommands:

- `open --stack {prod,dev} --source {test,capture}`:
  1. If the index has a session with `end: null` **for the same stack** (dev
     and prod sessions may be open at once): close it as `"dirty"`,
     `ended_utc` = newest `logs/publish-*.log` / `logs/dev-publish.log` mtime
     (fallback: now), timeline event `{event: "dirty-close", detail: "closed by next up"}`.
  2. Write `sessions/<id>.json` with everything collectable at open.
  3. Prepend the summary row to `data.json`.
  4. Print the session id (scripts echo it to the user).
- `close --stack {prod,dev}`:
  1. Find the open session for that stack (no-op with a warning if none).
  2. Fill `ended_utc`, `end: "clean"`, `publisher_hw.at_close`, `timeline`,
     `log_excerpt`; update the index row.

Environment override `RECEIPTS_DIR` (default `site/receipts`) so tests write
to a temp dir. Every collection step is individually try/excepted; a step's
failure records `null` for that field. Exit code is always 0 unless the JSON
files themselves cannot be written.

## Script hooks

- `dev.sh up`: after the publisher starts —
  `python3 scripts/session_receipt.py open --stack dev --source "$src" || true`
- `dev.sh down`: before killing —
  `python3 scripts/session_receipt.py close --stack dev || true`
- `prod.sh up` / `down`: same with `--stack prod --source "$SOURCE"`.
- `down` calls `close` FIRST so the ffmpeg CPU% snapshot can find the process,
  then kills the pipeline as today.
- `status` and everything else: untouched. Receipts never gate publishing.

## Pages (`site/receipts/`)

Same visual language as `site/results/index.html` (dark, monospace accents);
plain JS, no dependencies beyond what `/results` already uses.

- `index.html` — session list, newest first. Columns: start date/time, stack
  badge (prod/dev), source, duration, end state (clean / dirty / **open**),
  machine, link to the session page. Renders from `data.json`.
- `session.html?id=<id>` — fetches `sessions/<id>.json` +
  `endpoints.json` + `../results/data.json`. Sections, in order:
  1. Header: id, stack, source, start→end, end-state.
  2. Config receipt table.
  3. Hardware: publisher (open/close snapshots side by side), relay and
     origin panels (facts file + live probes).
  4. ASCII endpoint map in a `<pre>`.
  5. Measurement runs whose `started_utc` falls inside the session window —
     summary tiles per run in the `/results` style, linking to `/results`.
  6. Timeline events.
  7. Log excerpt in a `<pre>`.
  Unknown id or missing file → "no such session" with a link back.
- Cross-links: main page footer gains a `receipts/` link next to
  `results/`; `/results` header links to `/receipts` and vice versa.

## Failure handling summary

| failure | behavior |
|---|---|
| any collection step fails | field is `null`, session still recorded |
| collector itself explodes | `\|\| true` in scripts; publishing unaffected |
| crash / Ctrl-C (no `down`) | next `up` closes session as `dirty` |
| `close` with no open session | warning to stderr, exit 0 |
| page can't fetch a JSON | inline error text, no blank page |
| JWT anywhere in collected text | stripped before writing (`jwt=…` → `jwt=<redacted>`) |

## Testing

`tests/test-session-receipt.sh`, following the existing `tests/` conventions
(self-skipping if `python3` missing):

- `open` writes a session file + index row with required fields
  (id format, `started_utc`, `end: null`, config/hw groups present).
- `close` marks it clean, sets `ended_utc`, updates the index.
- `open` over a dangling session marks the old one `dirty` with log-mtime end.
- JWT-bearing input (a fake log line) comes out redacted.
- All against `RECEIPTS_DIR=$(mktemp -d)`; repo files untouched.

Pages: manual check on localhost against a real dev session, plus one
hand-broken JSON to see the error paths.

## Out of scope / later

- Periodic hardware sampler (time-series graphs) — revisit if the x86
  throttling question needs data.
- Auto-commit/push of session files (git stays human-run).
- Viewer-side beacons.
