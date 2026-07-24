-- example/server_luaeco.lua
-- Yar TCP Server + lua-eco 协程并发示例
-- 启动：eco example/server_luaeco.lua
--
-- lua-eco 是基于 Lua 5.4 + epoll 的协程优先网络运行时，每个连接在独立协程内
-- 被调度，实现单进程多连接并发。server:handle({ socket = sock }) 需要一个具备
-- receive(n)/send(data)/close() 的 socket，而 lua-eco 的 socket 对象 API
-- 略有不同（recv/recvfull），这里用 adapter 适配。
--
-- 安装：https://github.com/zhaojh329/lua-eco
-- 依赖：luarocks install lua-eco

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local eco    = require("eco")
local socket = require("eco.socket")
local Server = require("yar.server")

local api = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    greet = function(name) return "hello, " .. name end,
}

-- 宿主模式下 protocol 默认 "tcp"，无需 listen()
local server = Server.new(api)

-- 将 lua-eco socket 适配为 luasocket 兼容接口（receive/send/close）
local function adapt(eco_sock)
    return {
        receive = function(_, n)
            -- receive(n)：读最多 n 字节（非精确，由调用方按帧拼接）
            local data, err = eco_sock:recv(n)
            if not data then return nil, err end
            return data
        end,
        send = function(_, data)
            local ok, err = eco_sock:send(data)
            if not ok then return nil, err end
            return #data
        end,
        close = function()
            eco_sock:close()
        end,
    }
end

local host, port = "0.0.0.0", 9999
local srv = socket.listen_tcp(host, port)
print("Yar Lua TCP server (lua-eco) listening on " .. host .. ":" .. port)

-- lua-eco 的事件循环：accept 后 eco.run 为每个连接起一个协程
while true do
    local client = srv:accept()
    if client then
        eco.run(function()
            local sock = adapt(client)
            local ok, err = pcall(function()
                server:handle({ socket = sock })
            end)
            if not ok then
                print("[Yar lua-eco] handler error: " .. tostring(err))
            end
            sock:close()
        end)
    end
end
