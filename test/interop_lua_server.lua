-- test/interop_lua_server.lua
-- Lua HTTP 服务端（互操作测试用，PHP 客户端测 Lua 服务端）
-- 启动：lua test/interop_lua_server.lua [port]
-- 客户端连接：http://127.0.0.1:<port>/
--
-- 端口来源（优先级递减）：
--   1. 命令行参数 arg[1]
--   2. 环境变量 LUA_HTTP_PORT
--   3. 默认值 9801（见 test/PORTS.md）
--
-- 方法与 PHP 互操作测试服务端（test/server.php）对齐：
--   add(a, b)   → a + b
--   sub(a, b)   → a - b
--   upper(s)    → string.upper(s)
--   greet(name) → "hello, " .. name

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server = require("yar.server")

local port = tonumber(arg[1]) or tonumber(os.getenv("LUA_HTTP_PORT")) or 9801

local server = Server.new({
    add   = function(a, b) return a + b end,
    sub   = function(a, b) return a - b end,
    upper = function(s) return string.upper(s) end,
    greet = function(name) return "hello, " .. name end,
})

local ok, err = server:listen("http://127.0.0.1:" .. port)
if not ok then
    io.stderr:write("listen failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
server:loop()
