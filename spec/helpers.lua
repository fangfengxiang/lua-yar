-- spec/helpers.lua
-- 共享测试辅助模块：mock socket 工厂，供各 spec 文件复用。
-- 迁移自 test/client_test.lua 的 local mock 函数，集中维护避免跨文件复制。

local M = {}

-- Mock TCP socket：从 data 缓冲区顺序读取，send 数据捕获到 sent 表
-- 用途：TcpServer:handle_connection 集成测试
function M.mock_tcp_socket(data)
    local pos = 1
    local sent = {}
    local sock = {
        receive = function(_, n)
            local remaining = #data - pos + 1
            if remaining <= 0 then return nil, "closed" end
            local chunk = string.sub(data, pos, pos + n - 1)
            pos = pos + #chunk
            return chunk
        end,
        send = function(_, d)
            sent[#sent + 1] = d
            return #d
        end,
        settimeout = function() end,
        close = function() end,
    }
    return sock, sent
end

-- Mock HTTP socket：按行读取（*l）或按长度读取（number），send 捕获到 sent 表
-- 用途：HttpServer:handle_connection 集成测试
function M.mock_http_socket(request_str)
    local pos = 1
    local sent = {}
    local sock = {
        receive = function(_, pattern)
            if pattern == "*l" then
                local s, e = string.find(request_str, "\r\n", pos, true)
                if not s then
                    if pos > #request_str then return nil end
                    local line = string.sub(request_str, pos)
                    pos = #request_str + 1
                    return line
                end
                local line = string.sub(request_str, pos, s - 1)
                pos = e + 1
                return line
            elseif type(pattern) == "number" then
                if pos > #request_str then return nil, "closed" end
                local chunk = string.sub(request_str, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        send = function(_, d)
            sent[#sent + 1] = d
            return #d
        end,
        settimeout = function() end,
        close = function() end,
    }
    return sock, sent
end

-- Mock framing socket：支持精确读取（number），用于 framing 帧拆解边界测试
-- 用途：half-packet / sticky-packet / framing edge case 测试
function M.mock_framing_socket(data)
    local pos = 1
    local sock = {
        receive = function(_, pattern)
            if type(pattern) == "number" then
                if pos > #data then return nil, "closed" end
                local chunk = string.sub(data, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        send = function(_, d) return #d end,
        settimeout = function() end,
        close = function() end,
    }
    return sock
end

-- Mock HTTPS-over-proxy socket：模拟 CONNECT 隧道 + TLS 握手 + 真实 POST 响应
-- 用途：HTTPS over proxy CONNECT 隧道测试（issue #10）
function M.mock_proxy_socket(proxy_resp)
    local sent_log = {}
    local pos = 1
    local sock = {
        connect = function() return true end,
        send = function(_, d)
            sent_log[#sent_log + 1] = d
            return #d
        end,
        receive = function(_, pattern)
            if pattern == "*l" then
                local s, e = string.find(proxy_resp, "\r\n", pos, true)
                if not s then
                    if pos > #proxy_resp then return nil end
                    local line = string.sub(proxy_resp, pos)
                    pos = #proxy_resp + 1
                    return line
                end
                local line = string.sub(proxy_resp, pos, s - 1)
                pos = e + 1
                return line
            elseif type(pattern) == "number" then
                if pos > #proxy_resp then return nil, "closed" end
                local chunk = string.sub(proxy_resp, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        sslhandshake = function() return true, nil end,
        settimeout = function() end,
        settimeouts = function() end,
        close = function() end,
    }
    return sock, sent_log
end

return M
