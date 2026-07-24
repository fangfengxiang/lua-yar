-- yar/server/daemon.lua
-- YAR Daemon：accept 循环 + 委托 server:handle。
-- 顺序执行（accept -> handle -> close），无并发。
-- WARNING: Lua VM 非线程安全，luasocket accept 阻塞，无内置并发原语。
-- 生产并发用 copas（协程调度器 + 非阻塞 I/O）或 OpenResty（cosocket + worker 进程）。
-- copas 集成路径：server:listen(addr) 创建 listen_sock，传给 copas.addserver() 实现协程并发。

local Log         = require("yar.log")
local ServerConst = require("yar.server.constants")

local tostring, pcall = tostring, pcall
local MAX_ACCEPT_FAILURES = ServerConst.MAX_ACCEPT_FAILURES

local _M = {}

--- Run accept loop: accept connections, delegate to server:handle, close.
-- Sequential execution: one connection at a time, blocking.
-- For concurrency, use copas.addserver(server.listen_sock, handler) or OpenResty.
---@param server Server Server Facade instance (must have listen_sock set)
---@return nil|nil, string|nil Returns nil, err only if listen_sock not set; otherwise loops forever
function _M.run(server)
    if not server.listen_sock then
        return nil, "no addr configured, call listen(addr) first"
    end
    local listen_sock = server.listen_sock  ---@type table
    local opts = server.options or {}
    local fail_count = 0
    while true do
        local client, accept_err = listen_sock:accept()
        if not client then
            fail_count = fail_count + 1
            Log.error("[Daemon] accept error: " .. tostring(accept_err))
            if fail_count >= MAX_ACCEPT_FAILURES then
                return nil, "accept loop aborted: " .. tostring(accept_err)
            end
        else
            fail_count = 0
            if opts.timeout then
                client:settimeout(opts.timeout)
            end
            -- pcall 隔离 handler 异常，对标 copas coroutine.resume 捕获不崩溃
            local ok, handler_err = pcall(function()
                server:handle({ socket = client })
            end)
            if not ok then
                Log.error("[Daemon] handler error: " .. tostring(handler_err))
            end
            client:close()
        end
    end
end

return _M
