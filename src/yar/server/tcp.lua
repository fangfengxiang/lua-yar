-- yar/server/tcp.lua
-- YAR TCP 传输层：纯 I/O，不含 accept 循环。
-- 从原 TcpServer 提取 handle_connection 逻辑，改为模块级 serve 函数。
-- accept 循环由 daemon.lua 的 Daemon.run 负责。

local Framing      = require("yar.protocol.framing")
local Log          = require("yar.log")
local ServerConst  = require("yar.server.constants")

local tostring = tostring

local DEFAULT_MAX_BODY_LEN = ServerConst.DEFAULT_MAX_BODY_LEN

local _M = {}

--- Handle a TCP connection: read YAR frame, dispatch, write response
-- Connection-level handler, runnable by any coroutine runtime
-- (lua-eco / Skynet / OpenResty stream cosocket) for multi-connection concurrency;
-- dispatcher handle_message is I/O-free and coroutine-safe.
---@param sock table Accepted client socket
---@param dispatcher Dispatcher Protocol dispatcher
---@param spec table|nil Connection spec (may contain keepalive flag)
---@param opts table|nil { max_body_len, timeout, keepalive }
function _M.serve(sock, dispatcher, spec, opts)
    opts = opts or {}
    local max_body_len = opts.max_body_len or DEFAULT_MAX_BODY_LEN
    local keepalive = (spec and spec.keepalive) or opts.keepalive
    if keepalive then
        -- 连接保活循环：一个 TCP 连接处理多条 YAR 消息，减少握手开销
        while true do
            local data = Framing.receive_message(sock, max_body_len)
            if not data then break end
            local resp, herr = dispatcher:handle_message(data)
            if not resp then
                Log.error("[TCP] handle_message error: " .. tostring(herr))
                break   -- 渲染失败：无法构造错误帧，关闭连接
            end
            local _, serr = sock:send(resp)
            if serr then break end
        end
    else
        -- 单消息模式（向后兼容）
        local data = Framing.receive_message(sock, max_body_len)
        if data then
            local resp, herr = dispatcher:handle_message(data)
            if not resp then
                Log.error("[TCP] handle_message error: " .. tostring(herr))
                return
            end
            local _, serr = sock:send(resp)
            if serr then return end
        end
    end
end

return _M
