-- example/resty_http_provider.lua
-- lua-resty-http 适配器：将 resty-http 适配为 yar HTTP provider 接口。
--
-- 用法：
--   local provider = require("example.resty_http_provider")
--   Yar.client.set_http_provider(provider)            -- 类级（进程级生效）
--   client:set_options({ http_provider = provider })  -- 实例级（覆盖类级）
--
-- Provider 接口：function(url, opts) → body, err
--   opts 字段：method, body, headers, timeout, connect_timeout, proxy, resolve, keepalive

local resty_http = require("resty.http")

--- yar HTTP provider function (lua-resty-http adapter)
---@param url string Request URL
---@param opts table { method, body, headers, timeout, connect_timeout, proxy, resolve, keepalive }
---@return string|nil body Response body
---@return string|nil err Error message
return function(url, opts)
    local httpc = resty_http.new()
    local res, err = httpc:request_uri(url, {
        method          = opts.method or "POST",
        body            = opts.body,
        headers         = opts.headers,
        timeout         = opts.timeout,           -- resty-http v0.10+ 用毫秒
        connect_timeout = opts.connect_timeout,
        -- proxy / resolve / keepalive 由 resty-http 内部处理（如支持）
    })
    if not res then
        return nil, err or "http request failed"
    end
    if res.status ~= 200 then
        return nil, "http status: " .. res.status
    end
    return res.body
end
