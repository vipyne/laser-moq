#!/usr/bin/env bash
# Ralph loop: feed ralph/PROMPT.md to claude until it prints the completion
# promise or MAX_ITER is reached. Each iteration is a fresh `claude -p` session;
# state lives in the repo (ralph/plan.md checkboxes, ralph/PROGRESS.md, git history).
#
#   ./ralph/ralph.sh                # default: 25 iterations, bypass permission prompts
#   MAX_ITER=5 ./ralph/ralph.sh     # cap
#   PERMS="--permission-mode acceptEdits" ./ralph/ralph.sh   # prompt-free edits, ask for bash
#
# Safety: .claude/settings.json has a permissions.deny list (aws, oci, ssh, gh api …)
# that Claude Code enforces even under --dangerously-skip-permissions. ralph/PROMPT.md
# repeats those rules. Infra work is written to ralph/HUMAN.md for you to run.
#
# Alternative (in-session, needs the plugin): claude plugin install ralph-loop@claude-plugins-official
#   then inside claude:  /ralph-loop "$(cat ralph/PROMPT.md)" --completion-promise LASER_MOQ_COMPLETE --max-iterations 25
set -u
cd "$(dirname "$0")/.."   # always run from the repo root
MAX_ITER="${MAX_ITER:-25}"
PERMS="${PERMS:---dangerously-skip-permissions}"
PROMISE="LASER_MOQ_COMPLETE"
mkdir -p ralph/logs
command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 1; }
[[ -f ralph/PROMPT.md ]] || { echo "ralph/PROMPT.md missing" >&2; exit 1; }

for ((i = 1; i <= MAX_ITER; i++)); do
  log="ralph/logs/ralph-$(date +%Y%m%d-%H%M%S)-$i.log"
  echo "=== ralph iteration $i/$MAX_ITER → $log"
  # shellcheck disable=SC2086
  claude -p "$(cat ralph/PROMPT.md)" $PERMS --output-format text 2>&1 | tee "$log"
  if grep -q "<promise>$PROMISE</promise>" "$log"; then
    echo "=== promise found after $i iteration(s). Done."
    exit 0
  fi
  # leave nothing running between iterations
  pkill -f 'ffmpeg .*testsrc2' 2>/dev/null; pkill -f 'moq --client-connect' 2>/dev/null
  sleep 3
done
echo "=== hit MAX_ITER=$MAX_ITER without the promise. See ralph/PROGRESS.md and ralph/logs/." >&2
exit 1
