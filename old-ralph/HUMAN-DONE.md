# HUMAN.md — things only you can do

Ordered. Each item has the exact command(s). The ralph loop never runs these,
but it reads this file FIRST every iteration.

Conventions:
- **Gate:** items stop the loop. When only gated/blocked work remains, the loop
  prints `<promise>HUMAN_GATE</promise>` and `ralph.sh` exits pointing here.
  Do the item, tick its box, rerun `./ralph/ralph.sh`.
- **Gate failed?** Leave the box UNCHECKED and write a dated note directly under
  the item — what you ran, what you saw, verbatim errors. The next loop run
  treats that note as a bug report and turns it into plan work.

The relay endpoint is deliberately nowhere in this repo: `export MOQ_RELAY_URL=…`
in any shell that runs `scripts/` or `tests/`, and set the Actions variable in §1
before the Pages site can deploy.

## 1. GitHub repo + Pages
- [x] **Gate: review before anything is pushed.** `git log --oneline` + skim the diffs
      (`git diff <last-commit-you-reviewed>..HEAD`). Only proceed when you're happy.
- [x] **Gate: review the v2 loop's commits before pushing** (scaffolded 2026-09-15).
      Same drill: `git log --oneline` + `git diff <last-reviewed>..HEAD`, push only
      when happy — the loop only ever commits locally.
- [x] `gh repo create vipyne/laser-moq --public --source . --push`
- [x] `gh variable set MOQ_RELAY_URL --body 'https://<your-relay-host>/anon'` — the Pages
      workflow writes `site/config.js` from this; the run triggered by the first push
      fails without it (rerun afterwards: `gh workflow run pages`)
- [x] Enable Pages via workflow: `gh api -X POST repos/vipyne/laser-moq/pages -f build_type=workflow`
      (if it says already exists: `gh api -X PUT repos/vipyne/laser-moq/pages -f build_type=workflow`)
- [x] Custom domain: `gh api -X PUT repos/vipyne/laser-moq/pages -f cname=moq-laserdisc.vanessa-dev.com`
- [x] Route 53 CNAME `moq-laserdisc.vanessa-dev.com → vipyne.github.io` (AWS_PROFILE=vanessa-dev):

```bash
ZONE=$(AWS_PROFILE=vanessa-dev aws route53 list-hosted-zones-by-name --dns-name vanessa-dev.com \
  --query 'HostedZones[0].Id' --output text)
AWS_PROFILE=vanessa-dev aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
  --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "moq-laserdisc.vanessa-dev.com",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "vipyne.github.io"}]
    }
  }]
}'
```

- [x] After the cert shows in Settings → Pages: `gh api -X PUT repos/vipyne/laser-moq/pages -F https_enforced=true`
- [x] Gate: `curl -sI https://moq-laserdisc.vanessa-dev.com/ | head -1` → 200

## 2. HLS origin VM
- [x] Follow `docs/deploy-hls-origin.md` (new VM, DNS `hls-laserdisc.vanessa-dev.com`, ports 80/443/1935).
- [x] Gate: `J=$(mktemp); curl -sfL -c "$J" -b "$J" https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8 | head -3` while `SOURCE=test RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=$RTMP_PUBLISH_PASS" scripts/publish.sh` runs.

## 3. Hardware
- Pengo not detected on 2026-09-10 (`scripts/list-devices.sh` shows no match); plug in and rerun the loop so Task 7 (capture probe + defaults) can run.
- [x] Plug LaserDisc → Ocean Matrix → Pengo → Mac. `scripts/list-devices.sh` must show the Pengo in BOTH video and audio lists. Note the exact name and set `VIDEO_DEV`/`AUDIO_DEV` if it isn't "Pengo".
- [x] `SOURCE=capture scripts/watch.sh` in one terminal, `SOURCE=capture HLS=0 scripts/publish.sh` in another → picture.

## 4. Browser checks
- [x] With `SOURCE=test HLS=1 scripts/publish.sh` and local MediaMTX running (`docker compose -f hls-origin/compose.local.yml up -d`),
      serve the page (`cd site && python3 -m http.server 8000`) and
      open http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8 in Chrome.
      Expect: both players show the colour bars + burned-in clock; note the MoQ vs HLS delta vs the page clocks.

- [x] **Fix the relay's WebSocket TLS first** (found 2026-09-13: Safari's `wss://` fallback
      was never functional — TCP 443 on the relay serves *plain* HTTP from `[web.http]`,
      so the TLS handshake fails). On the relay box, in the relay's TOML replace the
      `[web.http] listen = "[::]:443"` listener with:
      ```toml
      [web.https]
      listen = "[::]:443"
      cert = "<fullchain.pem path inside the container>"   # same LE cert QUIC uses
      key  = "<privkey.pem path inside the container>"
      ```
It's the relay config swap sitting in HUMAN.md §4 — 
genuinely quick if the cert files are already mounted in the relay
  container (they should be; the QUIC side uses them). On the relay box:

  1. In the relay's TOML config, find the web section — it currently has:

  [web.http]
  listen = "[::]:443"

  Replace it with:

  [web.https]
  listen = "[::]:443"
  cert = "<path to fullchain.pem as the container sees it>"
  key  = "<path to privkey.pem as the container sees it>"

  The paths are whatever the QUIC/TLS section of that same config already points at — same Let's Encrypt pair, just
  referenced a second time. (If [web.http] also serves something on another port you want to keep, you can have both
  sections; it's only the 443 listener that must become https.)

  2. Restart the relay container.

  3. Gates, in order:
  - curl -s https://relay.vanessa-dev.com/anon | head -1 → should print the relay's HTML landing page over real TLS (today
    that command fails the handshake — that's the whole bug). Say the word once you've restarted and I'll run this check
    from here.
  - Chrome still plays (proves QUIC/UDP untouched — it should be, this only changes the TCP listener).
  - Then the actual prize: the §4 Safari check against the localhost page — the stack from the timecode work is still
    running, so it's just a matter of opening the same URL in Safari.

  Why this fixes it: Safari has no WebTransport, so @moq/watch falls back to wss:// on TCP 443 — but that port currently
  serves plaintext HTTP (verified: http://relay.vanessa-dev.com:443/anon answers in cleartext), so Safari's TLS handshake
  dies before WebSocket ever starts. The WS handler itself is fine and enabled by default (web-ws = true); it just needs a
  TLS listener in front of it.

  Blast radius: QUIC (UDP 443) untouched; the only behavior change on TCP 443 is plaintext→TLS, which nothing legitimate
  should have depended on.

      then restart the relay container. QUIC/WebTransport (UDP 443) is untouched.
      Gate: `curl -s https://relay.vanessa-dev.com/anon | head -1` prints the
      relay landing page over TLS (today that command fails the handshake).
- [x] **PINNED 2026-09-13 (Safari support deferred).** Same URL in Safari: MoQ via WebSocket fallback should connect; HLS via native player.
- [x] `/results` page: serve locally (`cd site && python3 -m http.server 8000`) and open
      http://localhost:8000/results/ — expect the summary tiles, the dots chart, and the
      runs table rendered from `data.json` (one seeded test run today). Check it on prod
      (https://moq-laserdisc.vanessa-dev.com/results/) after the next push.

## 5. Public end-to-end
- [x] Phone on cellular: https://moq-laserdisc.vanessa-dev.com shows both streams.

2026-09-17: https://moq-laserdisc.vanessa-dev.com shows super choppy MoQ and  "HLS offline: manifestLoadError" - no HLS at all.  tested by running `SOURCE=test ./scripts/prod.sh`, so maybe something wonky there?

> **Loop reply 2026-09-17 (PLAN Task 11):** root-caused — the origin serves the
> CORS allow-origin header TWICE (Caddy added its own on top of MediaMTX's;
> browsers reject duplicate values → hls.js manifestLoadError; curl ignores
> duplicates, which is why §2's gate passed and no browser ever hit prod HLS
> until now). Your publish leg was fine: today's log shows the RTMP tee ran
> error-free for the whole 4.5 min. Fixed in `hls-origin/Caddyfile` (guarded by
> `tests/test-caddyfile.sh`); the VM still runs the old file — redeploy runbook
> in **§9**. The choppy MoQ is not reproducible repo-side: the deployed page
> predates all the tuning/preset commits (no `hlspreset` in the served HTML),
> and yesterday's local runs through the same relay were smooth (p50 648ms,
> tight spread) — re-judge after §9 + push, and leave a dated note if it's
> still choppy on the new page.

2026-09-18: HLS works on https://moq-laserdisc.vanessa-dev.com now but MoQ is still
choppy.

> **Loop reply 2026-09-18 (PLAN Task 12):** root-caused — the `<moq-watch>`
> element defaults its `latency` control to `"real-time"`: a ZERO jitter
> buffer, so every frame that arrives a hair late is a visible stutter. The
> page never set the attribute. HLS looks smooth on the same network only
> because hls.js buffers ≥1.5 s. (Pushing the earlier pending commits alone
> would never have fixed this — none of them touch the MoQ pane.) Fixed in
> `site/index.html`: MoQ now runs a 150 ms jitter buffer by default
> (`?moqlatency=<ms>` or `?moqlatency=real-time` to override; the status line
> under the player shows which is active). 150 ms keeps MoQ ~0.8 s
> glass-to-glass — still well under both HLS modes. Re-check runbook: **§10**.

## 6. MoQ publish auth (optional hardening — do after §1–§5 work)

Locks MoQ publishing behind a token while viewing stays public, without touching
the `anon/` prefix (the other demo on the relay keeps working). Verified against
moq-relay 0.13.5 + moq-cli 0.11.0: token wire format matches (`root`/`put`/`get`
claims identical between the CLI's signer and the relay's verifier), and the relay
reads `?jwt=` from the connect URL. No repo code changes — tokens travel inside
`MOQ_RELAY_URL`.

- [x] **Generate the signing key** (laptop; HS256 shared secret — never commit it):
      `moq token generate --out ~/moq-root.jwk`
- [x] **Relay box:** copy `~/moq-root.jwk` onto the relay host, mount it into the
      relay container, and in the relay's TOML add under the existing `[auth]`
      section: `key = "<path to moq-root.jwk inside the container>"`.
      **Keep `public = "anon"` as-is** — that's what leaves the other demo alone.
      Restart the relay container.
- [x] **Mint tokens** (laptop; pick an expiry after the show, e.g. `date -v+60d +%s`):
      - publisher (secret, publish+subscribe under `livestream/`):
        `moq token sign --key ~/moq-root.jwk --root livestream --publish "" --subscribe "" --expires <unix>`
      - viewers (public by design, subscribe-only):
        `moq token sign --key ~/moq-root.jwk --root livestream --subscribe "" --expires <unix>`
- [x] **Flip the endpoints** (path moves from `/anon` to `/livestream`):
      - laptop: `export MOQ_RELAY_URL="https://relay.vanessa-dev.com/livestream?jwt=<PUBLISHER_TOKEN>"`
      - page: `gh variable set MOQ_RELAY_URL --body 'https://relay.vanessa-dev.com/livestream?jwt=<VIEWER_TOKEN>'`
        then `gh workflow run pages`
- [ ] Gate (publisher CLI — no viewer page involved): `SOURCE=test HLS=0 scripts/publish.sh`
      streams; the same command with the jwt stripped from `MOQ_RELAY_URL` (same URL,
      no `?jwt=…`) is **rejected**; the pipecat demo on `anon/` still works.
2026-09-20: is this for prod or dev 'viewer page'? moq-laserdisc.vanessa-dev.com or localhost:8000 ?
what url does the publish script use by default?

> **Loop reply 2026-09-20:** This first gate involves **no viewer page at all** —
> it's publisher-only, run in any laptop shell. `scripts/publish.sh` has **no
> default relay URL**: it exits immediately with "MOQ_RELAY_URL not set" unless
> the env var is exported, so it publishes to exactly what your shell carries
> (your notes-to-self export: the `/livestream?jwt=<publisher token>` URL). The
> rejection half is the same command with the same URL minus the `?jwt=…` query.
> Easiest way to run the whole gate: `bash tests/test-auth.sh` with the
> publisher-token URL exported — it does both halves (token publish stays up 5s;
> tokenless publish dies) and never echoes the URL. The pipecat-on-`anon/` check
> is yours (other demo, other repo).
>
> The SECOND gate below ("the public page still connects") is **prod**:
> https://moq-laserdisc.vanessa-dev.com — its `config.js` comes from the Actions
> variable you already flipped to the viewer token, so it needs a Pages deploy
> after the flip to take effect. localhost:8000 works too, with two caveats:
> `dev.sh up` writes `site/config.js` from `$MOQ_RELAY_URL` only when the file
> is MISSING, so a stale config.js keeps pointing at `/anon` — delete it first,
> or skip config.js entirely with `?relay=<viewer-token-url>` in the page URL;
> and if your shell exports the PUBLISHER token when dev.sh writes config.js,
> the secret token lands in that file — harmless locally (gitignored), just
> don't screen-share it.

2026-09-20: this script fails with this websocket connection error:
`SOURCE=test HLS=0 scripts/publish.sh`
==>
...
2026-09-20T20:04:01.618362Z  WARN moq_native::websocket: WebSocket connection failed err=failed to connect WebSocket
2026-09-20T20:04:01.618420Z  WARN moq_native::client: WebSocket connection failed err=failed to connect WebSocket

it doesn't work if I pass in the `/anon` moq relay url either.

> **Loop reply 2026-09-20 (PLAN Task 13): the relay is down — this is not a
> token or repo problem.** Timeline from your own logs:

> `logs/publish-20260920-140522.log` shows the 19:05Z (14:05 local) publish to
> `/anon` connected over QUIC (`connected version=moq-lite-04`) and streamed
> for ~30 minutes with live subscribers — then at **19:35:39Z** the session
> dropped from the RELAY side (`failed to read capsule e=UnexpectedEnd`),

> i.e. the moment the relay restarted for the §6 auth config, and nothing has
> connected since: not `/anon`, not `/livestream`, not QUIC, not WebSocket
> (`logs/dev-publish.log` at 20:01Z shows the same failure with the token URL).

> Probed from this machine just now, client-side only: DNS resolves, but
> TCP 443 is **connection refused** — the box is reachable, nothing is
> listening on 443; QUIC (UDP 443) times out identically per your logs. The
> two `WebSocket connection failed` WARN lines you quoted are just the
> fallback failing after the primary QUIC connect had already failed — red
> herring, ignore them. Almost certainly the relay container didn't come back
> up after the `[auth] key = …` 
edit (wrong in-container path to the jwk, or
> a TOML typo). **The pipecat demo on `anon/` is down too, right now.**

> Recovery runbook: **§11** — once the relay is back, re-run this gate.
> (Also: your dev stack's publisher is limping — ffmpeg lost the MoQ leg and
> is feeding RTMP only; `scripts/dev.sh down` then `up` again after recovery.)

- [ ] Gate (browser): the public page still connects — this also confirms
      `@moq/watch@0.5.2` passes the `?jwt=` query through (it wraps the url attr
      in `new URL(...)` without stripping the query; verified in its source, but
      eyes-on is the real check). If it fails only in the browser, fall back to
      `?relay=` testing and check the moq-watch version.
- [ ] If a token leaks or expires mid-prep: re-mint with the same key — no relay
      restart needed.

## 7. Publisher-machine (x86 Mac) prep — for latency measurement

The OCR harness runs on the machine that publishes, so the burned-in clock and
the local clock are the same clock.

- [x] `brew install tesseract node`; make sure Google Chrome is installed
      (Playwright launches it via `channel: "chrome"` — no browser download).
- [x] Clone the repo, then `cd tools/measure && npm install` (the only place
      `npm install` is allowed).
- [x] Gate: `bash tests/test-measure.sh` passes with **no SKIP lines** (a SKIP
      means tesseract/node/node_modules is missing).
- [ ] Load caveat: during a measurement the old machine encodes once and decodes
      two streams at the same time. If ffmpeg reports dropped frames in the
      publish log, shorten the run (`--samples 6`) and say so in `--notes`.

2026-09-20: i have questions about this "load caveat"- explain it more.

> **Loop reply 2026-09-20:** During a measurement, the x86 Mac is doing three
> CPU-heavy jobs at once: (1) **encoding** the capture in real time (ffmpeg:
> 720x480@60 h264 + the drawtext clock overlay + AAC, teed to MoQ and RTMP);
> (2) **decoding two live streams** — the harness's Chrome plays the MoQ pane
> AND the HLS pane simultaneously, plus the canvas timecode strip; (3) **OCR
> bursts** — every sample, the harness screenshots both panes, crops the clocks,
> and spawns tesseract on each crop. On the old machine these compete for the
> same cores.
>
> The failure mode: the capture card delivers frames at a fixed 60 fps; if the
> encoder can't keep pace because Chrome+tesseract are eating the CPU, ffmpeg
> **drops frames** (it logs warnings in the publish log — `logs/dev-publish.log`
> or `logs/publish-*.log`; `grep -i drop` finds them). That hurts twice: the
> published stream itself stutters, and the latency samples are then measuring
> an overloaded encoder rather than the transports — the numbers come out noisy
> and inflated for BOTH panes, which is exactly the kind of dishonest data the
> receipts exist to prevent.
>
> So the runbook is: after (or during) a run, check the publish log for drop
> warnings. If there are any, re-run shorter — `--samples 6` shrinks the OCR
> bursts and the contention window — and say so in `--notes` (e.g.
> `--notes "old x86 mac, encoder dropped frames, samples=6"`) so the committed
> run in `data.json` carries the caveat and `/results` readers know why n is
> small. No drops in the log → full-length runs are fine.


## 8. Mode A/B run review (after PLAN Task 10)
- [ ] **Gate: review `site/results/data.json` before pushing.** The loop appended two
      local runs: Mode A (`tuning.preset: "typical"`, expect HLS ~1.5 s — the
      MoQ-wins story) then Mode B (`"ragged"`, expect HLS ~0.5–0.8 s — its best
      shot at MoQ's ~0.65 s). Check both carry `tuning` receipts, note who won
      Mode B, and — since the tiles headline the LAST run — decide whether ragged
      should stay last or a real capture run should land after it before pushing.
- [ ] Push when satisfied (§1 gate applies as always).
- [ ] Measure for real: during a `SOURCE=capture` stream, on the publisher machine (§7 prep
      first) run `scripts/measure-latency.sh --source laserdisc --notes "<disc title>"`,
      review the run it appended to `site/results/data.json`, commit + push, then check
      https://moq-laserdisc.vanessa-dev.com/results/. Tick Task 7 Step 4 in `ralph/plan.md`
      in the same pass.

## 9. HLS origin: redeploy the fixed Caddyfile (clears §5's manifestLoadError)

The repo-side fix (PLAN Task 11) removed Caddy's duplicate CORS/cache header
lines from `hls-origin/Caddyfile` — MediaMTX sends its own single
allow-origin header, and browsers reject responses that carry two. The VM
still runs the old Caddyfile:

- [x] Copy the fixed file and recreate caddy (adjust the repo path on the VM):

```bash
scp hls-origin/Caddyfile <vm>:<repo>/hls-origin/Caddyfile
ssh <vm> 'cd <repo>/hls-origin && docker compose up -d --force-recreate caddy'
```

- [x] Gate: `curl -sI https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8 | grep -ci access-control-allow-origin` → prints exactly `1` (no publisher needed — the 404 carries the header too; today it prints `2`).
- [x] Gate: with a publisher up (`SOURCE=test scripts/prod.sh up`), the prod page shows the HLS pane playing — the §5 symptom is gone. Then tick §5's browser re-check or leave a dated note here if anything is still off. Re-judge the choppy MoQ only AFTER pushing the pending commits (the deployed page is stale — it predates the Mode A/B + LL-HLS tuning work).

## 10. Choppy MoQ: re-check after pushing the jitter-buffer fix (PLAN Task 12)

The 2026-09-18 choppiness is the `<moq-watch>` element's zero-buffer
`"real-time"` default; the page now sets a 150 ms jitter buffer
(`site/index.html`, commit "fix: 150ms MoQ jitter buffer + receipt").

- [ ] Push the pending commits (§1 review gate applies), wait for Pages to
      deploy, then hard-reload https://moq-laserdisc.vanessa-dev.com with a
      publisher up (`SOURCE=test scripts/prod.sh up`).
- [ ] Gate: the MoQ status line reads `… · buffer 150ms` and playback is
      smooth. To confirm the cause, compare
      `https://moq-laserdisc.vanessa-dev.com/?moqlatency=real-time` — that's
      yesterday's behavior and should stutter the same way you saw.
- [ ] If it's STILL choppy with the buffer: leave a dated note here with the
      browser used (Chrome vs Safari matters — Safari rides the WebSocket/TCP
      fallback) and whether `?moqlatency=500` helps; the loop will take it
      from there. Tick PLAN Task 12 Step 5 when satisfied.

## 11. Relay down after the §6 auth restart (2026-09-20 — blocks ALL MoQ, both demos)

The relay stopped listening when it was restarted with the new `[auth] key`
config at ~19:35Z on 2026-09-20 (evidence in the §6 loop reply: TCP 443 now
refuses connections; QUIC times out; the pipecat demo on `anon/` is down too).
On the relay box:

- [ ] Look at the container: `docker ps -a` (expect the relay Exited or
      Restarting), then `docker logs --tail 50 <relay-container>`. Expect a
      startup error. Usual suspects, in order:
      1. the `key = "…"` value in the TOML is the **host** path to
         `moq-root.jwk`, but the relay reads it **inside the container** — the
         file must be volume-mounted and the TOML must use the in-container
         path (same pattern as the cert files);

      2. the jwk file isn't mounted into the container at all;
      3. a TOML syntax error from the edit.

2026-09-20: the file is owned by ubuntu, not root, that seems to be causing the container to not
be able to read the .jwk. how do I make it owned by root
```
-rw-r--r-- 1 root   root   4829 Aug  6 22:12 fullchain.pem
-rw------- 1 ubuntu ubuntu  174 Sep 20 19:28 moq-root.jwk
-rw-r--r-- 1 root   root    241 Aug  6 22:12 privkey.pem
```

> **Loop reply 2026-09-20 (Task 13, part 2):** Close — but the blocker is the
> **mode**, not the owner. The jwk is `-rw-------` (only its owner can read
> it); the two certs the relay already reads fine are `-rw-r--r--` (anyone
> can read them). One tell from your own evidence: if the relay process ran
> as root inside the container, ownership and mode wouldn't matter at all —
> root reads everything. Since it CAN'T read the file, the container runs as
> some non-root uid, which also means `chown root` **while keeping mode 600
> would fix nothing** (then only real root could read it — still not the
> relay). The guaranteed fix is to make the jwk look exactly like the certs
> that already work, owner and mode both (adjust the path to the cert dir):
>
> ```bash
> sudo chown root:root /path/to/moq-root.jwk
> sudo chmod 644 /path/to/moq-root.jwk
> docker restart <relay-container>
> ```
>
> Trade-off, stated honestly: 644 means any local user on that VM can read
> the signing key. On this single-admin box that matches the existing
> posture (`privkey.pem` — the TLS private key — is already 644 in the same
> dir). If you'd rather keep it tight: find the uid the container actually
> runs as (`docker exec <relay-container> id -u`, or
> `docker inspect --format '{{.Config.User}}' <relay-container>`) and do
> `sudo chown <that-uid> /path/to/moq-root.jwk && sudo chmod 400 ...`
> instead — same effect, no world-read.
>
> After the restart, pick up §11's remaining boxes in order: if it still
> won't start, `docker logs --tail 50 <relay-container>` (suspects 1–3
> above); then the `/anon` publish gate; then straight to §6's
> `bash tests/test-auth.sh` gate since this is the fix-not-rollback path.

- [ ] Fix and restart — or, to get both demos back up NOW and retry auth
      later: comment out the `key = "…"` line, restart, and leave §6's gates
      unticked (the `/livestream` endpoints will then reject everything until
      the key is back, but `anon/` works again).
- [ ] Gate: from the laptop, with the `/anon` URL in `MOQ_RELAY_URL`:
      `SOURCE=test HLS=0 scripts/publish.sh` logs
      `connected version=moq-lite-04` within a few seconds and stays up.
- [ ] If you fixed (not rolled back) the key config: go straight to §6's
      first gate (`bash tests/test-auth.sh` with the publisher-token URL
      exported) and tick it there. Then say so with a dated note so the loop
      unblocks PLAN Task 13 Step 3.



## 12. Prod page MoQ dead: placeholder relay host in the deployed config.js (2026-09-22)

`https://moq-laserdisc.vanessa-dev.com/config.js` serves
`window.MOQ_RELAY_URL = "https://<relay-host>/livestream?jwt=…"` — literal
`<relay-host>` placeholder, so the page throws `Invalid URL` at
`moq.setAttribute("url", …)` and the MoQ pane never connects. The Actions
variable held a placeholder at the last Pages deploy; the correct
`gh variable set` line (real host + the **get-only** token) is already in the
notes-to-self below. Note the pages workflow does NOT redeploy on a variable
change — only on a `site/**` push or manual dispatch.

- [x] `gh variable get MOQ_RELAY_URL` — expect the placeholder
- [x] Run the `gh variable set MOQ_RELAY_URL --body '…'` line from the notes
      below (real host, get-only token)
- [x] `gh workflow run pages`
- [ ] Gate: `curl -s https://moq-laserdisc.vanessa-dev.com/config.js` shows
      `relay.vanessa-dev.com/livestream` and the get-only jwt

### human notes to self
RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=explorers4LYF" SOURCE=test scripts/publish.sh

http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8?relay=https://relay.vanessa-dev.com/anon

MOQ_RELAY_URL=https://relay.vanessa-dev.com/anon SOURCE=capture VIDEO_DEV="HDMI to U3 capture" AUDIO_DEV="HDMI to U3 capture" SIZE=720x480 FPS=60 scripts/publish.sh

MOQ_RELAY_URL=https://relay.vanessa-dev.com/anon SOURCE=capture VIDEO_DEV="HDMI to U3 capture" AUDIO_DEV="HDMI to U3 capture" SIZE=720x480 FPS=60 scripts/watch.sh

pkill -f 'ffmpeg .*testsrc2'; pkill -f 'moq --client-connect'; docker compose -f hls-origin/compose.local.yml down

relay.vanessa-dev.com deploy-oci.md info is in `pcc-transport-latency-bench` repo

moq token sign --key ~/moq-root.jwk --root livestream --publish "" --subscribe "" --expires 1795120594
export MOQ_RELAY_URL="https://relay.vanessa-dev.com/livestream?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsInB1dCI6WyIiXSwiZ2V0IjpbIiJdLCJleHAiOjE3OTUxMjA1OTR9.a95BlIjpxRGTxedEkEZPahnRwKPc4TLI3xX9CukexZo"

moq token sign --key ~/moq-root.jwk --root livestream --subscribe "" --expires 1795120594
eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsImdldCI6WyIiXSwiZXhwIjoxNzk1MTIwNTk0fQ.syJ8b8k93_Er5X7cZ86CsAcifzro_4eoiVKIF5fIqeg
gh variable set MOQ_RELAY_URL --body 'https://relay.vanessa-dev.com/livestream?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsImdldCI6WyIiXSwiZXhwIjoxNzk1MTIwNTk0fQ.syJ8b8k93_Er5X7cZ86CsAcifzro_4eoiVKIF5fIqeg'


pmset -g thermlog shows throttling events, and ps -o %cpu -p $(pgrep ffmpeg) pinned near a full core is a
  hint encode is struggling.




