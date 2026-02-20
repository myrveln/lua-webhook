-- Test-only config module used by docker-compose's `openresty_config` service.
-- This file is mounted into the container at:
--   /usr/local/openresty/lualib/webhook_config_test.lua
-- and loaded via:
--   WEBHOOK_CONFIG_MODULE=webhook_config_test

return {
  -- Use an isolated prefix so config tests don't interfere with the main
  -- integration suite (and vice versa).
  PREFIX = "cfgtest:",

  DEFAULT_CATEGORY = "cfg",
  DEFAULT_TTL = 4242,

  -- Keep these small so tests run fast.
  MAX_BODY_SIZE = 256,
  TOTAL_PAYLOAD_LIMIT = 360,

  -- Enable auth (so we can verify module-driven auth config works)
  API_KEYS = {"test-config-key"},

  -- Keep _stats reachable without auth so healthchecks and readiness probes work.
  AUTH_EXEMPT = {"_stats"},
}
