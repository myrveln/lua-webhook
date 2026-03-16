local cjson = require "cjson.safe"
cjson.encode_escape_forward_slash(false)
local redis = require "resty.redis"

local settings = require "lua_webhook.settings"
local cors = require "lua_webhook.cors"
local redis_client = require "lua_webhook.redis_client"

local CFG = settings.load()
local SETTINGS = CFG.SETTINGS

local PREFIX = CFG.PREFIX                           -- prefix for all keys
local CALLBACK_PREFIX = CFG.CALLBACK_PREFIX         -- prefix for callback URLs
local METRICS_PREFIX = CFG.METRICS_PREFIX           -- prefix for metrics
local WEBSOCKET_PREFIX = CFG.WEBSOCKET_PREFIX       -- prefix for WebSocket subscriptions
local DEFAULT_CATEGORY = CFG.DEFAULT_CATEGORY       -- fallback category
local DEFAULT_TTL = CFG.DEFAULT_TTL
local MAX_BODY_SIZE = CFG.MAX_BODY_SIZE
local TOTAL_PAYLOAD_LIMIT = CFG.TOTAL_PAYLOAD_LIMIT
local TOTAL_SIZE_KEY = CFG.TOTAL_SIZE_KEY
local LAST_RECALC_KEY = CFG.LAST_RECALC_KEY

-- Indexes for scalable listing/searching.
local INDEX_KEY = CFG.INDEX_KEY
local INDEX_CAT_PREFIX = CFG.INDEX_CAT_PREFIX
local CATEGORY_COUNT_KEY = CFG.CATEGORY_COUNT_KEY

-- Rate limiting keys.
local RATE_LIMIT_PREFIX = CFG.RATE_LIMIT_PREFIX
local RECALC_INTERVAL = CFG.RECALC_INTERVAL
local REDIS_HOST = CFG.REDIS_HOST
local REDIS_PORT = CFG.REDIS_PORT

local REDIS_KEEPALIVE_TIMEOUT_MS = CFG.REDIS_KEEPALIVE_TIMEOUT_MS
local REDIS_KEEPALIVE_POOL_SIZE = CFG.REDIS_KEEPALIVE_POOL_SIZE

local DEFAULT_LIMIT = CFG.DEFAULT_LIMIT
local MAX_LIMIT = CFG.MAX_LIMIT
local SEARCH_MAX_CANDIDATES = CFG.SEARCH_MAX_CANDIDATES

local RATE_LIMIT_ENABLED = CFG.RATE_LIMIT_ENABLED
local RATE_LIMIT_WINDOW_S = CFG.RATE_LIMIT_WINDOW_S
local RATE_LIMIT_MAX_REQUESTS = CFG.RATE_LIMIT_MAX_REQUESTS

local CORS_ALLOW_ORIGIN = CFG.CORS_ALLOW_ORIGIN
local CORS_ALLOW_METHODS = CFG.CORS_ALLOW_METHODS
local CORS_ALLOW_HEADERS = CFG.CORS_ALLOW_HEADERS
local CORS_EXPOSE_HEADERS = CFG.CORS_EXPOSE_HEADERS
local CORS_ALLOW_CREDENTIALS = CFG.CORS_ALLOW_CREDENTIALS
local CORS_MAX_AGE_S = CFG.CORS_MAX_AGE_S

local CALLBACK_URL_MAX_LEN = CFG.CALLBACK_URL_MAX_LEN
local CALLBACK_URL_ALLOW_HTTP = CFG.CALLBACK_URL_ALLOW_HTTP
local CALLBACK_URL_BLOCK_PRIVATE_IPS = CFG.CALLBACK_URL_BLOCK_PRIVATE_IPS

-- ==== AUTHENTICATION (optional) ====
-- Set one or more API keys to require auth on all endpoints.
--
-- Option A (recommended): set env var WEBHOOK_API_KEYS="key1,key2" (and ensure nginx passes it via `env WEBHOOK_API_KEYS;`).
-- Option B: hardcode keys in STATIC_API_KEYS below.
--
-- Exempt endpoints (by the 2nd path segment, e.g. "_metrics") can be provided via:
--   WEBHOOK_AUTH_EXEMPT="_metrics,_stats"
local function _coerce_string_list(v)
    local out = {}
    if type(v) ~= "table" then
        return out
    end
    for _, item in ipairs(v) do
        if type(item) == "string" and item ~= "" then
            out[#out + 1] = item
        end
    end
    return out
end

local STATIC_API_KEYS
if type(SETTINGS.API_KEYS) == "table" then
    -- Ergonomic: API_KEYS overrides STATIC_API_KEYS.
    STATIC_API_KEYS = _coerce_string_list(SETTINGS.API_KEYS)
else
    STATIC_API_KEYS = _coerce_string_list(SETTINGS.STATIC_API_KEYS)
end

local MODULE_AUTH_API_KEYS = _coerce_string_list(SETTINGS.AUTH_API_KEYS)
local MODULE_AUTH_EXEMPT = _coerce_string_list(SETTINGS.AUTH_EXEMPT)
local AUTH_API_KEYS_ENV = SETTINGS.AUTH_API_KEYS_ENV
local AUTH_EXEMPT_ENV = SETTINGS.AUTH_EXEMPT_ENV or ""

local function _trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _split_csv(s)
    local out = {}
    if not s or s == "" then
        return out
    end
    for part in string.gmatch(s, "[^,]+") do
        local v = _trim(part)
        if v ~= "" then
            table.insert(out, v)
        end
    end
    return out
end

local function _secure_equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local alen = #a
    local blen = #b
    if alen ~= blen then
        return false
    end
    if not bit then
        return a == b
    end
    local diff = 0
    for i = 1, alen do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

local function _normalize_hex_sha256(s)
    if type(s) ~= "string" then
        return nil
    end
    local v = _trim(s):lower()
    if v:match("^[0-9a-f]+$") and #v == 64 then
        return v
    end
    return nil
end

local function _coerce_sha256_hash_list(v)
    local out = {}
    if type(v) ~= "table" then
        return out
    end
    for _, item in ipairs(v) do
        local n = _normalize_hex_sha256(item)
        if n then
            out[#out + 1] = n
        end
    end
    return out
end

local function _build_auth_state()
    local keys = {}
    for _, k in ipairs(STATIC_API_KEYS) do
        if type(k) == "string" and k ~= "" then
            table.insert(keys, k)
        end
    end
    for _, k in ipairs(MODULE_AUTH_API_KEYS) do
        table.insert(keys, k)
    end
    for _, k in ipairs(_split_csv(AUTH_API_KEYS_ENV)) do
        table.insert(keys, k)
    end

    local hashes = {}
    local module_hashes
    if type(SETTINGS.API_KEY_HASHES) == "table" then
        module_hashes = _coerce_sha256_hash_list(SETTINGS.API_KEY_HASHES)
    else
        module_hashes = {}
    end
    local module_auth_hashes = _coerce_sha256_hash_list(SETTINGS.AUTH_API_KEY_HASHES)
    for _, h in ipairs(module_hashes) do
        hashes[#hashes + 1] = h
    end
    for _, h in ipairs(module_auth_hashes) do
        hashes[#hashes + 1] = h
    end
    for _, h in ipairs(_split_csv(SETTINGS.AUTH_API_KEY_HASHES_ENV)) do
        local n = _normalize_hex_sha256(h)
        if n then
            hashes[#hashes + 1] = n
        end
    end

    local exempt = {}
    for _, e in ipairs(_split_csv(AUTH_EXEMPT_ENV)) do
        exempt[e] = true
    end
    for _, e in ipairs(MODULE_AUTH_EXEMPT) do
        exempt[e] = true
    end

    return keys, hashes, exempt
end

local API_KEYS, API_KEY_HASHES, AUTH_EXEMPT = _build_auth_state()
local AUTH_ENABLED = (#API_KEYS > 0) or (#API_KEY_HASHES > 0)

local function _build_rate_limit_exempt_state()
    local exempt = {}
    for _, e in ipairs(_split_csv(SETTINGS.RATE_LIMIT_EXEMPT_ENV or "")) do
        exempt[e] = true
    end
    for _, e in ipairs(_coerce_string_list(SETTINGS.RATE_LIMIT_EXEMPT)) do
        exempt[e] = true
    end
    return exempt
end

local RATE_LIMIT_EXEMPT = _build_rate_limit_exempt_state()

local function _build_callback_allowlist_state()
    local allow = {}
    for _, h in ipairs(_split_csv(SETTINGS.CALLBACK_URL_ALLOWLIST_ENV or "")) do
        if h and h ~= "" then
            allow[h:lower()] = true
        end
    end
    for _, h in ipairs(_coerce_string_list(SETTINGS.CALLBACK_URL_ALLOWLIST)) do
        if h and h ~= "" then
            allow[h:lower()] = true
        end
    end
    return allow
end

local CALLBACK_URL_ALLOWLIST_STATE = _build_callback_allowlist_state()

local function _get_presented_api_key()
    local headers = ngx.req.get_headers()
    local key = headers["x-api-key"] or headers["X-API-Key"]
    if key and type(key) == "string" and key ~= "" then
        return key
    end

    local auth = headers["authorization"] or headers["Authorization"]
    if auth and type(auth) == "string" then
        local bearer = auth:match("^[Bb]earer%s+(.+)$")
        if bearer and bearer ~= "" then
            return bearer
        end
    end

    return nil
end

local function _api_key_is_valid(presented)
    if not presented or presented == "" then
        return false
    end

    for _, allowed in ipairs(API_KEYS) do
        if _secure_equals(presented, allowed) then
            return true
        end
    end

    if #API_KEY_HASHES > 0 then
        local ok_sha, sha256 = pcall(require, "resty.sha256")
        local ok_str, str = pcall(require, "resty.string")
        if not ok_sha or not ok_str then
            -- Misconfiguration: hashes were provided but hashing libs are unavailable.
            return false
        end
        local h = sha256:new()
        h:update(presented)
        local digest = str.to_hex(h:final()):lower()
        for _, allowed_hash in ipairs(API_KEY_HASHES) do
            if _secure_equals(digest, allowed_hash) then
                return true
            end
        end
    end

    return false
end

-- Forward declarations for helpers referenced by earlier-defined functions.
-- In Lua, if a local isn't declared before use, it becomes a global reference.
local _parse_key_timestamp
local _index_key_for_category
local _index_add
local _index_remove
local _get_callback_url
local _set_callback_url
local _del_callback_url
local _validate_callback_url

-- ==== UTILS ====
local function read_request_body()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file_path = ngx.req.get_body_file()
        if file_path then
            local file, err = io.open(file_path, "rb")
            if not file then
                return nil, "Failed to read temp file: " .. (err or "unknown error")
            end
            data = file:read("*a")
            file:close()
        end
    end

    if data and ngx.ctx then
        ngx.ctx.request_bytes_in = (ngx.ctx.request_bytes_in or 0) + #data
    end
    return data
end

local function _clamp(n, lo, hi)
    if n == nil then
        return lo
    end
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

local function _parse_limit(args)
    local limit = tonumber(args and args.limit)
    if not limit then
        limit = DEFAULT_LIMIT
    end
    return _clamp(math.floor(limit), 1, MAX_LIMIT)
end

local function _parse_cursor(args)
    local cursor = args and args.cursor
    if cursor == nil or cursor == "" then
        return nil
    end
    local n = tonumber(cursor)
    if n then
        return n
    end
    return nil
end

local function _parse_include_payload(args)
    local v = args and (args.include_payload or args.includePayload)
    if v == nil then
        return true
    end
    if v == true or v == 1 then
        return true
    end
    if type(v) == "string" then
        local s = v:lower()
        if s == "false" or s == "0" or s == "no" then
            return false
        end
    end
    return true
end

local function _apply_cors_headers()
    return cors.apply(CFG)
end

local function _redis_put_back(red)
    return redis_client.put_back(CFG, red)
end

local function _finish(status)
    local red = ngx.ctx and ngx.ctx.red
    if red then
        _redis_put_back(red)
    end
    ngx.exit(status)
end

local function increment_metric(red, metric_name, value)
    value = value or 1
    local metric_key = METRICS_PREFIX .. metric_name
    red:incrby(metric_key, value)
end

local function mget_chunked(red, keys, chunk_size)
    if not keys or #keys == 0 then
        return {}
    end
    chunk_size = chunk_size or 500

    local out = {}
    local i = 1
    while i <= #keys do
        local j = math.min(i + chunk_size - 1, #keys)
        local chunk = {}
        for k = i, j do
            chunk[#chunk + 1] = keys[k]
        end

        local vals, err = red:mget(unpack(chunk))
        if not vals then
            return nil, err
        end

        for _, v in ipairs(vals) do
            out[#out + 1] = v
        end
        i = j + 1
    end

    return out
end

local function scan_keys(red, pattern, count)
    count = count or 1000
    local cursor = "0"
    local out = {}

    while true do
        local res, err = red:scan(cursor, "MATCH", pattern, "COUNT", count)
        if not res then
            return nil, err
        end

        cursor = res[1]
        local batch = res[2]
        if batch and type(batch) == "table" then
            for _, k in ipairs(batch) do
                out[#out + 1] = k
            end
        end

        if cursor == "0" or cursor == 0 then
            break
        end
    end

    return out
end

local function zscan_members(red, zkey, count)
    count = count or 1000
    local cursor = "0"
    local out = {}

    while true do
        local res, err = red:zscan(zkey, cursor, "COUNT", count)
        if not res then
            return nil, err
        end
        cursor = res[1]
        local batch = res[2]
        if batch and type(batch) == "table" then
            local i = 1
            while i <= #batch do
                local member = batch[i]
                out[#out + 1] = member
                i = i + 2
            end
        end

        if cursor == "0" or cursor == 0 then
            break
        end
    end

    return out
end

local function ttl_pipeline_chunked(red, keys, chunk_size)
    if not keys or #keys == 0 then
        return {}
    end
    chunk_size = chunk_size or 500

    local out = {}
    local i = 1
    while i <= #keys do
        local j = math.min(i + chunk_size - 1, #keys)
        red:init_pipeline()
        for k = i, j do
            red:ttl(keys[k])
        end

        local res, err = red:commit_pipeline()
        if not res then
            return nil, err
        end
        for _, v in ipairs(res) do
            out[#out + 1] = v
        end
        i = j + 1
    end

    return out
end

local function send_json(status, tbl, headers)
    -- Track errors centrally for all JSON responses with HTTP status >= 400.
    -- This keeps `webhook_errors_total` consistent across endpoints.
    if status and status >= 400 then
        local ctx_red = ngx.ctx and ngx.ctx.red
        if ctx_red then
            pcall(function()
                increment_metric(ctx_red, "errors_total")
            end)
        end
    end

    -- Generic response accounting
    do
        local ctx_red = ngx.ctx and ngx.ctx.red
        if ctx_red and status then
            pcall(function()
                increment_metric(ctx_red, "responses_total")
                increment_metric(ctx_red, "responses_status_" .. tostring(status))
                local cls = math.floor(status / 100)
                increment_metric(ctx_red, "responses_class_" .. tostring(cls) .. "xx")
            end)
        end
    end

    ngx.status = status
    ngx.header.content_type = "application/json"

    _apply_cors_headers()

    -- Add custom headers if provided
    if headers then
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
    end

    local encoded = cjson.encode(tbl)
    if ngx.ctx then
        ngx.ctx.response_bytes_out = (ngx.ctx.response_bytes_out or 0) + #encoded + 1
    end

    do
        local ctx_red = ngx.ctx and ngx.ctx.red
        if ctx_red then
            local in_bytes = ngx.ctx and ngx.ctx.request_bytes_in
            local out_bytes = ngx.ctx and ngx.ctx.response_bytes_out
            pcall(function()
                if in_bytes and in_bytes > 0 then
                    increment_metric(ctx_red, "bytes_in_total", in_bytes)
                    ngx.ctx.request_bytes_in = 0
                end
                if out_bytes and out_bytes > 0 then
                    increment_metric(ctx_red, "bytes_out_total", out_bytes)
                    ngx.ctx.response_bytes_out = 0
                end
            end)
        end
    end

    -- Latency metrics
    do
        local ctx_red = ngx.ctx and ngx.ctx.red
        local started = ngx.ctx and ngx.ctx.request_start
        if ctx_red and started then
            local elapsed_ms = math.floor((ngx.now() - started) * 1000)
            pcall(function()
                increment_metric(ctx_red, "latency_ms_sum", elapsed_ms)
                increment_metric(ctx_red, "latency_ms_count", 1)

                local buckets = { 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }
                for _, le in ipairs(buckets) do
                    if elapsed_ms <= le then
                        increment_metric(ctx_red, "latency_ms_bucket_le_" .. tostring(le), 1)
                    end
                end
                increment_metric(ctx_red, "latency_ms_bucket_le_inf", 1)
            end)
        end
    end

    ngx.say(encoded)
    local red = ngx.ctx and ngx.ctx.red
    if red then
        _redis_put_back(red)
    end
    ngx.exit(status)
end

local function iso8601_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%S") -- UTC time
end

local function get_total_size(red)
    local size = red:get(TOTAL_SIZE_KEY)
    if not size or size == ngx.null then
        return 0
    end
    return tonumber(size) or 0
end

local function update_total_size(red, delta)
    local new_size, err = red:incrby(TOTAL_SIZE_KEY, delta)
    if not new_size then return nil, err end
    if new_size < 0 then
        red:set(TOTAL_SIZE_KEY, 0)
    end
    return new_size
end

local function lazy_recalc_total_size(red)
    local now = ngx.time()
    local last = red:get(LAST_RECALC_KEY)
    last = tonumber(last) or 0
    if now - last < RECALC_INTERVAL then
        return get_total_size(red)
    end

    local members = zscan_members(red, INDEX_KEY)
    local sum = 0
    if members and #members > 0 then
        local redis_keys = {}
        for i, k in ipairs(members) do
            redis_keys[i] = PREFIX .. k
        end
        local vals, err = mget_chunked(red, redis_keys)
        if vals then
            for i, val in ipairs(vals) do
                local webhook_key = members[i]
                if val and val ~= ngx.null then
                    local ok, d = pcall(cjson.decode, val)
                    if ok and type(d) == "table" and d.size then
                        sum = sum + d.size
                    else
                        sum = sum + #val
                    end
                else
                    -- Stale index entry (expired/deleted)
                    _index_remove(red, nil, webhook_key)
                end
            end
        end
    end
    red:set(TOTAL_SIZE_KEY, sum)
    red:set(LAST_RECALC_KEY, now)
    return sum
end

local function get_stats(red)
    local total_size = lazy_recalc_total_size(red)

    local count = tonumber(red:zcard(INDEX_KEY)) or 0
    local categories = {}
    do
        local raw = red:hgetall(CATEGORY_COUNT_KEY)
        if raw and type(raw) == "table" then
            local i = 1
            while i <= #raw do
                local k = raw[i]
                local v = tonumber(raw[i + 1]) or 0
                if v > 0 then
                    categories[k] = v
                end
                i = i + 2
            end
        end
    end

    local oldest_key
    local newest_key
    local oldest_time
    local newest_time

    do
        local newest = red:zrevrange(INDEX_KEY, 0, 0)
        if newest and newest[1] then
            newest_key = newest[1]
            newest_time = _parse_key_timestamp(newest_key)
        end
        local oldest = red:zrange(INDEX_KEY, 0, 0)
        if oldest and oldest[1] then
            oldest_key = oldest[1]
            oldest_time = _parse_key_timestamp(oldest_key)
        end
    end

    return {
        total_webhooks = count,
        total_size_bytes = total_size,
        storage_limit_bytes = TOTAL_PAYLOAD_LIMIT,
        storage_used_percent = math.floor((total_size / TOTAL_PAYLOAD_LIMIT) * 100),
        categories = categories,
        oldest_webhook = oldest_key,
        newest_webhook = newest_key,
        oldest_timestamp = oldest_time and os.date("!%Y-%m-%dT%H:%M:%S", oldest_time) or nil,
        newest_timestamp = newest_time and os.date("!%Y-%m-%dT%H:%M:%S", newest_time) or nil
    }
end

local function search_webhooks(red, query)
    local keys = scan_keys(red, PREFIX .. "*")
    local results = {}

    if not keys or #keys == 0 then
        return results
    end

    local vals, err = mget_chunked(red, keys)
    if not vals then
        return results
    end

    for i, val in ipairs(vals) do
        local key_name = keys[i]
        if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY
            and not string.match(key_name, "^" .. CALLBACK_PREFIX)
            and not string.match(key_name, "^" .. METRICS_PREFIX)
            and not string.match(key_name, "^" .. WEBSOCKET_PREFIX) then
            if val and val ~= ngx.null then
                local ok, decoded = pcall(cjson.decode, val)
                if ok and type(decoded) == "table" then
                    -- Search in payload
                    local payload_str = cjson.encode(decoded.payload or {})
                    if string.find(string.lower(payload_str), string.lower(query)) then
                        table.insert(results, {
                            key = string.gsub(key_name, "^" .. PREFIX, ""),
                            ttl = red:ttl(key_name) or -1,
                            created_at = decoded.created_at,
                            category = decoded.category,
                            payload = decoded.payload
                        })
                    end
                end
            end
        end
    end

    return results
end

local function get_prometheus_metrics(red)
    local metrics = {}

    -- Load metrics keys.
    local function _load(prefix)
        local metric_keys = scan_keys(red, prefix .. "*")
        if metric_keys and #metric_keys > 0 then
            local values, err = mget_chunked(red, metric_keys)
            if values then
                for i, key in ipairs(metric_keys) do
                    local metric_name = string.gsub(key, "^" .. prefix, "")
                    local value = values[i]
                    if value and value ~= ngx.null then
                        metrics[metric_name] = (tonumber(value) or 0)
                    end
                end
            end
        end
    end

    _load(METRICS_PREFIX)

    -- Get current stats
    local stats = get_stats(red)

    -- Format as Prometheus metrics
    local output = {}
    table.insert(output, "# HELP webhook_requests_total Total number of webhook requests")
    table.insert(output, "# TYPE webhook_requests_total counter")
    table.insert(output, string.format("webhook_requests_total{method=\"POST\"} %d", metrics.requests_post or 0))
    table.insert(output, string.format("webhook_requests_total{method=\"GET\"} %d", metrics.requests_get or 0))
    table.insert(output, string.format("webhook_requests_total{method=\"DELETE\"} %d", metrics.requests_delete or 0))
    table.insert(output, string.format("webhook_requests_total{method=\"PATCH\"} %d", metrics.requests_patch or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_created_total Total number of webhooks created")
    table.insert(output, "# TYPE webhook_created_total counter")
    table.insert(output, string.format("webhook_created_total %d", metrics.created_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_deleted_total Total number of webhooks deleted")
    table.insert(output, "# TYPE webhook_deleted_total counter")
    table.insert(output, string.format("webhook_deleted_total %d", metrics.deleted_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_storage_bytes Current storage usage in bytes")
    table.insert(output, "# TYPE webhook_storage_bytes gauge")
    table.insert(output, string.format("webhook_storage_bytes %d", stats.total_size_bytes))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_storage_limit_bytes Storage limit in bytes")
    table.insert(output, "# TYPE webhook_storage_limit_bytes gauge")
    table.insert(output, string.format("webhook_storage_limit_bytes %d", stats.storage_limit_bytes))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_count Current number of webhooks")
    table.insert(output, "# TYPE webhook_count gauge")
    table.insert(output, string.format("webhook_count %d", stats.total_webhooks))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_errors_total Total number of errors")
    table.insert(output, "# TYPE webhook_errors_total counter")
    table.insert(output, string.format("webhook_errors_total %d", metrics.errors_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_rate_limited_total Total number of rate-limited requests")
    table.insert(output, "# TYPE webhook_rate_limited_total counter")
    table.insert(output, string.format("webhook_rate_limited_total %d", metrics.rate_limited_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_bytes_in_total Total request bytes received")
    table.insert(output, "# TYPE webhook_bytes_in_total counter")
    table.insert(output, string.format("webhook_bytes_in_total %d", metrics.bytes_in_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_bytes_out_total Total response bytes sent")
    table.insert(output, "# TYPE webhook_bytes_out_total counter")
    table.insert(output, string.format("webhook_bytes_out_total %d", metrics.bytes_out_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_responses_total Total responses")
    table.insert(output, "# TYPE webhook_responses_total counter")
    table.insert(output, string.format("webhook_responses_total %d", metrics.responses_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_request_latency_ms Request latency histogram in milliseconds")
    table.insert(output, "# TYPE webhook_request_latency_ms histogram")
    local buckets = { 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 }
    for _, le in ipairs(buckets) do
        local v = metrics["latency_ms_bucket_le_" .. tostring(le)] or 0
        table.insert(output, string.format("webhook_request_latency_ms_bucket{le=\"%d\"} %d", le, v))
    end
    table.insert(output, string.format("webhook_request_latency_ms_bucket{le=\"+Inf\"} %d", metrics.latency_ms_bucket_le_inf or 0))
    table.insert(output, string.format("webhook_request_latency_ms_sum %d", metrics.latency_ms_sum or 0))
    table.insert(output, string.format("webhook_request_latency_ms_count %d", metrics.latency_ms_count or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_auth_missing_total Requests missing an API key")
    table.insert(output, "# TYPE webhook_auth_missing_total counter")
    table.insert(output, string.format("webhook_auth_missing_total %d", metrics.auth_missing_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_auth_invalid_total Requests with an invalid API key")
    table.insert(output, "# TYPE webhook_auth_invalid_total counter")
    table.insert(output, string.format("webhook_auth_invalid_total %d", metrics.auth_invalid_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_ws_connected_total Total number of WebSocket connections")
    table.insert(output, "# TYPE webhook_ws_connected_total counter")
    table.insert(output, string.format("webhook_ws_connected_total %d", metrics.ws_connected_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_ws_disconnected_total Total number of WebSocket disconnects")
    table.insert(output, "# TYPE webhook_ws_disconnected_total counter")
    table.insert(output, string.format("webhook_ws_disconnected_total %d", metrics.ws_disconnected_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_ws_messages_sent_total Total number of messages sent over WebSocket")
    table.insert(output, "# TYPE webhook_ws_messages_sent_total counter")
    table.insert(output, string.format("webhook_ws_messages_sent_total %d", metrics.ws_messages_sent_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_ws_handshake_errors_total WebSocket handshake/setup errors")
    table.insert(output, "# TYPE webhook_ws_handshake_errors_total counter")
    table.insert(output, string.format("webhook_ws_handshake_errors_total %d", metrics.ws_handshake_errors_total or 0))

    table.insert(output, "")
    table.insert(output, "# HELP webhook_ws_backend_errors_total WebSocket backend (Valkey/Redis) errors")
    table.insert(output, "# TYPE webhook_ws_backend_errors_total counter")
    table.insert(output, string.format("webhook_ws_backend_errors_total %d", metrics.ws_backend_errors_total or 0))

    return table.concat(output, "\n") .. "\n"
end

local function export_webhooks(red, category_filter)
    local zkey = category_filter and _index_key_for_category(category_filter) or INDEX_KEY
    local members = zscan_members(red, zkey)
    local export_data = {
        version = "1.0",
        exported_at = iso8601_timestamp(),
        category = category_filter or "all",
        webhooks = {}
    }

    if not members or #members == 0 then
        return export_data
    end

    local redis_keys = {}
    for i, k in ipairs(members) do
        redis_keys[i] = PREFIX .. k
    end
    local vals = mget_chunked(red, redis_keys)
    if vals then
        for i, val in ipairs(vals) do
            local webhook_key = members[i]
            if val and val ~= ngx.null then
                local ok, decoded = pcall(cjson.decode, val)
                if ok and type(decoded) == "table" then
                    local ttl = red:ttl(PREFIX .. webhook_key) or -1
                    table.insert(export_data.webhooks, {
                        key = webhook_key,
                        ttl = ttl,
                        created_at = decoded.created_at,
                        category = decoded.category,
                        payload = decoded.payload,
                        callback_url = _get_callback_url(red, webhook_key)
                    })
                end
            else
                _index_remove(red, nil, webhook_key)
            end
        end
    end

    export_data.total_exported = #export_data.webhooks
    return export_data
end

local function import_webhooks(red, import_data)
    if type(import_data) ~= "table" or not import_data.webhooks then
        return nil, "Invalid import format"
    end

    local results = {
        imported = {},
        failed = {},
        total_imported = 0,
        total_failed = 0
    }

    local current_total = lazy_recalc_total_size(red)

    for idx, webhook in ipairs(import_data.webhooks) do
        if type(webhook) == "table" and webhook.payload and webhook.category then
            local payload_json = cjson.encode(webhook.payload)
            local ttl = tonumber(webhook.ttl) or DEFAULT_TTL
            if ttl <= 0 then ttl = DEFAULT_TTL end

            if current_total + #payload_json > TOTAL_PAYLOAD_LIMIT then
                table.insert(results.failed, {
                    index = idx,
                    error = "Storage limit reached",
                    error_code = "STORAGE_LIMIT_EXCEEDED"
                })
                results.total_failed = results.total_failed + 1
            else

                local created_at = webhook.created_at or iso8601_timestamp()
                local key = PREFIX .. webhook.category .. ":" .. ngx.time() .. ":" .. idx .. ":" .. ngx.md5(payload_json)

            local store_data = {
                created_at = created_at,
                category = webhook.category,
                payload = webhook.payload,
                size = #payload_json
            }

                local ok, err = red:set(key, cjson.encode(store_data), "EX", ttl)
                if ok then
                    update_total_size(red, #payload_json)
                    current_total = current_total + #payload_json

                    local webhook_key = string.gsub(key, "^" .. PREFIX, "")
                    _index_add(red, webhook.category, webhook_key)

                    -- Restore callback URL if present
                    if webhook.callback_url then
                        _set_callback_url(red, webhook_key, webhook.callback_url, ttl)
                    end

                    table.insert(results.imported, {
                        index = idx,
                        key = webhook_key,
                        category = webhook.category
                    })
                    results.total_imported = results.total_imported + 1
                else
                    table.insert(results.failed, {
                        index = idx,
                        error = "Failed to import",
                        details = err
                    })
                    results.total_failed = results.total_failed + 1
                end
            end
        else
            table.insert(results.failed, {
                index = idx,
                error = "Invalid webhook format"
            })
            results.total_failed = results.total_failed + 1
        end
    end

    return results
end

local function publish_websocket_event(red, event_type, data)
    local event = {
        type = event_type,
        timestamp = iso8601_timestamp(),
        data = data
    }

    -- Publish to Redis pub/sub channel
    red:publish("webhook:events", cjson.encode(event))
end

local function _is_internal_endpoint(category)
    return category == "_stats"
        or category == "_metrics"
        or category == "_search"
        or category == "_export"
        or category == "_import"
        or category == "_ws"
end

local function _validate_category(category)
    if not category or category == "" then
        return false, "Category is required"
    end
    if category:sub(1, 1) == "_" then
        return false, "Categories starting with '_' are reserved"
    end
    if #category > 64 then
        return false, "Category too long"
    end
    if not category:match("^[A-Za-z0-9][A-Za-z0-9_%-%.,]*$") then
        return false, "Invalid category format"
    end
    return true
end

local function _validate_key(key)
    if not key or key == "" then
        return false, "Key is required"
    end
    if #key > 512 then
        return false, "Key too long"
    end
    if key:find("/") then
        return false, "Key must not contain '/'"
    end
    if key:match("[%c%s]") then
        return false, "Key must not contain whitespace/control characters"
    end
    return true
end

local function _key_matches_category(category, key)
    if not category or not key then
        return false
    end
    return key:sub(1, #category + 1) == (category .. ":")
end

_parse_key_timestamp = function(key)
    if type(key) ~= "string" then
        return nil
    end
    local ts = key:match(":(%d+):")
    if ts then
        return tonumber(ts)
    end
    return nil
end

_get_callback_url = function(red, webhook_key)
    local k_new = CALLBACK_PREFIX .. webhook_key
    local v = red:get(k_new)
    if v and v ~= ngx.null then
        return v
    end
    return nil
end

_del_callback_url = function(red, webhook_key)
    local k_new = CALLBACK_PREFIX .. webhook_key
    red:del(k_new)
end

_set_callback_url = function(red, webhook_key, callback_url, ttl)
    local k_new = CALLBACK_PREFIX .. webhook_key
    red:set(k_new, callback_url, "EX", ttl)
end

_index_key_for_category = function(category)
    return INDEX_CAT_PREFIX .. category
end

_index_add = function(red, category, webhook_key, score)
    if not score then
        local ts = _parse_key_timestamp(webhook_key) or ngx.time()
        local crc = 0
        if ngx and ngx.crc32_short then
            crc = ngx.crc32_short(webhook_key) or 0
        end
        -- Offset in [0, 1) so we never cross into the next second.
        local offset = (crc % 1000000) / 1000000
        score = (ts or ngx.time()) + offset
    end
    red:zadd(INDEX_KEY, score, webhook_key)
    red:zadd(_index_key_for_category(category), score, webhook_key)
    red:hincrby(CATEGORY_COUNT_KEY, category, 1)
end

_index_remove = function(red, category, webhook_key)
    red:zrem(INDEX_KEY, webhook_key)
    if category and category ~= "" then
        red:zrem(_index_key_for_category(category), webhook_key)
        red:hincrby(CATEGORY_COUNT_KEY, category, -1)
    else
        -- Best-effort removal when category is unknown: derive from key prefix.
        local cat = webhook_key:match("^([^:]+):")
        if cat then
            red:zrem(_index_key_for_category(cat), webhook_key)
            red:hincrby(CATEGORY_COUNT_KEY, cat, -1)
        end
    end
end

local function _zrevrangebyscore_withscores(red, zkey, max_score, min_score, limit)
    local function _score_arg(v, d)
        if v == nil then
            return d
        end
        if type(v) == "string" then
            return v
        end
        return tostring(v)
    end

    local maxv = _score_arg(max_score, "+inf")
    local minv = _score_arg(min_score, "-inf")
    local res, err = red:zrevrangebyscore(zkey, maxv, minv, "WITHSCORES", "LIMIT", 0, limit)
    if not res then
        return nil, err
    end
    return res
end

local function _decode_index_withscores(res)
    local out = {}
    local i = 1
    while i <= #res do
        local member = res[i]
        local score = tonumber(res[i + 1])
        out[#out + 1] = { member = member, score = score }
        i = i + 2
    end
    return out
end

local function _load_webhook_objects(red, webhook_keys, include_payload)
    if not webhook_keys or #webhook_keys == 0 then
        return {}
    end

    local redis_keys = {}
    for i, k in ipairs(webhook_keys) do
        redis_keys[i] = PREFIX .. k
    end

    local vals, err = mget_chunked(red, redis_keys)
    local ttls, terr = ttl_pipeline_chunked(red, redis_keys)

    local out = {}
    if not vals then
        return out
    end

    for i, val in ipairs(vals) do
        local webhook_key = webhook_keys[i]
        if val and val ~= ngx.null then
            local decoded
            local ok, d = pcall(cjson.decode, val)
            if ok and type(d) == "table" then
                decoded = d
            end
            local ttl = -1
            if ttls and ttls[i] ~= nil then
                ttl = tonumber(ttls[i]) or -1
            end
            local item = {
                key = webhook_key,
                ttl = ttl,
                created_at = decoded and decoded.created_at or nil,
                category = decoded and decoded.category or (webhook_key:match("^([^:]+):") or nil),
            }
            if include_payload then
                item.payload = decoded and decoded.payload or nil
            end
            out[#out + 1] = item
        else
            -- Stale index entry (expired/deleted). Remove lazily.
            _index_remove(red, nil, webhook_key)
        end
    end

    return out
end

local function _ensure_indexes(red)
    local ready_key = PREFIX .. "_index_ready"
    local ready = red:get(ready_key)
    if ready and ready ~= ngx.null and tostring(ready) == "1" then
        return
    end

    -- If indexes already have content, consider them ready.
    local n = red:zcard(INDEX_KEY)
    if n and tonumber(n) and tonumber(n) > 0 then
        red:set(ready_key, "1")
        return
    end

    -- Rebuild from existing webhook keys.
    local keys = scan_keys(red, PREFIX .. "*")
    if not keys or #keys == 0 then
        red:set(ready_key, "1")
        return
    end

    -- Reset counts/indexes (best-effort) to avoid double counting.
    pcall(function()
        red:del(INDEX_KEY)
        red:del(CATEGORY_COUNT_KEY)
    end)

    -- Clear per-category index keys.
    pcall(function()
        local idx_keys = scan_keys(red, INDEX_CAT_PREFIX .. "*")
        if idx_keys and #idx_keys > 0 then
            red:del(unpack(idx_keys))
        end
    end)

    for _, redis_key in ipairs(keys) do
        if redis_key ~= TOTAL_SIZE_KEY
            and redis_key ~= LAST_RECALC_KEY
            and redis_key ~= INDEX_KEY
            and redis_key ~= CATEGORY_COUNT_KEY
            and not string.match(redis_key, "^" .. CALLBACK_PREFIX)
            and not string.match(redis_key, "^" .. METRICS_PREFIX)
            and not string.match(redis_key, "^" .. WEBSOCKET_PREFIX)
            and not string.match(redis_key, "^" .. RATE_LIMIT_PREFIX) then

            local webhook_key = string.gsub(redis_key, "^" .. PREFIX, "")
            local category = webhook_key:match("^([^:]+):")
            if category then
                local ts = _parse_key_timestamp(webhook_key) or ngx.time()
                local crc = 0
                if ngx and ngx.crc32_short then
                    crc = ngx.crc32_short(webhook_key) or 0
                end
                local offset = (crc % 1000000) / 1000000
                local score = ts + offset
                _index_add(red, category, webhook_key, score)
            end
        end
    end

    red:set(ready_key, "1")
end

local function _rate_limit_key_for(identifier)
    local window_start = math.floor(ngx.time() / RATE_LIMIT_WINDOW_S) * RATE_LIMIT_WINDOW_S
    return RATE_LIMIT_PREFIX .. identifier .. ":" .. tostring(window_start)
end

local function _enforce_rate_limit(red, identifier)
    local k = _rate_limit_key_for(identifier)
    local n, err = red:incr(k)
    if not n then
        -- If rate limiting is misbehaving, fail open.
        increment_metric(red, "rate_limit_errors_total")
        return true
    end
    if n == 1 then
        red:expire(k, RATE_LIMIT_WINDOW_S + 1)
    end
    if n > RATE_LIMIT_MAX_REQUESTS then
        increment_metric(red, "rate_limited_total")
        return false, n
    end
    return true, n
end

local function _is_private_ip_literal(host)
    if not host or host == "" then
        return false
    end
    local h = host
    -- Strip port.
    h = h:gsub(":%d+$", "")
    if h == "localhost" then
        return true
    end
    if h:match("^%d+%.%d+%.%d+%.%d+$") then
        local a, b, c, d = h:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        a = tonumber(a)
        b = tonumber(b)
        if not a or not b then
            return false
        end
        if a == 10 then
            return true
        end
        if a == 127 then
            return true
        end
        if a == 192 and b == 168 then
            return true
        end
        if a == 172 and b >= 16 and b <= 31 then
            return true
        end
        if a == 169 and b == 254 then
            return true
        end
        return false
    end
    -- Bracketed IPv6 literal.
    if h:match("^%[.+%]$") then
        -- Block all IPv6 literals by default (conservative).
        return true
    end
    -- Hostname.
    if h:lower():match("^localhost$") then
        return true
    end
    return false
end

_validate_callback_url = function(url)
    if url == nil then
        return true
    end
    if type(url) ~= "string" then
        return false, "callback_url must be a string"
    end
    if url == "" then
        return true
    end
    if #url > CALLBACK_URL_MAX_LEN then
        return false, "callback_url too long"
    end

    local m = ngx.re.match(url, [[^(https?)://([^/]+)(/.*)?$]], "jo")
    if not m then
        return false, "callback_url must be an absolute http(s) URL"
    end
    local scheme = (m[1] or ""):lower()
    local hostport = (m[2] or "")
    if scheme == "http" and not CALLBACK_URL_ALLOW_HTTP then
        return false, "callback_url http scheme is not allowed"
    end

    local host = hostport:lower()
    -- Remove any userinfo
    host = host:gsub("^.-@", "")

    if next(CALLBACK_URL_ALLOWLIST_STATE) ~= nil then
        -- allowlist matches on host (including optional port).
        if not CALLBACK_URL_ALLOWLIST_STATE[host] then
            -- Try without port.
            local bare = host:gsub(":%d+$", "")
            if not CALLBACK_URL_ALLOWLIST_STATE[bare] then
                return false, "callback_url host is not in allowlist"
            end
        end
    end

    if CALLBACK_URL_BLOCK_PRIVATE_IPS and _is_private_ip_literal(host) then
        return false, "callback_url host is not allowed"
    end

    return true
end

-- ==== MAIN LOGIC ====
local method = ngx.req.get_method()
local args = ngx.req.get_uri_args()

if ngx.ctx then
    ngx.ctx.request_start = ngx.now()
end

-- Parse REST-style path: /webhook/category or /webhook/category/key
local uri = ngx.var.uri
local path_parts = {}
for part in string.gmatch(uri, "[^/]+") do
    table.insert(path_parts, part)
end

-- path_parts[1] = "webhook", path_parts[2] = category, path_parts[3] = key (optional)
-- If path_parts[2] exists and is not empty, use it; otherwise use default
local category = DEFAULT_CATEGORY
if path_parts[2] and path_parts[2] ~= "" then
    category = path_parts[2]
end
local key_from_path = path_parts[3]

-- Handle CORS preflight early (no Redis needed).
if method == "OPTIONS" then
    _apply_cors_headers()
    ngx.status = 204
    return ngx.exit(204)
end

-- Connect to Redis
local red, err = redis_client.connect(CFG)
if not red then
    return send_json(500, { error = "Failed to connect to Redis: " .. (err or "unknown") })
end

-- Make the Redis client available to helper functions (e.g., send_json) for
-- centralized metrics accounting.
ngx.ctx.red = red
-- This is a no-op after the first successful rebuild.
_ensure_indexes(red)

-- Determine any presented API key once (also used for rate limiting).
local presented_api_key = _get_presented_api_key()
-- Browsers can't set custom headers on WebSocket connections.
-- For GET /webhook/_ws, allow passing the key via query string.
if (not presented_api_key or presented_api_key == "") and category == "_ws" then
    presented_api_key = args.api_key or args.token
end

-- Optional rate limiting (fail-open if Redis errors).
if RATE_LIMIT_ENABLED and not RATE_LIMIT_EXEMPT[category] then
    local ident
    if presented_api_key and presented_api_key ~= "" then
        ident = "k:" .. ngx.md5(presented_api_key)
    else
        ident = "ip:" .. (ngx.var.remote_addr or "unknown")
    end

    local ok_rl, current = _enforce_rate_limit(red, ident)
    if not ok_rl then
        return send_json(429, {
            error = "Rate limit exceeded",
            error_code = "RATE_LIMITED",
            window_seconds = RATE_LIMIT_WINDOW_S,
            limit = RATE_LIMIT_MAX_REQUESTS,
            current = current
        }, {
            ["Retry-After"] = tostring(RATE_LIMIT_WINDOW_S)
        })
    end
end

-- Enforce API-key auth if configured.
-- Applies to all endpoints unless exempted via WEBHOOK_AUTH_EXEMPT.
if AUTH_ENABLED and not AUTH_EXEMPT[category] then
    local presented = presented_api_key
    if not presented then
        increment_metric(red, "auth_missing_total")
        return send_json(401, {
            error = "Missing API key",
            error_code = "AUTH_REQUIRED",
            hint = "Provide X-API-Key or Authorization: Bearer <token>"
        }, {
            ["WWW-Authenticate"] = 'Bearer realm="webhook"'
        })
    end
    if not _api_key_is_valid(presented) then
        increment_metric(red, "auth_invalid_total")
        return send_json(403, {
            error = "Invalid API key",
            error_code = "AUTH_INVALID"
        })
    end
end

-- ===== POST =====
if method == "POST" then
    increment_metric(red, "requests_post")

    -- Handle special endpoints
    if category == "_stats" or category == "_metrics" or category == "_export" then
        return send_json(405, { error = "Cannot POST to this endpoint", error_code = "METHOD_NOT_ALLOWED" })
    end

    if category == "_search" then
        return send_json(405, { error = "Cannot POST to search endpoint", error_code = "METHOD_NOT_ALLOWED" })
    end

    -- POST /webhook/_import - import webhooks from backup
    if category == "_import" then
        local body, err = read_request_body()
        if not body then
            return send_json(400, { error = "No import data received", error_code = "NO_BODY" })
        end

        local import_data, perr = cjson.decode(body)
        if not import_data then
            return send_json(400, { error = "Invalid JSON in import data", error_code = "INVALID_JSON" })
        end

        local results, import_err = import_webhooks(red, import_data)
        if not results then
            return send_json(400, { error = import_err, error_code = "INVALID_IMPORT_FORMAT" })
        end

        return send_json(200, results)
    end

    -- POST /webhook/:category/:key/_replay - replay a webhook
    if key_from_path and path_parts[4] == "_replay" then
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end
        local ok_key, key_err = _validate_key(key_from_path)
        if not ok_key then
            return send_json(400, { error = key_err, error_code = "INVALID_KEY" })
        end
        if not _key_matches_category(category, key_from_path) then
            return send_json(400, { error = "Key does not match category", error_code = "KEY_CATEGORY_MISMATCH" })
        end

        local full_key = PREFIX .. key_from_path
        local val = red:get(full_key)
        if not val or val == ngx.null then
            return send_json(404, { error = "Webhook not found", error_code = "KEY_NOT_FOUND" })
        end

        local decoded = cjson.decode(val)
        if not decoded or not decoded.payload then
            return send_json(500, { error = "Failed to decode webhook data", error_code = "DECODE_ERROR" })
        end

        -- Get optional replay configuration from request body
        local body = read_request_body()
        local replay_config = {}
        if body and body ~= "" then
            local ok, config = pcall(cjson.decode, body)
            if ok then
                replay_config = config
            end
        end

        -- Replay: create a new webhook with the same payload
        -- TTL from query params takes precedence, then body config, then default
        local new_ttl = tonumber(args.ttl) or replay_config.ttl or DEFAULT_TTL
        local new_category = args.category or replay_config.category or decoded.category
        do
            local ok_new_cat, new_cat_err = _validate_category(new_category)
            if not ok_new_cat then
                return send_json(400, { error = new_cat_err, error_code = "INVALID_CATEGORY" })
            end
        end
        local payload_json = cjson.encode(decoded.payload)

        local created_at = iso8601_timestamp()
        local new_key = PREFIX .. new_category .. ":" .. ngx.time() .. ":replay:" .. ngx.md5(payload_json .. created_at)

        local store_data = {
            created_at = created_at,
            category = new_category,
            payload = decoded.payload,
            size = #payload_json,
            replayed_from = key_from_path,
            original_created_at = decoded.created_at
        }

        local ok, rerr = red:set(new_key, cjson.encode(store_data), "EX", new_ttl)
        if not ok then
            return send_json(500, {
                error = "Failed to replay webhook",
                error_code = "REDIS_ERROR",
                details = rerr
            })
        end

        update_total_size(red, #payload_json)

        local generated_key = string.gsub(new_key, "^" .. PREFIX, "")

        _index_add(red, new_category, generated_key)

        -- Publish WebSocket event
        publish_websocket_event(red, "webhook.replayed", {
            key = generated_key,
            category = new_category,
            original_key = key_from_path
        })

        return send_json(200, {
            status = "replayed",
            new_key = generated_key,
            original_key = key_from_path,
            created_at = created_at,
            category = new_category,
            ttl = new_ttl,
            url = ngx.var.scheme .. "://" .. ngx.var.host .. "/webhook/" .. new_category .. "/" .. generated_key
        })
    end

    -- Validate non-internal category for creation.
    do
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end
    end

    local body, err = read_request_body()
    if not body then
        return send_json(400, { error = "No POST body received", error_code = "NO_BODY", details = err })
    end

    if #body > MAX_BODY_SIZE then
        return send_json(413, { error = "Payload too large", error_code = "PAYLOAD_TOO_LARGE" })
    end

    local payload, perr = cjson.decode(body)
    if not payload then
        return send_json(400, { error = "Invalid JSON payload", error_code = "INVALID_JSON" })
    end

    -- Handle batch operations: POST /webhook/:category/_batch
    if key_from_path == "_batch" then
        if type(payload) ~= "table" or not payload.items or type(payload.items) ~= "table" then
            return send_json(400, {
                error = "Batch requires 'items' array in payload",
                error_code = "INVALID_BATCH_FORMAT",
                example = { items = { {data = "..."}, {data = "..."} } }
            })
        end

        local current_total = lazy_recalc_total_size(red)
        local batch_results = {
            success = {},
            failed = {},
            total_created = 0,
            total_failed = 0
        }

        for idx, item in ipairs(payload.items) do
            if type(item) == "table" then
                local item_json = cjson.encode(item)

                if current_total + #item_json > TOTAL_PAYLOAD_LIMIT then
                    table.insert(batch_results.failed, {
                        index = idx,
                        error = "Storage limit reached",
                        error_code = "STORAGE_LIMIT_EXCEEDED"
                    })
                    batch_results.total_failed = batch_results.total_failed + 1
                else
                    local ttl = tonumber(item.ttl) or DEFAULT_TTL
                    if ttl <= 0 then ttl = DEFAULT_TTL end
                    item.ttl = nil

                    local created_at = iso8601_timestamp()
                    local key = PREFIX .. category .. ":" .. ngx.time() .. ":" .. idx .. ":" .. ngx.md5(item_json)

                    local store_data = {
                        created_at = created_at,
                        category = category,
                        payload = item,
                        size = #item_json
                    }

                    local ok, rerr = red:set(key, cjson.encode(store_data), "EX", ttl)
                    if ok then
                        update_total_size(red, #item_json)
                        current_total = current_total + #item_json

                        local webhook_key = string.gsub(key, "^" .. PREFIX, "")
                        _index_add(red, category, webhook_key)

                        table.insert(batch_results.success, {
                            index = idx,
                            key = webhook_key,
                            created_at = created_at
                        })
                        batch_results.total_created = batch_results.total_created + 1
                    else
                        table.insert(batch_results.failed, {
                            index = idx,
                            error = "Failed to store in Redis",
                            error_code = "REDIS_ERROR",
                            details = rerr
                        })
                        batch_results.total_failed = batch_results.total_failed + 1
                    end
                end
            else
                table.insert(batch_results.failed, {
                    index = idx,
                    error = "Item is not an object",
                    error_code = "INVALID_ITEM_TYPE"
                })
                batch_results.total_failed = batch_results.total_failed + 1
            end
        end

        local status_code = batch_results.total_failed > 0 and 207 or 200
        return send_json(status_code, batch_results)
    end

    -- Regular single webhook creation
    -- TTL can be specified in query params, payload, or use default
    local ttl = tonumber(args.ttl) or tonumber(payload.ttl) or DEFAULT_TTL
    if ttl <= 0 then ttl = DEFAULT_TTL end
    -- Extract callback URL if provided (query param takes precedence)
    local callback_url = args.callback_url or payload.callback_url

    if callback_url and type(callback_url) == "string" and callback_url ~= "" then
        local ok_cb, cb_err = _validate_callback_url(callback_url)
        if not ok_cb then
            return send_json(400, { error = cb_err, error_code = "INVALID_CALLBACK_URL" })
        end
    end
    -- Remove ttl and callback_url from payload if present
    payload.ttl = nil
    payload.callback_url = nil

    -- Lazy total size check
    local current_total = lazy_recalc_total_size(red)
    if current_total + #body > TOTAL_PAYLOAD_LIMIT then
        return send_json(413, {
            error = "Storage limit reached",
            error_code = "STORAGE_LIMIT_EXCEEDED",
            total_bytes = current_total,
            limit_bytes = TOTAL_PAYLOAD_LIMIT
        })
    end

    local created_at = iso8601_timestamp()
    local key = PREFIX .. category .. ":" .. ngx.time() .. ":" .. ngx.md5(body)

    local store_data = {
        created_at = created_at,
        category = category,
        payload = payload,
        size = #body
    }

    local ok, rerr = red:set(key, cjson.encode(store_data), "EX", ttl)
    if not ok then
        return send_json(500, {
            error = "Failed to store in Redis: " .. (rerr or "unknown"),
            error_code = "REDIS_ERROR"
        })
    end

    update_total_size(red, #body)

    local generated_key = string.gsub(key, "^" .. PREFIX, "")  -- Remove prefix for URL
    _index_add(red, category, generated_key)

    -- Store callback URL if provided
    if callback_url and type(callback_url) == "string" and callback_url ~= "" then
        _set_callback_url(red, generated_key, callback_url, ttl)
    end
    local total_size = get_total_size(red)

    -- Increment metrics
    increment_metric(red, "created_total")

    -- Publish WebSocket event
    publish_websocket_event(red, "webhook.created", {
        key = generated_key,
        category = category,
        created_at = created_at
    })

    return send_json(200, {
        status = "stored",
        key = generated_key,
        created_at = created_at,
        category = category,
        url = ngx.var.scheme .. "://" .. ngx.var.host .. "/webhook/" .. category .. "/" .. generated_key,
        ttl = ttl,
        callback_registered = callback_url ~= nil
    }, {
        ["X-Storage-Used"] = tostring(total_size),
        ["X-Storage-Limit"] = tostring(TOTAL_PAYLOAD_LIMIT),
        ["X-Storage-Available"] = tostring(TOTAL_PAYLOAD_LIMIT - total_size)
    })

-- ===== GET =====
elseif method == "GET" then
    increment_metric(red, "requests_get")

    -- GET /webhook/_ws - WebSocket event stream (bridges Valkey/Redis pub/sub channel `webhook:events`)
    if category == "_ws" then
        local ws_server = require "resty.websocket.server"

        -- Keep the polling timeouts modest to avoid busy looping while still
        -- delivering events with low latency.
        local poll_timeout_ms = 250

        local wb, werr = ws_server:new({
            timeout = poll_timeout_ms,
            max_payload_len = 64 * 1024
        })
        if not wb then
            increment_metric(red, "ws_handshake_errors_total")
            return send_json(400, {
                error = "Failed to establish WebSocket connection",
                error_code = "WS_HANDSHAKE_FAILED",
                details = werr
            })
        end

        -- Use a dedicated Valkey/Redis connection for pub/sub.
        local pub = redis:new()
        pub:set_timeout(poll_timeout_ms)
        local pok, perr = pub:connect(REDIS_HOST, REDIS_PORT)
        if not pok then
            increment_metric(red, "ws_backend_errors_total")
            wb:send_close()
            return ngx.exit(200)
        end

        local sres, serr = pub:subscribe("webhook:events")
        if not sres then
            increment_metric(red, "ws_backend_errors_total")
            wb:send_close()
            return ngx.exit(200)
        end

        increment_metric(red, "ws_connected_total")
        wb:send_text(cjson.encode({
            type = "webhook.ws_ready",
            timestamp = iso8601_timestamp(),
            data = { channel = "webhook:events" }
        }))

        local function _ws_cleanup()
            increment_metric(red, "ws_disconnected_total")
            pcall(function()
                pub:unsubscribe("webhook:events")
            end)
            pcall(function()
                _redis_put_back(pub)
            end)
            pcall(function()
                wb:send_close()
            end)

            -- Return the main request Redis connection too.
            pcall(function()
                _redis_put_back(red)
            end)
        end

        while true do
            -- 1) Bridge pub/sub messages to the WS client.
            local reply, rerr = pub:read_reply()
            if reply then
                if reply[1] == "message" then
                    local msg = reply[3]
                    local bytes, send_err = wb:send_text(msg)
                    if not bytes then
                        break
                    end
                    increment_metric(red, "ws_messages_sent_total")
                end
            elseif rerr and rerr ~= "timeout" then
                increment_metric(red, "ws_backend_errors_total")
                break
            end

            -- 2) Drain/handle client frames so pings/closes are respected.
            local data, typ, ferr = wb:recv_frame()
            if wb.fatal then
                break
            end

            if typ == "close" then
                break
            elseif typ == "ping" then
                wb:send_pong(data)
            end
            -- Ignore text/binary frames for now.
        end

        _ws_cleanup()
        return ngx.exit(200)
    end

    -- GET /webhook/_metrics - Prometheus metrics endpoint
    if category == "_metrics" then
        _apply_cors_headers()
        ngx.header.content_type = "text/plain; version=0.0.4"
        ngx.say(get_prometheus_metrics(red))
        _redis_put_back(red)
        return ngx.exit(200)
    end

    -- GET /webhook/_stats - return statistics
    if category == "_stats" then
        local stats = get_stats(red)
        return send_json(200, stats, {
            ["X-Total-Webhooks"] = tostring(stats.total_webhooks),
            ["X-Storage-Used"] = tostring(stats.total_size_bytes),
            ["X-Storage-Limit"] = tostring(stats.storage_limit_bytes)
        })
    end

    -- GET /webhook/_export or GET /webhook/:category/_export - export webhooks
    if category == "_export" or key_from_path == "_export" then
        local export_category = (category == "_export") and nil or category
        local export_data = export_webhooks(red, export_category)

        ngx.header.content_type = "application/json"
        ngx.header["Content-Disposition"] = string.format(
            'attachment; filename="webhooks_%s_%s.json"',
            export_category or "all",
            os.date("%Y%m%d_%H%M%S")
        )

        return send_json(200, export_data)
    end

    -- GET /webhook/_search?q=term - search across all webhooks
    if category == "_search" then
        local query = args.q
        if not query or query == "" then
            return send_json(400, {
                error = "Search query required",
                error_code = "MISSING_QUERY",
                usage = "GET /webhook/_search?q=searchterm"
            })
        end

        local limit = _parse_limit(args)
        local cursor = _parse_cursor(args)
        local include_payload = _parse_include_payload(args)

        local max_bound
        if cursor then
            max_bound = "(" .. tostring(cursor)
        else
            max_bound = "+inf"
        end
        local scanned = 0
        local next_cursor = nil
        local results = {}
        local last_match_score = nil

        -- Iterate in batches until we have enough matches or hit the scan cap.
        while #results < limit and scanned < SEARCH_MAX_CANDIDATES do
            local raw, zerr = _zrevrangebyscore_withscores(red, INDEX_KEY, max_bound, "-inf", math.min(MAX_LIMIT, limit * 5))
            if not raw then
                return send_json(500, { error = "Search index read failed", error_code = "REDIS_ERROR", details = zerr })
            end
            local entries = _decode_index_withscores(raw)
            if #entries == 0 then
                next_cursor = nil
                break
            end

            local candidate_keys = {}
            local last_score = nil
            local score_by_member = {}
            for _, e in ipairs(entries) do
                scanned = scanned + 1
                last_score = e.score
                candidate_keys[#candidate_keys + 1] = e.member
                score_by_member[e.member] = e.score
            end

            -- Advance scan cursor for the next batch; actual pagination cursor is
            -- derived from the last returned match (see below).
            if last_score ~= nil then
                max_bound = "(" .. tostring(last_score)
            end

            local redis_keys = {}
            for i, k in ipairs(candidate_keys) do
                redis_keys[i] = PREFIX .. k
            end
            local vals, merr = mget_chunked(red, redis_keys)
            if vals then
                for i, val in ipairs(vals) do
                    local webhook_key = candidate_keys[i]
                    if val and val ~= ngx.null then
                        local ok, decoded = pcall(cjson.decode, val)
                        if ok and type(decoded) == "table" then
                            local payload_str = cjson.encode(decoded.payload or {})
                            if string.find(string.lower(payload_str), string.lower(query), 1, true) then
                                local item = {
                                    key = webhook_key,
                                    ttl = red:ttl(PREFIX .. webhook_key) or -1,
                                    created_at = decoded.created_at,
                                    category = decoded.category,
                                }
                                if include_payload then
                                    item.payload = decoded.payload
                                end
                                results[#results + 1] = item
                                last_match_score = score_by_member[webhook_key]
                                if #results >= limit then
                                    break
                                end
                            end
                        end
                    else
                        _index_remove(red, nil, webhook_key)
                    end
                end
            end

            if #entries < math.min(MAX_LIMIT, limit * 5) then
                break
            end
        end

        -- Determine whether there are more candidates below the last returned match.
        if last_match_score ~= nil then
            local probe, _ = _zrevrangebyscore_withscores(red, INDEX_KEY, "(" .. tostring(last_match_score), "-inf", 1)
            if probe and #probe > 0 then
                next_cursor = last_match_score
            else
                next_cursor = nil
            end
        end

        local headers = {
            ["X-Search-Results"] = tostring(#results)
        }
        if next_cursor then
            headers["X-Next-Cursor"] = tostring(next_cursor)
        end

        return send_json(200, {
            query = query,
            count = #results,
            results = results,
            next_cursor = next_cursor
        }, headers)
    end

    -- GET /webhook/:category/:key - retrieve specific key
    if key_from_path then
        local ok_key, key_err = _validate_key(key_from_path)
        if not ok_key then
            return send_json(400, { error = key_err, error_code = "INVALID_KEY" })
        end
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end
        if not _key_matches_category(category, key_from_path) then
            return send_json(400, {
                error = "Key does not match category",
                error_code = "KEY_CATEGORY_MISMATCH"
            })
        end

        -- Construct full key with prefix
        local full_key = PREFIX .. key_from_path
        local val, gerr = red:get(full_key)
        if not val or val == ngx.null then
            return send_json(404, { error = "Key not found", error_code = "KEY_NOT_FOUND" })
        end
        local ttl = red:ttl(full_key) or -1
        local decoded = cjson.decode(val)

        -- Check for callback URL
        local callback_url = _get_callback_url(red, key_from_path)

        return send_json(200, {
            key = key_from_path,
            ttl = ttl,
            category = decoded and decoded.category or nil,
            created_at = decoded and decoded.created_at or nil,
            value = decoded and decoded.payload or val,
            callback_url = callback_url
        })
    else
        -- GET /webhook/:category - list all keys in category with optional filtering
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end

        local since = args.since and tonumber(args.since)
        local limit = _parse_limit(args)
        local cursor = _parse_cursor(args)
        local include_payload = _parse_include_payload(args)

        local zkey = _index_key_for_category(category)
        local max_bound
        if cursor then
            max_bound = "(" .. tostring(cursor)
        else
            max_bound = "+inf"
        end

        local collected = {}
        local scanned = 0
        local batch_size = math.min(MAX_LIMIT, limit * 3)
        local next_cursor = nil

        while #collected < limit and scanned < SEARCH_MAX_CANDIDATES do
            local raw, zerr = _zrevrangebyscore_withscores(red, zkey, max_bound, "-inf", batch_size)
            if not raw then
                return send_json(500, { error = "Index read failed", error_code = "REDIS_ERROR", details = zerr })
            end

            local entries = _decode_index_withscores(raw)
            if #entries == 0 then
                next_cursor = nil
                break
            end

            local keys = {}
            local last_score = nil
            for _, e in ipairs(entries) do
                scanned = scanned + 1
                last_score = e.score
                local ts = since and _parse_key_timestamp(e.member) or nil
                if (not since) or (ts and ts >= since) then
                    keys[#keys + 1] = e.member
                    if #keys >= limit then
                        break
                    end
                end
            end

            if last_score ~= nil then
                max_bound = "(" .. tostring(last_score)
                next_cursor = last_score
            end

            local objects = _load_webhook_objects(red, keys, include_payload)
            for _, obj in ipairs(objects) do
                if #collected >= limit then
                    break
                end
                collected[#collected + 1] = obj
            end

            if #collected >= limit then
                -- Determine whether there are more results beyond this cursor.
                local probe, _ = _zrevrangebyscore_withscores(red, zkey, "(" .. tostring(next_cursor), "-inf", 1)
                if not probe or #probe == 0 then
                    next_cursor = nil
                end
                break
            end

            if #entries < batch_size then
                next_cursor = nil
                break
            end
        end

        local total_size = get_total_size(red)
        local headers = {
            ["X-Total-Count"] = tostring(#collected),
            ["X-Storage-Used"] = tostring(total_size),
            ["X-Storage-Limit"] = tostring(TOTAL_PAYLOAD_LIMIT)
        }
        if next_cursor then
            headers["X-Next-Cursor"] = tostring(next_cursor)
        end

        return send_json(200, {
            keys = collected,
            count = #collected,
            category = category,
            next_cursor = next_cursor
        }, headers)
    end

-- ===== PATCH =====
elseif method == "PATCH" then
    increment_metric(red, "requests_patch")

    -- PATCH /webhook/:category/:key - update TTL or metadata
    if not key_from_path then
        return send_json(400, {
            error = "Key required in path: /webhook/:category/:key",
            error_code = "MISSING_KEY"
        })
    end

    do
        local ok_key, key_err = _validate_key(key_from_path)
        if not ok_key then
            return send_json(400, { error = key_err, error_code = "INVALID_KEY" })
        end
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end
        if not _key_matches_category(category, key_from_path) then
            return send_json(400, { error = "Key does not match category", error_code = "KEY_CATEGORY_MISMATCH" })
        end
    end

    local body, err = read_request_body()
    if not body then
        return send_json(400, {
            error = "No PATCH body received",
            error_code = "NO_BODY",
            details = err
        })
    end

    local updates, perr = cjson.decode(body)
    if not updates then
        return send_json(400, {
            error = "Invalid JSON payload",
            error_code = "INVALID_JSON"
        })
    end

    local full_key = PREFIX .. key_from_path
    local val = red:get(full_key)
    if not val or val == ngx.null then
        return send_json(404, {
            error = "Key not found",
            error_code = "KEY_NOT_FOUND"
        })
    end

    local decoded = cjson.decode(val)
    local changes = {}

    -- Update TTL if provided
    if updates.ttl then
        local new_ttl = tonumber(updates.ttl)
        if new_ttl and new_ttl > 0 then
            red:expire(full_key, new_ttl)
            changes.ttl = new_ttl

            -- Also update callback TTL if exists
            local k_new = CALLBACK_PREFIX .. key_from_path
            if red:exists(k_new) == 1 then
                red:expire(k_new, new_ttl)
            end
        end
    end

    -- Update callback URL if provided
    if updates.callback_url ~= nil then
        if updates.callback_url == cjson.null or updates.callback_url == "" or updates.callback_url == false then
            -- Remove callback
            _del_callback_url(red, key_from_path)
            changes.callback_url = nil
        else
            -- Set/update callback
            local ok_cb, cb_err = _validate_callback_url(updates.callback_url)
            if not ok_cb then
                return send_json(400, { error = cb_err, error_code = "INVALID_CALLBACK_URL" })
            end
            local current_ttl = red:ttl(full_key)
            if current_ttl and current_ttl > 0 then
                _set_callback_url(red, key_from_path, updates.callback_url, current_ttl)
                changes.callback_url = updates.callback_url
            end
        end
    end

    -- Publish WebSocket event
    if next(changes) then
        publish_websocket_event(red, "webhook.updated", {
            key = key_from_path,
            category = category,
            changes = changes
        })
    end

    return send_json(200, {
        status = "updated",
        key = key_from_path,
        changes = changes,
        ttl = red:ttl(full_key) or -1
    })

-- ===== DELETE =====
elseif method == "DELETE" then
    increment_metric(red, "requests_delete")
    -- DELETE /webhook/:category/_batch - batch delete
    if key_from_path == "_batch" then
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end

        local body, err = read_request_body()
        if not body then
            return send_json(400, {
                error = "No DELETE body received",
                error_code = "NO_BODY",
                details = err
            })
        end

        local payload, perr = cjson.decode(body)
        if not payload or not payload.keys or type(payload.keys) ~= "table" then
            return send_json(400, {
                error = "Batch delete requires 'keys' array in payload",
                error_code = "INVALID_BATCH_FORMAT",
                example = { keys = {"key1", "key2"} }
            })
        end

        local batch_results = {
            deleted = {},
            not_found = {},
            total_deleted = 0,
            total_not_found = 0
        }

        for _, key_to_delete in ipairs(payload.keys) do
            local ok_key, key_err = _validate_key(key_to_delete)
            if not ok_key then
                table.insert(batch_results.not_found, key_to_delete)
                batch_results.total_not_found = batch_results.total_not_found + 1
            elseif not _key_matches_category(category, key_to_delete) then
                table.insert(batch_results.not_found, key_to_delete)
                batch_results.total_not_found = batch_results.total_not_found + 1
            else
            local full_key = PREFIX .. key_to_delete
            local val = red:get(full_key)
            if val and val ~= ngx.null then
                local decoded = cjson.decode(val)
                if decoded and decoded.size then
                    update_total_size(red, -decoded.size)
                else
                    update_total_size(red, -#val)
                end
                _index_remove(red, category, key_to_delete)
                _del_callback_url(red, key_to_delete)
                red:del(full_key)

                table.insert(batch_results.deleted, key_to_delete)
                batch_results.total_deleted = batch_results.total_deleted + 1
            else
                table.insert(batch_results.not_found, key_to_delete)
                batch_results.total_not_found = batch_results.total_not_found + 1
            end
            end
        end

        return send_json(200, batch_results)
    end

    -- DELETE /webhook/:category/:key - single delete
    if not key_from_path then
        return send_json(400, {
            error = "Key required in path: /webhook/:category/:key",
            error_code = "MISSING_KEY"
        })
    end

    do
        local ok_key, key_err = _validate_key(key_from_path)
        if not ok_key then
            return send_json(400, { error = key_err, error_code = "INVALID_KEY" })
        end
        local ok_cat, cat_err = _validate_category(category)
        if not ok_cat then
            return send_json(400, { error = cat_err, error_code = "INVALID_CATEGORY" })
        end
        if not _key_matches_category(category, key_from_path) then
            return send_json(400, { error = "Key does not match category", error_code = "KEY_CATEGORY_MISMATCH" })
        end
    end

    local full_key = PREFIX .. key_from_path
    local val = red:get(full_key)
    if val and val ~= ngx.null then
        local decoded = cjson.decode(val)
        if decoded and decoded.size then
            update_total_size(red, -decoded.size)
        else
            update_total_size(red, -#val)
        end
        _index_remove(red, category, key_from_path)
        _del_callback_url(red, key_from_path)
        red:del(full_key)

        -- Increment metrics
        increment_metric(red, "deleted_total")

        -- Publish WebSocket event
        publish_websocket_event(red, "webhook.deleted", {
            key = key_from_path,
            category = category
        })

        return send_json(200, { status = "deleted", key = key_from_path })
    else
        return send_json(404, {
            error = "Key not found",
            error_code = "KEY_NOT_FOUND"
        })
    end

-- ===== OTHER METHODS =====
else
    return send_json(405, { error = "Method not allowed", error_code = "METHOD_NOT_ALLOWED" })
end
