-- test/nginx_stream_server.lua
-- OpenResty 并发测试用 YAR TCP 服务端 handler（stream 模块 content_by_lua 上下文）
--
-- 测试场景：
--   - nginx stream {} 块，2 worker_processes，每个 worker 用 content_by_lua_block
--     处理 TCP 连接
--   - 每个连接在 nginx 协程中处理，调用 handle_message（纯函数，reentrant）
--   - handler 记录每个请求的 worker_id + requestId 到 error.log，供测试脚本
--     解析日志验证协程没有异常、requestId 没有串数据
--   - keepalive 模式：单连接处理多条 YAR 消息
--   - 方法：add/sub/echo/greet（与 PHP 客户端测试对齐）
--
-- 被引用方式：nginx.conf stream {} 的 content_by_lua_block { require("test.nginx_stream_server").serve() }
--
-- 约束：仅测试代码，不修改 src 类库代码
-- 注意：stream 模块中下游 socket 通过 ngx.req.socket(true) 获取（raw request socket）

local Yar      = require("yar")
local Server   = Yar.server
local Packager = require("yar.packager.packager")
local Util     = require("yar.util")
local Framing  = require("yar.protocol.framing")

-- 进程级 Server 实例
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

--- 从 YAR 二进制消息中提取 requestId
---@param data string YAR binary message
---@return number requestId
local function extract_request_id(data)
    if not data or #data < Framing.HEADER_TOTAL then
        return 0
    end
    return Util.unpack_u32(data, Framing.HEADER_OFFSET)
end

local MAX_BODY_LEN = 1024 * 1024  -- 1MB

--- 处理单个 TCP 连接（keepalive 循环）
-- 这是 TcpServer:handle_connection 的带日志版本（测试代码，不修改 src）
---@param sock table downstream cosocket (from ngx.req.socket)
local function handle_connection(sock)
    local server = get_server()
    local worker_id = ngx.worker.id() or -1

    while true do
        -- 读取完整 YAR 消息（packager + header + body）
        local data, rerr = Framing.receive_message(sock, MAX_BODY_LEN)
        if not data then
            -- 连接关闭或读错误，退出 keepalive 循环
            if rerr and rerr ~= "short header" and rerr ~= "connection closed" then
                ngx.log(ngx.WARN, "[YAR-STREAM] worker=", worker_id,
                    " read_error=", rerr)
            end
            break
        end

        -- 提取 requestId 用于日志追踪
        local request_id = extract_request_id(data)

        -- 记录请求开始
        ngx.log(ngx.INFO, "[YAR-STREAM] worker=", worker_id,
            " requestId=", request_id, " status=processing")

        -- 核心：handle_message（纯函数，reentrant，多协程安全）
        local resp, herr = server:handle_message(data)
        if not resp then
            ngx.log(ngx.ERR, "[YAR-STREAM] worker=", worker_id,
                " requestId=", request_id, " status=error err=", herr)
            break  -- 渲染失败：无法构造错误帧，关闭连接
        end

        -- 发送响应
        local _, serr = sock:send(resp)
        if serr then
            ngx.log(ngx.ERR, "[YAR-STREAM] worker=", worker_id,
                " requestId=", request_id, " send_error=", serr)
            break
        end

        -- 记录请求完成
        ngx.log(ngx.INFO, "[YAR-STREAM] worker=", worker_id,
            " requestId=", request_id, " status=done")
    end
end

-- stream content_by_lua 入口
local function serve()
    -- stream 模块中获取下游（客户端）socket
    -- ngx.req.socket(true) 返回 raw request socket，支持 receive/send
    local sock, err = ngx.req.socket(true)
    if not sock then
        ngx.log(ngx.ERR, "[YAR-STREAM] failed to get downstream socket: ", err)
        return
    end

    -- 设置超时（ms）：connect/send/read 三段超时
    sock:settimeouts(5000, 5000, 5000)

    -- 处理连接（keepalive 循环）
    handle_connection(sock)
end

return {
    serve = serve,
    get_server = get_server,
    extract_request_id = extract_request_id,
    handle_connection = handle_connection,
}
