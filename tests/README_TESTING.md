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

Stop the environment when done:

```bash
docker compose down
```

## Python Environment Setup

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
BASE_URL=http://localhost:8080/webhook pytest test_webhook.py -v

# Deactivate when done
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

## Test Data Cleanup

After testing, you may want to clean up test data:

```bash
# Using valkey-cli inside the Compose container
docker compose exec -T valkey valkey-cli --scan --pattern "test:*" | xargs docker compose exec -T valkey valkey-cli del
docker compose exec -T valkey valkey-cli --scan --pattern "batch-test:*" | xargs docker compose exec -T valkey valkey-cli del

# Using Python
python -c "
import redis
r = redis.Redis()  # redis library is compatible with Valkey
for pattern in ['test:*', 'batch-test:*', 'export-*']:
    keys = r.keys(pattern)
    if keys:
        r.delete(*keys)
print('Cleanup complete')
"
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

## Troubleshooting

### Virtual Environment Not Activating

```bash
# Make sure you're in the right directory
cd tests

# Use relative path
source venv/bin/activate
```

### Wrong Python Version

```bash
# Check which Python is being used
which python
# Should show venv path, not system Python

# If showing system Python, make sure venv is activated
source venv/bin/activate
```

### Permission Denied Errors

```bash
# If you see permission errors, you're likely using system Python
# Never use sudo with pip in a virtual environment
# Instead, make sure venv is activated (no sudo needed):
source venv/bin/activate
pip install -r requirements.txt
```

### SSL Verification Issues

```python
# Disable SSL verification (not recommended for production)
response = requests.get(BASE_URL, verify=False)
```

### Valkey Connection

Ensure Valkey is running:

```bash
docker compose exec -T valkey valkey-cli ping
# Should return: PONG
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
