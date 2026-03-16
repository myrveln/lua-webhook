-- Example override module for lua-webhook.
--
-- 1) Copy this file to a stable location on your server, for example:
--      /etc/openresty/lua/webhook_config.lua
--
-- 2) Ensure that directory is on `lua_package_path`.
--
-- 3) Restart/reload OpenResty.
--
-- Notes:
-- - This module is loaded via: require("webhook_config") by default.
-- - You can change the module name via env var: WEBHOOK_CONFIG_MODULE.
-- - Values here override defaults in webhook.lua.

return {
  -- Storage & defaults
  DEFAULT_CATEGORY = "default",
  DEFAULT_TTL = 3 * 24 * 60 * 60, -- 3 days
  MAX_BODY_SIZE = 1024 * 1024, -- 1 MB
  TOTAL_PAYLOAD_LIMIT = 50 * 1024 * 1024, -- 50 MB

  -- Redis/Valkey
  -- REDIS_HOST = "127.0.0.1",
  -- REDIS_PORT = 6379,

  -- Authentication (optional)
  -- If you set API_KEYS here, auth becomes enabled for all endpoints
  -- except those listed in AUTH_EXEMPT.
  -- API_KEYS = {"changeme"},
  -- Or, provide SHA-256 hashes instead of plaintext keys:
  -- API_KEY_HASHES = {"<64-char-hex-sha256>"},
  AUTH_EXEMPT = {"_metrics", "_stats"},

  -- Pagination defaults
  -- DEFAULT_LIMIT = 100,
  -- MAX_LIMIT = 1000,

  -- Redis keepalive pooling
  -- REDIS_KEEPALIVE_TIMEOUT_MS = 60000,
  -- REDIS_KEEPALIVE_POOL_SIZE = 100,

  -- Rate limiting (optional)
  -- RATE_LIMIT_ENABLED = false,
  -- RATE_LIMIT_WINDOW_S = 60,
  -- RATE_LIMIT_MAX_REQUESTS = 300,
  -- RATE_LIMIT_EXEMPT = {"_stats"},

  -- CORS (optional)
  -- CORS_ALLOW_ORIGIN = "*",

  -- Callback URL validation (stored only)
  -- CALLBACK_URL_ALLOW_HTTP = true,
  -- CALLBACK_URL_ALLOWLIST = {"example.com"},
}
