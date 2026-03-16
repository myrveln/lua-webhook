# Webhook Service Testing

This directory contains integration tests for the webhook service using **pytest**.

The intended workflow is:

1. Start the service stack (OpenResty + Valkey) using Docker Compose
2. Run the Python tests from a local virtual environment, pointing at the Compose endpoint

## Prerequisites

- Docker + Docker Compose
- Python 3

## Quick Start (Makefile)

All local testing is driven via the Makefile in this directory.

From `./tests`:

```bash
# CI parity: runs no-auth, auth, and all opt-in modes
make test all

# Run a single mode
make test noauth
make test auth
make test cors
make test rate_limit
make test hash_auth
make test callback_allowlist
```

## Python Environment Setup

Note: if `python` on your machine is not Python 3, use `python3` in the commands below.

**Benefits:**
- Isolated environments per project
- Clean dependency management
- Reproducible across machines
- No permission issues

### Setup Project Environment

The Makefile creates a local venv at `tests/.venv` automatically and installs `tests/requirements.txt`.

## Run Tests (manual / advanced)

If you prefer manual control, the Makefile ultimately runs `docker compose up -d --build` from the repo root and invokes pytest from the venv.

Notes:

- `test_webhook.py`, `test_events.py`, and `test_ws.py` automatically include `X-API-Key` on all requests if you set `WEBHOOK_TEST_API_KEY`. This allows running the same functional suite against an auth-enabled deployment.
- `test_events.py` consumes Valkey/Redis Pub/Sub on the `webhook:events` channel. With the default Compose stack, this is available on `localhost:6379`. If you run Valkey elsewhere, set `WEBHOOK_REDIS_HOST`/`WEBHOOK_REDIS_PORT`.
- `test_ws.py` validates the real WebSocket endpoint at `GET /webhook/_ws`, which streams the same events as the Pub/Sub channel.

## Run Tests With Authentication Enabled

The service supports optional API key authentication (see the repo README). The test suite includes additional authentication tests in `test_auth.py`.

### 1) Run auth mode

From `./tests`:

```bash
make test auth
```

Quick checks:

```bash
# _stats should be reachable without a key
curl -fsS http://localhost:8080/webhook/_stats

# Other endpoints should require a key
curl -i http://localhost:8080/webhook
curl -i -H "X-API-Key: definitely-wrong" http://localhost:8080/webhook
curl -i -H "X-API-Key: test-api-key" http://localhost:8080/webhook
```

The Makefile starts Compose with `WEBHOOK_API_KEYS=test-api-key` and `WEBHOOK_AUTH_EXEMPT=_stats`, and runs the full integration suite with `WEBHOOK_TEST_API_KEY` set.

## Run Config Module Tests

The repository includes integration tests that validate loading settings from a local override module (`WEBHOOK_CONFIG_MODULE`).

The default `docker-compose.yml` defines a second OpenResty instance (`openresty_config`) on port 8081 that mounts a test module from `tests/fixtures/webhook_config_test.lua`.

These are included in all Makefile modes that run the main suite (`noauth` and `auth`) and in `make test all`.

### Run the full suite (CI parity)

```bash
cd tests
make test all
```
## Opt-in feature coverage (CI)

Some features are enabled only via environment/module config at service startup (CORS, built-in rate limiting, hashed API keys, callback allowlists). These are covered in CI by running additional Compose passes with different env vars.

Locally, the corresponding tests are skipped unless you set `WEBHOOK_TEST_OPTIN` to the scenario name *and* start the service with the matching config.

Examples:

- CORS: `make test cors`
- Rate limiting: `make test rate_limit`
- Hashed auth: `make test hash_auth`
- Callback allowlist: `make test callback_allowlist`

### 3) Run the full integration suite with auth enabled (recommended)

With `WEBHOOK_TEST_API_KEY` set, the main integration tests will authenticate automatically.

```bash
cd tests
source .venv/bin/activate

BASE_URL=http://localhost:8080/webhook \
WEBHOOK_TEST_API_KEY="test-api-key" \
pytest -v \
    test_webhook.py \
    test_events.py \
    test_ws.py \
    test_auth.py

deactivate
```

### 4) Optional: run the same suite with auth disabled

This is useful to validate deployments that do not require an API key.

```bash
cd ..
docker compose down

# Start compose with auth explicitly disabled for this invocation (avoids relying on your shell
# environment state).
WEBHOOK_API_KEYS= WEBHOOK_AUTH_EXEMPT= docker compose up -d --build

cd tests
source .venv/bin/activate

BASE_URL=http://localhost:8080/webhook pytest -v \
    test_webhook.py \
    test_events.py \
    test_ws.py

deactivate
```

### Notes

- `BASE_URL` defaults to the local Docker Compose environment (`http://localhost:8080/webhook`).
- To run against a different environment, pass `BASE_URL=...` when invoking pytest.
- If you changed the Compose port mapping, update the URL accordingly.

## Test Organization

### Test Classes

| Class | Description | Tests |
|-------|-------------|-------|
| `TestWebhookBasicOperations` | CRUD operations | POST, GET, DELETE, PATCH |
| `TestWebhookErrors` | Error handling | Missing body, invalid JSON, 404s |
| `TestWebhookBatchOperations` | Batch operations | Batch create, batch delete |
| `TestWebhookAdvancedFeatures` | Advanced features | Search, stats, replay, callbacks |
| `TestWebhookExportImport` | Backup/restore | Export, import functionality |
| `TestWebhookMetrics` | Monitoring | Prometheus metrics |
| `TestWebhookLargePayloads` | Performance | Large JSON handling |
| `TestWebhookAuthentication` | Authentication | API key enforcement, exemptions |
| `TestWebhookEventPublishing` | Events | Valkey/Redis Pub/Sub webhook events |
| `TestWebhookConfigModule` | Configuration | Config-module overrides and limits |

Note: `test_ws.py` is function-based (no test class) and covers the WebSocket endpoint.

### Running Specific Test Categories

```bash
# Only basic operations
pytest test_webhook.py::TestWebhookBasicOperations -v

# Only error handling
pytest test_webhook.py::TestWebhookErrors -v

# Only batch operations
pytest test_webhook.py::TestWebhookBatchOperations -v
```

## Advanced Usage

### Generate HTML Report

```bash
pytest test_webhook.py --html=report.html --self-contained-html
```

### Run with Different Verbosity

```bash
# Minimal output
pytest test_webhook.py -q

# Standard output
pytest test_webhook.py

# Verbose output
pytest test_webhook.py -v

# Very verbose (show all test details)
pytest test_webhook.py -vv
```

### Stop on First Failure

```bash
pytest test_webhook.py -x
```

### Run Last Failed Tests

```bash
pytest test_webhook.py --lf
```

### Parallel Execution

```bash
# Install pytest-xdist
pip install pytest-xdist

# Run tests in parallel
pytest test_webhook.py -n auto
```

## Environment Management

### Checking Your Setup

```bash
# Verify virtual environment is active (you should see (venv) in prompt)
which python
# Should show: .../tests/.venv/bin/python

# Verify correct Python version
python --version

# List installed packages
pip list
```

### Adding New Dependencies

```bash
# Activate environment
source .venv/bin/activate

# Install new package
pip install <package-name>

# Update requirements.txt
pip freeze > requirements.txt
```

### Recreating Environment

If your environment gets corrupted:

```bash
# Deactivate current environment
deactivate

# Remove old environment
rm -rf .venv

# Create fresh environment
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Best Practices

1. **Run tests before commits**: `pytest test_webhook.py -v`
2. **Check coverage**: `pytest test_webhook.py --cov=.`
3. **Use fixtures** for common setup/teardown
4. **Clean test data** after test runs
5. **Mock external services** when appropriate
6. **Test both success and failure cases**
7. **Keep tests independent** and idempotent

## Contributing

When adding new features:

1. Add corresponding tests to `test_webhook.py`
2. Update this README if needed
3. Ensure all tests pass
4. Maintain test coverage above 80%
