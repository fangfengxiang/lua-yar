-- yar/error.lua
-- 结构化错误对象：替代字符串前缀惯例，提供 .code 字段供程序化匹配。

local type, setmetatable = type, setmetatable

---@class Error
---@field TRANSPORT string Transport layer error code
---@field TIMEOUT string Timeout error code
---@field PROTOCOL string Protocol error code
---@field NOT_FOUND string Method not found error code
---@field EXCEPTION string Method execution exception code
local _M = {}

-- 错误码常量（字符串值，自文档化，debug 时可直接辨识）
_M.TRANSPORT  = "TRANSPORT"
_M.TIMEOUT    = "TIMEOUT"
_M.PROTOCOL   = "PROTOCOL"
_M.NOT_FOUND  = "NOT_FOUND"
_M.EXCEPTION  = "EXCEPTION"

-- 共享 metatable（避免每次 Error.new 创建新 metatable + 闭包）
local Error_mt = { __tostring = function(e)
    return e.message
end}

--- Create a structured error object
---@param code string Error code (Error.TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION)
---@param message string|nil Error message
---@return table err Error object with .code and .message fields
function _M.new(code, message)
    if type(code) ~= "string" then
        code = _M.EXCEPTION
    end
    local err = { code = code, message = message or "" }
    setmetatable(err, Error_mt)
    return err
end

return _M
