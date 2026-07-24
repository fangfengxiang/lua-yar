-- example/hooks.lua
-- Hook 使用示例：日志观测 + 耗时统计
--
-- 演示 Client 和 Server 的 on_request / on_response 回调，
-- 实现 RPC 调用的方法名记录、耗时统计、错误追踪。
-- 运行方式：lua example/hooks.lua（需先启动 PHP 或 Lua Yar Server）

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar = require("yar")

-- ============================================================
-- 客户端 Hook：日志观测 + 耗时统计
-- ============================================================

local client = Yar.client.new("http://127.0.0.1:8888/api")

-- 耗时统计表（方法名 → 最近一次耗时毫秒）
local timings = {}

client:set_options({
    timeout = 3000,
    hooks = {
        on_request = function(method, params)
            -- 记录请求开始时间（os.clock 返回 CPU 时间，此处用 os.time 简化）
            timings[method] = os.clock()
            print(string.format("[client] → %s params=%s", method, tostring(params)))
        end,
        on_response = function(method, retval, err)
            local elapsed = (os.clock() - (timings[method] or 0)) * 1000
            if err then
                print(string.format("[client] ← %s ERR: %s (%.2fms)", method, tostring(err), elapsed))
            else
                print(string.format("[client] ← %s OK: %s (%.2fms)", method, tostring(retval), elapsed))
            end
        end,
    },
})

-- ============================================================
-- 服务端 Hook：请求日志 + 错误追踪
-- ============================================================

local Server = require("yar.server")
local server = Server.new({
    add = function(a, b) return a + b end,
    greet = function(name) return "hello, " .. name end,
})

server:set_options({
    hooks = {
        on_request = function(method, params)
            print(string.format("[server] → %s params=%s", method, tostring(params)))
        end,
        on_response = function(method, retval, err)
            if err then
                print(string.format("[server] ← %s ERR: %s", method, tostring(err)))
            else
                print(string.format("[server] ← %s OK: %s", method, tostring(retval)))
            end
        end,
    },
})

-- ============================================================
-- 演示：处理一条 YAR 请求消息（模拟）
-- ============================================================

-- 构造一条 YAR 请求（通过客户端渲染）
local packager = Yar.get_packager(Yar.PACKAGER_JSON)
local Protocol = require("yar.protocol.protocol")
local Request = require("yar.message.request")

local request = Request.new({
    method = "add",
    params = { 10, 20 },
})
local render_ok, message = pcall(Protocol.render, request, packager)
if not render_ok then
    print("render error: " .. tostring(message))
    os.exit(1)
end

-- 服务端处理请求（触发 server hooks）
print("=== server hooks ===")
local resp = server:handle_message(message)
print()

-- 客户端解析响应（触发 client hooks）
-- 注意：实际场景中 client:call() 会自动触发 hooks，
-- 此处仅演示 handle_message 的 server 端 hooks。
-- 要触发 client hooks，需通过 client:call() 发起真实 RPC 调用。

print("=== done ===")
print("Response bytes: " .. #resp)
