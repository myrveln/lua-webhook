# Webhook Service Testing

This directory contains integration tests for the webhook service using **pytest**.

The intended workflow is:

1. Start the service stack (OpenResty + Valkey) using Docker Compose
2. Run the Python tests from a local virtual environment, pointing at the Compose endpoint

## Prerequisites

- Docker + Docker Compose
- Python 3

## Start the Test Environment (Docker Compose)

From the repository root:

```bash
docker compose up -d --build
```

Verify the service is responding (default is port 8080):

```bash
curl -fsS http://localhost:8080/webhook/_stats
```

Note: the test suite includes a small startup wait (see `tests/conftest.py`) to reduce flakiness where `docker compose up -d` returns before OpenResty is accepting connections. You can tune the wait via:

```bash
export WEBHOOK_TEST_STARTUP_TIMEOUT_S=20
```

Stop the environment when done:

```bash
docker compose down
```

## Python Environment Setup

Note: if `python` on your machine is not Python 3, use `python3` in the commands below.

**Benefits:**
- Isolated environments per project
- Clean dependency management
- Reproducible across machines
- No permission issues

### Setup Project Environment

```bash
cd tests

# Create virtual environment
python -m venv venv

# Activate virtual environment
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

## Run Tests (Python venv)

```bash
cd tests

# Activate virtual environment
source venv/bin/activate

# Run tests against the Docker Compose environment
BASE_URL=http://localhost:8080/webhook pytest -v \
    test_webhook.py \
    test_events.py \
    test_ws.py

# Deactivate when done
deactivate
```

Notes:

- `test_webhook.py`, `test_events.py`, and `test_ws.py` automatically include `X-API-Key` on all requests if you set `WEBHOOK_TEST_API_KEY`. This allows running the same functional suite against an auth-enabled deployment.
- `test_events.py` consumes Valkey/Redis Pub/Sub on the `webhook:events` channel. With the default Compose stack, this is available on `localhost:6379`. If you run Valkey elsewhere, set `VALKEY_HOST`/`VALKEY_PORT` (or `REDIS_HOST`/`REDIS_PORT`).
- `test_ws.py` validates the real WebSocket endpoint at `GET /webhook/_ws`, which streams the same events as the Pub/Sub channel.

## Run Tests With Authentication Enabled

The service supports optional API key authentication (see the repo README). The test suite includes additional authentication tests in `test_auth.py`.

### 1) Start Docker Compose with auth enabled

From the repository root:

```bash
# Require an API key for all endpoints except _stats (so healthchecks still work)
export WEBHOOK_API_KEYS="test-api-key"
export WEBHOOK_AUTH_EXEMPT="_stats"

docker compose up -d --build
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

### 2) Run the auth tests

From the repository root (or any directory), with your venv available:

```bash
cd tests
source venv/bin/activate

BASE_URL=http://localhost:8080/webhook \
WEBHOOK_TEST_API_KEY="test-api-key" \
pytest -v test_auth.py
```

## Run Config Module Tests

The repository includes integration tests that validate loading settings from a local override module (`WEBHOOK_CONFIG_MODULE`).

The default `docker-compose.yml` defines a second OpenResty instance (`openresty_config`) on port 8081 that mounts a test module from `tests/fixtures/webhook_config_test.lua`.

Start the stack (this will bring up both `openresty` and `openresty_config`):

```bash
docker compose up -d --build
```

Then run the config tests:

```bash
cd tests
source venv/bin/activate

BASE_URL_CONFIG=http://localhost:8081/webhook \
WEBHOOK_TEST_CONFIG_API_KEY="test-config-key" \
pytest -v test_config.py
```

### Run the full suite (CI parity)

This runs *all* tests, including config-module tests:

```bash
cd tests
source venv/bin/activate

BASE_URL=http://localhost:8080/webhook \
BASE_URL_CONFIG=http://localhost:8081/webhook \
WEBHOOK_TEST_API_KEY="test-api-key" \
WEBHOOK_TEST_CONFIG_API_KEY="test-config-key" \
pytest -v

deactivate
```

### 3) Run the full integration suite with auth enabled (recommended)

With `WEBHOOK_TEST_API_KEY` set, the main integration tests will authenticate automatically.

```bash
cd tests
source venv/bin/activate

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

This is useful to ensure backwards compatibility for deployments that do not require an API key.

```bash
cd ..
docker compose down

# Start compose with auth explicitly disabled for this invocation (avoids relying on your shell
# environment state).
WEBHOOK_API_KEYS= WEBHOOK_AUTH_EXEMPT= docker compose up -d --build

cd tests
source venv/bin/activate

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
# Should show: .../tests/venv/bin/python

# Verify correct Python version
python --version

# List installed packages
pip list
```

### Adding New Dependencies

```bash
# Activate environment
source venv/bin/activate

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
rm -rf venv

# Create fresh environment
python -m venv venv
source venv/bin/activate
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
