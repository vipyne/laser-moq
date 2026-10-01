#!/usr/bin/env bash
# Programmatic encoder-to-glass measurement; appends a run to site/results/data.json.
set -euo pipefail
cd "$(dirname "$0")/.."
exec node tools/measure/measure.mjs "$@"
