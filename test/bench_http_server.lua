-- test/bench_http_server.lua
-- 压测用纯 Lua HTTP 服务端（luasocket, HTTP/1.1 keepalive）
-- 替代 PHP Yar HTTP 服务端，确保性能压测全链路纯 Lua（client + server）
--
-- 启动：lua test/bench_http_server.lua [port]

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Server = require("yar.server")
local Socket  = require("yar.transport.socket")

local port = tonumber(arg[1]) or 9800

local server = Server.new({
    add = function(a, b) return a + b end,
})

local srv, err = Socket.bind("127.0.0.1", port)
if not srv then error("bind failed: " .. tostring(err)) end
srv:settimeout(nil)  -- 阻塞 accept

-- HTTP/1.1 keepalive 循环
while true do
    local client = srv:accept()
    if client then
        client:settimeout(server.options.timeout or 5)
        -- keepalive 循环：同一连接处理多个 HTTP 请求
        while true do
            -- 1. 读 HTTP 请求行
            local line = client:receive("*l")
            if not line then break end  -- 客户端断开

            local method, path, proto = string.match(line, "^(%u+)%s+(%S+)%s+(HTTP/%d%.%d)")
            if not method then break end

            -- 2. 读 HTTP headers
            local content_length
            local connection_close = false
            while true do
                line = client:receive("*l")
                if not line or line == "" then break end
                local k, v = string.match(line, "^([^:]+):%s*(.*)$")
                if k then
                    local kl = string.lower(k)
                    if kl == "content-length" then
                        content_length = tonumber(v)
                    elseif kl == "connection" and string.lower(v) == "close" then
                        connection_close = true
                    end
                end
            end

            -- 3. 读 HTTP body（YAR 二进制消息）
            local body
            if content_length and content_length > 0 then
                body = client:receive(content_length)
            end
            if not body then break end

            -- 4. handle_message 全链路（parse → dispatch → render）
            local resp = server.dispatcher:handle_message(body)

            -- 5. 发送 HTTP 响应
            local resp_headers = table.concat({
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: application/octet-stream\r\n",
                "Content-Length: " .. #resp .. "\r\n",
                "Connection: keep-alive\r\n",
                "\r\n",
            })
            client:send(resp_headers .. resp)

            if connection_close then break end
        end
        client:close()
    end
end
