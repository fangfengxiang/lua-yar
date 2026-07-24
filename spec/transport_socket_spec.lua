-- spec/transport_socket_spec.lua
-- Socket 提供者测试：wrap/wrap_server、tcp/unix/bind 工厂、set_timeouts、release、poolable

local Socket = require("yar.transport.socket")

after_each(function()
    Socket.set(nil)
end)

describe("transport.socket", function()
    describe("tcp — default provider (luasocket)", function()
        it("should create a TCP socket with connect/send/receive/close", function()
            local sock = Socket.tcp()
            assert.is_not_nil(sock)
            assert.truthy(sock.connect)
            assert.truthy(sock.send)
            assert.truthy(sock.receive)
            assert.truthy(sock.close)
            assert.truthy(sock.settimeout)
            sock:close()
        end)
    end)

    describe("set — custom provider injection", function()
        it("should use injected provider for tcp()", function()
            local created = false
            Socket.set({
                tcp = function()
                    created = true
                    return {
                        connect = function() return true end,
                        send = function() return 0 end,
                        receive = function() return nil end,
                        close = function() end,
                        settimeout = function() end,
                    }
                end,
            })
            local sock = Socket.tcp()
            assert.is_true(created)
            assert.is_not_nil(sock)
        end)

        it("should reset to default when set(nil)", function()
            Socket.set({ tcp = function() return nil end })
            Socket.set(nil)
            local sock = Socket.tcp()
            assert.is_not_nil(sock)
            sock:close()
        end)
    end)

    describe("unix — default provider", function()
        it("should return error when unix socket not available", function()
            -- 默认 provider 的 unix() 在无 luasocket unix 支持时返回 nil, err
            -- 测试环境可能无 unix 支持，验证错误返回而非崩溃
            local sock, err = Socket.unix()
            if not sock then
                assert.truthy(err)
                assert.truthy(string.find(err, "unix"))
            end
        end)

        it("should use injected provider for unix()", function()
            local unix_called = false
            Socket.set({
                unix = function()
                    unix_called = true
                    return {
                        connect = function() return true end,
                        send = function() return 0 end,
                        receive = function() return nil end,
                        close = function() end,
                        settimeout = function() end,
                    }
                end,
                tcp = function() return nil end,
            })
            local sock = Socket.unix()
            assert.is_true(unix_called)
            assert.is_not_nil(sock)
        end)
    end)

    describe("bind — server socket factory", function()
        it("should return error when provider has no bind", function()
            Socket.set({
                tcp = function() return nil end,
                -- no bind field
            })
            local sock, err = Socket.bind("0.0.0.0", 0)
            assert.is_nil(sock)
            assert.truthy(string.find(err, "bind"))
        end)

        it("should create server socket with injected bind", function()
            local bind_called = false
            local mock_server = {
                accept = function()
                    return {
                        connect = function() return true end,
                        send = function() return 0 end,
                        receive = function() return nil end,
                        close = function() end,
                        settimeout = function() end,
                    }
                end,
                settimeout = function() end,
                close = function() end,
            }
            Socket.set({
                bind = function(host, port)
                    bind_called = true
                    assert.are.equal("0.0.0.0", host)
                    assert.are.equal(9999, port)
                    return mock_server
                end,
                tcp = function() return nil end,
            })
            local server = Socket.bind("0.0.0.0", 9999)
            assert.is_true(bind_called)
            assert.is_not_nil(server)
            assert.truthy(server.accept)
            assert.truthy(server.settimeout)
            assert.truthy(server.close)
            -- accept 返回的 client socket 也应有 wrap 的方法
            local client = server.accept()
            assert.truthy(client.connect)
            assert.truthy(client.send)
            assert.truthy(client.receive)
            assert.truthy(client.close)
            assert.truthy(client.settimeout)
        end)

        it("should return error when bind fails", function()
            Socket.set({
                bind = function(_, _)
                    return nil, "address in use"
                end,
                tcp = function() return nil end,
            })
            local server, err = Socket.bind("0.0.0.0", 80)
            assert.is_nil(server)
            assert.are.equal("address in use", err)
        end)

        it("should handle nil timeout in server settimeout", function()
            local settimeout_called = false
            local mock_server = {
                accept = function() return nil end,
                settimeout = function(_, ms)
                    settimeout_called = true
                    if ms == nil then return true end
                end,
                close = function() end,
            }
            Socket.set({
                bind = function() return mock_server end,
                tcp = function() return nil end,
            })
            local server = Socket.bind("0.0.0.0", 0)
            server:settimeout(nil)
            assert.is_true(settimeout_called)
        end)
    end)

    describe("set_timeouts", function()
        it("should use settimeouts when available (cosocket)", function()
            local captured = {}
            local sock = {
                settimeouts = function(_, ct, st, rt)
                    captured.connect = ct
                    captured.send = st
                    captured.read = rt
                end,
            }
            Socket.set_timeouts(sock, 1000, 2000, 3000)
            assert.are.equal(1000, captured.connect)
            assert.are.equal(2000, captured.send)
            assert.are.equal(3000, captured.read)
        end)

        it("should fall back to settimeout when settimeouts unavailable (luasocket)", function()
            local captured
            local sock = {
                settimeout = function(_, ms)
                    captured = ms
                end,
            }
            Socket.set_timeouts(sock, 1000, 2000, 3000)
            assert.are.equal(3000, captured)
        end)

        it("should handle nil ms in settimeout (blocking mode)", function()
            local captured
            local sock = {
                settimeout = function(_, ms)
                    captured = ms
                end,
            }
            Socket.set_timeouts(sock, nil, nil, nil)
            assert.is_nil(captured)
        end)
    end)

    describe("release", function()
        it("should call setkeepalive when available (cosocket pool return)", function()
            local ka_called = false
            local ka_args = {}
            local sock = {
                setkeepalive = function(_, ...)
                    ka_called = true
                    ka_args = { ... }
                    return true
                end,
            }
            Socket.release(sock, 60000, 128)
            assert.is_true(ka_called)
            assert.are.equal(60000, ka_args[1])
            assert.are.equal(128, ka_args[2])
        end)

        it("should call close when setkeepalive unavailable (luasocket)", function()
            local closed = false
            local sock = {
                close = function() closed = true end,
            }
            Socket.release(sock)
            assert.is_true(closed)
        end)
    end)

    describe("poolable", function()
        it("should return true for cosocket (has setkeepalive)", function()
            local sock = { setkeepalive = function() end }
            assert.is_true(Socket.poolable(sock))
        end)

        it("should return false for luasocket (no setkeepalive)", function()
            local sock = { close = function() end }
            assert.is_false(Socket.poolable(sock))
        end)
    end)

    describe("wrap — luasocket wrapper", function()
        it("should convert ms timeout to seconds for luasocket", function()
            -- 使用默认 provider（luasocket），验证 wrap 的 ms→sec 转换
            -- 默认 provider 的 tcp() 调用 socket.tcp() 后 wrap(s)
            -- wrap 后的 settimeout(5000) 应调用 raw s:settimeout(5)
            local sock = Socket.tcp()
            if not sock then return end  -- 无 luasocket 则跳过
            -- 验证 settimeout 不报错（5000ms = 5s）
            assert.has_no_errors(function() sock:settimeout(5000) end)
            -- 验证 nil 超时也不报错（阻塞模式）
            assert.has_no_errors(function() sock:settimeout(nil) end)
            sock:close()
        end)
    end)
end)
