-- spec/transport_resolve_spec.lua
-- Resolve 模块测试：curl/PHP 风格 host→IP 映射

local Resolve = require("yar.transport.resolve")

describe("transport.resolve", function()
    describe("apply_resolve — nil/empty", function()
        it("should return original host when resolve_str is nil", function()
            assert.are.equal("example.com", Resolve.apply_resolve("example.com", 80, nil))
        end)

        it("should return original host when resolve_str is empty", function()
            assert.are.equal("example.com", Resolve.apply_resolve("example.com", 80, ""))
        end)
    end)

    describe("apply_resolve — curl style (host:port:ip)", function()
        it("should return IP when host and port both match", function()
            assert.are.equal("192.168.1.1",
                Resolve.apply_resolve("example.com", 80, "example.com:80:192.168.1.1"))
        end)

        it("should return original host when port does not match", function()
            assert.are.equal("example.com",
                Resolve.apply_resolve("example.com", 8080, "example.com:80:192.168.1.1"))
        end)

        it("should return original host when host does not match", function()
            assert.are.equal("example.com",
                Resolve.apply_resolve("example.com", 80, "other.com:80:192.168.1.1"))
        end)

        it("should not fall back to PHP format when curl format matches but port differs", function()
            -- curl 格式匹配成功但 port 不匹配 → 返回 host，不回退 PHP 格式
            assert.are.equal("example.com",
                Resolve.apply_resolve("example.com", 443, "example.com:80:192.168.1.1"))
        end)
    end)

    describe("apply_resolve — PHP style (host:ip)", function()
        it("should return IP when host matches (PHP format)", function()
            assert.are.equal("10.0.0.1",
                Resolve.apply_resolve("example.com", 80, "example.com:10.0.0.1"))
        end)

        it("should return original host when host does not match (PHP format)", function()
            assert.are.equal("example.com",
                Resolve.apply_resolve("example.com", 80, "other.com:10.0.0.1"))
        end)
    end)

    describe("apply_resolve — edge cases", function()
        it("should handle localhost resolve", function()
            assert.are.equal("127.0.0.1",
                Resolve.apply_resolve("localhost", 8888, "localhost:8888:127.0.0.1"))
        end)

        it("should handle IPv6-style IP in curl format", function()
            assert.are.equal("::1",
                Resolve.apply_resolve("localhost", 80, "localhost:80:::1"))
        end)
    end)
end)
