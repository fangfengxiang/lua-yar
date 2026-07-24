-- yar/server/http.lua
-- YAR HTTP 传输层：纯 I/O，不含 accept 循环。
-- 两种模式：
--   1. socket 模式 serve(sock, dispatcher, opts) — 从 socket 读取 HTTP 请求
--   2. 回调模式 serve_callback(spec, dispatcher, opts) — 宿主注入 method/data，通过 writer 回调输出
-- accept 循环由 daemon.lua 的 Daemon.run 负责。

local ServerConst    = require("yar.server.constants")
local TransportConst = require("yar.transport.constants")
local Log            = require("yar.log")

local string, table, tonumber, tostring =
    string, table, tonumber, tostring

local DEFAULT_MAX_BODY_LEN = ServerConst.DEFAULT_MAX_BODY_LEN
local MAX_HEADER_COUNT     = ServerConst.MAX_HEADER_COUNT

local _M = {}

-- HTTP 协议常量（单一定义点：transport/constants.lua，对标 lua-resty-http resty.http_const）
local HTTP_OK                  = TransportConst.HTTP_OK
local HTTP_BAD_REQUEST        = TransportConst.HTTP_BAD_REQUEST
local HTTP_METHOD_NOT_ALLOWED = TransportConst.HTTP_METHOD_NOT_ALLOWED
local HTTP_REQUEST_TOO_LARGE  = TransportConst.HTTP_REQUEST_TOO_LARGE
local HTTP_INTERNAL_ERROR      = TransportConst.HTTP_INTERNAL_ERROR

local METHOD_GET  = TransportConst.HTTP_METHOD_GET
local METHOD_POST = TransportConst.HTTP_METHOD_POST

local CONTENT_TYPE_TEXT = TransportConst.HTTP_CONTENT_TYPE_TEXT
local CONTENT_TYPE_JSON = TransportConst.HTTP_CONTENT_TYPE_JSON
local CONTENT_TYPE_YAR  = TransportConst.HTTP_CONTENT_TYPE_OCTET_STREAM

local HTTP_REASON  = TransportConst.HTTP_REASON
local HTTP_LINE_DELIMITER = TransportConst.HTTP_LINE_DELIMITER

--- Build complete HTTP response string (for socket mode)
-- table.concat 风格：无格式串解析开销，高性能 Lua 库（lua-resty-http）惯例
---@param status integer HTTP status code
---@param content_type string Content-Type header value
---@param body string Response body
---@return string response Complete HTTP response
local function http_response(status, content_type, body)
    return table.concat({
        "HTTP/1.1", " ", status, " ", HTTP_REASON[status] or "Error", HTTP_LINE_DELIMITER,
        "Content-Type: ", content_type, HTTP_LINE_DELIMITER,
        "Content-Length: ", #body, HTTP_LINE_DELIMITER,
        "Connection: close", HTTP_LINE_DELIMITER, HTTP_LINE_DELIMITER,
        body
    })
end

--- Send HTTP response via socket, log on error (centralized send + error check)
---@param sock table Client socket
---@param status integer HTTP status code
---@param content_type string Content-Type header value
---@param body string Response body
local function send_response(sock, status, content_type, body)
    local _, serr = sock:send(http_response(status, content_type, body))
    if serr then
        Log.error("[HTTP] send error: " .. tostring(serr))
    end
end

--- Handle an HTTP connection from a socket: read HTTP request, dispatch, write response
-- Socket mode: reads HTTP request line + headers + body from socket, writes HTTP response.
---@param sock table Accepted client socket
---@param dispatcher Dispatcher Protocol dispatcher
---@param _spec table|nil Connection spec (may contain keepalive flag, aligned with TcpTransport)
---@param opts table|nil { max_body_len, timeout }
---@diagnostic disable-next-line: unused-local
function _M.serve(sock, dispatcher, _spec, opts)
    opts = opts or {}
    local max_body_len = opts.max_body_len or DEFAULT_MAX_BODY_LEN

    local line = sock:receive("*l")
    if not line then return end   -- 连接已关闭，直接返回
    local method = string.match(line, "^(%u+)%s")
    if method == METHOD_GET then
        -- GET introspection: return method list as JSON
        local body, perr = dispatcher:pack(dispatcher:list_methods())
        if not body then
            send_response(sock, HTTP_INTERNAL_ERROR, CONTENT_TYPE_TEXT, perr or "encode error")
            return
        end
        send_response(sock, HTTP_OK, CONTENT_TYPE_JSON, body)
        return
    end
    if method ~= METHOD_POST then
        send_response(sock, HTTP_METHOD_NOT_ALLOWED, CONTENT_TYPE_TEXT, "method not allowed")
        return
    end
    -- POST：读 headers 获取 Content-Length
    local content_length
    local header_count = 0
    while true do
        line = sock:receive("*l")
        if not line or line == "" then break end
        header_count = header_count + 1
        if header_count > MAX_HEADER_COUNT then
            send_response(sock, HTTP_BAD_REQUEST, CONTENT_TYPE_TEXT, "too many headers")
            return
        end
        local k, v = string.match(line, "^([^:]+):%s*(.*)$")
        if k and string.lower(k) == "content-length" then
            content_length = tonumber(v)
        end
    end
    -- body 长度上限校验：超出 max_body_len 直接返回 413，不读取 body
    if content_length and content_length > max_body_len then
        send_response(sock, HTTP_REQUEST_TOO_LARGE, CONTENT_TYPE_TEXT,
            "body too large: " .. content_length .. " bytes (max " .. max_body_len .. ")")
        return
    end
    local data = ""
    if content_length and content_length > 0 then
        data = sock:receive(content_length)
        if not data then
            send_response(sock, HTTP_BAD_REQUEST, CONTENT_TYPE_TEXT, "failed to read body")
            return
        end
    end
    if data == "" then
        send_response(sock, HTTP_BAD_REQUEST, CONTENT_TYPE_TEXT, "empty body")
        return
    end
    local resp, herr = dispatcher:handle_message(data)
    if not resp then
        send_response(sock, HTTP_INTERNAL_ERROR, CONTENT_TYPE_TEXT, herr or "internal error")
        return
    end
    send_response(sock, HTTP_OK, CONTENT_TYPE_YAR, resp)
end

--- Handle an HTTP request in callback mode (host environment like OpenResty)
-- Callback mode: host injects method + data, library calls writer(status, headers, body).
-- writer signature: writer(status, headers, body) — aligns with WSGI start_response(status, headers).
-- Parameter order = HTTP wire order = callback execution order: status -> headers -> body.
---@param spec table { method = string, data = string, writer = function }
---@param dispatcher Dispatcher Protocol dispatcher
---@param opts table|nil { max_body_len }
---@return boolean|nil ok true on success, nil on error
---@return string|nil err Error message
function _M.serve_callback(spec, dispatcher, opts)
    opts = opts or {}
    local max_body_len = opts.max_body_len or DEFAULT_MAX_BODY_LEN
    local writer = spec.writer
    if type(writer) ~= "function" then
        return nil, "spec.writer must be a function"
    end

    local method = spec.method
    if method == METHOD_GET then
        -- GET introspection: return method list as JSON
        local body, perr = dispatcher:pack(dispatcher:list_methods())
        if not body then
            local err_body = perr or "encode error"
            writer(HTTP_INTERNAL_ERROR,
                { ["Content-Type"] = CONTENT_TYPE_TEXT, ["Content-Length"] = tostring(#err_body) },
                err_body)
            return true
        end
        writer(HTTP_OK,
            { ["Content-Type"] = CONTENT_TYPE_JSON, ["Content-Length"] = tostring(#body) },
            body)
        return true
    end
    if method ~= METHOD_POST then
        local body = "method not allowed"
        writer(HTTP_METHOD_NOT_ALLOWED,
            { ["Content-Type"] = CONTENT_TYPE_TEXT, ["Content-Length"] = tostring(#body) },
            body)
        return true
    end

    -- POST: process YAR request
    local data = spec.data or ""
    if #data == 0 then
        local body = "empty body"
        writer(HTTP_BAD_REQUEST,
            { ["Content-Type"] = CONTENT_TYPE_TEXT, ["Content-Length"] = tostring(#body) },
            body)
        return true
    end
    -- body 长度上限校验
    if #data > max_body_len then
        local body = "body too large: " .. #data .. " bytes (max " .. max_body_len .. ")"
        writer(HTTP_REQUEST_TOO_LARGE,
            { ["Content-Type"] = CONTENT_TYPE_TEXT, ["Content-Length"] = tostring(#body) },
            body)
        return true
    end
    local resp, herr = dispatcher:handle_message(data)
    if not resp then
        local body = herr or "internal error"
        writer(HTTP_INTERNAL_ERROR,
            { ["Content-Type"] = CONTENT_TYPE_TEXT, ["Content-Length"] = tostring(#body) },
            body)
        return true
    end
    writer(HTTP_OK,
        { ["Content-Type"] = CONTENT_TYPE_YAR, ["Content-Length"] = tostring(#resp) },
        resp)
    return true
end

return _M
