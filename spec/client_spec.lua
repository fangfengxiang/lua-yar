-- spec/client_spec.lua
-- Client 测试：set_options + deep_copy isolation + no mutation

local Yar = require("yar")
local Client = Yar.client
local Packager = require("yar.packager.packager")
local Error = Yar.error

describe("client", function()
    describe("set_options", function()
        it("should set flat-style options", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({
                packager        = Packager.MSGPACK,
                timeout         = 3000,
                connect_timeout = 2000,
                provider        = "test-app",
                token           = "secret",
            })
            assert.are.equal(Packager.MSGPACK, client.options.protocol.packager)
            assert.are.equal(3000, client.options.transport.timeout)
            assert.are.equal(2000, client.options.transport.connect_timeout)
            assert.are.equal("test-app", client.options.protocol.provider)
            assert.are.equal("secret", client.options.protocol.token)
        end)

        it("should support setopt convenience and chaining", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({ timeout = 3000 })
            client:setopt("timeout", 9999)
            assert.are.equal(9999, client.options.transport.timeout)
            client:setopt("provider", "chain-app"):setopt("token", "chain-secret")
            assert.are.equal("chain-app", client.options.protocol.provider)
            assert.are.equal("chain-secret", client.options.protocol.token)
        end)

        it("should not modify options on set_options(nil)", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({ timeout = 3000 })
            client:set_options(nil)
            assert.are.equal(3000, client.options.transport.timeout)
        end)

        it("should set nested-style options", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({
                protocol = { packager = Packager.MSGPACK, provider = "nested-app" },
                transport = { timeout = 5000, keepalive = { pool_size = 128 } },
            })
            assert.are.equal(Packager.MSGPACK, client.options.protocol.packager)
            assert.are.equal("nested-app", client.options.protocol.provider)
            assert.are.equal(5000, client.options.transport.timeout)
            assert.are.equal(128, client.options.transport.keepalive.pool_size)
            assert.are.equal(60000, client.options.transport.keepalive.idle_timeout)
        end)

        it("should route flat keepalive to transport.keepalive", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({ keepalive = { pool_size = 256, idle_timeout = 30000 } })
            assert.are.equal(256, client.options.transport.keepalive.pool_size)
            assert.are.equal(30000, client.options.transport.keepalive.idle_timeout)
            assert.is_nil(client.options.keepalive)
        end)

        it("should route flat headers to transport.headers", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({ headers = { ["X-Custom"] = "bar" } })
            assert.are.equal("bar", client.options.transport.headers["X-Custom"])
            assert.is_nil(client.options.headers)
        end)
    end)

    describe("deep_copy isolation", function()
        it("should not share table references between instances", function()
            local a = Client.new("http://127.0.0.1:8888/api")
            local b = Client.new("http://127.0.0.1:8888/api")
            a.options.transport.headers["X-Custom"] = "value-a"
            assert.is_nil(b.options.transport.headers["X-Custom"])
            a.options.transport.keepalive.pool_size = 256
            assert.are.equal(64, b.options.transport.keepalive.pool_size)
            assert.are_not_equal(a.options.transport.keepalive, b.options.transport.keepalive)
        end)
    end)

    describe("set_options no mutation", function()
        it("should not modify caller's opts table", function()
            local opts = {
                timeout   = 3000,
                packager  = Packager.MSGPACK,
                keepalive = { pool_size = 128 },
                headers   = { ["X-Foo"] = "bar" },
            }
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options(opts)
            assert.are.equal(3000, opts.timeout)
            assert.are.equal(Packager.MSGPACK, opts.packager)
            assert.is_not_nil(opts.keepalive)
            assert.is_not_nil(opts.headers)
            assert.is_nil(opts.socket_provider)
            assert.are.equal(3000, client.options.transport.timeout)
            assert.are.equal(Packager.MSGPACK, client.options.protocol.packager)
            assert.are.equal(128, client.options.transport.keepalive.pool_size)
            assert.are.equal("bar", client.options.transport.headers["X-Foo"])
        end)
    end)

    describe("call transport error", function()
        it("should return TRANSPORT error on invalid tcp url", function()
            local client = Client.new("tcp://not-a-valid-url")
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.are.equal(Error.TRANSPORT, err.code)
            assert.truthy(string.find(err.message, "invalid tcp url"))
        end)
    end)

    describe("call error paths via http_provider mock", function()
        local Http = require("yar.transport.http")

        after_each(function()
            Http.set_provider(nil)
        end)

        it("should return PROTOCOL error on unsupported packager", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            client:set_options({ packager = "NONEXISTENT" })
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.are.equal(Error.PROTOCOL, err.code)
            assert.truthy(string.find(err.message, "unsupported packager"))
        end)

        it("should return TRANSPORT error when http_provider returns transport error", function()
            Http.set_provider(function(_url, _opts)
                return nil, "connection refused"
            end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.are.equal(Error.TRANSPORT, err.code)
            assert.truthy(string.find(err.message, "connection refused"))
        end)

        it("should return TIMEOUT error when transport error contains 'timeout'", function()
            Http.set_provider(function(_url, _opts)
                return nil, "connect timeout"
            end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.are.equal(Error.TIMEOUT, err.code)
            assert.truthy(string.find(err.message, "timeout"))
        end)

        it("should return PROTOCOL error on unparseable response (garbage data)", function()
            Http.set_provider(function(_url, _opts)
                return "garbage-data-not-yar-protocol"
            end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.are.equal(Error.PROTOCOL, err.code)
        end)

        it("should return PROTOCOL error on truncated response (too short)", function()
            Http.set_provider(function(_url, _opts)
                return "short"  -- 远短于协议最小长度
            end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("add", { 1, 2 })
            assert.is_nil(result)
            assert.are.equal(Error.PROTOCOL, err.code)
        end)

        it("should return NOT_FOUND when server responds 'method not found'", function()
            -- 构造一个 status=1, err="method not found: xxx" 的 YAR 响应
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_ERROR, err = "method not found: unknown" })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("unknown", {})
            assert.is_nil(result)
            assert.are.equal(Error.NOT_FOUND, err.code)
            assert.truthy(string.find(err.message, "method not found"))
        end)

        it("should return EXCEPTION when server responds with other error", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_ERROR, err = "division by zero" })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)
            local client = Client.new("http://example.com/api")
            local result, err = client:call("div", { 1, 0 })
            assert.is_nil(result)
            assert.are.equal(Error.EXCEPTION, err.code)
            assert.truthy(string.find(err.message, "division by zero"))
        end)

        it("should return retval on success", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_OK, retval = 42 })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)
            local client = Client.new("http://example.com/api")
            local result = client:call("add", { 1, 2 })
            assert.are.equal(42, result)
        end)
    end)

    describe("call hooks", function()
        local Http = require("yar.transport.http")

        after_each(function()
            Http.set_provider(nil)
        end)

        it("should call on_request hook before sending", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_OK, retval = 1 })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)

            local hook_method, hook_params
            local client = Client.new("http://example.com/api")
            client:set_options({ hooks = { on_request = function(method, params)
                hook_method = method
                hook_params = params
            end } })
            client:call("add", { 1, 2 })
            assert.are.equal("add", hook_method)
            assert.are.equal(2, hook_params[2])
        end)

        it("should call on_response hook with retval on success", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_OK, retval = 99 })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)

            local hook_retval, hook_err
            local client = Client.new("http://example.com/api")
            client:set_options({ hooks = { on_response = function(_method, retval, err)
                hook_retval = retval
                hook_err = err
            end } })
            client:call("add", { 1, 2 })
            assert.are.equal(99, hook_retval)
            assert.is_nil(hook_err)
        end)

        it("should call on_response hook with err on failure", function()
            Http.set_provider(function(_url, _opts)
                return nil, "connection refused"
            end)

            local hook_err
            local client = Client.new("http://example.com/api")
            client:set_options({ hooks = { on_response = function(_method, _retval, err)
                hook_err = err
            end } })
            client:call("add", { 1, 2 })
            assert.is_not_nil(hook_err)
            assert.are.equal(Error.TRANSPORT, hook_err.code)
        end)

        it("should not crash on hook error (degrade to log)", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_OK, retval = 1 })
            local msg = Protocol.render(resp, json)
            Http.set_provider(function(_url, _opts) return msg end)

            local client = Client.new("http://example.com/api")
            client:set_options({ hooks = { on_request = function()
                error("hook crash")
            end } })
            -- should not throw, hook error degrades to log
            local result = client:call("add", { 1, 2 })
            assert.are.equal(1, result)
        end)
    end)

    describe("call persistent mode", function()
        local Http = require("yar.transport.http")

        after_each(function()
            Http.set_provider(nil)
        end)

        it("should reuse transport instance in persistent mode", function()
            local Protocol = require("yar.protocol.protocol")
            local Response = require("yar.message.response")
            local json = Packager.get(Packager.JSON)
            local resp = Response.new({ id = 1, status = Response.STATUS_OK, retval = 1 })
            local msg = Protocol.render(resp, json)
            local call_count = 0
            Http.set_provider(function(_url, _opts)
                call_count = call_count + 1
                return msg
            end)

            local client = Client.new("http://example.com/api")
            client:set_options({ persistent = true })
            client:call("add", { 1, 2 })
            client:call("add", { 3, 4 })
            -- persistent 模式下 provider 被调用 2 次（每次 call 都 send），
            -- 但 transport 实例只创建一次
            assert.are.equal(2, call_count)
            assert.is_not_nil(client._transport)
        end)

        it("should clear cached transport on error in persistent mode", function()
            Http.set_provider(function(_url, _opts)
                return nil, "connection refused"
            end)

            local client = Client.new("http://example.com/api")
            client:set_options({ persistent = true })
            client:call("add", { 1, 2 })
            assert.is_nil(client._transport)
        end)
    end)

    describe("call method validation", function()
        it("should error on non-string method", function()
            local client = Client.new("http://127.0.0.1:8888/api")
            local ok, err = pcall(function() client:call(123, {}) end)
            assert.is_false(ok)
            assert.truthy(string.find(err, "method must be a string"))
        end)
    end)
end)
