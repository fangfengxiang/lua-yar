-- example/server_openresty.lua
-- Yar TCP Server + OpenResty stream 模块高并发示例
--
-- OpenResty stream 模块通过 content_by_lua_block 处理 TCP 连接，
-- ngx.req.sock() 返回下游 cosocket，其 API（receive/send/close）与
-- luasocket 兼容，可直接传给 server:handle({ socket = sock })，无需 adapter。
--
-- 本文件不是独立脚本，而是供 nginx.conf stream{} 引用的 Lua 片段。
-- nginx.conf 配置：
--
--   stream {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       server {
--           listen 9999;
--           content_by_lua_block {
--               require("example.server_openresty").serve()
--           }
--       }
--   }
--
-- 客户端连接：
--   local c = Yar.client.new("tcp://127.0.0.1:9999")
--   print(c:call("add", {10, 20}))   -- => 30

local Server = require("yar.server")

local _M = {}

-- RPC 服务对象（进程级复用，worker 内共享）
-- 宿主模式下 protocol 默认 "tcp"，无需 listen()
local server = Server.new({
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    greet = function(name) return "hello, " .. name end,
})

--- 处理单个 TCP 连接（由 stream content_by_lua 调用）
-- cosocket 的 receive/send/close 与 luasocket 接口一致，直接传入即可
function _M.serve()
    local sock, err = ngx.req.sock()
    if not sock then
        ngx.log(ngx.ERR, "failed to get downstream socket: " .. tostring(err))
        return
    end
    -- handle 内部按 YAR 帧读取、派发、回写
    local ok, e = pcall(function()
        server:handle({ socket = sock })
    end)
    if not ok then
        ngx.log(ngx.ERR, "[Yar OpenResty] handler error: " .. tostring(e))
    end
    sock:close()
end

return _M
