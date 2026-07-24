-- example/server_http.lua
-- Yar HTTP Server 示例（标准 Lua + luasocket）
-- 启动：lua example/server_http.lua
--
-- OpenResty 环境请见 README「OpenResty HTTP Server」一节，直接在 content_by_lua
-- 中调用 server:handle({ method = ..., data = ..., writer = ... }) 即可，无需本文件。

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar = require("yar")

local api = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    greet = function(name) return "hello, " .. name end,
}

local server = Yar.server.new(api)
server:listen("http://0.0.0.0:8888")
server:loop()
