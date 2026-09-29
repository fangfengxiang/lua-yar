-- yar/protocol/framing.lua
-- YAR 消息帧读取：精确读取 n 字节 + 接收完整 YAR 消息（header + packager + body）。
-- 供 transport/tcp.lua（客户端）和 tcp_server.lua（服务端）共用，避免重复实现。

local Header = require("yar.protocol.header")

local table = table

---@class Framing
---@field HEADER_TOTAL integer 82 (header only, body_len covers packager+body)
---@field HEADER_OFFSET integer 1 (header starts at byte 1)
---@field DEFAULT_MAX_BODY_LEN integer 10MB
local _M = {}

_M.PACKAGER_NAME_SIZE = Header.PACKAGER_NAME_SIZE  -- 导出供 dispatcher 等下游复用，单一来源在 header.lua
_M.HEADER_TOTAL = Header.SIZE          -- 先读 header(82)，body_len 涵盖后续 packager_name(8)+body(N)
_M.HEADER_OFFSET = 1                   -- header 从第 1 字节开始（header 在消息最前面）
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

--- Receive a complete YAR message (header + packager + body)
---@param sock table Socket object
---@param max_body_len integer|nil Max body length (default DEFAULT_MAX_BODY_LEN)
---@return string|nil data complete YAR message (header + packager + body)
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
    -- body_len 含 packager name（PHP Yar 语义），实际 body = body_len - PACKAGER_NAME_SIZE
    local actual_body_len = header.body_len - _M.PACKAGER_NAME_SIZE
    if actual_body_len > max_body_len then
        return nil, body_too_large_err(actual_body_len, max_body_len)
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
    local actual_body_len = header.body_len - _M.PACKAGER_NAME_SIZE
    if actual_body_len > max_body_len then
        return nil, body_too_large_err(actual_body_len, max_body_len)
    end
    return true
end

return _M
