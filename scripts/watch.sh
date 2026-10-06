#!/usr/bin/env bash
# Local subscriber for eyeballing the MoQ leg.
set -euo pipefail
MOQ_RELAY_URL="${MOQ_RELAY_URL:?not set (e.g. export MOQ_RELAY_URL=https://your-relay.example.com/anon)}"
BROADCAST="${BROADCAST:-laserdisc.hang}"
exec moq --client-connect "$MOQ_RELAY_URL" --broadcast "$BROADCAST" export fmp4 | ffplay -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -
