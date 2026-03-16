#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"

ROOT_DIR="${ROOT_DIR:-..}"
COMPOSE="${COMPOSE:-docker compose}"

BASE_URL="${BASE_URL:-http://localhost:8080/webhook}"
BASE_URL_CONFIG="${BASE_URL_CONFIG:-http://localhost:8081/webhook}"

TEST_API_KEY="${TEST_API_KEY:-test-api-key}"
TEST_CONFIG_API_KEY="${TEST_CONFIG_API_KEY:-test-config-key}"

PYTEST_ARGS="${PYTEST_ARGS:-}"

PY_BIN="python"
if [[ -x ".venv/bin/python" ]]; then
  PY_BIN=".venv/bin/python"
fi

compose_down() {
  (cd "${ROOT_DIR}" && ${COMPOSE} down -v) >/dev/null 2>&1 || true
}

compose_up() {
  (cd "${ROOT_DIR}" && env "$@" ${COMPOSE} up -d --build)
}

wait_for_http_200() {
  local url="$1"
  local attempts="${2:-60}"
  local sleep_s="${3:-0.25}"

  local i=1
  while [[ $i -le $attempts ]]; do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
    i=$((i + 1))
  done

  echo "Timed out waiting for service: $url" >&2
  (cd "${ROOT_DIR}" && ${COMPOSE} ps) >&2 || true
  (cd "${ROOT_DIR}" && ${COMPOSE} logs --no-color --tail=200 openresty openresty_config valkey) >&2 || true
  return 1
}

run_mode() {
  local m="$1"
  case "$m" in
    all)
      run_mode noauth
      run_mode auth
      run_mode cors
      run_mode rate_limit
      run_mode hash_auth
      run_mode callback_allowlist
      ;;

    noauth)
      compose_down
      compose_up WEBHOOK_API_KEYS= WEBHOOK_AUTH_EXEMPT=
      wait_for_http_200 "${BASE_URL}/_stats"
      wait_for_http_200 "${BASE_URL_CONFIG}/_stats"
      BASE_URL="$BASE_URL" BASE_URL_CONFIG="$BASE_URL_CONFIG" \
        WEBHOOK_TEST_CONFIG_API_KEY="$TEST_CONFIG_API_KEY" \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_webhook.py test_events.py test_ws.py test_config.py
      compose_down
      ;;

    auth)
      compose_down
      compose_up WEBHOOK_API_KEYS="$TEST_API_KEY" WEBHOOK_AUTH_EXEMPT=_stats
      wait_for_http_200 "${BASE_URL}/_stats"
      wait_for_http_200 "${BASE_URL_CONFIG}/_stats"
      BASE_URL="$BASE_URL" BASE_URL_CONFIG="$BASE_URL_CONFIG" \
        WEBHOOK_TEST_API_KEY="$TEST_API_KEY" \
        WEBHOOK_TEST_CONFIG_API_KEY="$TEST_CONFIG_API_KEY" \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_webhook.py test_events.py test_ws.py test_auth.py test_config.py
      compose_down
      ;;

    cors)
      compose_down
      compose_up WEBHOOK_API_KEYS="$TEST_API_KEY" WEBHOOK_AUTH_EXEMPT=_stats WEBHOOK_CORS_ALLOW_ORIGIN='*'
      wait_for_http_200 "${BASE_URL}/_stats"
      BASE_URL="$BASE_URL" WEBHOOK_TEST_API_KEY="$TEST_API_KEY" WEBHOOK_TEST_OPTIN=cors \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_optin_cors.py
      compose_down
      ;;

    rate_limit)
      compose_down
      compose_up WEBHOOK_API_KEYS="$TEST_API_KEY" WEBHOOK_AUTH_EXEMPT=_stats \
        WEBHOOK_RATE_LIMIT_ENABLED=true WEBHOOK_RATE_LIMIT_WINDOW_S=60 WEBHOOK_RATE_LIMIT_MAX_REQUESTS=3 \
        WEBHOOK_RATE_LIMIT_EXEMPT=_stats,_metrics
      wait_for_http_200 "${BASE_URL}/_stats"
      BASE_URL="$BASE_URL" WEBHOOK_TEST_API_KEY="$TEST_API_KEY" WEBHOOK_TEST_OPTIN=rate_limit \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_optin_rate_limit.py
      compose_down
      ;;

    hash_auth)
      compose_down
      local hash
      hash=$($PY_BIN -c "import hashlib; print(hashlib.sha256(b'${TEST_API_KEY}').hexdigest())")
      compose_up WEBHOOK_API_KEYS= WEBHOOK_AUTH_EXEMPT=_stats WEBHOOK_API_KEY_HASHES="$hash"
      wait_for_http_200 "${BASE_URL}/_stats"
      BASE_URL="$BASE_URL" WEBHOOK_TEST_API_KEY="$TEST_API_KEY" WEBHOOK_TEST_OPTIN=hash_auth \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_optin_hash_auth.py
      compose_down
      ;;

    callback_allowlist)
      compose_down
      compose_up WEBHOOK_API_KEYS="$TEST_API_KEY" WEBHOOK_AUTH_EXEMPT=_stats WEBHOOK_CALLBACK_URL_ALLOWLIST=example.com
      wait_for_http_200 "${BASE_URL}/_stats"
      BASE_URL="$BASE_URL" WEBHOOK_TEST_API_KEY="$TEST_API_KEY" WEBHOOK_TEST_OPTIN=callback_allowlist \
        "$PY_BIN" -m pytest -v ${PYTEST_ARGS} test_optin_callback_allowlist.py
      compose_down
      ;;

    *)
      echo "Unknown mode: $m"
      echo "Valid modes: all noauth auth cors rate_limit hash_auth callback_allowlist"
      exit 2
      ;;
  esac
}

run_mode "$MODE"
