-- spec/soft_dependency_spec.lua
-- 软依赖优雅降级测试：验证 luasocket 不可用时框架不崩溃
-- 此 spec 不依赖 luasocket，可在无 luasocket 环境运行（CI no-luasocket job）
-- 也可在有 luasocket 环境运行（通过注入 nil-returning provider 模拟降级）

local Yar = require("yar")
local Client = Yar.client
local Socket = require("yar.transport.socket")

describe("soft dependency graceful degradation", function()
    local saved_provider

    before_each(function()
        saved_provider = Socket.tcp
    end)

    after_each(function()
        Socket.tcp = saved_provider
    end)

    it("should return error instead of crashing when socket provider unavailable", function()
        -- 模拟 luasocket 不可用：tcp() 返回 nil + err
        Socket.tcp = function() return nil, "luasocket not available" end

        local client = Client.new("http://127.0.0.1:8888/api")
        local ret, err = client:call("add", { 1, 2 })

        assert.is_nil(ret)
        assert.is_not_nil(err)
        assert.truthy(string.find(tostring(err), "luasocket")
            or string.find(tostring(err), "transport")
            or string.find(tostring(err), "socket"))
    end)

    it("should return error for tcp:// scheme when socket provider unavailable", function()
        Socket.tcp = function() return nil, "luasocket not available" end

        local client = Client.new("tcp://127.0.0.1:9999")
        local ret, err = client:call("add", { 1, 2 })

        assert.is_nil(ret)
        assert.is_not_nil(err)
    end)
end)
