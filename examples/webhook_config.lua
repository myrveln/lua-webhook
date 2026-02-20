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
  -- Prefer env vars (VALKEY_HOST/VALKEY_PORT) if you can.
  -- REDIS_HOST = "127.0.0.1",
  -- REDIS_PORT = 6379,

  -- Authentication (optional)
  -- If you set API_KEYS here, auth becomes enabled for all endpoints
  -- except those listed in AUTH_EXEMPT.
  -- API_KEYS = {"changeme"},
  AUTH_EXEMPT = {"_metrics", "_stats"},
}
