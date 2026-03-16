local redis = require "resty.redis"

local M = {}

function M.connect(cfg)
    local red = redis:new()
    red:set_timeout(1000)

    local ok, err = red:connect(cfg.REDIS_HOST, cfg.REDIS_PORT)
    if not ok then
        return nil, err
    end

    return red
end

function M.put_back(cfg, red)
    if not red then
        return
    end

    if cfg.REDIS_KEEPALIVE_POOL_SIZE and cfg.REDIS_KEEPALIVE_POOL_SIZE > 0 then
        pcall(function()
            red:set_keepalive(cfg.REDIS_KEEPALIVE_TIMEOUT_MS, cfg.REDIS_KEEPALIVE_POOL_SIZE)
        end)
    else
        pcall(function()
            red:close()
        end)
    end
end

return M
