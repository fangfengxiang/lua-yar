-- spec/header_spec.lua
-- 协议头测试：pack/unpack roundtrip

local Header = require("yar.protocol.header")

describe("protocol header", function()
    it("should pack and unpack header fields", function()
        local h = Header.new({ id = 123, provider = "lua", token = "secret", body_len = 456 })
        local s = h:pack()
        assert.are.equal(Header.SIZE, #s)
        local h2 = Header.unpack(s)
        assert.are.equal(123, h2.id)
        assert.are.equal(Header.MAGIC_NUM, h2.magic_num)
        assert.are.equal(Header.VERSION, h2.version)
        assert.are.equal("lua", h2.provider)
        assert.are.equal("secret", h2.token)
        assert.are.equal(456, h2.body_len)
    end)
end)
