-- yar/transport/transport.lua
-- 传输器工厂：按 URL scheme 选择传输方式（http / tcp），并管理 socket 提供者。

local Http   = require("yar.transport.http")
local Tcp    = require("yar.transport.tcp")
local Socket = require("yar.transport.socket")

local string = string

---@class Transport
local _M = {}

--- Set socket provider
-- Framework defaults to luasocket; under OpenResty, inject cosocket
-- to reuse all transport capabilities without modifying the framework:
--   Yar.client.set_socket(ngx.socket)
---@param mod table Socket provider module (e.g. ngx.socket)
---@return Transport
function _M.set_socket(mod)
    Socket.set(mod)
    return _M
end

--- Set HTTP provider (forwards to Http module)
-- Inject a third-party HTTP library (e.g. lua-resty-http) to replace the default manual HTTP implementation
---@param provider function HTTP provider function(url, opts) → body, err
---@return Transport
function _M.set_http_provider(provider)
    require("yar.transport.http").set_provider(provider)
    return _M
end

--- Get transport by URL scheme
---@param url string http://host/path, tcp://host:port, or unix:///path
---@return table transport (Http or Tcp, with new/open/send/close)
function _M.get(url)
    if string.match(url, "^tcp://") or string.match(url, "^unix://") then
        return Tcp  -- TCP 与 Unix socket 都是流式 socket，YAR 帧协议相同
    end
    return Http  -- 默认 HTTP（含 http:// https://）
end

return _M
