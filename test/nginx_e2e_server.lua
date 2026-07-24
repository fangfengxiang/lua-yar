-- test/nginx_e2e_server.lua
-- nginx content_by_lua 上下文中的 YAR HTTP 服务端 handler
-- 被 test/nginx.conf 的 content_by_lua_block 引用
--
-- 验证：handle_message 在 nginx 请求生命周期内正确工作
--   - ngx.req.read_body() 读取请求体
--   - server:handle_message(data) 处理 YAR 消息
--   - ngx.print(resp) 输出响应

local Yar      = require("yar")
local Server   = Yar.server
local Packager = require("yar.packager.packager")

-- 进程级 Server 实例（init_by_lua 阶段创建，worker 内所有协程共享）
local _server

local function get_server()
    if not _server then
        _server = Server.new({
            add   = function(a, b) return a + b end,
            sub   = function(a, b) return a - b end,
            echo  = function(s) return s end,
            greet = function(name) return "hello, " .. name end,
        })
        _server:set_options({ packager = Packager.JSON })
    end
    return _server
end

-- content_by_lua 入口
local function serve()
    local method = ngx.req.get_method()

    -- GET：内省，返回方法列表
    if method == "GET" then
        ngx.header["Content-Type"] = "application/json"
        local p = Packager.get(Packager.JSON)
        ngx.print(p.pack({ "add", "sub", "echo", "greet" }))
        return
    end

    if method ~= "POST" then
        ngx.status = 405
        ngx.header["Content-Type"] = "text/plain"
        ngx.print("method not allowed")
        return
    end

    -- 读请求体
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data or data == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "text/plain"
        ngx.print("empty body")
        return
    end

    -- 核心：调 yar handle_message（纯函数，reentrant）
    local server = get_server()
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

return {
    serve = serve,
    get_server = get_server,
}
