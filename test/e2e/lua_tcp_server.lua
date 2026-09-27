-- test/e2e/lua_tcp_server.lua
-- E2E Lua TCP 服务端：提供 add(a,b) 方法，keepalive 模式
-- 启动：lua test/e2e/lua_tcp_server.lua [port]
-- 端口来源：arg[1] > env LUA_TCP_PORT > 默认 9802

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server = require("yar.server")

local port = tonumber(arg[1]) or tonumber(os.getenv("LUA_TCP_PORT")) or 9802

local server = Server.new({
    add = function(a, b) return a + b end,
})

server:setopt("keepalive", true)

local ok, err = server:listen("tcp://127.0.0.1:" .. port)
if not ok then
    io.stderr:write("listen failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
server:loop()
