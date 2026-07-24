-- yar/transport/constants.lua
-- 传输层共享常量（叶子模块，零依赖，无循环风险）。
-- 参考 lua-resty-http 的 resty.http_const 模式：包内共享常量集中到叶子模块，
-- 各传输实现（http/tcp/socket）及 server 子模块按需引用，不反向依赖 transport.lua 工厂。

local _M = {}

-- 超时（ms）
_M.DEFAULT_TIMEOUT         = 5000
_M.DEFAULT_CONNECT_TIMEOUT = 1000

-- 端口
_M.HTTP_PORT       = 80
_M.HTTPS_PORT      = 443
_M.HTTP_PROXY_PORT = 8080   -- HTTP 代理默认端口（对齐 PHP YAR_OPT_PROXY 常见默认）

-- HTTP 状态码
_M.HTTP_OK                  = 200
_M.HTTP_BAD_REQUEST         = 400
_M.HTTP_METHOD_NOT_ALLOWED  = 405
_M.HTTP_REQUEST_TOO_LARGE   = 413
_M.HTTP_INTERNAL_ERROR       = 500

-- HTTP 方法
_M.HTTP_METHOD_GET     = "GET"
_M.HTTP_METHOD_POST    = "POST"
_M.HTTP_METHOD_CONNECT = "CONNECT"

-- HTTP 内容类型
_M.HTTP_CONTENT_TYPE_TEXT         = "text/plain"
_M.HTTP_CONTENT_TYPE_JSON         = "application/json"
_M.HTTP_CONTENT_TYPE_OCTET_STREAM = "application/octet-stream"

-- HTTP Connection 头值
_M.HTTP_CONN_KEEP_ALIVE = "keep-alive"
_M.HTTP_CONN_CLOSE      = "close"

-- HTTP 状态码原因短语（RFC 7231 §6）
_M.HTTP_REASON = {
    [_M.HTTP_OK]                  = "OK",
    [_M.HTTP_BAD_REQUEST]         = "Bad Request",
    [_M.HTTP_METHOD_NOT_ALLOWED]  = "Method Not Allowed",
    [_M.HTTP_REQUEST_TOO_LARGE]  = "Request Entity Too Large",
    [_M.HTTP_INTERNAL_ERROR]      = "Internal Server Error",
}

-- HTTP 报文行定界符（RFC 7230 §3.5: CRLF line delimiter）
_M.HTTP_LINE_DELIMITER = "\r\n"

return _M
