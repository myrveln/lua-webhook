local cjson = require "cjson.safe"
cjson.encode_escape_forward_slash(false)
local redis = require "resty.redis"

-- ==== SETTINGS ====
local PREFIX = "webhook:"                     -- prefix for all keys
local CALLBACK_PREFIX = "webhook:callback:"   -- prefix for callback URLs
local METRICS_PREFIX = "webhook:metrics:"     -- prefix for metrics
local WEBSOCKET_PREFIX = "webhook:ws:"        -- prefix for WebSocket subscriptions
local DEFAULT_CATEGORY = "default"            -- fallback category
local DEFAULT_TTL = 259200                    -- 3 days in seconds
local MAX_BODY_SIZE = 1024 * 1024             -- 1 MB
local TOTAL_PAYLOAD_LIMIT = 50 * 1024 * 1024  -- 50 MB total
local TOTAL_SIZE_KEY = PREFIX .. "total_size"
local LAST_RECALC_KEY = PREFIX .. "total_size_last_recalc"
local RECALC_INTERVAL = 300                   -- seconds, 5 minutes
local REDIS_HOST = os.getenv("VALKEY_HOST") or os.getenv("REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = tonumber(os.getenv("VALKEY_PORT") or os.getenv("REDIS_PORT")) or 6379

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
    return data
end

local function send_json(status, tbl, headers)
    ngx.status = status
    ngx.header.content_type = "application/json"

    -- Add custom headers if provided
    if headers then
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
    end

    ngx.say(cjson.encode(tbl))
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

    local keys = red:keys(PREFIX .. "*")
    local sum = 0
    if keys and #keys > 0 then
        local vals, err = red:mget(unpack(keys))
        if vals then
            for i, val in ipairs(vals) do
                local key_name = keys[i]
                if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY then
                    if val and val ~= ngx.null then
                        local ok, d = pcall(cjson.decode, val)
                        if ok and type(d) == "table" and d.size then
                            sum = sum + d.size
                        else
                            sum = sum + #val
                        end
                    end
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
    local keys = red:keys(PREFIX .. "*")

    local count = 0
    local categories = {}
    local oldest_key = nil
    local newest_key = nil
    local oldest_time = nil
    local newest_time = nil

    if keys and #keys > 0 then
        for _, key_name in ipairs(keys) do
            if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY and not string.match(key_name, "^" .. CALLBACK_PREFIX) then
                count = count + 1

                -- Extract category from key
                local cat = string.match(key_name, "^" .. PREFIX .. "([^:]+)")
                if cat then
                    categories[cat] = (categories[cat] or 0) + 1
                end

                -- Extract timestamp from key
                local timestamp = string.match(key_name, ":(%d+):")
                if timestamp then
                    local ts = tonumber(timestamp)
                    if not oldest_time or ts < oldest_time then
                        oldest_time = ts
                        oldest_key = string.gsub(key_name, "^" .. PREFIX, "")
                    end
                    if not newest_time or ts > newest_time then
                        newest_time = ts
                        newest_key = string.gsub(key_name, "^" .. PREFIX, "")
                    end
                end
            end
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
    local keys = red:keys(PREFIX .. "*")
    local results = {}

    if not keys or #keys == 0 then
        return results
    end

    local vals, err = red:mget(unpack(keys))
    if not vals then
        return results
    end

    for i, val in ipairs(vals) do
        local key_name = keys[i]
        if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY and not string.match(key_name, "^" .. CALLBACK_PREFIX) then
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

local function increment_metric(red, metric_name, value)
    value = value or 1
    local metric_key = METRICS_PREFIX .. metric_name
    red:incrby(metric_key, value)
end

local function get_prometheus_metrics(red)
    local metrics = {}
    local metric_keys = red:keys(METRICS_PREFIX .. "*")

    if metric_keys and #metric_keys > 0 then
        for _, key in ipairs(metric_keys) do
            local metric_name = string.gsub(key, "^" .. METRICS_PREFIX, "")
            local value = red:get(key)
            if value and value ~= ngx.null then
                metrics[metric_name] = tonumber(value) or 0
            end
        end
    end

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

    return table.concat(output, "\n") .. "\n"
end

local function export_webhooks(red, category_filter)
    local pattern = category_filter and (PREFIX .. category_filter .. ":*") or (PREFIX .. "*")
    local keys = red:keys(pattern)
    local export_data = {
        version = "1.0",
        exported_at = iso8601_timestamp(),
        category = category_filter or "all",
        webhooks = {}
    }

    if not keys or #keys == 0 then
        return export_data
    end

    local vals = red:mget(unpack(keys))
    if vals then
        for i, val in ipairs(vals) do
            local key_name = keys[i]
            if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY
               and not string.match(key_name, "^" .. CALLBACK_PREFIX)
               and not string.match(key_name, "^" .. METRICS_PREFIX)
               and not string.match(key_name, "^" .. WEBSOCKET_PREFIX) then

                if val and val ~= ngx.null then
                    local ok, decoded = pcall(cjson.decode, val)
                    if ok and type(decoded) == "table" then
                        local webhook_key = string.gsub(key_name, "^" .. PREFIX, "")
                        local ttl = red:ttl(key_name) or -1

                        -- Check for callback URL
                        local callback_key = CALLBACK_PREFIX .. webhook_key
                        local callback_url = red:get(callback_key)
                        if callback_url == ngx.null then
                            callback_url = nil
                        end

                        table.insert(export_data.webhooks, {
                            key = webhook_key,
                            ttl = ttl,
                            created_at = decoded.created_at,
                            category = decoded.category,
                            payload = decoded.payload,
                            callback_url = callback_url
                        })
                    end
                end
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

    for idx, webhook in ipairs(import_data.webhooks) do
        if type(webhook) == "table" and webhook.payload and webhook.category then
            local payload_json = cjson.encode(webhook.payload)
            local ttl = tonumber(webhook.ttl) or DEFAULT_TTL
            if ttl <= 0 then ttl = DEFAULT_TTL end

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

                -- Restore callback URL if present
                if webhook.callback_url then
                    local callback_key = CALLBACK_PREFIX .. string.gsub(key, "^" .. PREFIX, "")
                    red:set(callback_key, webhook.callback_url, "EX", ttl)
                end

                table.insert(results.imported, {
                    index = idx,
                    key = string.gsub(key, "^" .. PREFIX, ""),
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

-- ==== MAIN LOGIC ====
local method = ngx.req.get_method()
local args = ngx.req.get_uri_args()

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

-- Connect to Redis
local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
if not ok then
    return send_json(500, { error = "Failed to connect to Redis: " .. (err or "unknown") })
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

                        table.insert(batch_results.success, {
                            index = idx,
                            key = string.gsub(key, "^" .. PREFIX, ""),
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

    -- Store callback URL if provided
    if callback_url and type(callback_url) == "string" and callback_url ~= "" then
        local callback_key = CALLBACK_PREFIX .. string.gsub(key, "^" .. PREFIX, "")
        red:set(callback_key, callback_url, "EX", ttl)
    end

    local generated_key = string.gsub(key, "^" .. PREFIX, "")  -- Remove prefix for URL
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

    -- GET /webhook/_metrics - Prometheus metrics endpoint
    if category == "_metrics" then
        ngx.header.content_type = "text/plain; version=0.0.4"
        ngx.say(get_prometheus_metrics(red))
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

        local results = search_webhooks(red, query)
        return send_json(200, {
            query = query,
            count = #results,
            results = results
        }, {
            ["X-Search-Results"] = tostring(#results)
        })
    end

    -- GET /webhook/:category/:key - retrieve specific key
    if key_from_path then
        -- Construct full key with prefix
        local full_key = PREFIX .. key_from_path
        local val, gerr = red:get(full_key)
        if not val or val == ngx.null then
            return send_json(404, { error = "Key not found", error_code = "KEY_NOT_FOUND" })
        end
        local ttl = red:ttl(full_key) or -1
        local decoded = cjson.decode(val)

        -- Check for callback URL
        local callback_key = CALLBACK_PREFIX .. key_from_path
        local callback_url = red:get(callback_key)
        if callback_url == ngx.null then
            callback_url = nil
        end

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
        local since = args.since and tonumber(args.since)

        local pattern = PREFIX .. category .. ":*"
        local keys = red:keys(pattern)
        if not keys or #keys == 0 then
            return send_json(200, {
                keys = {},
                count = 0,
                category = category
            }, {
                ["X-Total-Count"] = "0"
            })
        end

        -- Filter by timestamp if 'since' parameter provided
        if since then
            local filtered_keys = {}
            for _, key_name in ipairs(keys) do
                local timestamp = string.match(key_name, ":(%d+):")
                if timestamp and tonumber(timestamp) >= since then
                    table.insert(filtered_keys, key_name)
                end
            end
            keys = filtered_keys
        end

        table.sort(keys, function(a, b) return a > b end) -- latest first

        local list = {}
        local vals, err = red:mget(unpack(keys))
        if vals then
            for i, val in ipairs(vals) do
                local key_name = keys[i]
                if key_name ~= TOTAL_SIZE_KEY and key_name ~= LAST_RECALC_KEY then
                    local decoded
                    if val and val ~= ngx.null then
                        local ok, d = pcall(cjson.decode, val)
                        if ok and type(d) == "table" then
                            decoded = d
                        end
                    end

                    -- Always include payload in REST API response for category listing
                    table.insert(list, {
                        key = string.gsub(key_name, "^" .. PREFIX, ""),  -- Remove prefix
                        ttl = red:ttl(key_name) or -1,
                        created_at = decoded and decoded.created_at or nil,
                        category = decoded and decoded.category or category,
                        payload = decoded and decoded.payload or nil
                    })
                end
            end
        end

        local total_size = get_total_size(red)
        return send_json(200, {
            keys = list,
            count = #list,
            category = category
        }, {
            ["X-Total-Count"] = tostring(#list),
            ["X-Storage-Used"] = tostring(total_size),
            ["X-Storage-Limit"] = tostring(TOTAL_PAYLOAD_LIMIT)
        })
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
            local callback_key = CALLBACK_PREFIX .. key_from_path
            local callback_exists = red:exists(callback_key)
            if callback_exists == 1 then
                red:expire(callback_key, new_ttl)
            end
        end
    end

    -- Update callback URL if provided
    if updates.callback_url ~= nil then
        local callback_key = CALLBACK_PREFIX .. key_from_path
        if updates.callback_url == "" or updates.callback_url == false then
            -- Remove callback
            red:del(callback_key)
            changes.callback_url = nil
        else
            -- Set/update callback
            local current_ttl = red:ttl(full_key)
            if current_ttl and current_ttl > 0 then
                red:set(callback_key, updates.callback_url, "EX", current_ttl)
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
            local full_key = PREFIX .. key_to_delete
            local val = red:get(full_key)
            if val and val ~= ngx.null then
                local decoded = cjson.decode(val)
                if decoded and decoded.size then
                    update_total_size(red, -decoded.size)
                else
                    update_total_size(red, -#val)
                end
                red:del(full_key)

                -- Also delete callback if exists
                local callback_key = CALLBACK_PREFIX .. key_to_delete
                red:del(callback_key)

                table.insert(batch_results.deleted, key_to_delete)
                batch_results.total_deleted = batch_results.total_deleted + 1
            else
                table.insert(batch_results.not_found, key_to_delete)
                batch_results.total_not_found = batch_results.total_not_found + 1
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

    local full_key = PREFIX .. key_from_path
    local val = red:get(full_key)
    if val and val ~= ngx.null then
        local decoded = cjson.decode(val)
        if decoded and decoded.size then
            update_total_size(red, -decoded.size)
        else
            update_total_size(red, -#val)
        end
        red:del(full_key)

        -- Also delete callback if exists
        local callback_key = CALLBACK_PREFIX .. key_from_path
        red:del(callback_key)

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
    increment_metric(red, "errors_total")
    return send_json(405, { error = "Method not allowed", error_code = "METHOD_NOT_ALLOWED" })
end
