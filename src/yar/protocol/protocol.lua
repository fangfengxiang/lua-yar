-- yar/protocol/protocol.lua
-- Yar 协议：消息的渲染（打包）与解析（解包）
-- 消息布局：[packager_name:8][yar_header:82][body:body_len]

local Util    = require("yar.util")
local Header  = require("yar.protocol.header")

local string = string

---@class Protocol
local _M = {}

local PACKAGER_NAME_SIZE = 8
local HEADER_OFFSET      = PACKAGER_NAME_SIZE + 1   -- header 起始位置（1-based）
local BODY_OFFSET        = PACKAGER_NAME_SIZE + Header.SIZE + 1

-- render/parse 调用 packager.pack/unpack。
--
-- encode/decode 错误处理不对称（Lua 生态惯例）：
--   decode：return nil, err（cjson/dkjson/lua-MessagePack 均如此）→ parse 检查返回值，无需 pcall。
--   encode：throw error()（cjson.encode/dkjson.encode 均如此，生态共识）→ render 直接调用，error() 传播到调用方边界。
--
-- pcall 位置（ADR #37 修正）：
--   render 内部不 pcall——pcall 是 LuaJIT JIT 硬屏障，放在热路径内部会使整条 encode 路径退化为解释器执行。
--   pcall 由调用方在边界处执行（dispatcher:handle_message / client:call），与业界模式一致：
--   cjson 内部不 pcall，OpenResty 在 C 层请求处理器边界 pcall；lua-resty-redis 热路径无 pcall。
--   详见 docs/design/cross-cutting.md ADR #37 修正记录。

--- Render request/response into a YAR binary message
-- encode 错误以 error() 抛出（循环引用/深度超限），由调用方在边界处 pcall 捕获。
---@param message table Request or Response object (needs id, provider, token, pack_body)
---@param packager table Packager module (with name, pack)
---@return string binary message (encode error throws error(), caller should pcall at boundary)
function _M.render(message, packager)
    local payload = packager.pack(message:pack_body())
    local packager_name = Util.pad_field(packager.name, PACKAGER_NAME_SIZE)
    local header = Header.new({
        id       = message.id,
        provider = message.provider,
        token    = message.token,
        body_len = #payload,
    })
    return packager_name .. header:pack() .. payload
end

--- Parse a YAR binary message
---@param data string Binary message
---@param packager table Packager module (with unpack)
---@return table|nil payload Decoded body ({i,m,p} or {i,s,r,o,e})
---@return table|nil header Protocol header
---@return string|nil err Error message
function _M.parse(data, packager)
    if #data < BODY_OFFSET - 1 then
        return nil, nil, "packet too short"
    end
    local header, err = Header.unpack(data, HEADER_OFFSET)
    if not header then
        return nil, nil, err
    end
    if #data < BODY_OFFSET - 1 + header.body_len then
        return nil, nil, "body length mismatch: declared " .. header.body_len
            .. " but only " .. (#data - BODY_OFFSET + 1) .. " bytes available"
    end
    local body = string.sub(data, BODY_OFFSET, BODY_OFFSET + header.body_len - 1)
    local payload, _, perr = packager.unpack(body)
    if perr ~= nil then
        return nil, nil, perr
    end
    return payload, header
end

return _M
