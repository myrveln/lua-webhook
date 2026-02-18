#!/usr/bin/env bash
set -euo pipefail

# Bring up the docker compose stack using healthchecks.
# Requires a Compose version that supports `up --wait`.
#
# Usage:
#   bash .github/scripts/compose_up.sh [--wait-timeout-seconds]
#
# You can also override the timeout via COMPOSE_WAIT_TIMEOUT.

wait_timeout="${COMPOSE_WAIT_TIMEOUT:-60}"

if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  wait_timeout="$1"
  shift
fi

# Ensure we always emit useful diagnostics on failures.
if ! docker compose up -d --build --wait --wait-timeout "$wait_timeout" "$@"; then
  docker compose ps || true
  docker compose logs || true
  exit 1
fi
