-- yar/transport/http.lua
-- HTTP 传输：通过 HTTP POST 发送 YAR 消息。
-- 依赖 transport.socket 抽象，框架本身不引用 ngx；OpenResty 注入 cosocket 即用。

local Socket   = require("yar.transport.socket")
local Resolve  = require("yar.transport.resolve")
local Const    = require("yar.transport.constants")

local string, tonumber, pairs, tostring, table, setmetatable, ipairs =
    string, tonumber, pairs, tostring, table, setmetatable, ipairs

---@class Http
---@field url string|nil Service URL (raw string, for provider path)
---@field parsed_url table|nil Parsed URL { scheme=, host=, port=, path= }
---@field options table|nil Client options
local _M = {}
_M.__index = _M

-- 类级 HTTP provider（nil = 用默认手动实现）
local http_provider = nil

--- Set HTTP provider (class-level, process-wide)
-- After injection, all Client HTTP transport goes through provider (unless instance-level override)
---@param provider function|nil HTTP provider function(url, opts) → body, err
function _M.set_provider(provider)
    http_provider = provider
end

-- 延迟引用 VERSION：避免 transport → init 循环依赖（init.lua require client → transport → http）
local USER_AGENT

--- Lazily get User-Agent (requires yar on first call to get VERSION, avoiding circular dependency)
local function user_agent()
    if not USER_AGENT then
        USER_AGENT = "Yar-Lua/" .. require("yar").VERSION
    end
    return USER_AGENT
end

--- Parse URL into a table with scheme, host, port, path
-- 对标 lua-resty-http parse_uri 返回 table 模式，open() 时一次解析缓存到 self.parsed_url
---@param url string URL to parse
---@return table parsed_url { scheme=, host=, port=, path= }
local function parse_url(url)
    local scheme = string.match(url, "^(https?)://") or "http"
    local rest = url:gsub("^https?://", "")
    local hostport, path = string.match(rest, "^([^/]*)(/.*)$")
    path = path or "/"
    local host, port = string.match(hostport or rest, "^([^:]+):(%d+)$")
    if not host then
        host = hostport or rest
    end
    port = tonumber(port) or (scheme == "https" and Const.HTTPS_PORT or Const.HTTP_PORT)
    return { scheme = scheme, host = host, port = port, path = path }
end

--- Parse proxy host and port from proxy option
-- Supports "http://host:port", "host:port", "http://host", "host" (default port 8080)
---@param proxy_str string Proxy address
---@return string|nil phost Proxy host
---@return number|nil pport Proxy port (nil if no proxy)
local function parse_proxy(proxy_str)
    if not proxy_str or proxy_str == "" then return nil end
    local phost, pport = string.match(proxy_str, "^https?://([^:]+):(%d+)")
    if not phost then
        phost, pport = string.match(proxy_str, "^([^:]+):(%d+)")
    end
    if not phost then
        -- 无端口：提取 host，使用默认端口 8080
        phost = string.match(proxy_str, "^https?://([^:/]+)")
        if not phost then
            phost = string.match(proxy_str, "^([^:/]+)")
        end
        pport = Const.HTTP_PROXY_PORT
    end
    return phost, tonumber(pport)
end

--- Default manual HTTP implementation (HTTP POST via socket abstraction, returns response body)
---@param parsed_url table Parsed URL { scheme=, host=, port=, path= }
---@param data string Request body
---@param options table|nil Transport options
---@return string|nil body Response body
---@return string|nil err Error message
local function manual_request(parsed_url, data, options)
    options = options or {}
    local transport_opts = options.transport or options
    local scheme, host, port, path = parsed_url.scheme, parsed_url.host, parsed_url.port, parsed_url.path

    -- resolve 选项：用自定义 IP 替换连接目标（Host header 保持原 host）
    local connect_host = Resolve.apply_resolve(host, port, transport_opts.resolve)

    -- proxy 选项：connect 到代理，请求行用绝对 URI
    local phost, pport = parse_proxy(transport_opts.proxy)
    local use_proxy = phost ~= nil

    local sock, err = Socket.tcp()
    if not sock then return nil, err end
    -- 超时：cosocket 三段（connect/send/receive），luasocket 单一
    local timeout = transport_opts.timeout or Const.DEFAULT_TIMEOUT
    local connect_timeout = transport_opts.connect_timeout or Const.DEFAULT_CONNECT_TIMEOUT
    Socket.set_timeouts(sock, connect_timeout, timeout, timeout)
    if use_proxy then
        local ok, cerr = sock:connect(phost, pport)
        if not ok then sock:close(); return nil, cerr end
    else
        local ok, cerr = sock:connect(connect_host, port)
        if not ok then sock:close(); return nil, cerr end
    end
    if scheme == "https" then
        -- HTTPS over proxy：先发 CONNECT 隧道请求，代理回 200 后再 sslhandshake
        -- 隧道建立后，后续 TLS 握手与请求发送与直连完全一致
        if use_proxy then
            -- CONNECT 请求目标为 authority 形式（host:port），Host 头同步
            local connect_target = host .. ":" .. port
            local connect_req = table.concat({
                Const.HTTP_METHOD_CONNECT, " ", connect_target, " HTTP/1.1", Const.HTTP_LINE_DELIMITER,
                "Host: ", connect_target, Const.HTTP_LINE_DELIMITER,
                "User-Agent: ", user_agent(), Const.HTTP_LINE_DELIMITER,
                Const.HTTP_LINE_DELIMITER,
            })
            local _, cerr = sock:send(connect_req)
            if cerr then sock:close(); return nil, cerr end
            -- 读代理响应状态行，必须 200（含 200 Connection established 等）
            local line = sock:receive("*l")
            if not line then sock:close(); return nil, "proxy CONNECT no response" end
            local status = tonumber(string.match(line, "HTTP/%d+%.%d+%s+(%d+)"))
            if not status or status ~= Const.HTTP_OK then
                sock:close()
                return nil, "proxy CONNECT rejected: " .. line
            end
            -- 消费代理响应剩余 headers（到空行结束）
            while true do
                line = sock:receive("*l")
                if not line or line == "" then break end
            end
            -- 隧道已建立，继续 sslhandshake（SNI 用目标 host，非代理 host）
        end
        if not sock.sslhandshake then
            sock:close()
            return nil, "https requires ssl-capable socket (set cosocket provider)"
        end
        -- ssl_verify 默认 true（对齐 lua-resty-http / luasec 业界默认）
        -- 生产环境必须开启证书验证；开发/自签场景可设 transport.ssl_verify = false
        local ssl_verify = transport_opts.ssl_verify ~= false
        local ssl_sock, serr = sock:sslhandshake(nil, host, ssl_verify)
        if not ssl_sock then sock:close(); return nil, serr or "ssl handshake failed" end
    end

    -- 请求行：走代理用绝对 URI（省略默认端口），直连用相对 path
    local default_port = (scheme == "https" and Const.HTTPS_PORT or Const.HTTP_PORT)
    local request_target = use_proxy
        and (scheme .. "://" .. host .. (port ~= default_port and (":" .. port) or "") .. path)
        or path

    -- 构建请求头：默认头有序排列，用户自定义头可覆盖（大小写不敏感），不产生重复头
    local default_headers = {
        { "Host",            host },
        { "Content-Type",    Const.HTTP_CONTENT_TYPE_OCTET_STREAM },
        { "Content-Length",  tostring(#data) },
        { "User-Agent",      user_agent() },
        { "Connection",      Socket.poolable(sock) and Const.HTTP_CONN_KEEP_ALIVE or Const.HTTP_CONN_CLOSE },
    }
    -- 收集用户自定义头（按小写键索引，用于大小写不敏感的覆盖匹配）
    local user_headers = {}
    if transport_opts.headers then
        for k, v in pairs(transport_opts.headers) do
            user_headers[string.lower(k)] = { key = k, val = v }
        end
    end
    -- 默认头：若用户覆盖了同名头（大小写不敏感），用用户的值并标记已消费
    local parts = {}
    for _, pair in ipairs(default_headers) do
        local dk, dv = pair[1], pair[2]
        local ov = user_headers[string.lower(dk)]
        if ov then
            dv = ov.val
            user_headers[string.lower(dk)] = nil  -- 标记已使用，避免重复输出
        end
        parts[#parts + 1] = dk .. ": " .. dv .. Const.HTTP_LINE_DELIMITER
    end
    -- 追加非覆盖性用户自定义头
    for _, entry in pairs(user_headers) do
        parts[#parts + 1] = entry.key .. ": " .. entry.val .. Const.HTTP_LINE_DELIMITER
    end

    local req = table.concat({
        Const.HTTP_METHOD_POST, " ", request_target, " HTTP/1.1", Const.HTTP_LINE_DELIMITER,
        table.concat(parts),
        Const.HTTP_LINE_DELIMITER,
        data,
    })
    local _, serr2 = sock:send(req)
    if serr2 then sock:close(); return nil, serr2 end
    -- 读 status line
    local line = sock:receive("*l")
    if not line then sock:close(); return nil, "no response" end
    local status = tonumber(string.match(line, "HTTP/%d+%.%d+%s+(%d+)"))
    -- 读 headers
    local content_length
    local chunked = false
    while true do
        line = sock:receive("*l")
        if not line or line == "" then break end
        local k, v = string.match(line, "^([^:]+):%s*(.*)$")
        if k and string.lower(k) == "content-length" then
            content_length = tonumber(v)
        elseif k and string.lower(k) == "transfer-encoding" and string.lower(v) == "chunked" then
            chunked = true
        end
    end
    local body, rerr
    if chunked then
        -- 分块读取：按 chunk size 行读取每个分块，直到 0 长度分块
        local chunks = {}
        while true do
            local size_line = sock:receive("*l")
            if not size_line then break end
            local size = tonumber(string.match(size_line, "^%s*(%x+)"), 16)
            if not size or size == 0 then
                -- 消费 0-chunk 后的 trailer headers + 最终 CRLF（HTTP/1.1 规范要求）
                while true do
                    local trailer = sock:receive("*l")
                    if not trailer or trailer == "" then break end
                end
                break
            end
            local chunk = sock:receive(size)
            if not chunk then break end
            chunks[#chunks + 1] = chunk
            sock:receive("*l")  -- 读取分块后的 \r\n
        end
        body = table.concat(chunks)
    elseif content_length then
        body, rerr = sock:receive(content_length)
    else
        body, rerr = sock:receive("*a")   -- 无 Content-Length 时读到连接关闭（luasocket）
    end
    -- body 读取失败：连接可能含残留数据或已断开，close 不归池
    if not body then
        sock:close()
        return nil, rerr or "response body read failed"
    end
    -- 归池：cosocket setkeepalive(idle_timeout, pool_size)，luasocket close
    local ka = transport_opts.keepalive or {}
    Socket.release(sock, ka.idle_timeout, ka.pool_size)
    if status and status ~= Const.HTTP_OK then
        return nil, "http status: " .. status
    end
    return body
end

--- Create a new HTTP transport instance
---@return Http
function _M.new()
    return setmetatable({}, _M)
end

--- Open a connection to the given URL
---@param url string Service URL (http://host/path or https://host/path)
---@param options table|nil Transport options
---@return boolean true (HTTP connections are per-request, no pre-validation needed)
function _M:open(url, options)
    self.url = url
    self.parsed_url = parse_url(url)
    self.options = options or {}
    return true
end

--- Send data over HTTP and receive response
---@param data string YAR binary message to send
---@return string|nil body Response body
---@return string|nil err Error message
function _M:send(data)
    self.options = self.options or {}
    -- 实例级 provider 优先，类级次之，默认手动实现
    local transport_opts = self.options.transport or self.options
    local provider = transport_opts.http_provider or http_provider
    if provider then
        -- 展平嵌套选项为 provider 的 flat opts（provider 不感知 yar 选项结构）
        local headers = {
            ["Content-Type"]   = Const.HTTP_CONTENT_TYPE_OCTET_STREAM,
            ["Content-Length"] = tostring(#data),
            ["User-Agent"]     = user_agent(),
        }
        if transport_opts.headers then
            for k, v in pairs(transport_opts.headers) do
                headers[k] = v
            end
        end
        local opts = {
            method          = Const.HTTP_METHOD_POST,
            body            = data,
            headers         = headers,
            timeout         = transport_opts.timeout or Const.DEFAULT_TIMEOUT,
            connect_timeout = transport_opts.connect_timeout or Const.DEFAULT_CONNECT_TIMEOUT,
            proxy           = transport_opts.proxy,
            resolve         = transport_opts.resolve,
            keepalive       = transport_opts.keepalive,
            ssl_verify      = transport_opts.ssl_verify,  -- 透传给 provider
        }
        return provider(self.url, opts)
    end
    -- 回退到手动实现（使用 open() 时预解析的 parsed_url，跳过重复 URL 解析）
    return manual_request(self.parsed_url, data, self.options)
end

--- Close the HTTP transport (no-op for HTTP, connections are per-request)
function _M:close() end

return _M
