-- yar/protocol/framing.lua
-- YAR 消息帧读取：精确读取 n 字节 + 接收完整 YAR 消息（packager + header + body）。
-- 供 transport/tcp.lua（客户端）和 tcp_server.lua（服务端）共用，避免重复实现。

local Header = require("yar.protocol.header")

local table = table

---@class Framing
---@field HEADER_TOTAL integer 90 (8 + 82)
---@field HEADER_OFFSET integer 9 (header starts at byte 9)
---@field DEFAULT_MAX_BODY_LEN integer 10MB
local _M = {}

_M.HEADER_TOTAL = 8 + Header.SIZE   -- packager(8) + header(82) = 90
_M.HEADER_OFFSET = 9                -- header 从第 9 字节开始（packager name 占 8 字节）
_M.DEFAULT_MAX_BODY_LEN = 10 * 1024 * 1024  -- 10MB 上限，防止恶意大 body 导致内存耗尽

--- Generate body-too-large error message
local function body_too_large_err(body_len, max)
    return "body too large: " .. body_len .. " bytes (max " .. max .. ")"
end

--- Read exactly n bytes
-- Standard TCP read pattern: loop and concatenate until n bytes received.
-- luasocket/cosocket receive(n) may return fewer than n bytes; this loop guarantees completeness.
---@param sock table Socket object (cosocket or luasocket wrapper)
---@param n integer Exact byte count to read
---@return string|nil data received bytes
---@return nil|string err error message
function _M.receive_exact(sock, n)
    local chunks = {}
    local received = 0
    while received < n do
        local chunk, err = sock:receive(n - received)
        if not chunk then return nil, err end
        if #chunk == 0 then
            return nil, "connection closed (received " .. received .. "/" .. n .. " bytes)"
        end
        chunks[#chunks + 1] = chunk
        received = received + #chunk
    end
    return table.concat(chunks)
end

--- Receive a complete YAR message (packager + header + body)
---@param sock table Socket object
---@param max_body_len integer|nil Max body length (default DEFAULT_MAX_BODY_LEN)
---@return string|nil data complete YAR message (packager + header + body)
---@return nil|string err error message
function _M.receive_message(sock, max_body_len)
    max_body_len = max_body_len or _M.DEFAULT_MAX_BODY_LEN
    local head, rerr = _M.receive_exact(sock, _M.HEADER_TOTAL)
    if not head then
        return nil, rerr or "short header"
    end
    local header, err = Header.unpack(head, _M.HEADER_OFFSET)
    if not header then
        return nil, err
    end
    if header.body_len > max_body_len then
        return nil, body_too_large_err(header.body_len, max_body_len)
    end
    local body = "" ---@type string|nil
    if header.body_len > 0 then
        local berr
        body, berr = _M.receive_exact(sock, header.body_len)
        if not body then return nil, berr or "short body" end
    end
    return head .. body
end

--- Check body length of a rendered message (defensive validation before sending)
-- Parses the header from the rendered YAR binary message to extract body_len, compares with max_body_len.
---@param data string Rendered YAR binary message
---@param max_body_len integer|nil Max body length
---@return boolean|nil ok true if within limit
---@return nil|string err error message
function _M.check_body_len(data, max_body_len)
    max_body_len = max_body_len or _M.DEFAULT_MAX_BODY_LEN
    if #data < _M.HEADER_TOTAL then return true end
    -- header 解析失败时 best-effort 放行（返回 true）：调用方已持有完整 data，
    -- 校验仅作防御性前置检查，解析失败交由后续 Protocol.parse 统一报错。
    local header = Header.unpack(data, _M.HEADER_OFFSET)
    if not header then return true end
    if header.body_len > max_body_len then
        return nil, body_too_large_err(header.body_len, max_body_len)
    end
    return true
end

return _M
