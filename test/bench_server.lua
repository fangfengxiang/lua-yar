-- test/bench_server.lua
-- 压测用最小 TCP 服务端（luasocket, keepalive 模式）
-- 被 benchmark_cosocket.lua / benchmark_matrix.lua 以子进程启动和终止
--
-- 端口来源（优先级递减）：
--   1. 命令行参数 arg[1]
--   2. 环境变量 BENCH_SERVER_PORT
--   3. 默认值 9600（见 test/PORTS.md）
--
-- 启动：lua test/bench_server.lua [port]

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server       = require("yar.server")
local TcpTransport = require("yar.server.tcp")
local Socket       = require("yar.transport.socket")

local port = tonumber(arg[1]) or tonumber(os.getenv("BENCH_SERVER_PORT")) or 9600

local server = Server.new({
    add = function(a, b) return a + b end,
})

local srv, err = Socket.bind("127.0.0.1", port)
if not srv then error("bind failed: " .. tostring(err)) end
srv:settimeout(nil)  -- 阻塞 accept

while true do
    local client = srv:accept()
    if client then
        client:settimeout(server.options.timeout)
        -- keepalive=true：连接保活循环，处理多条消息直到客户端断开
        TcpTransport.serve(client, server.dispatcher, { keepalive = true })
        client:close()
    end
end
