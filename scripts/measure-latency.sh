#!/usr/bin/env bash
# Programmatic glass-to-glass measurement; appends a run to site/results/data.json.
set -euo pipefail
cd "$(dirname "$0")/.."
exec node tools/measure/measure.mjs "$@"
