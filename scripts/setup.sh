#!/usr/bin/env bash
# One-time setup: pinned moq binaries (cargo), tesseract + node deps for the
# latency harness, Docker daemon check. Idempotent — rerun anytime, anything
# already in place is skipped.
set -u
cd "$(dirname "$0")/.."

MOQ_CLI_VERSION=0.11.2
MOQ_RELAY_VERSION=0.13.5

command -v cargo >/dev/null || { echo "cargo missing — install rust first: https://rustup.rs" >&2; exit 1; }
command -v brew  >/dev/null || { echo "brew missing — install homebrew first: https://brew.sh" >&2; exit 1; }
command -v npm   >/dev/null || { echo "npm missing — install node >=20 first (brew install node)" >&2; exit 1; }

# Publisher + local relay, pinned as a pair (skew connects fine and silently drops streams).
if moq --version 2>/dev/null | grep -q "$MOQ_CLI_VERSION"; then
  echo "moq-cli $MOQ_CLI_VERSION ok"
else
  cargo install moq-cli --locked --version "$MOQ_CLI_VERSION"
fi
if moq-relay --version 2>/dev/null | grep -q "$MOQ_RELAY_VERSION"; then
  echo "moq-relay $MOQ_RELAY_VERSION ok"
else
  cargo install moq-relay --locked --version "$MOQ_RELAY_VERSION"
fi

# Latency measurement: tesseract OCR + the Playwright harness deps.
if command -v tesseract >/dev/null; then
  echo "tesseract ok"
else
  brew install tesseract
fi
if [ -d tools/measure/node_modules ]; then
  echo "tools/measure deps ok"
else
  (cd tools/measure && npm install)
fi

# HLS server runs as a Docker image (bluenviron/mediamtx, pinned in
# hls-origin/compose.local.yml), pulled on first `dev.sh up`.
if docker info >/dev/null 2>&1; then
  echo "docker ok"
else
  echo "docker daemon is down — start Docker Desktop before \`dev.sh up\`"
fi

echo "setup done"
