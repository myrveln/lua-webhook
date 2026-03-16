local M = {}

local function _env_str(name)
    local v = os.getenv(name)
    if v and v ~= "" then
        return v
    end
    return nil
end

local function _env_num(name)
    local v = _env_str(name)
    if not v then
        return nil
    end
    local n = tonumber(v)
    if n == nil then
        return nil
    end
    return n
end

local function _env_bool_true(name)
    local n = _env_num(name)
    if n ~= nil then
        return n == 1
    end
    local s = _env_str(name)
    if not s then
        return false
    end
    return string.lower(s) == "true"
end

-- Returns true by default unless explicitly disabled via 0/false.
local function _env_bool_default_true(name)
    local n = _env_num(name)
    if n ~= nil and n == 0 then
        return false
    end
    local s = _env_str(name)
    if s and string.lower(s) == "false" then
        return false
    end
    return true
end

local function _normalize_prefix(prefix)
    if not prefix or prefix == "" then
        return "webhook:"
    end
    if prefix:sub(-1) ~= ":" then
        return prefix .. ":"
    end
    return prefix
end

local function _build_allowed_override_map()
    local out = {}
    for _, k in ipairs({
        "PREFIX",
        "DEFAULT_CATEGORY",
        "DEFAULT_TTL",
        "MAX_BODY_SIZE",
        "TOTAL_PAYLOAD_LIMIT",
        "RECALC_INTERVAL",
        "REDIS_HOST",
        "REDIS_PORT",
        "CALLBACK_PREFIX",
        "METRICS_PREFIX",
        "WEBSOCKET_PREFIX",

        "REDIS_KEEPALIVE_TIMEOUT_MS",
        "REDIS_KEEPALIVE_POOL_SIZE",

        "DEFAULT_LIMIT",
        "MAX_LIMIT",
        "SEARCH_MAX_CANDIDATES",

        "RATE_LIMIT_ENABLED",
        "RATE_LIMIT_WINDOW_S",
        "RATE_LIMIT_MAX_REQUESTS",
        "RATE_LIMIT_EXEMPT",
        "RATE_LIMIT_EXEMPT_ENV",

        "CORS_ALLOW_ORIGIN",
        "CORS_ALLOW_METHODS",
        "CORS_ALLOW_HEADERS",
        "CORS_EXPOSE_HEADERS",
        "CORS_ALLOW_CREDENTIALS",
        "CORS_MAX_AGE_S",

        "CALLBACK_URL_MAX_LEN",
        "CALLBACK_URL_ALLOW_HTTP",
        "CALLBACK_URL_ALLOWLIST",
        "CALLBACK_URL_ALLOWLIST_ENV",
        "CALLBACK_URL_BLOCK_PRIVATE_IPS",

        "API_KEY_HASHES",
        "AUTH_API_KEY_HASHES",
        "AUTH_API_KEY_HASHES_ENV",

        "API_KEYS",
        "AUTH_API_KEYS",
        "AUTH_EXEMPT",
        "STATIC_API_KEYS",
        "AUTH_API_KEYS_ENV",
        "AUTH_EXEMPT_ENV",
    }) do
        out[k] = true
    end
    return out
end

local ALLOWED_OVERRIDE_KEYS = _build_allowed_override_map()

local function _apply_overrides(settings, overrides)
    if type(overrides) ~= "table" then
        return
    end
    for k, v in pairs(overrides) do
        if ALLOWED_OVERRIDE_KEYS[k] then
            settings[k] = v
        end
    end
end

function M.load()
    local settings = {
        PREFIX = _normalize_prefix(_env_str("WEBHOOK_PREFIX") or "webhook:"),
        DEFAULT_CATEGORY = _env_str("WEBHOOK_DEFAULT_CATEGORY") or "default",
        DEFAULT_TTL = _env_num("WEBHOOK_DEFAULT_TTL") or 259200, -- 3 days
        MAX_BODY_SIZE = _env_num("WEBHOOK_MAX_BODY_SIZE") or (1024 * 1024), -- 1 MB
        TOTAL_PAYLOAD_LIMIT = _env_num("WEBHOOK_TOTAL_PAYLOAD_LIMIT") or (50 * 1024 * 1024), -- 50 MB
        RECALC_INTERVAL = _env_num("WEBHOOK_RECALC_INTERVAL") or 300, -- seconds

        REDIS_HOST = _env_str("WEBHOOK_REDIS_HOST") or "127.0.0.1",
        REDIS_PORT = _env_num("WEBHOOK_REDIS_PORT") or 6379,

        -- Optional explicit prefixes (rarely needed); defaults derive from PREFIX.
        -- Defaults use underscore to avoid colliding with user categories.
        CALLBACK_PREFIX = _env_str("WEBHOOK_CALLBACK_PREFIX"),
        METRICS_PREFIX = _env_str("WEBHOOK_METRICS_PREFIX"),
        WEBSOCKET_PREFIX = _env_str("WEBHOOK_WEBSOCKET_PREFIX"),

        -- Redis connection pooling (keepalive)
        REDIS_KEEPALIVE_TIMEOUT_MS = _env_num("WEBHOOK_REDIS_KEEPALIVE_TIMEOUT_MS") or 60000,
        REDIS_KEEPALIVE_POOL_SIZE = _env_num("WEBHOOK_REDIS_KEEPALIVE_POOL_SIZE") or 100,

        -- Pagination defaults
        DEFAULT_LIMIT = _env_num("WEBHOOK_DEFAULT_LIMIT") or 100,
        MAX_LIMIT = _env_num("WEBHOOK_MAX_LIMIT") or 1000,
        SEARCH_MAX_CANDIDATES = _env_num("WEBHOOK_SEARCH_MAX_CANDIDATES") or 5000,

        -- Rate limiting (optional)
        RATE_LIMIT_ENABLED = _env_bool_true("WEBHOOK_RATE_LIMIT_ENABLED"),
        RATE_LIMIT_WINDOW_S = _env_num("WEBHOOK_RATE_LIMIT_WINDOW_S") or 60,
        RATE_LIMIT_MAX_REQUESTS = _env_num("WEBHOOK_RATE_LIMIT_MAX_REQUESTS") or 300,
        RATE_LIMIT_EXEMPT = nil, -- module override: {"_stats"}
        RATE_LIMIT_EXEMPT_ENV = os.getenv("WEBHOOK_RATE_LIMIT_EXEMPT") or "_stats",

        -- CORS (optional)
        CORS_ALLOW_ORIGIN = _env_str("WEBHOOK_CORS_ALLOW_ORIGIN"),
        CORS_ALLOW_METHODS = _env_str("WEBHOOK_CORS_ALLOW_METHODS") or "GET,POST,PATCH,DELETE,OPTIONS",
        CORS_ALLOW_HEADERS = _env_str("WEBHOOK_CORS_ALLOW_HEADERS") or "Content-Type,Authorization,X-API-Key",
        CORS_EXPOSE_HEADERS = _env_str("WEBHOOK_CORS_EXPOSE_HEADERS")
            or "X-Total-Count,X-Storage-Used,X-Storage-Limit,X-Storage-Available,X-Next-Cursor,X-Search-Results",
        CORS_ALLOW_CREDENTIALS = _env_bool_true("WEBHOOK_CORS_ALLOW_CREDENTIALS"),
        CORS_MAX_AGE_S = _env_num("WEBHOOK_CORS_MAX_AGE_S") or 600,

        -- Callback URL validation (optional, stored only)
        CALLBACK_URL_MAX_LEN = _env_num("WEBHOOK_CALLBACK_URL_MAX_LEN") or 2048,
        CALLBACK_URL_ALLOW_HTTP = _env_bool_true("WEBHOOK_CALLBACK_URL_ALLOW_HTTP"),
        CALLBACK_URL_ALLOWLIST = nil, -- module override list or nil
        CALLBACK_URL_ALLOWLIST_ENV = os.getenv("WEBHOOK_CALLBACK_URL_ALLOWLIST") or "",
        CALLBACK_URL_BLOCK_PRIVATE_IPS = _env_bool_default_true("WEBHOOK_CALLBACK_URL_BLOCK_PRIVATE_IPS"),

        -- Auth: optional hashed keys
        -- Env var WEBHOOK_API_KEY_HASHES is comma-separated hex sha256 hashes.
        API_KEY_HASHES = nil,
        AUTH_API_KEY_HASHES = nil,
        AUTH_API_KEY_HASHES_ENV = os.getenv("WEBHOOK_API_KEY_HASHES"),

        -- Auth (optional). These can also be overridden from webhook_config.lua.
        API_KEYS = nil,
        AUTH_API_KEYS = nil,
        AUTH_EXEMPT = nil,
        STATIC_API_KEYS = {},
        AUTH_API_KEYS_ENV = os.getenv("WEBHOOK_API_KEYS"),
        AUTH_EXEMPT_ENV = os.getenv("WEBHOOK_AUTH_EXEMPT") or "",
    }

    do
        local module_name = _env_str("WEBHOOK_CONFIG_MODULE") or "webhook_config"
        local ok, overrides = pcall(require, module_name)
        if ok then
            _apply_overrides(settings, overrides)
        end
    end

    settings.PREFIX = _normalize_prefix(settings.PREFIX)

    -- Internal key prefixes.
    -- These default to underscore-prefixed names to avoid collisions with user categories.
    -- If you are upgrading an existing deployment and need to keep reading/writing under the
    -- same internal key locations, set WEBHOOK_CALLBACK_PREFIX / WEBHOOK_METRICS_PREFIX /
    -- WEBHOOK_WEBSOCKET_PREFIX explicitly.

    if settings.CALLBACK_PREFIX == nil or settings.CALLBACK_PREFIX == "" then
        settings.CALLBACK_PREFIX = settings.PREFIX .. "_callback:"
    end
    if settings.METRICS_PREFIX == nil or settings.METRICS_PREFIX == "" then
        settings.METRICS_PREFIX = settings.PREFIX .. "_metrics:"
    end
    if settings.WEBSOCKET_PREFIX == nil or settings.WEBSOCKET_PREFIX == "" then
        settings.WEBSOCKET_PREFIX = settings.PREFIX .. "_ws:"
    end

    local cfg = {
        SETTINGS = settings,

        PREFIX = settings.PREFIX,
        CALLBACK_PREFIX = settings.CALLBACK_PREFIX,
        METRICS_PREFIX = settings.METRICS_PREFIX,
        WEBSOCKET_PREFIX = settings.WEBSOCKET_PREFIX,

        DEFAULT_CATEGORY = settings.DEFAULT_CATEGORY,
        DEFAULT_TTL = settings.DEFAULT_TTL,
        MAX_BODY_SIZE = settings.MAX_BODY_SIZE,
        TOTAL_PAYLOAD_LIMIT = settings.TOTAL_PAYLOAD_LIMIT,

        TOTAL_SIZE_KEY = settings.PREFIX .. "total_size",
        LAST_RECALC_KEY = settings.PREFIX .. "total_size_last_recalc",

        INDEX_KEY = settings.PREFIX .. "_index",
        INDEX_CAT_PREFIX = settings.PREFIX .. "_index:",
        CATEGORY_COUNT_KEY = settings.PREFIX .. "_categories",

        RATE_LIMIT_PREFIX = settings.PREFIX .. "_rl:",

        RECALC_INTERVAL = settings.RECALC_INTERVAL,

        REDIS_HOST = settings.REDIS_HOST,
        REDIS_PORT = settings.REDIS_PORT,

        REDIS_KEEPALIVE_TIMEOUT_MS = tonumber(settings.REDIS_KEEPALIVE_TIMEOUT_MS) or 60000,
        REDIS_KEEPALIVE_POOL_SIZE = tonumber(settings.REDIS_KEEPALIVE_POOL_SIZE) or 100,

        DEFAULT_LIMIT = tonumber(settings.DEFAULT_LIMIT) or 100,
        MAX_LIMIT = tonumber(settings.MAX_LIMIT) or 1000,
        SEARCH_MAX_CANDIDATES = tonumber(settings.SEARCH_MAX_CANDIDATES) or 5000,

        RATE_LIMIT_ENABLED = (settings.RATE_LIMIT_ENABLED == true),
        RATE_LIMIT_WINDOW_S = tonumber(settings.RATE_LIMIT_WINDOW_S) or 60,
        RATE_LIMIT_MAX_REQUESTS = tonumber(settings.RATE_LIMIT_MAX_REQUESTS) or 300,
        RATE_LIMIT_EXEMPT = settings.RATE_LIMIT_EXEMPT,
        RATE_LIMIT_EXEMPT_ENV = settings.RATE_LIMIT_EXEMPT_ENV,

        CORS_ALLOW_ORIGIN = settings.CORS_ALLOW_ORIGIN,
        CORS_ALLOW_METHODS = settings.CORS_ALLOW_METHODS,
        CORS_ALLOW_HEADERS = settings.CORS_ALLOW_HEADERS,
        CORS_EXPOSE_HEADERS = settings.CORS_EXPOSE_HEADERS,
        CORS_ALLOW_CREDENTIALS = (settings.CORS_ALLOW_CREDENTIALS == true),
        CORS_MAX_AGE_S = tonumber(settings.CORS_MAX_AGE_S) or 600,

        CALLBACK_URL_MAX_LEN = tonumber(settings.CALLBACK_URL_MAX_LEN) or 2048,
        CALLBACK_URL_ALLOW_HTTP = (settings.CALLBACK_URL_ALLOW_HTTP == true),
        CALLBACK_URL_ALLOWLIST = settings.CALLBACK_URL_ALLOWLIST,
        CALLBACK_URL_ALLOWLIST_ENV = settings.CALLBACK_URL_ALLOWLIST_ENV,
        CALLBACK_URL_BLOCK_PRIVATE_IPS = (settings.CALLBACK_URL_BLOCK_PRIVATE_IPS == true),
    }

    return cfg
end

return M
