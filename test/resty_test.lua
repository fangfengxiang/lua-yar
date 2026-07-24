-- test/resty_test.lua
-- OpenResty 环境测试：通过 resty CLI 运行，验证 yar-lua 在 OpenResty/LuaJIT 下的兼容性
-- 运行：resty -e 'require("test.resty_test").run()'
--   或：resty test/resty_test.lua
--
-- 测试范围：
--   1. 协议往返（JSON + Msgpack）—— 验证纯数学二进制操作在 LuaJIT 下正确
--   2. Server handle_message —— 验证纯函数在 OpenResty 上下文 reentrant
--   3. cosocket 注入 —— 验证 Yar.client.set_socket(ngx.socket) 不报错
--   4. Framing 帧读取 —— 验证 receive_exact / receive_message 在 cosocket mock 下正确
--   5. 边界条件 —— half-packet / sticky packet 在 OpenResty 下行为一致

local package_path = package.path
package.path = package_path .. ";./src/?.lua;./src/?/init.lua;./test/?.lua"

local Yar      = require("yar")
local Header   = require("yar.protocol.header")
local Protocol = require("yar.protocol.protocol")
local Request  = require("yar.message.request")
local Response = require("yar.message.response")
local Framing  = require("yar.protocol.framing")
local Packager = require("yar.packager.packager")

local M = {}

local function assert_ok(cond, msg)
    if not cond then error("ASSERT FAILED: " .. (msg or "expression is false"), 2) end
end

-- 1. 协议往返（JSON + Msgpack）
local function test_protocol_roundtrip()
    local p = Packager.get(Packager.JSON)
    local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
    local msg = Protocol.render(req, p)
    local payload, header = Protocol.parse(msg, p)
    assert_ok(payload.m == "add", "resty: json request method mismatch")
    assert_ok(payload.p[1] == 1, "resty: json request params mismatch")
    assert_ok(header.id == req.id, "resty: json request id mismatch")
    assert_ok(header.provider == "p", "resty: json provider mismatch")
    assert_ok(header.token == "t", "resty: json token mismatch")

    local mp = Packager.get(Packager.MSGPACK)
    local req2 = Request.new({ method = "echo", params = { "hi", 42 }, provider = "p2", token = "t2" })
    local msg2 = Protocol.render(req2, mp)
    local payload2, header2 = Protocol.parse(msg2, mp)
    assert_ok(payload2.m == "echo", "resty: msgpack method mismatch")
    assert_ok(payload2.p[1] == "hi", "resty: msgpack params mismatch")
    assert_ok(header2.provider == "p2", "resty: msgpack provider mismatch")

    print("  [OK] resty protocol roundtrip (JSON + Msgpack)")
end

-- 2. Server handle_message（纯函数，reentrant）
local function test_server_handle_message()
    local Server = Yar.server
    local server = Server.new({ add = function(a, b) return a + b end })

    local p = Packager.get(Packager.JSON)
    local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
    local msg = Protocol.render(req, p)
    local payload, header = Protocol.parse(server:handle_message(msg), p)
    assert_ok(payload.r == 30, "resty: server retval mismatch")
    assert_ok(header.id == req.id, "resty: server id mismatch")

    -- Msgpack 自动适配
    local mp = Packager.get(Packager.MSGPACK)
    local req2 = Request.new({ method = "add", params = { 7, 8 }, provider = "p", token = "t" })
    local msg2 = Protocol.render(req2, mp)
    local resp2 = server:handle_message(msg2)
    assert_ok(string.sub(resp2, 1, 7) == Packager.MSGPACK, "resty: server response packager mismatch")
    local payload2 = Protocol.parse(resp2, mp)
    assert_ok(payload2.r == 15, "resty: server msgpack retval mismatch")

    -- 错误路径：未知方法
    local req3 = Request.new({ method = "nope", params = {}, provider = "p", token = "t" })
    local resp3 = server:handle_message(Protocol.render(req3, p))
    local payload3 = Protocol.parse(resp3, p)
    assert_ok(payload3.s == Response.STATUS_ERROR, "resty: unknown method should return error status")

    print("  [OK] resty server handle_message (JSON + Msgpack + error path)")
end

-- 3. cosocket 注入
local function test_cosocket_injection()
    -- ngx.socket 应存在（resty CLI 提供 ngx API）
    assert_ok(ngx ~= nil, "resty: ngx table should be available")
    assert_ok(ngx.socket ~= nil, "resty: ngx.socket should be available")
    assert_ok(type(ngx.socket.tcp) == "function", "resty: ngx.socket.tcp should be a function")

    -- 注入 cosocket 到 Client（类级）
    Yar.client.set_socket(ngx.socket)

    -- 创建 Client 实例，验证不报错
    local client = Yar.client.new("tcp://127.0.0.1:9999")
    assert_ok(client ~= nil, "resty: client creation should succeed after cosocket injection")

    -- 验证 socket provider 已切换（非默认 luasocket）
    -- 注意：无法直接检查内部状态，但 set_socket 不报错即表示注入成功
    print("  [OK] resty cosocket injection (ngx.socket -> Client.set_socket)")
end

-- 4. Framing 帧读取（mock cosocket）
local function mock_cosocket(data)
    local pos = 1
    return {
        receive = function(_, pattern)
            if type(pattern) == "number" then
                if pos > #data then return nil, "closed" end
                local chunk = string.sub(data, pos, pos + pattern - 1)
                pos = pos + #chunk
                return chunk
            end
            return nil
        end,
        send = function(_, d) return #d end,
        settimeout = function() end,
        settimeouts = function() end,
        close = function() end,
        setkeepalive = function() return true end,
    }
end

local function test_framing_under_resty()
    local p = Packager.get(Packager.JSON)
    local req = Request.new({ method = "add", params = { 1, 2 }, provider = "p", token = "t" })
    local msg = Protocol.render(req, p)

    -- 正常消息读取
    local sock = mock_cosocket(msg)
    local data = Framing.receive_message(sock)
    assert_ok(data ~= nil, "resty: receive_message should succeed on complete message")
    assert_ok(#data == #msg, "resty: received message length should match")

    -- half-packet：只有 10 字节
    local sock_short = mock_cosocket(string.rep("X", 10))
    local data2, err = Framing.receive_message(sock_short)
    assert_ok(data2 == nil, "resty: half-packet should return nil")
    assert_ok(err ~= nil, "resty: half-packet should return error")

    -- sticky packet：两条消息拼接
    local req2 = Request.new({ method = "add", params = { 3, 4 }, provider = "p2", token = "t2" })
    local msg2 = Protocol.render(req2, p)
    local combined = msg .. msg2
    local sock3 = mock_cosocket(combined)
    local first = Framing.receive_message(sock3)
    assert_ok(first ~= nil and #first == #msg, "resty: first sticky message should be exact")
    local second = Framing.receive_message(sock3)
    assert_ok(second ~= nil and #second == #msg2, "resty: second sticky message should be exact")
    local third = Framing.receive_message(sock3)
    assert_ok(third == nil, "resty: third receive should return nil (no more data)")

    print("  [OK] resty framing (complete + half-packet + sticky packet)")
end

-- 5. handle_connection（TCP server，mock cosocket）
local function test_handle_connection_resty()
    local TcpTransport = require("yar.server.tcp")
    local Server = Yar.server
    local server = Server.new({
        add = function(a, b) return a + b end,
    })

    local p = Packager.get(Packager.JSON)
    local req = Request.new({ method = "add", params = { 10, 20 }, provider = "p", token = "t" })
    local msg = Protocol.render(req, p)

    -- 单消息模式
    local sent = {}
    local sock = mock_cosocket(msg)
    -- 覆盖 send 以捕获响应
    sock.send = function(_, d) sent[#sent + 1] = d; return #d end
    TcpTransport.serve(sock, server.dispatcher, { keepalive = false })
    local resp_data = table.concat(sent)
    local payload, header = Protocol.parse(resp_data, p)
    assert_ok(payload.r == 30, "resty: tcp handle_connection retval mismatch")
    assert_ok(header.id == req.id, "resty: tcp handle_connection id mismatch")

    print("  [OK] resty handle_connection (single message)")
end

-- 6. LuaJIT 兼容性：验证无 string.pack 依赖（纯数学实现）
local function test_luajit_compat()
    -- Header 打包/解包在 LuaJIT 下应正确（不依赖 string.pack）
    local h = Header.new({ id = 0xDEADBEEF, provider = "test", token = "secret", body_len = 256 })
    local packed = h:pack()
    assert_ok(#packed == Header.SIZE, "resty: header pack should be 82 bytes")
    local h2 = Header.unpack(packed, 1)
    assert_ok(h2.id == 0xDEADBEEF, "resty: header id roundtrip mismatch")
    assert_ok(h2.provider == "test", "resty: header provider roundtrip mismatch")
    assert_ok(h2.token == "secret", "resty: header token roundtrip mismatch")
    assert_ok(h2.body_len == 256, "resty: header body_len roundtrip mismatch")
    assert_ok(h2.magic_num == Header.MAGIC_NUM, "resty: header magic roundtrip mismatch")

    -- uint32 边界值
    local Util = require("yar.util")
    local max_u32 = 0xFFFFFFFF
    local packed_max = Util.pack_u32(max_u32)
    local unpacked = Util.unpack_u32(packed_max, 1)
    assert_ok(unpacked == max_u32, "resty: uint32 max roundtrip mismatch: " .. tostring(unpacked))

    print("  [OK] resty LuaJIT compat (header roundtrip + uint32 boundary)")
end

function M.run()
    print("=== Yar-Lua OpenResty tests ===")
    test_protocol_roundtrip()
    test_server_handle_message()
    test_cosocket_injection()
    test_framing_under_resty()
    test_handle_connection_resty()
    test_luajit_compat()
    print("=== all resty tests passed ===")
end

-- 直接运行（resty test/resty_test.lua）时自动执行；require 时不重复执行
if arg and arg[0] and string.find(arg[0], "resty_test") then
    M.run()
end

return M
