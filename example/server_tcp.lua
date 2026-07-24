-- example/server_tcp.lua
-- TCP Yar Server 示例（标准 Lua + luasocket，yar-c 风格的简化 daemon）
--
-- 启动：lua example/server_tcp.lua

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server = require("yar.server")

local api = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
}

local server = Server.new(api)
server:listen("tcp://0.0.0.0:9999")
server:loop()
