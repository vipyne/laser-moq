#!/usr/bin/env bash
# Runs every tests/test-*.sh; exits non-zero if any fails.
set -u
cd "$(dirname "$0")/.."
fail=0
for t in tests/test-*.sh; do
  if bash "$t"; then echo "PASS $t"; else echo "FAIL $t"; fail=1; fi
done
exit $fail
