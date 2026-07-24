-- yar/log.lua
-- Yar 统一日志：级别过滤 + 可注入 writer。
-- 默认 writer 为 print()，全环境可用。

local print, tonumber = print, tonumber

---@class Log
---@field DEBUG integer Debug level (1)
---@field INFO integer Info level (2)
---@field WARN integer Warn level (3)
---@field ERROR integer Error level (4)
local _M = {}

_M.DEBUG = 1
_M.INFO  = 2
_M.WARN  = 3
_M.ERROR = 4

local current_level = _M.WARN

-- 级别名映射（默认 writer 输出可读级别名，非裸数字）
local LEVEL_NAMES = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }

--- Default writer: formats [LEVEL] message, usable in all environments
local function default_writer(lvl, msg)
    print("[" .. (LEVEL_NAMES[lvl] or "?") .. "] " .. msg)
end

local writer = default_writer

--- Set log writer (injection point)
---@param fn function|nil Writer function(level, message), nil to reset to default
function _M.set_writer(fn)
    writer = fn or default_writer
end

--- Set log level
---@param lvl number Log.DEBUG / Log.INFO / Log.WARN / Log.ERROR
function _M.set_level(lvl)
    current_level = tonumber(lvl) or _M.WARN
end

local function log(lvl, msg)
    if lvl < current_level then return end
    writer(lvl, msg)
end

---@param msg string Log message
function _M.debug(msg) log(_M.DEBUG, msg) end
---@param msg string Log message
function _M.info(msg)  log(_M.INFO, msg)  end
---@param msg string Log message
function _M.warn(msg)  log(_M.WARN, msg)  end
---@param msg string Log message
function _M.error(msg) log(_M.ERROR, msg) end

return _M
