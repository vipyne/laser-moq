# Ralph loop prompt — LaserDisc over MoQ

You are one iteration of an unattended loop. The same prompt runs every iteration;
your memory is the repo. Read, do ONE task, verify, commit, stop.

## Read first (in this order)
1. `ralph/PROGRESS.md` — what previous iterations did, versions that worked, known failures.
2. `ralph/plan.md` — the task list with checkboxes. This is the source of truth for
   what to build and how to verify it.
3. `docs/superpowers/specs/2026-08-29-laserdisc-moq-livestream-design.md` — only if a
   task's intent is unclear.
4. `git log --oneline -20` and `git status`.

## Do
- Pick the **first task with unchecked steps** in the plan (Tasks 1→7, in order). Do not
  skip ahead unless the task is marked `blocked: hardware`.
- Follow its steps literally: write the test first, run it and see it fail, implement,
  run it and see it pass, commit. Use the exact code in the plan unless it is
  demonstrably wrong on this machine — if you change it, say why in `ralph/PROGRESS.md`.
- Tick each step's checkbox in the plan file as you complete it. Ticked = verified by
  running the command shown, not by reading the code.
- Before finishing, run `bash tests/run.sh` (once it exists) and make sure nothing that
  passed before is broken.
- Append a short dated entry to `ralph/PROGRESS.md`: task, what you ran, result, anything
  the next iteration must know (versions, quirks, failing commands verbatim).
- Commit with `git add -A && git commit -m "<type>: <what>"` where type ∈ feat/fix/docs/test.
  Every iteration ends with a commit, even if it's only `ralph/PROGRESS.md`.

## Hard rules (a deny list in `.claude/settings.json` enforces these too)
- NEVER run `aws`, `oci`, `ssh`, `scp`, `rsync` to a host, `gh repo create`, `gh api`,
  `gh pages`, `sudo`, or anything that touches infrastructure. Write the exact command
  into `ralph/HUMAN.md` under the right section instead.
- NEVER push to GitHub: no `git push`, no `git remote add`, no `gh` of any kind.
  Commit locally only. The human reviews the commits and pushes (gate in
  `ralph/HUMAN.md` §1).
- NEVER change the relay (the host behind `MOQ_RELAY_URL`), its config, its version,
  or its box. NEVER write the relay's URL, hostname, or IP into any file in this
  repo — it comes from the `MOQ_RELAY_URL` env var only.
- Only publish to the relay under broadcast names matching `laserdisc*.hang`.
- Never create a `README.md` in a subdirectory. One README, top level.
- Don't install anything globally except `cargo install moq-cli` (and the
  `--version 0.8.4` fallback described in Task 1).
- Docker is fine for the local MediaMTX only. Always `docker compose … down` what you
  started.
- Kill every background process you started (ffmpeg, moq, python http.server) before
  finishing: `pkill -f 'ffmpeg .*testsrc2'; pkill -f 'moq --client-connect'`.

## When stuck
- A step fails twice in this iteration → record the exact command and error in
  `ralph/PROGRESS.md` under `## Blockers`, leave the checkbox unticked, commit, and stop.
  The next iteration will read your notes and try a different angle.
- Something needs hardware (the Pengo capture card) or a human (a browser check,
  infra) → append to `ralph/HUMAN.md`, mark the step `blocked: hardware` /
  `blocked: human` in the plan, commit, and move to the next task.
- If `ralph/PROGRESS.md` shows the same blocker three iterations in a row, do not retry
  it; work on whatever else is unchecked, or finish.

## Finish
When Tasks 1–6 are fully checked, `bash tests/run.sh` passes, and Task 7 is checked or
marked `blocked: hardware` with a `ralph/HUMAN.md` entry, print exactly:

<promise>LASER_MOQ_COMPLETE</promise>

Otherwise just stop after your commit; the loop will call you again.
