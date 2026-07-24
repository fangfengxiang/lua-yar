-- yar/transport/resolve.lua
-- 传输层 DNS 解析工具：支持 curl/PHP 风格的自定义 host→IP 映射。

local string, tonumber = string, tonumber

---@class Resolve
local _M = {}

--- Extract custom IP for the target host from the resolve option
-- Supports curl-style "host:port:ip" and PHP-style "host:ip"
---@param host string Original host
---@param port number Original port
---@param resolve_str string Resolve option string
---@return string Resolved IP (returns original host if no match)
function _M.apply_resolve(host, port, resolve_str)
    if not resolve_str or resolve_str == "" then return host end
    -- curl 风格：host:port:ip（同时匹配 host 和 port）
    local rhost, rport, ip = string.match(resolve_str, "^([^:]+):(%d+):(.+)$")
    if rhost then
        -- curl 格式匹配成功：port 匹配则返回 IP，不匹配则不回退到 PHP 格式（避免畸形 IP）
        if rhost == host and tonumber(rport) == port then return ip end
        return host
    end
    -- PHP 风格：host:ip（仅匹配 host）
    local rhost2, ip2 = string.match(resolve_str, "^([^:]+):(.+)$")
    if rhost2 and rhost2 == host then return ip2 end
    return host
end

return _M
