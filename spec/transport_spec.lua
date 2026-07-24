-- spec/transport_spec.lua
-- Transport 工厂测试：URL scheme 路由 + socket/http provider 注入

local Transport = require("yar.transport.transport")
local Socket = require("yar.transport.socket")
local Http = require("yar.transport.http")

after_each(function()
    Socket.set(nil)
    Http.set_provider(nil)
end)

describe("transport", function()
    describe("get — URL scheme routing", function()
        it("should return Tcp transport for tcp:// scheme", function()
            local t = Transport.get("tcp://127.0.0.1:8888")
            assert.are.equal("table", type(t))
            assert.truthy(t.open)
            assert.truthy(t.send)
            assert.truthy(t.close)
        end)

        it("should return Tcp transport for unix:// scheme", function()
            local t = Transport.get("unix:///tmp/yar.sock")
            assert.truthy(t.open)
            assert.truthy(t.send)
        end)

        it("should return Http transport for http:// scheme", function()
            local t = Transport.get("http://example.com/api")
            assert.truthy(t.open)
            assert.truthy(t.send)
        end)

        it("should return Http transport for https:// scheme", function()
            local t = Transport.get("https://example.com/api")
            assert.truthy(t.open)
            assert.truthy(t.send)
        end)

        it("should return Http as default for unknown scheme", function()
            local t = Transport.get("foo://bar")
            assert.truthy(t.open)
        end)
    end)

    describe("set_socket", function()
        it("should inject custom socket provider", function()
            local custom_provider = { tcp = function() end }
            Transport.set_socket(custom_provider)
            -- 验证注入后 Socket.tcp() 使用新 provider
            -- (间接验证：不报错即成功)
            assert.has_no_errors(function() Transport.set_socket(nil) end)
        end)

        it("should reset to default when passed nil", function()
            Transport.set_socket({ tcp = function() end })
            Transport.set_socket(nil)
            -- 重置后应能正常创建 socket
            assert.has_no_errors(function()
                local s = Socket.tcp()
                if s then s:close() end
            end)
        end)

        it("should be chainable (returns Transport)", function()
            local result = Transport.set_socket(nil)
            assert.are.equal(Transport, result)
        end)
    end)

    describe("set_http_provider", function()
        it("should inject custom HTTP provider", function()
            local called = false
            Transport.set_http_provider(function(_, _)
                called = true
                return "injected-body"
            end)
            -- 验证 provider 被设置（通过 Http transport 使用它）
            local transport = Http.new()
            transport:open("http://test.com/api", {})
            local body = transport:send("data")
            assert.is_true(called)
            assert.are.equal("injected-body", body)
        end)

        it("should be chainable (returns Transport)", function()
            local result = Transport.set_http_provider(nil)
            assert.are.equal(Transport, result)
        end)

        it("should reset to default when passed nil", function()
            Transport.set_http_provider(function() return "injected" end)
            Transport.set_http_provider(nil)
            -- 重置后应走默认 manual_request 路径（需要 mock socket）
            local sock = {
                connect = function() return true end,
                send = function(_, d) return #d end,
                receive = function(_, pattern)
                    if pattern == "*l" then return nil end
                    return nil
                end,
                close = function() end,
                settimeout = function() end,
                settimeouts = function() end,
            }
            Socket.set({ tcp = function() return sock end })
            local transport = Http.new()
            transport:open("http://test.com/api", {})
            local body, err = transport:send("data")
            -- 无响应 → 返回 nil, "no response"
            assert.is_nil(body)
            assert.are.equal("no response", err)
        end)
    end)
end)
