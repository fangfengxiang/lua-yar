-- example/resty_yar_gateway.lua
-- lua-resty-yar OPM 包：RPC 网关示例（服务端 → 作为客户端 → 调用下游服务）
--
-- 这个示例展示为什么服务端也需要注入 cosocket：
--   服务端 A 收到请求 → handle_message 派发到 gateway 方法
--   → gateway 方法内部创建 Yar.client 调用下游服务 B
--   → 这条出向调用走 transport 层，需要 cosocket 才能非阻塞
--
-- 如果不注入 cosocket，出向调用走 luasocket（阻塞），整个 worker 协程被挂住，
-- 其他并发请求全部卡死。注入后走 cosocket，出向调用非阻塞，协程并发不受影响。
--
-- nginx.conf:
--   http {
--       lua_package_path "...";
--       init_by_lua_block { require("example.resty_yar_init").setup() }
--       server {
--           listen 8888;
--           location /api {
--               content_by_lua_block {
--                   require("example.resty_yar_gateway").serve()
--               }
--           }
--       }
--   }

local init   = require("example.resty_yar_init")
local Yar    = init.Yar
local config = init.get_config()

local _M = {}

-- 网关 service：收到 RPC 请求后，转发给下游服务
local service = {
    -- 透传：把请求原样转发给下游
    forward = function(method, params)
        -- ★ 服务端内部作为客户端：创建 Yar.client 调用下游
        --   transport 层已注入 cosocket（init 阶段），connect/send/receive 非阻塞
        --   不注入则走 luasocket 阻塞，worker 协程被挂住
        local client = Yar.client.new("http://127.0.0.1:9900/api")
        client:setopt("timeout", config.client_timeout)
        client:setopt("connect_timeout", config.connect_timeout)
        return client:call(method, params)
    end,

    -- 聚合：并行调用多个下游服务，合并结果
    -- （多协程并行出向调用，每条出向连接走 cosocket 连接池）
    aggregate = function(a_method, a_params, b_method, b_params)
        local client_a = Yar.client.new("http://127.0.0.1:9900/api")
        local client_b = Yar.client.new("http://127.0.0.1:9901/api")
        client_a:setopt("timeout", config.client_timeout)
        client_a:setopt("connect_timeout", config.connect_timeout)
        client_b:setopt("timeout", config.client_timeout)
        client_b:setopt("connect_timeout", config.connect_timeout)

        -- OpenResty 协程并行：两条出向 RPC 同时 in-flight，互不阻塞
        local co_a = ngx.thread.spawn(function()
            return client_a:call(a_method, a_params)
        end)
        local co_b = ngx.thread.spawn(function()
            return client_b:call(b_method, b_params)
        end)

        local _, ret_a = ngx.thread.wait(co_a)
        local _, ret_b = ngx.thread.wait(co_b)

        return { a = ret_a, b = ret_b }
    end,
}

local server = Yar.server.new(service)
server:set_packager(config.packager)

--- content_by_lua 入口
function _M.serve()
    local method = ngx.req.get_method()
    if method ~= "POST" then
        ngx.status = 405
        ngx.print("method not allowed")
        return
    end

    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then data = f:read("*a"); f:close() end
        end
    end
    if not data or data == "" then
        ngx.status = 400
        ngx.print("empty body")
        return
    end

    -- handle_message 内部 pcall 用户方法（forward/aggregate），
    -- 方法内部的出向 RPC 调用走 cosocket（已注入），非阻塞。
    local resp, err = server:handle_message(data)
    if not resp then
        ngx.status = 500
        ngx.header["Content-Type"] = "text/plain"
        ngx.print(err or "internal error")
        return
    end

    ngx.header["Content-Type"] = Yar.HTTP_TRANSPORT_CONTENT_TYPE
    ngx.print(resp)
end

return _M
