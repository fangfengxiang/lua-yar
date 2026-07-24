-- test/nginx_concurrent_server.lua
-- OpenResty 并发测试用 YAR HTTP 服务端 handler（content_by_lua 上下文）
--
-- 测试场景：
--   - nginx 2 worker_processes，每个 worker 用 content_by_lua 处理 HTTP 请求
--   - 每个请求在 nginx 协程中调用 handle_message（纯函数，reentrant）
--   - handler 记录每个请求的 worker_id + requestId 到 error.log，供测试脚本
--     解析日志验证协程没有异常、requestId 没有串数据
--   - 方法：add/sub/echo/greet（与 PHP 客户端测试对齐）
--
-- 被引用方式：nginx.conf 的 content_by_lua_block { require("test.nginx_concurrent_server").serve() }
--
-- 约束：仅测试代码，不修改 src 类库代码

local Yar      = require("yar")
local Server   = Yar.server
local Packager = require("yar.packager.packager")
local Util     = require("yar.util")
local Framing  = require("yar.protocol.framing")

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

--- 从 YAR 二进制消息中提取 requestId（transaction ID）
-- YAR 消息结构：packager(8) + header(82) + body
-- header 的前 4 字节是 requestId（big-endian u32）
---@param data string YAR binary message
---@return number requestId
local function extract_request_id(data)
    if not data or #data < Framing.HEADER_TOTAL then
        return 0
    end
    return Util.unpack_u32(data, Framing.HEADER_OFFSET)
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

    -- 提取 requestId 用于日志追踪
    local request_id = extract_request_id(data)
    local worker_id = ngx.worker.id() or -1

    -- 记录请求开始（测试脚本解析此日志验证协程处理）
    ngx.log(ngx.INFO, "[YAR-CONCURRENT] worker=", worker_id,
        " requestId=", request_id, " status=processing")

    -- 核心：调 yar handle_message（纯函数，reentrant，多协程安全）
    local server = get_server()
    local resp, err = server:handle_message(data)
    if not resp then
        ngx.log(ngx.ERR, "[YAR-CONCURRENT] worker=", worker_id,
            " requestId=", request_id, " status=error err=", err)
        ngx.status = 500
        ngx.header["Content-Type"] = "text/plain"
        ngx.print(err or "internal error")
        return
    end

    -- 记录请求完成
    ngx.log(ngx.INFO, "[YAR-CONCURRENT] worker=", worker_id,
        " requestId=", request_id, " status=done")

    ngx.header["Content-Type"] = Yar.HTTP_TRANSPORT_CONTENT_TYPE
    ngx.print(resp)
end

return {
    serve = serve,
    get_server = get_server,
    extract_request_id = extract_request_id,
}
