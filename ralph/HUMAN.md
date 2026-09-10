# HUMAN.md — things only you can do

The ralph loop never runs these. Task 6 rewrites this file into the full ordered
checklist with exact commands; until then earlier tasks append entries under the
matching heading.

The loop never pushes to GitHub (deny list blocks `git push` and `gh`). All commits
stay local until you review them (§1 gate) and push yourself.

## 1. GitHub repo + Pages
- [ ] **Gate: review the loop's commits before anything is pushed** — `git log --oneline`,
      skim the diffs; push only when satisfied.
(Task 6 fills in the rest)

## 2. HLS origin VM
(see `docs/deploy-hls-origin.md` once Task 6 writes it)

## 3. Hardware

## 4. Browser checks

- [ ] With `SOURCE=test HLS=1 scripts/publish.sh` and local MediaMTX running (`docker compose -f hls-origin/compose.local.yml up -d`),
      serve the page (`cd site && python3 -m http.server 8000`) and
      open http://localhost:8000/?hls=http://localhost:8888/laserdisc/index.m3u8 in Chrome.
      Expect: both players show the colour bars + burned-in clock; note the MoQ vs HLS delta vs the page clocks.
- [ ] Same URL in Safari: MoQ via WebSocket fallback should connect; HLS via native player.

## 5. Public end-to-end
