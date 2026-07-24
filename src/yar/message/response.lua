-- yar/message/response.lua
-- Yar 响应：{id, status, retval, output, err, provider, token}
-- 响应体打包为 {i=id, s=status, r=retval, o=output, e=error}

local setmetatable = setmetatable

---@class Response
---@field id number Transaction ID
---@field status number 0=OK, 1=ERROR
---@field retval any Return value
---@field output string Output
---@field err string Error message
---@field provider string Request source
---@field token string Auth token
local _M = {}
_M.__index = _M

---@type integer
_M.STATUS_OK    = 0   -- 成功
---@type integer
_M.STATUS_ERROR = 1   -- 错误

--- Construct a response
---@param t table {id=, status=, retval=, output=, err=}
---@return Response
function _M.new(t)
    t = t or {}
    setmetatable(t, _M)
    t.id       = t.id or 0
    t.status   = t.status or _M.STATUS_OK
    t.retval   = t.retval
    t.output   = t.output or ""
    t.err      = t.err or ""
    t.provider = t.provider or ""
    t.token    = t.token or ""
    return t
end

--- Set success return value
---@param val any Return value
---@return self
function _M:set_retval(val)
    self.status = _M.STATUS_OK
    self.retval = val
    return self
end

--- Set error (clears retval — error responses carry no return value)
---@param err string Error message
---@return self
function _M:set_error(err)
    self.status = _M.STATUS_ERROR
    self.err = err
    self.retval = nil
    return self
end

--- Pack into response body table {i, s, r, o, e}
---@return table
function _M:pack_body()
    return {
        i = self.id,
        s = self.status,
        r = self.retval,
        o = self.output,
        e = self.err,
    }
end

--- Construct response from decoded table
---@param t table {i, s, r, o, e}
---@return Response
function _M.unpack(t)
    return _M.new({
        id     = t.i,
        status = t.s,
        retval = t.r,
        output = t.o,
        err    = t.e,
    })
end

return _M
