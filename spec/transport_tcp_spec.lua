-- spec/transport_tcp_spec.lua
-- TCP 传输层测试：open/send/close 全路径覆盖，mock socket 注入。
-- 覆盖：unix socket 路径、持久连接复用、新建连接、各种错误路径、resolve 透传。

local Socket = require("yar.transport.socket")
local Tcp = require("yar.transport.tcp")
local Packager = require("yar.packager.packager")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")

after_each(function()
    Socket.set(nil)
end)

-- 构造 mock socket：position-based receive，支持 Framing.receive_message 的分块读取
local function mock_tcp_sock(opts)
    opts = opts or {}
    local response_data = opts.response_data or ""
    local pos = 1
    local sent_log = {}
    local connected = false
    local closed = false
    local connect_args = {}
    local sock = {
        connect = function(_, host, port)
            connect_args = { host = host, port = port }
            if opts.connect_fail then return false, "connection refused" end
            connected = true
            return true
        end,
        send = function(_, data)
            if opts.send_fail then
                if opts.partial_bytes then
                    return opts.partial_bytes, "send broken"
                end
                return nil, "send error"
            end
            sent_log[#sent_log + 1] = data
            return #data
        end,
        receive = function(_, n)
            if opts.receive_fail then return nil, "receive error" end
            if type(n) == "number" then
                if n == 0 then return "" end
                if pos > #response_data then return nil, "closed" end
                local chunk = string.sub(response_data, pos, pos + n - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil, "closed"
        end,
        close = function() closed = true end,
        settimeout = function() end,
        settimeouts = function() end,
    }
    -- 允许重置 response_data（persistent 复用测试用）
    sock.set_response = function(_, data) response_data = data; pos = 1 end
    return sock, {
        sent_log = sent_log,
        connected = function() return connected end,
        closed = function() return closed end,
        connect_args = function() return connect_args end,
    }
end

-- 构造一个有效的 YAR 响应消息
local function make_yar_response()
    local p = Packager.get(Packager.JSON)
    local resp = Response.new({ id = 42, status = 0, retval = "ok" })
    return Protocol.render(resp, p)
end

-- 构造一个有效的 YAR 请求消息（用于 max_body_len 测试，body_len > 0）
local function make_yar_request()
    local p = Packager.get(Packager.JSON)
    local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
    return Protocol.render(req, p)
end

describe("transport.tcp", function()

    describe("open", function()
        it("should parse tcp://host:port URL", function()
            local t = Tcp.new()
            local ok = t:open("tcp://127.0.0.1:8888", {})
            assert.is_true(ok)
            assert.are.equal("127.0.0.1", t.host)
            assert.are.equal(8888, t.port)
        end)

        it("should parse unix:///path URL", function()
            local t = Tcp.new()
            local ok = t:open("unix:///tmp/yar.sock", {})
            assert.is_true(ok)
            assert.are.equal("/tmp/yar.sock", t.unix_path)
        end)

        it("should return nil for invalid tcp URL", function()
            local t = Tcp.new()
            local ok, err = t:open("not-a-url", {})
            assert.is_nil(ok)
            assert.truthy(string.find(err, "invalid tcp url"))
        end)

        it("should return nil for missing port", function()
            local t = Tcp.new()
            local ok, err = t:open("tcp://localhost", {})
            assert.is_nil(ok)
            assert.truthy(string.find(err, "invalid tcp url"))
        end)

        it("should store transport options from options.transport", function()
            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { timeout = 5000 } })
            assert.are.equal(5000, t.transport_opts.timeout)
        end)

        it("should use options as transport_opts when no transport key", function()
            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { timeout = 3000 })
            assert.are.equal(3000, t.transport_opts.timeout)
        end)
    end)

    describe("send — new connection (TCP)", function()
        it("should connect, send data, and return response", function()
            local resp_msg = make_yar_response()
            local mock, info = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            local resp = t:send("request-data")
            assert.are.equal(resp_msg, resp)
            assert.is_true(info.connected())
            assert.is_true(info.closed())  -- 非 persistent，走 release → close（mock 无 setkeepalive，release 回退 close）
        end)

        it("should return error when socket creation fails", function()
            Socket.set({ tcp = function() return nil, "create failed" end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            local resp, err = t:send("data")
            assert.is_nil(resp)
            assert.are.equal("create failed", err)
        end)

        it("should return error when connect fails", function()
            local mock = mock_tcp_sock({ connect_fail = true })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            local resp, err = t:send("data")
            assert.is_nil(resp)
            assert.are.equal("connection refused", err)
        end)

        it("should return error when send fails on new connection", function()
            local mock = mock_tcp_sock({ send_fail = true })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            local resp, err = t:send("data")
            assert.is_nil(resp)
            assert.are.equal("send error", err)
        end)

        it("should return error when receive fails", function()
            local mock = mock_tcp_sock({ receive_fail = true })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            local resp, err = t:send("data")
            assert.is_nil(resp)
            assert.are.equal("receive error", err)
        end)

        it("should cache socket when persistent=true", function()
            local resp_msg = make_yar_response()
            local mock = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { persistent = true } })
            t:send("data")
            assert.is_not_nil(t.sock)
        end)

        it("should apply resolve option to connect host", function()
            local resp_msg = make_yar_response()
            local mock, info = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://example.com:80", { transport = { resolve = "example.com:80:192.168.1.1" } })
            t:send("data")
            local args = info.connect_args()
            assert.are.equal("192.168.1.1", args.host)
            assert.are.equal(80, args.port)
        end)
    end)

    describe("send — new connection (Unix socket)", function()
        it("should use Socket.unix() for unix:// URLs", function()
            local resp_msg = make_yar_response()
            local unix_called = false
            local mock = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({
                unix = function()
                    unix_called = true
                    return mock
                end,
                tcp = function() return nil end,
            })

            local t = Tcp.new()
            t:open("unix:///tmp/yar.sock", {})
            local resp = t:send("data")
            assert.is_true(unix_called)
            assert.are.equal(resp_msg, resp)
        end)

        it("should return error when unix socket creation fails", function()
            Socket.set({
                unix = function() return nil, "unix not available" end,
                tcp = function() return nil end,
            })

            local t = Tcp.new()
            t:open("unix:///tmp/yar.sock", {})
            local resp, err = t:send("data")
            assert.is_nil(resp)
            assert.are.equal("unix not available", err)
        end)

        it("should connect to unix_path", function()
            local resp_msg = make_yar_response()
            local connect_path = nil
            local mock = {
                connect = function(_, path) connect_path = path; return true end,
                send = function(_, d) return #d end,
                receive = function(_) return resp_msg end,
                close = function() end,
                settimeout = function() end,
            }
            Socket.set({
                unix = function() return mock end,
                tcp = function() return nil end,
            })

            local t = Tcp.new()
            t:open("unix:///tmp/yar.sock", {})
            t:send("data")
            assert.are.equal("/tmp/yar.sock", connect_path)
        end)
    end)

    describe("send — persistent connection reuse", function()
        it("should reuse cached socket for second send", function()
            local resp_msg = make_yar_response()
            local tcp_call_count = 0
            local sock1 = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({
                tcp = function()
                    tcp_call_count = tcp_call_count + 1
                    return sock1
                end,
            })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { persistent = true } })
            t:send("data1")
            assert.is_not_nil(t.sock)
            -- 重置 response 数据供第二次 receive 使用
            t.sock:set_response(resp_msg)
            local resp = t:send("data2")
            assert.are.equal(resp_msg, resp)
            assert.are.equal(1, tcp_call_count)  -- 只创建了一次 socket
        end)

        it("should close and reconnect when cached socket send fails", function()
            local resp_msg = make_yar_response()
            local sock1 = mock_tcp_sock({ response_data = resp_msg })
            local sock2 = mock_tcp_sock({ response_data = resp_msg })
            local call_idx = 0
            Socket.set({
                tcp = function()
                    call_idx = call_idx + 1
                    return call_idx == 1 and sock1 or sock2
                end,
            })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { persistent = true } })
            t:send("data1")
            assert.is_not_nil(t.sock)
            -- 让缓存的 socket send 失败（返回 nil, err = 0 字节，安全重试）
            t.sock.send = function() return nil, "broken pipe" end
            -- 第二次 send：缓存 socket send 失败 → 关闭 → 新建连接
            local resp = t:send("data2")
            assert.are.equal(resp_msg, resp)
        end)

        it("should return error on partial send (sent > 0)", function()
            local resp_msg = make_yar_response()
            local mock = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { persistent = true } })
            t:send("data1")
            -- 缓存 socket 的 send 返回 >0 字节 + err（不可重试）
            t.sock.send = function(_, _) return 5, "partial send error" end
            local resp, err = t:send("data2")
            assert.is_nil(resp)
            assert.truthy(string.find(err, "partial send"))
        end)

        it("should return error when receive fails on cached socket", function()
            local resp_msg = make_yar_response()
            local mock = mock_tcp_sock({ response_data = resp_msg })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { persistent = true } })
            t:send("data1")
            -- 缓存 socket 的 receive 失败
            t.sock.receive = function() return nil, "connection lost" end
            local resp, err = t:send("data2")
            assert.is_nil(resp)
            assert.truthy(err)
            assert.is_nil(t.sock)  -- socket 已关闭并清除
        end)

        it("should check max_body_len on cached socket before send", function()
            local req_msg = make_yar_request()
            local mock = mock_tcp_sock({ response_data = make_yar_response() })
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {
                transport = { persistent = true, max_body_len = 10 }
            })
            t:send(req_msg)
            -- 第二次 send：data 超过 max_body_len（req_msg > 10 bytes）
            local resp, err = t:send(req_msg)
            assert.is_nil(resp)
            assert.truthy(string.find(err, "body too large"))
        end)
    end)

    describe("send — max_body_len validation", function()
        it("should check body length before send on new connection", function()
            local req_msg = make_yar_request()
            local mock = mock_tcp_sock({})
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", { transport = { max_body_len = 10 } })
            -- req_msg 的 body_len > 10，check_body_len 应拒绝
            local resp, err = t:send(req_msg)
            assert.is_nil(resp)
            assert.truthy(string.find(err, "body too large"))
        end)
    end)

    describe("send — keepalive release", function()
        it("should release socket via keepalive when not persistent", function()
            local resp_msg = make_yar_response()
            local ka_called = false
            local mock = mock_tcp_sock({ response_data = resp_msg })
            mock.setkeepalive = function(_, _, _)
                ka_called = true
                return true
            end
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {
                transport = { keepalive = { idle_timeout = 60000, pool_size = 128 } }
            })
            t:send("data")
            assert.is_true(ka_called)
        end)
    end)

    describe("close", function()
        it("should close cached persistent socket", function()
            local resp_msg = make_yar_response()
            local mock = mock_tcp_sock({ response_data = resp_msg })
            local ka_called = false
            mock.setkeepalive = function() ka_called = true; return true end
            Socket.set({ tcp = function() return mock end })

            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {
                transport = { persistent = true, keepalive = { idle_timeout = 60000, pool_size = 128 } }
            })
            t:send("data")
            assert.is_not_nil(t.sock)
            t:close()
            assert.is_nil(t.sock)
            assert.is_true(ka_called)
        end)

        it("should be a no-op when no cached socket", function()
            local t = Tcp.new()
            t:open("tcp://127.0.0.1:8888", {})
            assert.has_no_errors(function() t:close() end)
            assert.is_nil(t.sock)
        end)
    end)
end)
