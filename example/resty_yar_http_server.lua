-- example/resty_yar_http_server.lua
-- lua-resty-yar OPM 包：OpenResty HTTP 服务端 handler
--
-- nginx.conf 配置：
--
--   http {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       init_by_lua_block { require("example.resty_yar_init").setup() }
--
--       server {
--           listen 8888;
--           location /api {
--               content_by_lua_block {
--                   require("example.resty_yar_http_server").serve()
--               }
--           }
--       }
--   }
--
-- 并发模型：OpenResty 每请求一协程，handle 是纯协议函数无 I/O，
-- 天然 reentrant，N 个并发请求 = N 个协程并行，由 nginx worker 调度。
-- Server 实例进程级复用（方法表 memoize，热路径只查表不遍历 service）。

local init = require("example.resty_yar_init")

local _M = {}

--- content_by_lua 入口：读 body → handle(callback) → writer 输出响应
function _M.serve()
    local server = init.get_server()
    local method = ngx.req.get_method()

    -- 读请求体（大 body 回退临时文件）
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then data = f:read("*a"); f:close() end
        end
    end
    data = data or ""

    -- writer 回调：将 YAR 响应写入 OpenResty 响应
    -- 签名 writer(status, headers, body)，对标 WSGI start_response(status, headers)
    local function writer(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do
            ngx.header[k] = v
        end
        ngx.print(body)
    end

    -- ★ 核心：调 yar-lua 的 handle(callback 模式)
    --   纯协议函数（解析 packager + header + body → 派发方法 → 渲染响应），
    --   无 I/O、无 yield、reentrant，多协程并发安全。
    --   内部已 pcall 用户方法，方法出错会返回 YAR 错误响应而非抛异常。
    server:handle({ method = method, data = data, writer = writer })
end

return _M
