# Ralph loop prompt — LaserDisc over MoQ: auth + results workflow (v2)

You are one iteration of an unattended loop. The same prompt runs every iteration;
your memory is the repo. Read, do ONE task, verify, commit, stop.

## Read first (in this order)
1. `ralph/HUMAN.md` — a dated human note under an UNCHECKED **Gate:** item is a bug
   report: before picking a task, add or amend the matching task/steps in
   `ralph/PLAN.md` so the fix gets done and re-gated.
2. `ralph/PLAN.md` — the `## Status` table, then the task list. This file is the
   source of truth for what to build and how to verify it.
3. `ralph/PROGRESS.md` — what previous iterations did, versions that worked, known
   failures. Never retry a `## Blockers` entry seen three iterations in a row.
4. `git log --oneline -20` and `git status`.

## Do
- Pick the **first task with unchecked steps**, in order. Do not touch steps marked
  `gated: HUMAN.md §N` (while that gate is unchecked) or `blocked: …`.
- Follow steps literally: write the test first, run it and see it fail, implement,
  run it and see it pass. Tick a checkbox ONLY after running the verify command
  shown — ticked means verified by running it, not by reading the code.
- Update the `## Status` table at the top of `ralph/PLAN.md` every iteration
  (statuses: pending / in progress / done / gated: HUMAN.md §N / blocked: <what>;
  refresh the `_Updated:_` line). Preserve each row's `Model` cell — the driver
  reads it to pick `--model` for the next iteration; change one only when
  re-planning that task from a HUMAN.md gate note.
- Append a dated entry to `ralph/PROGRESS.md` `## Iterations`: task, what you ran,
  result, anything the next iteration must know (versions, quirks, failing
  commands verbatim).
- Commit locally: `git add -A && git commit -m "<type>: <what>"`, type ∈
  feat/fix/docs/test. Every iteration ends with a commit, even if it only
  touches `ralph/` files.

## Hard rules (the deny list in `.claude/settings.json` enforces these too)
- NEVER push or use `gh`: no `git push`, no `git remote add`, no `gh` of any kind.
  Commits stay local; the human reviews and pushes (Gate in `ralph/HUMAN.md` §1).
- NEVER run anything that touches infrastructure or remote hosts (`ssh`, `scp`,
  `rsync` to a host, cloud CLIs, `sudo`). Write the exact command into
  `ralph/HUMAN.md` under the right section instead.
- NEVER change the relay (the host behind `MOQ_RELAY_URL`), its config, its
  version, or its box. NEVER write the relay's URL, hostname, IP, or any token
  into any file in this repo — the endpoint comes from the `MOQ_RELAY_URL` env
  var only, and `tests/test-auth.sh` must never echo it.
- Only publish to the relay under broadcast names matching `laserdisc*.hang`.
- `site/results/data.json` must never contain `"ip"`, `"hostname"`, or `"host"`
  keys — coarse geo (`city/region/country/lat/lon`) only.
- Never create a `README.md` in a subdirectory. One README, top level.
- Don't install anything globally except `brew install tesseract`; `npm install`
  only inside `tools/measure/` (never `npm i -g`, never `npx playwright install`
  — the harness drives the installed Chrome).
- `site/results/index.html` stays library-free: no external `<script src=`.
- Docker is fine for the local MediaMTX only (`hls-origin/compose.local.yml`).
  Don't run `tests/run.sh` while the dev stack is up — cleanup tears it down.
- Anything needing hardware, credentials, or a browser: append the exact
  command/instructions to `ralph/HUMAN.md` (new § if needed), mark the plan step
  `gated: HUMAN.md §N` (or `blocked: hardware`), and move to the next task.
- Kill every background process you started before finishing:
  `pkill -f 'ffmpeg .*overlay.filter'; pkill -f 'moq --client-connect'; pkill -f 'http.server 8000'; docker compose -f hls-origin/compose.local.yml down`

## When stuck
- A step fails twice in this iteration → record the exact command and error in
  `ralph/PROGRESS.md` under `## Blockers`, leave the checkbox unticked, commit,
  and stop. The next iteration will read your notes and try a different angle.

## Finish — promise protocol
Print exactly ONE of these as your last line, or neither:
- Every task in `ralph/PLAN.md` is fully checked and the full test suite passes →
  `<promise>LASER_MOQ_V2_COMPLETE</promise>`
- The ONLY remaining unchecked work is `gated:`/`blocked:` steps, each with a
  matching `ralph/HUMAN.md` entry → `<promise>HUMAN_GATE</promise>`
- Otherwise print no promise; stop after your commit and the loop calls you again.
