-- example/server_copas.lua
-- Yar TCP Server + copas 协程并发示例
-- 启动：lua example/server_copas.lua
--
-- copas 是基于 luasocket 的协程调度器，每个连接在独立协程内被调度，
-- 实现单线程多连接并发。server:handle({ socket = client }) 需要一个具备
-- receive(n)/send(data)/close() 的 socket，copas 包装的 socket 直接兼容。
--
-- 安装：luarocks install copas

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local copas  = require("copas")
local socket = require("socket")
local Server = require("yar.server")

local api = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    greet = function(name) return "hello, " .. name end,
}

-- 宿主模式下 protocol 默认 "tcp"，无需 listen()
local server = Server.new(api)

local host, port = "0.0.0.0", 9999
local srv = socket.bind(host, port)
print("Yar Lua TCP server (copas) listening on " .. host .. ":" .. port)

-- copas.addserver：注册监听 socket，每个连接在 copas 协程内回调
copas.addserver(srv, function(client)
    -- copas 已将 client 包装为协程安全 socket（receive/send/close 兼容）
    local ok, err = pcall(function()
        server:handle({ socket = client, keepalive = true })
    end)
    if not ok then
        print("[Yar copas] handler error: " .. tostring(err))
    end
    client:close()
end)

-- copas.loop：启动事件循环（阻塞，内部协程调度多连接并发）
copas.loop()
