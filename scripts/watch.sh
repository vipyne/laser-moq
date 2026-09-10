#!/usr/bin/env bash
# Local subscriber for eyeballing the MoQ leg.
set -euo pipefail
RELAY_URL="${RELAY_URL:-${MOQ_RELAY_URL}}"
BROADCAST="${BROADCAST:-laserdisc.hang}"
exec moq --client-connect "$RELAY_URL" --broadcast "$BROADCAST" export fmp4 | ffplay -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -
