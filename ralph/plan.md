# LaserDisc over MoQ (vs LL-HLS) Implementation Plan

> **For agentic workers:** This plan is executed by a **ralph loop** (`ralph/ralph.sh` + `ralph/PROMPT.md`), one task per iteration, laptop-only. Steps use checkbox (`- [ ]`) syntax; tick them in this file as you go. REQUIRED SUB-SKILL when run interactively instead: superpowers:executing-plans.

**Goal:** Livestream a LaserDisc's analog signal from a Mac to a public URL over Media over QUIC, with an identical LL-HLS stream beside it so viewers can see which protocol has lower latency.

**Architecture:** One ffmpeg process (avfoundation → h264_videotoolbox + aac, wall-clock burned in) tees the same stream to (a) `moq-cli import ts` → the existing relay `<moq-relay-host>` and (b) RTMP → MediaMTX → LL-HLS. A single static page (`site/index.html`, GitHub Pages) shows both players with a browser clock under each.

**Tech Stack:** bash, ffmpeg 7.1 (avfoundation, tee, drawtext, h264_videotoolbox), `moq-cli` (crates.io), `@moq/watch` 0.5.2 web component, `hls.js` 1.7.1, MediaMTX 1.20.1 (Docker), Caddy (prod TLS), GitHub Pages workflow.

**Spec:** `docs/superpowers/specs/2026-08-29-laserdisc-moq-livestream-design.md`

## Global Constraints

- **Laptop-only.** NEVER run `aws`, `oci`, `ssh`, `scp`, `rsync` to a remote, `gh repo create`, `gh api`, `gh pages`, or anything that changes infrastructure. Write those commands into `ralph/HUMAN.md` instead.
- **Relay is read/publish-only.** Relay URL is exactly `${MOQ_RELAY_URL}`. Publish only to broadcast names matching `laserdisc*.hang`. Never change the relay's config, version, or box.
- **Pinned versions:** `@moq/watch@0.5.2`, `hls.js@1.7.1`, `bluenviron/mediamtx:1.20.1`. `moq-cli`: try latest (0.9.14 on 2026-08-29); if Task 1's round-trip fails, `cargo install moq-cli --version 0.8.4 --locked` (same release day as the relay's `moq-relay 0.13.5`).
- **One README, top level only.** Never create `README.md` in a subdirectory (use `NOTES.md`, `deploy-*.md`, etc.).
- **ffmpeg drawtext goes in a filter script file** (`scripts/overlay.filter`, used with `-filter_script:v`). Inline `-vf` with `%{localtime…}` breaks on shell escaping — verified.
- **Verified ffmpeg encode line** (do not "improve" it without re-testing):
  `-c:v h264_videotoolbox -realtime 1 -b:v 2500k -g 30 -bf 0 -profile:v main -pix_fmt yuv420p -c:a aac -b:a 128k -ar 48000 -ac 2`
- **Verified tee line:** `-map 0:v -map 1:a -f tee "[f=mpegts]pipe:1|[f=flv:onfail=ignore]$RTMP_URL"`.
- Tests are plain bash scripts in `tests/`, run by `tests/run.sh`; every test exits non-zero on failure and prints `PASS <name>` / `FAIL <name>`.
- Commit after every task with a message starting `feat:`, `fix:`, `docs:`, or `test:`.
- Hardware-gated tasks (Task 7) and human-only steps: if the prerequisite is absent, append a dated entry to `ralph/HUMAN.md` describing exactly what is needed and move on. Do not loop on them.

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/publish.sh` | The demo: ffmpeg (test or capture source) → tee → `moq import ts` + RTMP. |
| `scripts/overlay.filter` | drawtext filter (wall clock, ms). |
| `scripts/resolve-device.sh` | Turn a device-name substring into avfoundation `video:audio` indices. |
| `scripts/list-devices.sh` | Wrapper around `ffmpeg -f avfoundation -list_devices`. |
| `scripts/watch.sh` | Local subscriber: `moq … export fmp4 \| ffplay -`. |
| `scripts/run-forever.sh` | Restart wrapper around `publish.sh` with backoff + log. |
| `hls-origin/mediamtx.yml` | MediaMTX config (RTMP in, LL-HLS out). |
| `hls-origin/compose.local.yml` | Laptop: mediamtx only. |
| `hls-origin/compose.yml` | Prod: mediamtx + caddy (TLS for `$HLS_DOMAIN`). |
| `hls-origin/Caddyfile` | `HLS_DOMAIN → mediamtx:8888`. |
| `site/index.html` | Public page: `<moq-watch>` + hls.js side by side, clocks. |
| `site/CNAME` | `laserdisc.vanessa-dev.com`. |
| `.github/workflows/pages.yml` | Publish `site/` to GitHub Pages. |
| `tests/run.sh`, `tests/test-*.sh`, `tests/fixtures/` | Bash tests. |
| `docs/deploy-hls-origin.md` | Human runbook for the new HLS VM. |
| `ralph/HUMAN.md` | Everything the human must do (infra, DNS, hardware, browser checks). |
| `README.md` | Top-level docs + stage runbook + measured latencies. |
| `ralph/PROGRESS.md` | Ralph loop's own running notes (what worked, what failed, versions). |

---

### Task 1: `moq-cli` install + `publish.sh` test source → relay round-trip (M0)

**Files:**
- Create: `scripts/publish.sh`, `scripts/overlay.filter`, `scripts/watch.sh`, `tests/run.sh`, `tests/test-roundtrip.sh`, `ralph/PROGRESS.md`

**Interfaces:**
- Produces: `scripts/publish.sh` honouring env vars `SOURCE` (`test`|`capture`, default `capture`), `RELAY_URL`, `BROADCAST` (default `laserdisc.hang`), `HLS` (`1`|`0`, default `1`), `RTMP_URL` (default `rtmp://localhost:1935/laserdisc`), `VIDEO_DEV`, `AUDIO_DEV`, `SIZE` (default `1280x720`), `FPS` (default `30`). Exits 2 with a usage message on `-h`/`--help` or bad `SOURCE`.

- [x] **Step 1: Install moq-cli and record the version**

Run:
```bash
cargo install moq-cli --locked
moq --version
```
Expected: prints a version (0.9.x). Write the version to `ralph/PROGRESS.md` under a `## Versions` heading. If `cargo install` fails on Rust version, note it — rustc 1.97 is installed and moq-cli needs ≥1.91, so this should not happen.

- [x] **Step 2: Write the failing test**

`tests/run.sh`:
```bash
#!/usr/bin/env bash
# Runs every tests/test-*.sh; exits non-zero if any fails.
set -u
cd "$(dirname "$0")/.."
fail=0
for t in tests/test-*.sh; do
  if bash "$t"; then echo "PASS $t"; else echo "FAIL $t"; fail=1; fi
done
exit $fail
```

`tests/test-roundtrip.sh`:
```bash
#!/usr/bin/env bash
# Publishes the test source to the relay for a few seconds and checks that a
# second moq process can export h264+aac back out. Needs network + moq-cli.
set -u
cd "$(dirname "$0")/.."
export SOURCE=test HLS=0 BROADCAST="laserdisc-test-$$.hang"
OUT="$(mktemp -d)"
scripts/publish.sh >"$OUT/pub.log" 2>&1 &
PUB=$!
trap 'kill $PUB 2>/dev/null; wait $PUB 2>/dev/null' EXIT
sleep 4
timeout 20 moq --client-connect "${RELAY_URL:-${MOQ_RELAY_URL}}" \
  --broadcast "$BROADCAST" export ts 2>"$OUT/sub.log" | head -c 400000 >"$OUT/out.ts"
codecs="$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$OUT/out.ts" | sort -u | tr '\n' ' ')"
echo "codecs: $codecs"
case "$codecs" in *h264*aac*|*aac*h264*) exit 0;; esac
echo "--- pub.log"; tail -20 "$OUT/pub.log"; echo "--- sub.log"; tail -20 "$OUT/sub.log"
exit 1
```

- [x] **Step 3: Run the test to verify it fails**

Run: `chmod +x tests/*.sh && bash tests/test-roundtrip.sh`
Expected: FAIL — `scripts/publish.sh: No such file or directory`.

- [x] **Step 4: Write `scripts/overlay.filter`** (exact content, one line):

```
drawtext=text='%{localtime\:%H\\\:%M\\\:%S.%3N}':fontsize=48:fontcolor=white:box=1:boxcolor=black@0.6:x=20:y=20
```

- [x] **Step 5: Write `scripts/publish.sh`**

```bash
#!/usr/bin/env bash
# Encode once, tee to MoQ (relay) and RTMP (MediaMTX → LL-HLS).
#   SOURCE=test|capture  RELAY_URL  BROADCAST  HLS=1|0  RTMP_URL
#   VIDEO_DEV/AUDIO_DEV  (capture: avfoundation index or name substring)
#   SIZE=1280x720 FPS=30
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE="${SOURCE:-capture}"
RELAY_URL="${RELAY_URL:-${MOQ_RELAY_URL}}"
BROADCAST="${BROADCAST:-laserdisc.hang}"
HLS="${HLS:-1}"
RTMP_URL="${RTMP_URL:-rtmp://localhost:1935/laserdisc}"
SIZE="${SIZE:-1280x720}"
FPS="${FPS:-30}"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
command -v moq >/dev/null || { echo "moq-cli not installed: cargo install moq-cli --locked" >&2; exit 1; }

case "$SOURCE" in
  test)
    INPUT=(-re -f lavfi -i "testsrc2=size=${SIZE}:rate=${FPS}"
           -f lavfi -i "sine=frequency=440:sample_rate=48000")
    ;;
  capture)
    DEV="$("$HERE/resolve-device.sh" "${VIDEO_DEV:-Pengo}" "${AUDIO_DEV:-Pengo}")"   # "vidx:aidx"
    INPUT=(-f avfoundation -framerate "$FPS" -video_size "$SIZE" -pixel_format uyvy422
           -i "$DEV")
    ;;
  *) echo "SOURCE must be test or capture" >&2; usage;;
esac

if [[ "$SOURCE" == "test" ]]; then MAP=(-map 0:v -map 1:a); else MAP=(-map 0:v -map 0:a); fi
if [[ "$HLS" == "1" ]]; then TEE="[f=mpegts]pipe:1|[f=flv:onfail=ignore]${RTMP_URL}"; else TEE="[f=mpegts]pipe:1"; fi

echo "publish: source=$SOURCE relay=$RELAY_URL broadcast=$BROADCAST hls=$HLS rtmp=$RTMP_URL" >&2
exec ffmpeg -hide_banner -loglevel warning -nostats "${INPUT[@]}" \
  -filter_script:v "$HERE/overlay.filter" \
  -c:v h264_videotoolbox -realtime 1 -b:v 2500k -g 30 -bf 0 -profile:v main -pix_fmt yuv420p \
  -c:a aac -b:a 128k -ar 48000 -ac 2 \
  "${MAP[@]}" -f tee "$TEE" \
  | moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" import ts
```

Note: the `capture` branch calls `scripts/resolve-device.sh`, written in Task 2. Until then `SOURCE=capture` fails with "No such file" — acceptable; Task 1 only tests `SOURCE=test`.

- [x] **Step 6: Write `scripts/watch.sh`**

```bash
#!/usr/bin/env bash
# Local subscriber for eyeballing the MoQ leg.
set -euo pipefail
RELAY_URL="${RELAY_URL:-${MOQ_RELAY_URL}}"
BROADCAST="${BROADCAST:-laserdisc.hang}"
exec moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" export fmp4 | ffplay -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -
```

- [x] **Step 7: Run the test to verify it passes**

Run: `chmod +x scripts/*.sh && bash tests/test-roundtrip.sh`
Expected: `codecs: aac h264` then exit 0.

If it fails with a protocol/handshake error in `sub.log`/`pub.log` (not a script bug): `cargo install moq-cli --version 0.8.4 --locked --force`, re-run, and record the outcome in `ralph/PROGRESS.md` (`## Versions`: which moq-cli talks to relay 0.13.5). If both fail, record the exact error and stop this task; do not loop.

- [x] **Step 8: Commit**

```bash
git add scripts tests ralph/PROGRESS.md
git commit -m "feat: publish test source to relay via moq-cli, round-trip test"
```

---

### Task 2: Device resolution for the capture card

**Files:**
- Create: `scripts/resolve-device.sh`, `scripts/list-devices.sh`, `tests/test-resolve-device.sh`, `tests/fixtures/avfoundation-list.txt`

**Interfaces:**
- Produces: `scripts/resolve-device.sh <video-substring> <audio-substring>` → prints `V:A` (avfoundation indices) and exits 0; exits 1 with a message listing devices if either is not found. Env `AVF_LIST_FILE` overrides the live `ffmpeg -list_devices` output (for tests). Numeric arguments are passed through unchanged.

- [x] **Step 1: Write the fixture** `tests/fixtures/avfoundation-list.txt` (this is real ffmpeg 7.1 output shape; the Pengo lines are what a UVC card looks like):

```
[AVFoundation indev @ 0x120606f00] AVFoundation video devices:
[AVFoundation indev @ 0x120606f00] [0] MacBook Pro Camera
[AVFoundation indev @ 0x120606f00] [1] MacBook Pro Desk View Camera
[AVFoundation indev @ 0x120606f00] [2] USB3.0 Capture: Pengo
[AVFoundation indev @ 0x120606f00] [3] Capture screen 0
[AVFoundation indev @ 0x120606f00] AVFoundation audio devices:
[AVFoundation indev @ 0x120606f00] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x120606f00] [1] LoomAudioDevice
[AVFoundation indev @ 0x120606f00] [2] USB3.0 Capture: Pengo
```

- [x] **Step 2: Write the failing test** `tests/test-resolve-device.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
export AVF_LIST_FILE=tests/fixtures/avfoundation-list.txt
r="$(scripts/resolve-device.sh Pengo Pengo)"        || { echo "expected exit 0"; exit 1; }
[[ "$r" == "2:2" ]]                                 || { echo "got '$r' want 2:2"; exit 1; }
r="$(scripts/resolve-device.sh "MacBook Pro Camera" Loom)"
[[ "$r" == "0:1" ]]                                 || { echo "got '$r' want 0:1"; exit 1; }
r="$(scripts/resolve-device.sh 3 0)"
[[ "$r" == "3:0" ]]                                 || { echo "numeric passthrough got '$r'"; exit 1; }
scripts/resolve-device.sh Nope Pengo >/dev/null 2>&1 && { echo "expected failure for missing device"; exit 1; }
exit 0
```

- [x] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-resolve-device.sh`
Expected: FAIL — `scripts/resolve-device.sh: No such file or directory`.

- [x] **Step 4: Write `scripts/list-devices.sh`**

```bash
#!/usr/bin/env bash
# Prints avfoundation video/audio devices (ffmpeg exits non-zero here by design).
ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | grep -E '^\[AVFoundation' || true
```

- [x] **Step 5: Write `scripts/resolve-device.sh`**

```bash
#!/usr/bin/env bash
# resolve-device.sh <video-name-or-index> <audio-name-or-index>  → "V:A"
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
want_v="${1:?video device}"; want_a="${2:?audio device}"
if [[ -n "${AVF_LIST_FILE:-}" ]]; then list="$(cat "$AVF_LIST_FILE")"; else list="$("$HERE/list-devices.sh")"; fi
section() {  # section <video|audio> → lines "idx<TAB>name"  (BSD-awk safe — verified on macOS awk 20200816)
  awk -v want="$1" '
    /AVFoundation video devices/ {cur="video"; next}
    /AVFoundation audio devices/ {cur="audio"; next}
    cur==want { if (match($0, /\[[0-9]+\] /)) { idx=substr($0, RSTART+1, RLENGTH-3); name=substr($0, RSTART+RLENGTH); print idx "\t" name } }' <<<"$list"
}
find_idx() {  # find_idx <video|audio> <query>
  local q="$2"
  [[ "$q" =~ ^[0-9]+$ ]] && { echo "$q"; return 0; }
  section "$1" | awk -F'\t' -v q="$q" 'index(tolower($2), tolower(q)) {print $1; exit}'
}
v="$(find_idx video "$want_v")"; a="$(find_idx audio "$want_a")"
if [[ -z "$v" || -z "$a" ]]; then
  echo "device not found (video='$want_v' → '${v:-}', audio='$want_a' → '${a:-}'). Available:" >&2
  echo "$list" >&2
  exit 1
fi
echo "$v:$a"
```

- [x] **Step 6: Run the test to verify it passes**

Run: `chmod +x scripts/*.sh && bash tests/test-resolve-device.sh && echo OK`
Expected: `OK`.

- [x] **Step 7: Commit**

```bash
git add scripts/resolve-device.sh scripts/list-devices.sh tests
git commit -m "feat: resolve avfoundation device indices by name"
```

---

### Task 3: HLS leg — local MediaMTX, tee to RTMP, LL-HLS verified (M1)

**Files:**
- Create: `hls-origin/mediamtx.yml`, `hls-origin/compose.local.yml`, `tests/test-hls.sh`

**Interfaces:**
- Consumes: `scripts/publish.sh` env `HLS=1`, `RTMP_URL` (Task 1).
- Produces: local LL-HLS at `http://localhost:8888/laserdisc/index.m3u8`; MediaMTX RTMP ingest at `rtmp://localhost:1935/laserdisc`.

- [ ] **Step 1: Write `hls-origin/mediamtx.yml`**

```yaml
# MediaMTX: RTMP in from ffmpeg, Low-Latency HLS out.
logLevel: info
api: no
metrics: no
rtsp: no
webrtc: no
srt: no

rtmp: yes
rtmpAddress: :1935

hls: yes
hlsAddress: :8888
hlsAllowOrigins: ['*']
hlsAlwaysRemux: yes          # prepare the playlist even with zero viewers
hlsVariant: lowLatency
hlsSegmentCount: 7
hlsSegmentDuration: 1s
hlsPartDuration: 200ms
hlsMuxerCloseAfter: 60s

paths:
  laserdisc:
    source: publisher
```

- [ ] **Step 2: Write `hls-origin/compose.local.yml`**

```yaml
# Laptop-only: MediaMTX with plain HTTP. Prod uses compose.yml (adds Caddy/TLS).
services:
  mediamtx:
    image: bluenviron/mediamtx:1.20.1
    container_name: laser-mediamtx
    restart: unless-stopped
    ports:
      - "1935:1935"
      - "8888:8888"
    volumes:
      - ./mediamtx.yml:/mediamtx.yml:ro
```

- [ ] **Step 3: Write the failing test** `tests/test-hls.sh`:

```bash
#!/usr/bin/env bash
# Starts local MediaMTX, publishes the test source with the RTMP leg on,
# and asserts the playlist is Low-Latency HLS. Then proves killing MediaMTX
# does not kill the MoQ leg.
set -u
cd "$(dirname "$0")/.."
docker compose -f hls-origin/compose.local.yml up -d >/dev/null || exit 1
export SOURCE=test HLS=1 BROADCAST="laserdisc-hls-$$.hang"
OUT="$(mktemp -d)"
scripts/publish.sh >"$OUT/pub.log" 2>&1 &
PUB=$!
cleanup() { kill $PUB 2>/dev/null; wait $PUB 2>/dev/null; docker compose -f hls-origin/compose.local.yml down >/dev/null 2>&1; }
trap cleanup EXIT
for i in $(seq 1 20); do
  curl -sf http://localhost:8888/laserdisc/index.m3u8 -o "$OUT/index.m3u8" && break; sleep 1
done
[[ -s "$OUT/index.m3u8" ]] || { echo "no playlist"; tail -20 "$OUT/pub.log"; exit 1; }
media="$(grep -m1 -E '\.m3u8' "$OUT/index.m3u8" | sed -E 's/^[^"]*"?([^" ]*\.m3u8)"?.*/\1/')"
[[ -n "$media" ]] || media="index.m3u8"
sleep 3
curl -sf "http://localhost:8888/laserdisc/$media" -o "$OUT/media.m3u8" || { echo "no media playlist $media"; exit 1; }
grep -q '#EXT-X-PART' "$OUT/media.m3u8" || { echo "not LL-HLS (no EXT-X-PART)"; head -30 "$OUT/media.m3u8"; exit 1; }
echo "LL-HLS ok"
# resilience: HLS origin dies, MoQ leg must keep running
docker compose -f hls-origin/compose.local.yml stop >/dev/null
sleep 5
kill -0 $PUB 2>/dev/null || { echo "publisher died when MediaMTX stopped"; tail -20 "$OUT/pub.log"; exit 1; }
echo "publisher survived HLS origin loss"
exit 0
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bash tests/test-hls.sh`
Expected: FAIL at `docker compose … up` (files missing) — or, if files exist but the tee isn't wired, "no playlist".

- [ ] **Step 5: Make it pass**

`scripts/publish.sh` from Task 1 already emits the tee leg when `HLS=1`. If the playlist never appears, check `docker logs laser-mediamtx` for the RTMP publish and `pub.log` for `onfail` messages. MediaMTX may reject FLV without `aac` ADTS-to-ASC conversion — if the log says so, add `-bsf:a aac_adtstoasc` **only to the flv leg**: `[f=flv:onfail=ignore:bsfs/a=aac_adtstoasc]${RTMP_URL}`.

Run: `bash tests/test-hls.sh`
Expected: `LL-HLS ok` and `publisher survived HLS origin loss`, exit 0.

- [ ] **Step 6: Run the whole suite and commit**

```bash
bash tests/run.sh
git add hls-origin tests
git commit -m "feat: LL-HLS leg via local MediaMTX, tee resilience test"
```

---

### Task 4: Viewer page (M2)

**Files:**
- Create: `site/index.html`, `site/CNAME`, `tests/test-site.sh`

**Interfaces:**
- Consumes: relay `${MOQ_RELAY_URL}`, broadcast `laserdisc.hang`, HLS URL (default `https://hls.vanessa-dev.com/laserdisc/index.m3u8`, overridable with `?hls=` and `?relay=`/`?name=` query params).

- [ ] **Step 1: Write the failing test** `tests/test-site.sh` (static checks — the browser check is human):

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
f=site/index.html
[[ -f $f ]] || { echo "missing $f"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm' $f || { echo "moq/watch not pinned"; exit 1; }
grep -q 'cdn.jsdelivr.net/npm/hls.js@1.7.1' $f                 || { echo "hls.js not pinned"; exit 1; }
grep -q '<moq-watch' $f                                          || { echo "no <moq-watch>"; exit 1; }
grep -q '<moq-relay-host>/anon' $f                           || { echo "relay url missing"; exit 1; }
grep -q 'laserdisc.hang' $f                                       || { echo "broadcast name missing"; exit 1; }
grep -q 'lowLatencyMode' $f                                       || { echo "hls.js lowLatencyMode missing"; exit 1; }
grep -q 'id="clock-moq"' $f && grep -q 'id="clock-hls"' $f        || { echo "clocks missing"; exit 1; }
[[ "$(cat site/CNAME)" == "laserdisc.vanessa-dev.com" ]]          || { echo "CNAME wrong"; exit 1; }
exit 0
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-site.sh` → `missing site/index.html`.

- [ ] **Step 3: Write `site/CNAME`** containing exactly `laserdisc.vanessa-dev.com` (no trailing newline required).

- [ ] **Step 4: Write `site/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LIVE from a LaserDisc</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #0b0b0f; color: #eee; font: 16px/1.4 system-ui, sans-serif; }
  header { padding: 1rem 1.5rem; border-bottom: 1px solid #222; }
  header h1 { margin: 0; font-size: 1.4rem; letter-spacing: .02em; }
  header p { margin: .25rem 0 0; color: #aaa; }
  main { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; padding: 1rem 1.5rem; }
  @media (max-width: 900px) { main { grid-template-columns: 1fr; } }
  .player { background: #000; border: 1px solid #222; border-radius: 6px; overflow: hidden; }
  .player h2 { margin: 0; padding: .5rem .75rem; font-size: 1rem; background: #15151c; }
  .player canvas, .player video { display: block; width: 100%; aspect-ratio: 16/9; background: #000; }
  .clock { font: 1.6rem/1 ui-monospace, monospace; padding: .5rem .75rem; }
  .status { padding: 0 .75rem .5rem; color: #aaa; font-size: .9rem; min-height: 1.2rem; }
  footer { padding: 1rem 1.5rem; color: #777; font-size: .85rem; }
  a { color: #8ab4ff; }
</style>
</head>
<body>
<header>
  <h1>📀 LIVE from a LaserDisc</h1>
  <p>Same analog signal, same encoder, two protocols. The clock burned into the picture is the publisher's; the clock under each player is yours. The difference is latency.</p>
</header>
<main>
  <section class="player">
    <h2>Media over QUIC</h2>
    <moq-watch id="moq" controls><canvas></canvas></moq-watch>
    <div class="clock" id="clock-moq">--:--:--.---</div>
    <div class="status" id="status-moq"></div>
  </section>
  <section class="player">
    <h2>Low-Latency HLS</h2>
    <video id="hls" controls autoplay muted playsinline></video>
    <div class="clock" id="clock-hls">--:--:--.---</div>
    <div class="status" id="status-hls"></div>
  </section>
</main>
<footer>
  A stunt hack. Source + runbook: <a href="https://github.com/vipyne/laser-moq">github.com/vipyne/laser-moq</a>.
  MoQ needs WebTransport (Chrome/Edge/Brave); this relay also speaks WebSocket so Safari should still connect.
</footer>

<script type="module">
  import "https://cdn.jsdelivr.net/npm/@moq/watch@0.5.2/element/+esm";
  import Hls from "https://cdn.jsdelivr.net/npm/hls.js@1.7.1/+esm";

  const q = new URLSearchParams(location.search);
  const RELAY = q.get("relay") ?? "${MOQ_RELAY_URL}";
  const NAME  = q.get("name")  ?? "laserdisc.hang";
  const HLS_URL = q.get("hls") ?? "https://hls.vanessa-dev.com/laserdisc/index.m3u8";

  // --- MoQ ---
  const moq = document.getElementById("moq");
  moq.setAttribute("url", RELAY);
  moq.setAttribute("name", NAME);
  const smoq = document.getElementById("status-moq");
  smoq.textContent = ("WebTransport" in window) ? "WebTransport" : "no WebTransport → WebSocket fallback";

  // --- HLS ---
  const video = document.getElementById("hls");
  const shls = document.getElementById("status-hls");
  if (Hls.isSupported()) {
    const hls = new Hls({ lowLatencyMode: true, liveSyncDuration: 1, liveMaxLatencyDuration: 3, backBufferLength: 10 });
    hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal) shls.textContent = "HLS offline: " + d.details; });
    hls.on(Hls.Events.MANIFEST_PARSED, () => { shls.textContent = "hls.js lowLatencyMode"; video.play().catch(() => {}); });
    hls.loadSource(HLS_URL);
    hls.attachMedia(video);
  } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = HLS_URL; shls.textContent = "native HLS (Safari)";
  } else {
    shls.textContent = "HLS not supported in this browser";
  }

  // --- clocks ---
  const fmt = d => d.toTimeString().slice(0, 8) + "." + String(d.getMilliseconds()).padStart(3, "0");
  const cm = document.getElementById("clock-moq"), ch = document.getElementById("clock-hls");
  const tick = () => { const s = fmt(new Date()); cm.textContent = s; ch.textContent = s; requestAnimationFrame(tick); };
  tick();
</script>
</body>
</html>
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-site.sh && echo OK` → `OK`.

- [ ] **Step 6: Serve locally and record the human check**

Run (leave running in the background, or just note the command):
```bash
(cd site && python3 -m http.server 8000)
```
Append to `ralph/HUMAN.md` under `## Browser checks`:
```
- [ ] With `SOURCE=test HLS=1 scripts/publish.sh` and local MediaMTX running (`docker compose -f hls-origin/compose.local.yml up -d`),
      open http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8 in Chrome.
      Expect: both players show the colour bars + burned-in clock; note the MoQ vs HLS delta vs the page clocks.
- [ ] Same URL in Safari: MoQ via WebSocket fallback should connect; HLS via native player.
```

- [ ] **Step 7: Commit**

```bash
git add site tests/test-site.sh ralph/HUMAN.md
git commit -m "feat: viewer page with MoQ and LL-HLS side by side"
```

---

### Task 5: `run-forever.sh` restart wrapper + soak (M4 part 1)

**Files:**
- Create: `scripts/run-forever.sh`, `tests/test-run-forever.sh`

**Interfaces:**
- Produces: `scripts/run-forever.sh` — runs `publish.sh` with the same env, restarts after 2 s on any exit, logs to `logs/publish-YYYYmmdd-HHMMSS.log`, stops cleanly on SIGINT/SIGTERM (kills the child pipeline too). Env `MAX_RESTARTS` (default unlimited) for tests.

- [ ] **Step 1: Write the failing test** `tests/test-run-forever.sh`:

```bash
#!/usr/bin/env bash
# Kill ffmpeg mid-stream; the wrapper must restart the pipeline.
set -u
cd "$(dirname "$0")/.."
export SOURCE=test HLS=0 BROADCAST="laserdisc-forever-$$.hang" MAX_RESTARTS=3
scripts/run-forever.sh &
W=$!
trap 'kill $W 2>/dev/null; wait $W 2>/dev/null' EXIT
sleep 5
first="$(pgrep -f 'ffmpeg .*testsrc2' | head -1)"
[[ -n "$first" ]] || { echo "ffmpeg not running"; exit 1; }
kill "$first"
sleep 6
second="$(pgrep -f 'ffmpeg .*testsrc2' | head -1)"
[[ -n "$second" && "$second" != "$first" ]] || { echo "no restart (first=$first second=$second)"; exit 1; }
kill -INT $W; sleep 2
pgrep -f 'ffmpeg .*testsrc2' >/dev/null && { echo "child survived SIGINT"; exit 1; }
echo "restart + clean shutdown ok"
exit 0
```

- [ ] **Step 2: Run to verify it fails** → `scripts/run-forever.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/run-forever.sh`**

```bash
#!/usr/bin/env bash
# Keep publish.sh running. Restarts after 2s on any exit. Ctrl-C stops everything.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/../logs"
LOG="$HERE/../logs/publish-$(date +%Y%m%d-%H%M%S).log"
MAX_RESTARTS="${MAX_RESTARTS:-0}"   # 0 = unlimited
n=0; child=
stop() { echo "stopping" | tee -a "$LOG"; [[ -n "$child" ]] && { pkill -TERM -P "$child" 2>/dev/null; kill -TERM "$child" 2>/dev/null; }; exit 0; }
trap stop INT TERM
while :; do
  n=$((n+1))
  echo "[$(date +%T)] start #$n" | tee -a "$LOG"
  "$HERE/publish.sh" >>"$LOG" 2>&1 &
  child=$!
  wait "$child"; rc=$?
  echo "[$(date +%T)] exited rc=$rc" | tee -a "$LOG"
  [[ "$MAX_RESTARTS" != "0" && "$n" -ge "$MAX_RESTARTS" ]] && exit "$rc"
  sleep 2
done
```

- [ ] **Step 4: Run to verify it passes** → `restart + clean shutdown ok`. If `pkill -P` leaves an orphan `moq` (the pipe's right-hand side), also `pkill -f "moq --client-connect.*$BROADCAST"` in `stop()`.

- [ ] **Step 5: Soak** — 20 minutes with the test source, then check for disconnects:

```bash
SOURCE=test HLS=0 BROADCAST=laserdisc-soak.hang timeout 1200 scripts/run-forever.sh; \
grep -c 'exited rc' logs/publish-*.log | tail -1
```
Expected: the last log shows exactly one `start #1` and the exit is from `timeout` (rc 124/143), i.e. no unplanned restarts. Record the result in `ralph/PROGRESS.md` (`## Soak`). If restarts occurred, paste the ffmpeg/moq error lines into `ralph/PROGRESS.md` and fix what is fixable (e.g. add `-rw_timeout`/retry flags); do not spend more than one iteration on it.

- [ ] **Step 6: Commit**

```bash
git add scripts/run-forever.sh tests/test-run-forever.sh ralph/PROGRESS.md
git commit -m "feat: restart wrapper for the publisher, soak results"
```

---

### Task 6: Production HLS origin files, Pages workflow, human runbooks, README (M4 part 2)

**Files:**
- Create: `hls-origin/compose.yml`, `hls-origin/Caddyfile`, `hls-origin/env.example`, `.github/workflows/pages.yml`, `docs/deploy-hls-origin.md`, `README.md`
- Modify: `ralph/HUMAN.md`

- [ ] **Step 1: `hls-origin/compose.yml`**

```yaml
# Production: MediaMTX + Caddy (automatic TLS for $HLS_DOMAIN).
# Ports: 1935/tcp (RTMP in), 80+443/tcp (Caddy). 8888 stays internal.
services:
  mediamtx:
    image: bluenviron/mediamtx:1.20.1
    container_name: laser-mediamtx
    restart: unless-stopped
    ports:
      - "1935:1935"
    volumes:
      - ./mediamtx.yml:/mediamtx.yml:ro
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
  caddy:
    image: caddy:2
    container_name: laser-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - HLS_DOMAIN=${HLS_DOMAIN:?set HLS_DOMAIN in .env}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [mediamtx]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
volumes:
  caddy_data:
  caddy_config:
```

`hls-origin/Caddyfile`:
```
{$HLS_DOMAIN} {
	encode zstd gzip
	header Access-Control-Allow-Origin *
	header Cache-Control "no-cache"
	reverse_proxy mediamtx:8888
}
```

`hls-origin/env.example`:
```
HLS_DOMAIN=hls.vanessa-dev.com
```

Validate locally: `cd hls-origin && HLS_DOMAIN=example.test docker compose -f compose.yml config >/dev/null && echo COMPOSE_OK`.

- [ ] **Step 2: `.github/workflows/pages.yml`**

```yaml
name: pages
on:
  push:
    branches: [main]
    paths: ["site/**", ".github/workflows/pages.yml"]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency: { group: pages, cancel-in-progress: true }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: { name: github-pages, url: "${{ steps.deployment.outputs.page_url }}" }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with: { path: site }
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 3: `docs/deploy-hls-origin.md`** — human runbook for a **new** VM. Write it in the same voice as the existing OCI runbooks (sections labelled *(laptop)* / *(on the box)*, a **Gate:** line after each section), provider-agnostic in substance. Required content, in order:

1. **Requirements:** Ubuntu 24.04, public IPv4, inbound 22/80/443/1935 TCP. On OCI: a *new* `VM.Standard.A1.Flex` 1 OCPU/6 GB in the same compartment (`<compartment-ocid>`), **new** VCN/subnet named `hls-vcn`/`hls-subnet` (do not reuse `relay-subnet`), reserved public IP `hls-ip`. Include the `oci` commands modelled on `<internal deploy-oci runbook>` §1–§2 but with the new names and this security list: `{"22/tcp": "YOUR_IP/32", "80/tcp": "0.0.0.0/0", "443/tcp": "0.0.0.0/0", "1935/tcp": "0.0.0.0/0"}`. Note the Always-Free A1 budget (4 OCPU total; three 1-OCPU boxes already exist → exactly one more fits).
2. **DNS (human):** Route 53 A record `hls.vanessa-dev.com → PUBLIC_IP` (`AWS_PROFILE=vanessa-dev`), with the `aws route53 change-resource-record-sets` JSON. Gate: `dig +short hls.vanessa-dev.com @1.1.1.1`.
3. **Box prep:** `iptables -I INPUT -p tcp --dport {80,443,1935} -j ACCEPT && netfilter-persistent save`; `apt-get install -y docker.io docker-compose-v2`; `usermod -aG docker ubuntu`.
4. **Ship + run:** `rsync -a hls-origin/ ubuntu@PUBLIC_IP:~/hls-origin/`; on the box `cp env.example .env`, `docker compose up -d`; Gate: `curl -sI https://hls.vanessa-dev.com/ → 404 ssl ok` (MediaMTX 404s the root; the cert is what matters).
5. **Publish from the laptop:** `RTMP_URL=rtmp://hls.vanessa-dev.com:1935/laserdisc SOURCE=test scripts/publish.sh`; Gate: `curl -sf https://hls.vanessa-dev.com/laserdisc/index.m3u8 | head`.
6. **Day-to-day:** logs, restart, park/terminate (OCI `instance action STOP/START`).

- [ ] **Step 4: `ralph/HUMAN.md`** — rewrite as the single ordered checklist the human works through (keep any browser-check / hardware entries earlier tasks appended, folding them into the right place):

```markdown
# HUMAN.md — things only you can do

Ordered. Each item has the exact command(s). The ralph loop never runs these.

## 1. GitHub repo + Pages
- [ ] `gh repo create vipyne/laser-moq --public --source . --push`
- [ ] Enable Pages via workflow: `gh api -X POST repos/vipyne/laser-moq/pages -f build_type=workflow`
      (if it says already exists: `gh api -X PUT repos/vipyne/laser-moq/pages -f build_type=workflow`)
- [ ] Custom domain: `gh api -X PUT repos/vipyne/laser-moq/pages -f cname=laserdisc.vanessa-dev.com`
- [ ] Route 53 CNAME `laserdisc.vanessa-dev.com → vipyne.github.io` (AWS_PROFILE=vanessa-dev; JSON below)
- [ ] After the cert shows in Settings → Pages: `gh api -X PUT repos/vipyne/laser-moq/pages -F https_enforced=true`
- [ ] Gate: `curl -sI https://laserdisc.vanessa-dev.com/ | head -1` → 200

## 2. HLS origin VM
- [ ] Follow `docs/deploy-hls-origin.md` (new VM, DNS `hls.vanessa-dev.com`, ports 80/443/1935).
- [ ] Gate: `curl -sf https://hls.vanessa-dev.com/laserdisc/index.m3u8 | head -3` while `SOURCE=test RTMP_URL=rtmp://hls.vanessa-dev.com:1935/laserdisc scripts/publish.sh` runs.

## 3. Hardware
- [ ] Plug LaserDisc → Ocean Matrix → Pengo → Mac. `scripts/list-devices.sh` must show the Pengo in BOTH video and audio lists. Note the exact name and set `VIDEO_DEV`/`AUDIO_DEV` if it isn't "Pengo".
- [ ] `SOURCE=capture scripts/watch.sh` in one terminal, `SOURCE=capture HLS=0 scripts/publish.sh` in another → picture.

## 4. Browser checks
(entries appended by the loop go here)

## 5. Public end-to-end
- [ ] Phone on cellular: https://laserdisc.vanessa-dev.com shows both streams.
- [ ] Read MoQ latency and HLS latency off the clocks; write them into README "Measured latency".
```
Include the Route 53 change-batch JSON for the CNAME (copy the shape from `<internal deploy-oci runbook>` §2, `"Type": "CNAME"`, `"Value": "vipyne.github.io"`).

- [ ] **Step 5: `README.md`** (top level; the only README). Sections: **What this is** (2 sentences, link to the old talk idea), **Architecture** (the ASCII diagram from the spec), **Hardware chain**, **Install** (`cargo install moq-cli --locked` + the version that worked, from `ralph/PROGRESS.md`), **Run** (`SOURCE=test` quick start; `SOURCE=capture`; env var table from `publish.sh`), **Stage runbook** (numbered: plug in → `scripts/list-devices.sh` → `docker`/HLS origin up → `scripts/run-forever.sh` → open URL → if it dies: Ctrl-C and rerun; viewers auto-reconnect), **Measured latency** (table with MoQ / LL-HLS columns, filled with "TBD by human" only here — this is the one allowed placeholder because the number requires eyes), **Tests** (`tests/run.sh`, which need network/docker), **Troubleshooting** (device index moved → use names; relay down → `ralph/HUMAN.md` §2 of relay notes: `oci compute instance list`, `ssh ubuntu@<moq-relay-ip> docker ps`; version skew → pin 0.8.4; Safari → WebSocket fallback; HLS offline → MoQ keeps going), **Layout** (file table from this plan).

- [ ] **Step 6: Run the full suite, then commit**

```bash
bash tests/run.sh
git add -A
git commit -m "docs: HLS origin deploy runbook, Pages workflow, HUMAN.md, README"
```

---

### Task 7: Real capture (M3) — hardware-gated

**Files:**
- Modify: `scripts/publish.sh` (only if the Pengo needs different `-pixel_format`/`-video_size`), `README.md` (Measured latency), `ralph/PROGRESS.md`

- [ ] **Step 1: Detect hardware**

Run: `scripts/list-devices.sh | grep -i "${VIDEO_DEV:-pengo}"`
If nothing matches: append to `ralph/HUMAN.md` §3 "Pengo not detected on <date>; plug in and rerun the loop", write `blocked: hardware` next to this task's heading in this file, and **stop this task** (the loop moves on / finishes).

- [ ] **Step 2: Probe the card's real modes**

Run: `ffmpeg -hide_banner -f avfoundation -framerate 30 -video_size 1280x720 -i "$(scripts/resolve-device.sh Pengo Pengo)" -t 1 -f null - 2>&1 | tail -20`
If avfoundation rejects the size/pixel format, it prints the supported list — set `SIZE`/`-pixel_format` accordingly in `publish.sh` defaults and note it in `ralph/PROGRESS.md`.

- [ ] **Step 3: Stream it**

Run: `SOURCE=capture HLS=1 scripts/publish.sh` (with local MediaMTX up) and `scripts/watch.sh` in another process for 30 s. Expected: no ffmpeg warnings about dropped frames beyond the first second.

- [ ] **Step 4: Record and commit**

Append to `ralph/HUMAN.md` §5: read the two latencies off the page and fill README "Measured latency". Commit: `git commit -am "feat: capture defaults for the Pengo card"`.

---

## Completion

The loop is **complete** when Tasks 1–6 are fully checked, `bash tests/run.sh` passes, and Task 7 is either checked or marked `blocked: hardware` with a `ralph/HUMAN.md` entry. Then output `<promise>LASER_MOQ_COMPLETE</promise>`.
