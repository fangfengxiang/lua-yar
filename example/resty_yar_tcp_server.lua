-- example/resty_yar_tcp_server.lua
-- lua-resty-yar OPM 包：OpenResty stream 模块 TCP 服务端 handler（连接保活）
--
-- nginx.conf 配置（stream 块，非 http 块）：
--
--   stream {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       server {
--           listen 9999;
--           content_by_lua_block {
--               require("example.resty_yar_tcp_server").serve()
--           }
--       }
--   }
--
-- 并发模型：OpenResty stream 每连接一协程，ngx.req.sock() 返回下游 cosocket。
-- 直接调 yar-lua 的 handle({ socket = sock, keepalive = true })，复用 yar-lua 内置的
-- 帧读取 + 连接保活循环。OPM 层只需组装：拿 socket → 设超时 → 委托 → 关闭。
--
-- options 流向：
--   连接级 keepalive_idle → OPM 层 sock:settimeout()（不经过 yar-lua）
--   服务端级 packager/timeout → init.setup() 时已设到 yar-lua 实例上

local init = require("example.resty_yar_init")

local _M = {}

--- stream content_by_lua 入口
function _M.serve()
    local sock, err = ngx.req.sock()
    if not sock then
        ngx.log(ngx.ERR, "[resty.yar tcp] failed to get downstream socket: " .. tostring(err))
        return
    end

    -- ★ 连接级 option：从 config 读，设在 cosocket 上（不经过 yar-lua）
    local config = init.get_config()
    sock:settimeout(config.keepalive_idle)

    -- ★ 直接调 yar-lua 的 handle(socket 模式)，循环模式
    --   yar-lua 负责：receive_message（帧读取）+ handle_message（协议派发）+ send（回写）
    --   服务端级 options（packager 等）在 init.setup() 时已设到 server 实例上
    --   宿主模式下 protocol 默认 "tcp"
    local server = init.get_server()
    local ok, e = pcall(function()
        server:handle({ socket = sock, keepalive = true })
    end)
    if not ok then
        ngx.log(ngx.ERR, "[resty.yar tcp] handler error: " .. tostring(e))
    end

    sock:close()
end

return _M
