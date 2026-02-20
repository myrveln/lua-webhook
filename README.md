# lua-webhook

[![codecov](https://codecov.io/gh/myrveln/lua-webhook/branch/master/graph/badge.svg)](https://codecov.io/gh/myrveln/lua-webhook)

A high-performance, RESTful webhook storage service built with OpenResty/Nginx and Lua, backed by Valkey. Store, retrieve, and manage webhook payloads with advanced features like batch operations, search, and expiry notifications.

## Features

- 🚀 **RESTful API** - Clean, intuitive REST endpoints
- 📦 **Batch Operations** - Create or delete multiple webhooks in one request
- 🔍 **Full-Text Search** - Search across all webhook payloads
- 📊 **Statistics** - Real-time storage and usage metrics
- ⏰ **TTL Management** - Automatic expiration with configurable time-to-live
- 🔔 **Callback URLs** - Register callbacks for expiry notifications
- 🏷️ **Categories** - Organize webhooks into categories
- 🎯 **Query Filtering** - Filter webhooks by timestamp
- 📝 **PATCH Support** - Update TTL and metadata without full replacement
- 🛡️ **Error Codes** - Comprehensive error handling with specific error codes
- 💾 **Storage Limits** - Configurable storage limits with quota management
- 📈 **Response Headers** - Storage metrics in HTTP headers
- 🔄 **Webhook Replay** - Replay webhooks to recreate them with new keys
- 📤 **Export/Import** - Backup and restore webhooks with full data preservation
- 📡 **Realtime Events** - Valkey/Redis pub/sub (`webhook:events`) and WebSocket stream (`GET /webhook/_ws`)
- 📊 **Prometheus Metrics** - Built-in metrics endpoint for monitoring

## Requirements

- [OpenResty](https://openresty.org/) (or Nginx with Lua support)
- Valkey 7.2+ (or Redis 3.0+)
- `lua-resty-redis` library (included with OpenResty)
- `lua-cjson` library (included with OpenResty)

## Installation

### Install with LuaRocks

If you already have LuaRocks set up for your OpenResty/Lua environment, you can install `lua-webhook` directly:

```bash
# Install the latest release
luarocks install lua-webhook

# Or install a specific release (LuaRocks uses "<version>-<rockspec_revision>")
# luarocks install lua-webhook 0.1.0-1
```

Note: OpenResty typically runs LuaJIT (Lua 5.1 compatible). Make sure your LuaRocks installation targets the same Lua/LuaJIT that OpenResty is using.

This project is distributed as a single Lua file (`webhook.lua`). After installation, locate it so you can reference it from your Nginx/OpenResty config:

```bash
# Prints the installed path to the module file (e.g. .../share/lua/5.1/webhook.lua)
luarocks which webhook
```

Then edit [examples/nginx-example.conf](examples/nginx-example.conf) to point at that file path (or copy the file into your preferred location and point Nginx/OpenResty at the copy).

### Configuration

If you installed via LuaRocks, avoid editing the installed `webhook.lua` directly (a `luarocks upgrade` may replace it). Instead, configure the service via environment variables and/or a local override module.

**Option A: Environment variables (recommended)**

Configure values like Redis/Valkey and defaults using env vars. In OpenResty, remember to allowlist env vars in `nginx.conf` (e.g. `env WEBHOOK_DEFAULT_TTL;`).

Common variables:

- `VALKEY_HOST` / `VALKEY_PORT` (or `REDIS_HOST` / `REDIS_PORT`)
- `WEBHOOK_DEFAULT_CATEGORY`, `WEBHOOK_DEFAULT_TTL`, `WEBHOOK_MAX_BODY_SIZE`, `WEBHOOK_TOTAL_PAYLOAD_LIMIT`
- `WEBHOOK_API_KEYS`, `WEBHOOK_AUTH_EXEMPT` (for auth)

**Option B: Local override module**

Create a `webhook_config.lua` file somewhere stable (e.g. `/etc/openresty/lua/webhook_config.lua`) and add that directory to `lua_package_path`. The module should return a Lua table (see [examples/webhook_config.lua](examples/webhook_config.lua)):

```lua
-- /etc/openresty/lua/webhook_config.lua
return {
  DEFAULT_TTL = 86400,
  TOTAL_PAYLOAD_LIMIT = 100 * 1024 * 1024,
  API_KEYS = {"changeme"},
  AUTH_EXEMPT = {"_metrics", "_stats"},
}
```

Then OpenResty will pick it up automatically (or set `WEBHOOK_CONFIG_MODULE` to load a differently named module).

## API Documentation

### Base URL
```
https://your-domain.com/webhook
```

### Endpoints

#### Create Webhook
```http
POST /webhook/:category
POST /webhook (uses default category)
```

**Request Body:**
```json
{
  "your": "data",
  "any": "json payload",
  "ttl": 3600,
  "callback_url": "https://example.com/notify"
}
```

**Response:**
```json
{
  "status": "stored",
  "key": "orders:1768418049:abc123...",
  "created_at": "2026-01-14T19:14:09",
  "category": "orders",
  "url": "https://your-domain.com/webhook/orders/orders:1768418049:abc123...",
  "ttl": 3600,
  "callback_registered": true
}
```

#### Get Webhook
```http
GET /webhook/:category/:key
```

**Response:**
```json
{
  "key": "orders:1768418049:abc123...",
  "ttl": 3540,
  "category": "orders",
  "created_at": "2026-01-14T19:14:09",
  "value": {
    "your": "data"
  },
  "callback_url": "https://example.com/notify"
}
```

#### List Webhooks in Category
```http
GET /webhook/:category
GET /webhook/:category?since=1768418000
```

**Response:**
```json
{
  "keys": [
    {
      "key": "orders:1768418049:abc123...",
      "ttl": 3540,
      "created_at": "2026-01-14T19:14:09",
      "category": "orders",
      "payload": {"your": "data"}
    }
  ],
  "count": 1,
  "category": "orders"
}
```

**Headers:**
- `X-Total-Count`: Number of webhooks returned
- `X-Storage-Used`: Current storage usage in bytes
- `X-Storage-Limit`: Maximum storage limit in bytes

#### Update Webhook (TTL or Callback)
```http
PATCH /webhook/:category/:key
```

**Request Body:**
```json
{
  "ttl": 7200,
  "callback_url": "https://example.com/new-callback"
}
```

#### Delete Webhook
```http
DELETE /webhook/:category/:key
```

**Response:**
```json
{
  "status": "deleted",
  "key": "orders:1768418049:abc123..."
}
```

#### Batch Create
```http
POST /webhook/:category/_batch
```

**Request Body:**
```json
{
  "items": [
    {"data": "item1"},
    {"data": "item2"},
    {"data": "item3"}
  ]
}
```

**Response:**
```json
{
  "success": [
    {"index": 1, "key": "...", "created_at": "..."},
    {"index": 2, "key": "...", "created_at": "..."}
  ],
  "failed": [
    {"index": 3, "error": "Storage limit reached", "error_code": "STORAGE_LIMIT_EXCEEDED"}
  ],
  "total_created": 2,
  "total_failed": 1
}
```

#### Batch Delete
```http
DELETE /webhook/:category/_batch
```

**Request Body:**
```json
{
  "keys": ["key1", "key2", "key3"]
}
```

#### Search Webhooks
```http
GET /webhook/_search?q=searchterm
```

**Response:**
```json
{
  "query": "searchterm",
  "count": 2,
  "results": [
    {
      "key": "...",
      "ttl": 3540,
      "created_at": "...",
      "category": "orders",
      "payload": {"matching": "data"}
    }
  ]
}
```

#### Get Statistics
```http
GET /webhook/_stats
```

**Response:**
```json
{
  "total_webhooks": 42,
  "total_size_bytes": 1048576,
  "storage_limit_bytes": 52428800,
  "storage_used_percent": 2,
  "categories": {
    "orders": 20,
    "products": 15,
    "default": 7
  },
  "oldest_webhook": "orders:1768400000:xyz...",
  "newest_webhook": "orders:1768418049:abc...",
  "oldest_timestamp": "2026-01-14T14:00:00",
  "newest_timestamp": "2026-01-14T19:14:09"
}
```

#### Replay Webhook
```http
POST /webhook/:category/:key/_replay
```

**Request Body (optional):**
```json
{
  "category": "replays",
  "ttl": 7200
}
```

**Response:**
```json
{
  "status": "replayed",
  "new_key": "replays:1768418500:replay:def456...",
  "original_key": "orders:1768418049:abc123...",
  "created_at": "2026-01-14T19:30:00",
  "category": "replays",
  "ttl": 7200,
  "url": "https://your-domain.com/webhook/replays/replays:1768418500:replay:def456..."
}
```

#### Export Webhooks
```http
GET /webhook/_export           # Export all webhooks
GET /webhook/:category/_export  # Export specific category
```

**Response:**
```json
{
  "version": "1.0",
  "exported_at": "2026-01-14T19:30:00",
  "category": "orders",
  "total_exported": 5,
  "webhooks": [
    {
      "key": "orders:1768418049:abc123...",
      "ttl": 3540,
      "created_at": "2026-01-14T19:14:09",
      "category": "orders",
      "payload": {"order_id": 12345},
      "callback_url": "https://example.com/notify"
    }
  ]
}
```

**Headers:**
- `Content-Disposition`: Suggests filename for download

#### Import Webhooks
```http
POST /webhook/_import
```

**Request Body:**
```json
{
  "version": "1.0",
  "exported_at": "2026-01-14T19:30:00",
  "category": "all",
  "webhooks": [...]
}
```

**Response:**
```json
{
  "imported": [
    {"index": 1, "key": "...", "category": "orders"},
    {"index": 2, "key": "...", "category": "orders"}
  ],
  "failed": [],
  "total_imported": 2,
  "total_failed": 0
}
```

#### Prometheus Metrics
```http
GET /webhook/_metrics
```

**Response** (Prometheus format):
```
# HELP webhook_requests_total Total number of webhook requests
# TYPE webhook_requests_total counter
webhook_requests_total{method="POST"} 150
webhook_requests_total{method="GET"} 320
webhook_requests_total{method="DELETE"} 45
webhook_requests_total{method="PATCH"} 12

# HELP webhook_created_total Total number of webhooks created
# TYPE webhook_created_total counter
webhook_created_total 150

# HELP webhook_storage_bytes Current storage usage in bytes
# TYPE webhook_storage_bytes gauge
webhook_storage_bytes 1048576

# HELP webhook_count Current number of webhooks
# TYPE webhook_count gauge
webhook_count 42
```

**Headers:**
- `Content-Type`: `text/plain; version=0.0.4`

### Error Codes

All errors include an `error_code` field for programmatic handling:

- `NO_BODY` - Request body is missing
- `INVALID_JSON` - Request body is not valid JSON
- `KEY_NOT_FOUND` - Requested webhook key doesn't exist
- `MISSING_KEY` - Key required but not provided in path
- `MISSING_QUERY` - Search query parameter missing
- `STORAGE_LIMIT_EXCEEDED` - Storage quota reached
- `PAYLOAD_TOO_LARGE` - Single payload exceeds size limit
- `INVALID_BATCH_FORMAT` - Batch request format is incorrect
- `INVALID_ITEM_TYPE` - Batch item is not a JSON object
- `METHOD_NOT_ALLOWED` - HTTP method not supported for endpoint
- `REDIS_ERROR` - Valkey operation failed

## Testing

The project includes a comprehensive Python test suite using pytest. See [tests/README_TESTING.md](tests/README_TESTING.md) for complete testing documentation.

```bash
cd tests
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pytest test_webhook.py -v
```

## Release Flow

Releases are automated on merges to `master`.

### Versioning

This project uses **Semantic Versioning (SemVer)**: `MAJOR.MINOR.PATCH`.

- **PATCH**: bugfixes, small internal improvements
- **MINOR**: new backwards-compatible features
- **MAJOR**: breaking changes

### How to steer the bump (predictable before merge)

When opening a PR, add exactly one of these labels:

- `release:patch` (default)
- `release:minor`
- `release:major`
- `release:none` (skip creating a release)

After the PR is merged and CI passes, the release workflow will:

1. Create a new git tag (e.g. `v1.2.3`)
2. Create a GitHub Release for that tag (with autogenerated notes)

### Fallback steering (direct pushes)

If a commit lands on `master` without an associated PR, the workflow falls back to the commit message.
You can include one of these tokens in the commit message:

- `release:patch`, `release:minor`, `release:major`
- `release:none` or `[skip release]`

### LuaRocks publishing

Publishing to LuaRocks happens automatically for non-pre-release GitHub Releases. You can still publish manually via the `Publish to LuaRocks` workflow.

## Usage Examples

### Store a webhook
```bash
curl -X POST https://your-domain.com/webhook/orders \
  -H "Content-Type: application/json" \
  -d '{"order_id": 12345, "total": 99.99, "ttl": 3600}'
```

### Retrieve a webhook
```bash
curl https://your-domain.com/webhook/orders/orders:1768418049:abc123...
```

### Search for webhooks
```bash
curl "https://your-domain.com/webhook/_search?q=12345"
```

### Get statistics
```bash
curl https://your-domain.com/webhook/_stats
```

### Batch create
```bash
curl -X POST https://your-domain.com/webhook/products/_batch \
  -H "Content-Type: application/json" \
  -d '{"items": [{"name": "Product 1"}, {"name": "Product 2"}]}'
```

### Replay a webhook
```bash
curl -X POST https://your-domain.com/webhook/orders/orders:1768418049:abc123/_replay \
  -H "Content-Type: application/json" \
  -d '{"category": "replays", "ttl": 7200}'
```

### Export webhooks
```bash
# Export all webhooks
curl https://your-domain.com/webhook/_export > backup.json

# Export specific category
curl https://your-domain.com/webhook/orders/_export > orders_backup.json
```

### Import webhooks
```bash
curl -X POST https://your-domain.com/webhook/_import \
  -H "Content-Type: application/json" \
  -d @backup.json
```

### Get Prometheus metrics
```bash
curl https://your-domain.com/webhook/_metrics
```

### Subscribe to events (WebSocket or Pub/Sub)
```bash
# Option A: WebSocket stream
# Connect to: ws(s)://your-domain.com/webhook/_ws

# Option B: Valkey/Redis Pub/Sub
valkey-cli SUBSCRIBE webhook:events  # compatible with redis-cli

# Integrate in your application (see integration examples below)
```

## Performance

- **Valkey-backed**: Extremely fast read/write operations
- **Automatic expiration**: Uses Valkey TTL for efficient cleanup
- **Lazy recalculation**: Storage metrics calculated periodically, not on every request
- **Batch operations**: Process multiple webhooks in a single request
- **Minimal overhead**: Direct Lua execution in Nginx worker processes
- **Event-driven**: Events are published to Valkey/Redis Pub/Sub and can be bridged to WebSocket clients
- **Metrics collection**: Track usage patterns with minimal performance impact

## Event Integration (WebSocket + Pub/Sub)

Webhook events are published to Valkey/Redis pub/sub channel `webhook:events`.

If you prefer a browser/client-friendly interface, the service also exposes a WebSocket endpoint that streams the same JSON messages:

- `GET /webhook/_ws`

### Event Types

- `webhook.created` - When a webhook is created
- `webhook.updated` - When a webhook is updated via PATCH
- `webhook.deleted` - When a webhook is deleted
- `webhook.replayed` - When a webhook is replayed

### Integration Examples

**WebSocket (browser/Node.js):**
```javascript
// If API-key auth is enabled and you need a browser client, pass the key
// via query string (browsers can't set custom WS headers):
//   wss://your-domain.com/webhook/_ws?api_key=YOUR_KEY
const ws = new WebSocket('wss://your-domain.com/webhook/_ws');

ws.onmessage = (evt) => {
  const event = JSON.parse(evt.data);
  console.log('Event:', event.type, event.data);
};
```

**Node.js with Socket.IO:**
```javascript
const redis = require('redis');
const io = require('socket.io')(server);

const subscriber = redis.createClient();
subscriber.subscribe('webhook:events');

subscriber.on('message', (channel, message) => {
  const event = JSON.parse(message);
  io.emit('webhook-event', event);
});
```

**Python:**
```python
import redis
import json

r = redis.Redis()
pubsub = r.pubsub()
pubsub.subscribe('webhook:events')

for message in pubsub.listen():
    if message['type'] == 'message':
        event = json.loads(message['data'])
        print(f"Event: {event['type']}", event['data'])
```

## Monitoring with Prometheus

The `/webhook/_metrics` endpoint provides metrics in Prometheus format. Add to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'webhook'
    static_configs:
      - targets: ['your-domain.com']
    metrics_path: '/webhook/_metrics'
    scrape_interval: 30s
```

### Available Metrics

- `webhook_requests_total` - Total requests by HTTP method (counter)
- `webhook_created_total` - Total webhooks created (counter)
- `webhook_deleted_total` - Total webhooks deleted (counter)
- `webhook_storage_bytes` - Current storage usage (gauge)
- `webhook_storage_limit_bytes` - Storage limit (gauge)
- `webhook_count` - Current number of webhooks (gauge)
- `webhook_errors_total` - Total errors encountered (counter)
- `webhook_auth_missing_total` - Requests missing an API key (counter)
- `webhook_auth_invalid_total` - Requests with an invalid API key (counter)

## Security Considerations

⚠️ **Important**: This webhook service does not include built-in authentication by default. Before deploying to production:

1. Implement authentication (API keys, OAuth, etc.)
2. Add rate limiting (Nginx `limit_req` / `limit_conn` are the usual approach)
3. Use HTTPS/TLS encryption
4. Restrict access via firewall rules
5. Monitor for abuse (Prometheus metrics are exposed at `/webhook/_metrics`)
6. Consider using nginx's built-in security modules

### API key authentication (optional)

`webhook.lua` supports a simple API-key gate:

- Set `WEBHOOK_API_KEYS="key1,key2"` and configure Nginx/OpenResty to pass the env var (via `env WEBHOOK_API_KEYS;`).
- Send the key as `X-API-Key: ...` or `Authorization: Bearer ...`.
- Optionally exempt endpoints like metrics: `WEBHOOK_AUTH_EXEMPT="_metrics"`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with [OpenResty](https://openresty.org/)
- Uses [Valkey](https://valkey.io/) for storage
- Inspired by modern webhook services

---

Made with ❤️ by myrveln
