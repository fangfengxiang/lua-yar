-- test/e2e/lua_tcp_server.lua
-- E2E Lua TCP 服务端：单请求互通 + 并发测试共用，keepalive 模式
-- 启动：lua test/e2e/lua_tcp_server.lua [port]
-- 端口来源：arg[1] > env LUA_TCP_PORT > 默认 9802
--
-- 方法与 PHP 互操作测试服务端（test/e2e/php_server.php）对齐：
--   add(a, b)   → a + b
--   sub(a, b)   → a - b
--   upper(s)    → string.upper(s)
--   greet(name) → "hello, " .. name

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server = require("yar.server")

local port = tonumber(arg[1]) or tonumber(os.getenv("LUA_TCP_PORT")) or 9802

local server = Server.new({
    add   = function(a, b) return a + b end,
    sub   = function(a, b) return a - b end,
    upper = function(s) return string.upper(s) end,
    greet = function(name) return "hello, " .. name end,
})

server:setopt("keepalive", true)

local ok, err = server:listen("tcp://127.0.0.1:" .. port)
if not ok then
    io.stderr:write("listen failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
server:loop()
