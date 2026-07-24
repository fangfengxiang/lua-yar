-- spec/transport_http_spec.lua
-- HTTP 传输层测试：mock socket 注入，覆盖 proxy 解析、HTTPS CONNECT 隧道、
-- http_provider 委托、set_provider、user_agent、chunked transfer 等路径。
-- 不依赖真实网络，全部通过 mock socket 模拟。

local Socket = require("yar.transport.socket")
local Http = require("yar.transport.http")
local Const = require("yar.transport.constants")

after_each(function()
    -- 恢复默认 provider
    Socket.set(nil)
    -- 清除类级 http_provider
    Http.set_provider(nil)
end)

-- 构造 mock socket：按预编程响应数据顺序返回
-- 支持 *l（行读）、number（定长读）、*a（全读）
local function mock_socket_factory(response_data, opts)
    opts = opts or {}
    local pos = 1
    local sent_log = {}
    local connected_to = nil
    local sock = {
        connect = function(_, host, port)
            connected_to = { host = host, port = port }
            if opts.connect_fail then return false, "connection refused" end
            return true
        end,
        send = function(_, d)
            sent_log[#sent_log + 1] = d
            return #d
        end,
        receive = function(_, pattern)
            if pattern == "*l" then
                local s, e = string.find(response_data, "\r\n", pos, true)
                if not s then
                    if pos > #response_data then return nil end
                    local line = string.sub(response_data, pos)
                    pos = #response_data + 1
                    return line
                end
                local line = string.sub(response_data, pos, s - 1)
                pos = e + 1
                return line
            elseif pattern == "*a" then
                local rest = string.sub(response_data, pos)
                pos = #response_data + 1
                return rest
            elseif type(pattern) == "number" then
                if pattern == 0 then return "" end  -- 0 bytes 永远成功（模拟真实 socket）
                if pos > #response_data then return nil, "closed" end
                local chunk = string.sub(response_data, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        settimeout = function() end,
        settimeouts = function() end,
        close = function() end,
        -- cosocket 特有方法（ssl 测试用）
        sslhandshake = opts.ssl_ok and function() return true, nil end or nil,
        setkeepalive = opts.cosocket and function() return true end or nil,
    }
    return sock, sent_log, function() return connected_to end
end

-- 注入 mock socket provider
local function inject_mock(sock)
    Socket.set({
        tcp = function() return sock end,
    })
end

describe("transport/http", function()

    describe("set_provider", function()
        it("should use injected http_provider when set", function()
            local called = false
            local captured_url
            Http.set_provider(function(url, _opts)
                called = true
                captured_url = url
                return "mock-response-body"
            end)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body, err = transport:send("request-data")
            assert.is_true(called)
            assert.are.equal("http://example.com/api", captured_url)
            assert.are.equal("mock-response-body", body)
            assert.is_nil(err)
        end)

        it("should fall back to manual_request when provider is nil", function()
            local sock, sent_log = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body = transport:send("request-data")
            assert.are.equal("hello", body)
            -- 验证 send 被调用（请求数据被发送）
            assert.is_true(#sent_log > 0)
            assert.truthy(string.find(sent_log[1], "POST", 1, true))
        end)

        it("should use instance-level http_provider over class-level", function()
            local class_called = false
            local instance_called = false
            Http.set_provider(function(_url, _opts)
                class_called = true
                return "class-body"
            end)
            local transport = Http.new()
            transport:open("http://example.com/api", {
                transport = { http_provider = function(_url, _opts)
                    instance_called = true
                    return "instance-body"
                end }
            })
            local body = transport:send("data")
            assert.is_true(instance_called)
            assert.is_false(class_called)
            assert.are.equal("instance-body", body)
        end)

        it("should pass headers and options to http_provider", function()
            local captured_opts
            Http.set_provider(function(_url, opts)
                captured_opts = opts
                return "body"
            end)
            local transport = Http.new()
            transport:open("http://example.com/api", {
                transport = {
                    timeout = 3000,
                    connect_timeout = 2000,
                    proxy = "http://proxy:8080",
                    headers = { ["X-Custom"] = "val" },
                    keepalive = { pool_size = 32 },
                    ssl_verify = false,
                }
            })
            transport:send("data")
            assert.are.equal(3000, captured_opts.timeout)
            assert.are.equal(2000, captured_opts.connect_timeout)
            assert.are.equal("http://proxy:8080", captured_opts.proxy)
            assert.are.equal("val", captured_opts.headers["X-Custom"])
            assert.are.equal(32, captured_opts.keepalive.pool_size)
            assert.is_false(captured_opts.ssl_verify)
            assert.are.equal("POST", captured_opts.method)
            assert.are.equal("data", captured_opts.body)
        end)
    end)

    describe("manual_request — basic HTTP", function()
        it("should send POST and return response body", function()
            local sock, sent_log = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nresult1"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body = transport:send("yar-data")
            assert.are.equal("result1", body)
            -- 验证请求行
            assert.truthy(string.find(sent_log[1], "POST /api HTTP/1%.1"))
            -- 验证 Host header
            assert.truthy(string.find(sent_log[1], "Host: example%.com"))
            -- 验证 Content-Length
            assert.truthy(string.find(sent_log[1], "Content%-Length: 8"))
        end)

        it("should return error on non-200 status", function()
            local sock = mock_socket_factory(
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.truthy(string.find(err, "http status: 500"))
        end)

        it("should return error when no response", function()
            local sock = mock_socket_factory("")
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.are.equal("no response", err)
        end)

        it("should handle connect failure", function()
            local sock = mock_socket_factory("", { connect_fail = true })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.are.equal("connection refused", err)
        end)
    end)

    describe("manual_request — chunked transfer", function()
        it("should decode chunked response body", function()
            local chunked_response =
                "HTTP/1.1 200 OK\r\n" ..
                "Transfer-Encoding: chunked\r\n" ..
                "\r\n" ..
                "5\r\nhello\r\n" ..
                "6\r\n world\r\n" ..
                "0\r\n\r\n"
            local sock = mock_socket_factory(chunked_response)
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body = transport:send("data")
            assert.are.equal("hello world", body)
        end)
    end)

    describe("manual_request — read until close", function()
        it("should read body without Content-Length (read *a)", function()
            local response =
                "HTTP/1.1 200 OK\r\n" ..
                "\r\n" ..
                "body-until-close"
            local sock = mock_socket_factory(response)
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {})
            local body = transport:send("data")
            assert.are.equal("body-until-close", body)
        end)
    end)

    describe("manual_request — proxy", function()
        it("should connect to proxy host:port when proxy is set", function()
            local sock, sent_log, get_connected = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://target.com/api", {
                transport = { proxy = "http://proxyhost:3128" }
            })
            local body = transport:send("data")
            assert.are.equal("abc", body)
            -- 验证连接到了 proxy 而非 target
            local conn = get_connected()
            assert.are.equal("proxyhost", conn.host)
            assert.are.equal(3128, conn.port)
            -- 验证请求行使用绝对 URI
            assert.truthy(string.find(sent_log[1], "POST http://target%.com/api"))
        end)

        it("should parse proxy without scheme (host:port)", function()
            local sock, _, get_connected = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://target.com/api", {
                transport = { proxy = "proxyhost:3128" }
            })
            transport:send("data")
            local conn = get_connected()
            assert.are.equal("proxyhost", conn.host)
            assert.are.equal(3128, conn.port)
        end)

        it("should use default proxy port 8080 when no port given", function()
            local sock, _, get_connected = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://target.com/api", {
                transport = { proxy = "http://proxyhost" }
            })
            transport:send("data")
            local conn = get_connected()
            assert.are.equal("proxyhost", conn.host)
            assert.are.equal(Const.HTTP_PROXY_PORT, conn.port)
        end)

        it("should parse bare hostname proxy (no scheme, no port)", function()
            local sock, _, get_connected = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://target.com/api", {
                transport = { proxy = "proxyhost" }
            })
            transport:send("data")
            local conn = get_connected()
            assert.are.equal("proxyhost", conn.host)
            assert.are.equal(Const.HTTP_PROXY_PORT, conn.port)
        end)
    end)

    describe("manual_request — HTTPS over proxy CONNECT tunnel", function()
        it("should send CONNECT request then sslhandshake then POST", function()
            -- 代理 CONNECT 响应 + 后续 HTTP 响应
            local response_data =
                "HTTP/1.1 200 Connection established\r\n" ..
                "\r\n" ..
                "HTTP/1.1 200 OK\r\n" ..
                "Content-Length: 4\r\n" ..
                "\r\n" ..
                "done"
            local sock, sent_log = mock_socket_factory(response_data, { ssl_ok = true })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://target.com/api", {
                transport = { proxy = "http://proxy:3128" }
            })
            local body = transport:send("data")
            assert.are.equal("done", body)
            -- 验证 CONNECT 请求被发送
            local all_sent = table.concat(sent_log)
            assert.truthy(string.find(all_sent, "CONNECT target%.com:443"))
            assert.truthy(string.find(all_sent, "Host: target%.com:443"))
            -- 验证后续 POST 请求
            assert.truthy(string.find(all_sent, "POST https://target%.com/api"))
        end)

        it("should return error when proxy rejects CONNECT", function()
            local response_data =
                "HTTP/1.1 407 Proxy Authentication Required\r\n" ..
                "\r\n"
            local sock = mock_socket_factory(response_data, { ssl_ok = true })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://target.com/api", {
                transport = { proxy = "http://proxy:3128" }
            })
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.truthy(string.find(err, "proxy CONNECT rejected"))
        end)

        it("should return error when proxy gives no response to CONNECT", function()
            local sock = mock_socket_factory("", { ssl_ok = true })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://target.com/api", {
                transport = { proxy = "http://proxy:3128" }
            })
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.are.equal("proxy CONNECT no response", err)
        end)
    end)

    describe("manual_request — HTTPS direct (no proxy)", function()
        it("should sslhandshake on direct HTTPS connection", function()
            local response_data =
                "HTTP/1.1 200 OK\r\n" ..
                "Content-Length: 3\r\n" ..
                "\r\n" ..
                "ok!"
            local sock, sent_log = mock_socket_factory(response_data, { ssl_ok = true })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://secure.com/api", {})
            local body = transport:send("data")
            assert.are.equal("ok!", body)
            -- 验证请求行用相对 path（非代理）
            assert.truthy(string.find(sent_log[1], "POST /api HTTP/1%.1"))
        end)

        it("should return error when socket lacks sslhandshake (plain luasocket)", function()
            -- mock socket without sslhandshake method
            local sock = mock_socket_factory("", { ssl_ok = false })
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://secure.com/api", {})
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.truthy(string.find(err, "ssl%-capable socket"))
        end)

        it("should pass ssl_verify option to sslhandshake", function()
            local response_data =
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok!"
            local ssl_verify_received
            local sock = mock_socket_factory(response_data, { ssl_ok = true })
            -- 覆盖 sslhandshake 以捕获 verify 参数
            sock.sslhandshake = function(_, _, _, verify)
                ssl_verify_received = verify
                return true, nil
            end
            inject_mock(sock)
            -- ssl_verify = true (default)
            local transport = Http.new()
            transport:open("https://secure.com/api", {})
            transport:send("data")
            assert.is_true(ssl_verify_received)
        end)

        it("should return error when sslhandshake fails", function()
            local sock = {
                connect = function() return true end,
                send = function(_, d) return #d end,
                receive = function() return nil end,
                settimeout = function() end,
                settimeouts = function() end,
                close = function() end,
                sslhandshake = function() return false, "ssl error" end,
            }
            inject_mock(sock)
            local transport = Http.new()
            transport:open("https://secure.com/api", {})
            local body, err = transport:send("data")
            assert.is_nil(body)
            assert.truthy(string.find(err, "ssl"))
        end)
    end)

    describe("manual_request — custom headers", function()
        it("should merge user headers with defaults", function()
            local sock, sent_log = mock_socket_factory(
                "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"
            )
            inject_mock(sock)
            local transport = Http.new()
            transport:open("http://example.com/api", {
                transport = { headers = { ["X-Custom"] = "myval", ["Host"] = "override.com" } }
            })
            transport:send("data")
            local all_sent = table.concat(sent_log)
            -- 用户覆盖 Host
            assert.truthy(string.find(all_sent, "Host: override%.com"))
            -- 用户自定义头
            assert.truthy(string.find(all_sent, "X%-Custom: myval"))
        end)
    end)

    describe("open and close", function()
        it("should store url and options on open", function()
            local transport = Http.new()
            local result = transport:open("http://test.com/path", { foo = "bar" })
            assert.is_true(result)
            assert.are.equal("http://test.com/path", transport.url)
            assert.are.equal("bar", transport.options.foo)
        end)

        it("should close without error (no-op)", function()
            local transport = Http.new()
            assert.has_no_errors(function() transport:close() end)
        end)
    end)
end)
