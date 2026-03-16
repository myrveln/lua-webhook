local M = {}

function M.apply(cfg)
    if not cfg or not cfg.CORS_ALLOW_ORIGIN or cfg.CORS_ALLOW_ORIGIN == "" then
        return
    end

    local headers = ngx.req.get_headers()
    local origin = headers["origin"] or headers["Origin"]

    -- If CORS is enabled but no Origin header is present, we still set the
    -- configured allow-origin; this keeps curl/browser behaviors predictable.
    ngx.header["Access-Control-Allow-Origin"] = cfg.CORS_ALLOW_ORIGIN
    ngx.header["Access-Control-Allow-Methods"] = cfg.CORS_ALLOW_METHODS
    ngx.header["Access-Control-Allow-Headers"] = cfg.CORS_ALLOW_HEADERS
    ngx.header["Access-Control-Expose-Headers"] = cfg.CORS_EXPOSE_HEADERS
    ngx.header["Access-Control-Max-Age"] = tostring(cfg.CORS_MAX_AGE_S)

    if cfg.CORS_ALLOW_CREDENTIALS then
        ngx.header["Access-Control-Allow-Credentials"] = "true"
    end

    -- If allow-origin is "*", do not set Vary: Origin.
    if cfg.CORS_ALLOW_ORIGIN ~= "*" and origin and origin ~= "" then
        ngx.header["Vary"] = "Origin"
    end
end

return M
