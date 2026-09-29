# HUMAN.md — things only you can do

Ordered. Each item has the exact command(s). The ralph loop never runs these,
but it reads this file FIRST every iteration.

Conventions:
- **Gate:** items stop the loop. When only gated/blocked work remains, the loop
  prints `<promise>HUMAN_GATE</promise>` and `ralph.sh` exits pointing here.
  Do the item, tick its box, then rerun:

  ```bash
  ./ralph/ralph.sh
  ```

- **Gate failed?** Leave the box UNCHECKED and write a dated note directly under
  the item — what you ran, what you saw, verbatim errors. The next loop run
  treats that note as a bug report and turns it into plan work.

The relay endpoint is deliberately nowhere in this repo. In any shell that runs
`scripts/` or `tests/`:

```bash
export MOQ_RELAY_URL=…
```

## 6. MoQ publish auth (optional hardening — do after §1–§5 work)

Locks MoQ publishing behind a token while viewing stays public, without touching
the `anon/` prefix (the other demo on the relay keeps working). Verified against
moq-relay 0.13.5 + moq-cli 0.11.0: token wire format matches (`root`/`put`/`get`
claims identical between the CLI's signer and the relay's verifier), and the relay
reads `?jwt=` from the connect URL. No repo code changes — tokens travel inside
`MOQ_RELAY_URL`.

Key generated, relay configured, tokens minted, endpoints flipped. Remaining
gates blocked on §11 (relay down since the auth restart) — recover there first.

- [ ] Gate (publisher CLI — no viewer page involved):

  ```bash
  SOURCE=test HLS=0 scripts/publish.sh
  ```

  streams; the same command with the jwt stripped from `MOQ_RELAY_URL` (same URL,
  no `?jwt=…`) is **rejected**; the pipecat demo on `anon/` still works.
  Easiest way to run the whole gate, with the publisher-token URL exported —
  it does both halves and never echoes the URL:

  ```bash
  bash tests/test-auth.sh
  ```
2026-09-23: `FAIL: tokenless publish was NOT rejected`

> **Loop reply 2026-09-23 (Task 14):** That FAIL was the TEST lying, not the
> relay — and the relay is enforcing correctly now. The old test judged both
> halves by exit code alone (pipeline must die within `timeout 5`), which
> can't tell "streaming fine" from "hanging on a dead relay": when the relay
> is down/unreachable, BOTH halves hang past 5s, so the jwt half spuriously
> passes and the tokenless half prints exactly your FAIL. You most likely ran
> it while the relay was still mid-§11-recovery. `tests/test-auth.sh` now
> requires moq's `connected version=moq-lite-04` stderr line as connect
> proof: jwt half must log it, tokenless half must NOT (a down relay now
> says so: "authorized publish never connected … see §11"). Verified against
> a black-hole address to confirm the down-relay case reports correctly.
>
> Ran the whole gate for real from this machine today:
> `bash tests/test-auth.sh` → `auth ok: token publishes, no-token rejected`
> (tokenless rejection is explicit — relay says `unauthorized` in ~1s), and a
> tokenless publish to the `anon/` prefix still connects (pipecat demo
> unaffected). So your §11 fix worked. Rerun `bash tests/test-auth.sh` with
> the publisher-token URL exported and tick this gate; §11's publish gate is
> implicitly satisfied too (authorized connect = relay up).

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

- [ ] Load caveat: during a measurement the old machine encodes once and decodes
      two streams at the same time. Check the publish log for dropped frames:

  ```bash
  grep -i drop logs/publish-*.log logs/dev-publish.log
  ```

  If ffmpeg reported drops, shorten the run (`--samples 6`) and say so in
  `--notes`.

## 8. Mode A/B run review (after PLAN Task 10)
- [ ] **Gate: review `site/results/data.json` before pushing.** The loop appended two
      local runs: Mode A (`tuning.preset: "typical"`, expect HLS ~1.5 s — the
      MoQ-wins story) then Mode B (`"ragged"`, expect HLS ~0.5–0.8 s — its best
      shot at MoQ's ~0.65 s). Check both carry `tuning` receipts, note who won
      Mode B, and — since the tiles headline the LAST run — decide whether ragged
      should stay last or a real capture run should land after it before pushing.
- [ ] Push when satisfied (§1 gate applies as always).
- [ ] Measure for real: during a `SOURCE=capture` stream, on the publisher
      machine (§7 prep first) run:

  ```bash
  scripts/measure-latency.sh --source laserdisc --notes "<disc title>"
  ```

  Review the run it appended to `site/results/data.json`, commit + push, then
  check https://moq-laserdisc.vanessa-dev.com/results/. Tick Task 7 Step 4 in
  `ralph/plan.md` in the same pass.

## 10. Choppy MoQ: re-check after pushing the jitter-buffer fix (PLAN Task 12)

The 2026-09-18 choppiness is the `<moq-watch>` element's zero-buffer
`"real-time"` default; the page now sets a 150 ms jitter buffer
(`site/index.html`, commit "fix: 150ms MoQ jitter buffer + receipt").

- [ ] Push the pending commits (§1 review gate applies), wait for Pages to
      deploy, then hard-reload https://moq-laserdisc.vanessa-dev.com with a
      publisher up:

  ```bash
  SOURCE=test scripts/prod.sh up
  ```

- [ ] Gate: the MoQ status line reads `… · buffer 150ms` and playback is
      smooth. To confirm the cause, compare
      https://moq-laserdisc.vanessa-dev.com/?moqlatency=real-time — that's
      yesterday's behavior and should stutter the same way you saw.
- [ ] If it's STILL choppy with the buffer: leave a dated note here with the
      browser used (Chrome vs Safari matters — Safari rides the WebSocket/TCP
      fallback) and whether `?moqlatency=500` helps; the loop will take it
      from there. Tick PLAN Task 12 Step 5 when satisfied.

## 11. Relay down after the §6 auth restart (2026-09-20 — blocks ALL MoQ, both demos)

The relay stopped listening when it was restarted with the new `[auth] key`
config at ~19:35Z on 2026-09-20 (TCP 443 refuses connections; QUIC times out;
the pipecat demo on `anon/` is down too). On the relay box:

- [ ] Look at the container (expect the relay Exited or Restarting, then a
      startup error in the logs):

  ```bash
  docker ps -a
  docker logs --tail 50 <relay-container>
  ```

  Usual suspects, in order:
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
> runs as:
>
> ```bash
> docker exec <relay-container> id -u
> # or
> docker inspect --format '{{.Config.User}}' <relay-container>
> ```
>
> then:
>
> ```bash
> sudo chown <that-uid> /path/to/moq-root.jwk
> sudo chmod 400 /path/to/moq-root.jwk
> ```
>
> instead — same effect, no world-read.
>
> After the restart, pick up §11's remaining boxes in order: if it still
> won't start, check the logs (suspects 1–3 above):
>
> ```bash
> docker logs --tail 50 <relay-container>
> ```
>
> then the `/anon` publish gate; then straight to §6's `bash tests/test-auth.sh`
> gate since this is the fix-not-rollback path.

- [ ] Fix and restart — or, to get both demos back up NOW and retry auth
      later: comment out the `key = "…"` line, restart, and leave §6's gates
      unticked (the `/livestream` endpoints will then reject everything until
      the key is back, but `anon/` works again).
- [ ] Gate: from the laptop, with the `/anon` URL in `MOQ_RELAY_URL`:

  ```bash
  SOURCE=test HLS=0 scripts/publish.sh
  ```

  logs `connected version=moq-lite-04` within a few seconds and stays up.
- [ ] If you fixed (not rolled back) the key config: go straight to §6's
      first gate, with the publisher-token URL exported:

  ```bash
  bash tests/test-auth.sh
  ```

  Tick it there, then say so with a dated note so the loop unblocks
  PLAN Task 13 Step 3.

### human notes to self

```bash
RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=explorers4LYF" SOURCE=test scripts/publish.sh
```

http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8?relay=https://relay.vanessa-dev.com/anon

```bash
MOQ_RELAY_URL=https://relay.vanessa-dev.com/anon SOURCE=capture VIDEO_DEV="HDMI to U3 capture" AUDIO_DEV="HDMI to U3 capture" SIZE=720x480 FPS=60 scripts/publish.sh
```

```bash
MOQ_RELAY_URL=https://relay.vanessa-dev.com/anon SOURCE=capture VIDEO_DEV="HDMI to U3 capture" AUDIO_DEV="HDMI to U3 capture" SIZE=720x480 FPS=60 scripts/watch.sh
```

```bash
pkill -f 'ffmpeg .*testsrc2'; pkill -f 'moq --client-connect'; docker compose -f hls-origin/compose.local.yml down
```

relay.vanessa-dev.com deploy-oci.md info is in `pcc-transport-latency-bench` repo

```bash
moq token sign --key ~/moq-root.jwk --root livestream --publish "" --subscribe "" --expires 1795120594
```

```bash
export MOQ_RELAY_URL="https://relay.vanessa-dev.com/livestream?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsInB1dCI6WyIiXSwiZ2V0IjpbIiJdLCJleHAiOjE3OTUxMjA1OTR9.a95BlIjpxRGTxedEkEZPahnRwKPc4TLI3xX9CukexZo"
```

```bash
moq token sign --key ~/moq-root.jwk --root livestream --subscribe "" --expires 1795120594
```

eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsImdldCI6WyIiXSwiZXhwIjoxNzk1MTIwNTk0fQ.syJ8b8k93_Er5X7cZ86CsAcifzro_4eoiVKIF5fIqeg

```bash
gh variable set MOQ_RELAY_URL --body 'https://relay.vanessa-dev.com/livestream?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjE0NmEyMDBlMDI4MWE4YTcifQ.eyJyb290IjoibGl2ZXN0cmVhbSIsImdldCI6WyIiXSwiZXhwIjoxNzk1MTIwNTk0fQ.syJ8b8k93_Er5X7cZ86CsAcifzro_4eoiVKIF5fIqeg'
```

`pmset -g thermlog` shows throttling events, and `ps -o %cpu -p $(pgrep ffmpeg)` pinned near a full core is a hint encode is struggling.
