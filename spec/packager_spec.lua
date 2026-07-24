-- spec/packager_spec.lua
-- Packager 测试：error paths + cjson injection via register

local Yar = require("yar")
local Packager = require("yar.packager.packager")
local Json = require("yar.packager.json")
local Msgpack = require("yar.packager.msgpack")
local Request = require("yar.message.request")
local Response = require("yar.message.response")
local Protocol = require("yar.protocol.protocol")

describe("packager", function()
    describe("Packager.get error paths", function()
        it("should return nil, err for unknown packager name", function()
            local p, err = Packager.get("UNKNOWN")
            assert.is_nil(p)
            assert.truthy(string.find(err, "unsupported"))
        end)

        it("should return JSON as default", function()
            local jp = Packager.get()
            assert.is_not_nil(jp)
        end)
    end)

    describe("Packager.register", function()
        -- 注册测试用 Packager.JSON/MSGPACK + restore 模式（白名单只允许这两种）。
        -- registry 是模块级状态，每个用例改完即 restore，避免污染后续测试。
        it("should construct adapter from encode/decode lib", function()
            local fake_lib = {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            }
            local adapter, aerr = Packager.register(Packager.JSON, fake_lib)
            assert.is_not_nil(adapter)
            assert.is_nil(aerr)
            assert.are.equal("JSON", adapter.name)
            local p2 = Packager.get(Packager.JSON)
            assert.are.equal(adapter, p2)
            -- restore
            Packager.register(Packager.JSON, Json)
        end)

        it("should construct adapter from pack/unpack lib", function()
            local adapter2 = Packager.register(Packager.MSGPACK, {
                pack = function(t) return Msgpack.pack(t) end,
                unpack = function(s) return Msgpack.unpack(s) end,
            })
            assert.is_not_nil(adapter2)
            assert.are.equal("MSGPACK", adapter2.name)
            assert.are.equal(adapter2, Packager.get(Packager.MSGPACK))
            -- restore
            Packager.register(Packager.MSGPACK, Msgpack)
        end)

        it("should accept case-insensitive name and normalize to upper", function()
            local adapter = Packager.register("json", {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            })
            assert.are.equal("JSON", adapter.name)
            assert.are.equal(adapter, Packager.get("json"))
            -- restore
            Packager.register(Packager.JSON, Json)

            local adapter2 = Packager.register("msgpack", {
                pack = function(t) return Msgpack.pack(t) end,
                unpack = function(s) return Msgpack.unpack(s) end,
            })
            assert.are.equal("MSGPACK", adapter2.name)
            assert.are.equal(adapter2, Packager.get("msgpack"))
            -- restore
            Packager.register(Packager.MSGPACK, Msgpack)
        end)

        it("should reject non-whitelisted name (protocol compatibility)", function()
            local ok, err = pcall(Packager.register, "IGBINARY", {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            })
            assert.is_false(ok)
            assert.truthy(string.find(err, "must be JSON or MSGPACK"))
            assert.truthy(string.find(err, "IGBINARY"))
        end)

        it("should reject non-whitelisted name with valid pack/unpack lib", function()
            local ok, err = pcall(Packager.register, "FAKE", {
                pack = function(t) return Msgpack.pack(t) end,
                unpack = function(s) return Msgpack.unpack(s) end,
            })
            assert.is_false(ok)
            assert.truthy(string.find(err, "must be JSON or MSGPACK"))
        end)

        it("should validate lib before whitelist (bad lib + non-whitelisted name)", function()
            -- lib 校验先于白名单校验：非白名单 name + 非法 lib 应报 lib 错误
            local ok, err = pcall(Packager.register, "FAKE", "not-a-table")
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must be a table"))
        end)

        it("should reject non-string name", function()
            local ok, err = pcall(Packager.register, 123, { encode = function() end, decode = function() end })
            assert.is_false(ok)
            assert.truthy(string.find(err, "name must be a non%-empty string"))
        end)

        it("should reject empty name", function()
            local ok, err = pcall(Packager.register, "", { encode = function() end, decode = function() end })
            assert.is_false(ok)
            assert.truthy(string.find(err, "name must be a non%-empty string"))
        end)

        it("should reject non-table lib", function()
            local ok, err = pcall(Packager.register, "BAD", "not-a-table")
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must be a table"))
        end)

        it("should reject lib without methods", function()
            local ok, err = pcall(Packager.register, "BAD2", { foo = "bar" })
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must have pack/unpack or encode/decode"))
        end)

        it("should reject non-function methods", function()
            local ok, err = pcall(Packager.register, "BAD3", { encode = "not-a-func", decode = function() end })
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must have pack/unpack or encode/decode"))
        end)

        it("should reject lib with only pack (no unpack)", function()
            local ok, err = pcall(Packager.register, "BAD4", { pack = function() end })
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must have pack/unpack or encode/decode"))
        end)

        it("should reject lib with only encode (no decode)", function()
            local ok, err = pcall(Packager.register, "BAD5", { encode = function() end })
            assert.is_false(ok)
            assert.truthy(string.find(err, "lib must have pack/unpack or encode/decode"))
        end)
    end)

    describe("cjson injection via register", function()
        it("should inject + roundtrip + restore", function()
            local mock_cjson = {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            }

            local pure = Packager.get(Packager.JSON)
            -- 功能等价而非对象同一性：前面用例 restore 后 registry["JSON"] 是 adapter
            -- （register 构造 {name,pack,unpack}），pack/unpack 仍指向 Json 实现
            assert.are.equal(Json.pack, pure.pack)
            assert.are.equal(Json.unpack, pure.unpack)

            local adapter = Packager.register("JSON", mock_cjson)
            assert.is_not_nil(adapter)
            assert.are.equal("JSON", adapter.name)

            local injected = Packager.get(Packager.JSON)
            assert.are.equal(adapter, injected)
            assert.are_not_equal(Json, injected)

            local req = Request.new({ method = "add", params = { 10, 20 }, provider = "ci", token = "ct" })
            local msg = Protocol.render(req, injected)
            local payload, header = Protocol.parse(msg, injected)
            assert.are.equal("add", payload.m)
            assert.are.equal(10, payload.p[1])
            assert.are.equal(req.id, header.id)
            assert.are.equal("ci", header.provider)

            local resp = Response.new({ id = req.id }):set_retval(30)
            local rmsg = Protocol.render(resp, injected)
            local rpayload, rheader = Protocol.parse(rmsg, injected)
            assert.are.equal(30, rpayload.r)
            assert.are.equal(0, rpayload.s)
            assert.are.equal(req.id, rheader.id)

            -- restore: register(Json) 构造 adapter，行为等价于 Json
            Packager.register("JSON", Json)
            local restored = Packager.get(Packager.JSON)
            assert.are.equal(Json.pack, restored.pack)
            assert.are.equal(Json.unpack, restored.unpack)
        end)
    end)

    describe("Yar facade API", function()
        it("should NOT export Yar.Packager (facade closed)", function()
            assert.is_nil(Yar.Packager)
        end)

        it("should expose PACKAGER_JSON / PACKAGER_MSGPACK constants", function()
            assert.are.equal("JSON", Yar.PACKAGER_JSON)
            assert.are.equal("MSGPACK", Yar.PACKAGER_MSGPACK)
        end)

        it("Yar.get_packager delegates to Packager.get", function()
            local jp = Yar.get_packager(Yar.PACKAGER_JSON)
            assert.is_not_nil(jp)
            assert.are.equal("JSON", jp.name)
            local mp = Yar.get_packager(Yar.PACKAGER_MSGPACK)
            assert.is_not_nil(mp)
            assert.are.equal("MSGPACK", mp.name)
            -- case-insensitive
            local jp2 = Yar.get_packager("json")
            assert.are.equal(jp, jp2)
            -- default to JSON when name is nil
            local jp3 = Yar.get_packager()
            assert.are.equal(jp, jp3)
            -- unknown packager returns nil, err
            local unknown, err = Yar.get_packager("NOPE")
            assert.is_nil(unknown)
            assert.truthy(string.find(err, "unsupported"))
        end)

        it("Yar.register_packager delegates to Packager.register", function()
            local fake_lib = {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            }
            local adapter, aerr = Yar.register_packager(Yar.PACKAGER_JSON, fake_lib)
            assert.is_not_nil(adapter)
            assert.is_nil(aerr)
            assert.are.equal("JSON", adapter.name)
            -- registered via facade, retrievable via facade
            local p2 = Yar.get_packager(Yar.PACKAGER_JSON)
            assert.are.equal(adapter, p2)
            -- and also retrievable via internal Packager.get
            assert.are.equal(adapter, Packager.get(Packager.JSON))
            -- restore
            Yar.register_packager(Yar.PACKAGER_JSON, Json)
        end)

        it("Yar.register_packager rejects non-whitelisted name (facade passthrough)", function()
            local ok, err = pcall(Yar.register_packager, "FAKE", {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            })
            assert.is_false(ok)
            assert.truthy(string.find(err, "must be JSON or MSGPACK"))
        end)

        it("Yar.register_packager validates input (rejects bad name/lib)", function()
            local ok1 = pcall(Yar.register_packager, 123, { encode = function() end, decode = function() end })
            assert.is_false(ok1)
            local ok2 = pcall(Yar.register_packager, "YARBAD", "not-a-table")
            assert.is_false(ok2)
            local ok3 = pcall(Yar.register_packager, "YARBAD2", { foo = "bar" })
            assert.is_false(ok3)
        end)

        it("Yar.set_options({packager={json_max_depth=N}}) delegates to Json.set_max_depth", function()
            local orig = Json.max_depth
            Yar.set_options({ packager = { json_max_depth = 77 } })
            assert.are.equal(77, Json.max_depth)
            -- restore
            Json.set_max_depth(orig)
        end)

        it("Yar.set_options({packager={msgpack_max_depth=N}}) delegates to Msgpack.set_max_depth", function()
            local orig = Msgpack.max_depth
            Yar.set_options({ packager = { msgpack_max_depth = 88 } })
            assert.are.equal(88, Msgpack.max_depth)
            -- restore
            Msgpack.set_max_depth(orig)
        end)

        it("Yar.set_options ignores nil opts and nil packager sub-level", function()
            assert.has_no_errors(function() Yar.set_options(nil) end)
            assert.has_no_errors(function() Yar.set_options({ transport = { timeout = 1000 } }) end)
        end)

        it("registering cjson under Yar.PACKAGER_JSON keeps protocol name JSON", function()
            local mock_cjson = {
                encode = function(t) return Json.pack(t) end,
                decode = function(s) return Json.unpack(s) end,
            }
            local adapter = Yar.register_packager(Yar.PACKAGER_JSON, mock_cjson)
            assert.are.equal("JSON", adapter.name)
            -- protocol header packager name field carries "JSON", not "CJSON"
            local req = Request.new({ method = "echo", params = {} })
            local msg = Protocol.render(req, adapter)
            local packager_name = string.sub(msg, 1, 8)
            assert.are.equal("JSON\0\0\0\0", packager_name)
            -- restore
            Yar.register_packager(Yar.PACKAGER_JSON, Json)
        end)
    end)
end)
