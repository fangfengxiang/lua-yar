-- test/bench_transport.lua
-- lua-yar 综合传输层 benchmark
-- 用法: <runtime> test/bench_transport.lua <case> <mode> [provider]
--   case: 1=http+json  2=http+msgpack  3=tcp+json  4=tcp+msgpack
--   mode: mock | real | all (默认 all)
--   provider: yar-http | resty-http (仅 OpenResty HTTP real 模式)
--
-- 运行时自动检测：Lua 5.1 / 5.3 / 5.5 / LuaJIT / OpenResty

--------------------------------------------------------------------------------
-- 运行时检测与 package 路径设置
--------------------------------------------------------------------------------

local jit_available = (type(jit) == "table" and type(jit.version) == "string"
    and jit.version:match("LuaJIT") ~= nil)
local is_resty = (ngx ~= nil and ngx.socket ~= nil)

local runtime_name
if is_resty then
    runtime_name = "OpenResty"
elseif jit_available then
    runtime_name = "LuaJIT"
else
    runtime_name = _VERSION and ("Lua-" .. _VERSION) or "Lua"
end

-- Lua 5.1/5.3 需要自定义 luarocks tree 路径
if _VERSION == "Lua 5.1" then
    package.path = package.path
        .. ";/Users/frank/.luarocks-5.1/share/lua/5.1/?.lua"
        .. ";/Users/frank/.luarocks-5.1/share/lua/5.1/?/init.lua"
    package.cpath = package.cpath
        .. ";/Users/frank/.luarocks-5.1/lib/lua/5.1/?.so"
elseif _VERSION == "Lua 5.3" then
    package.path = package.path
        .. ";/Users/frank/.luarocks-5.3/share/lua/5.3/?.lua"
        .. ";/Users/frank/.luarocks-5.3/share/lua/5.3/?/init.lua"
    package.cpath = package.cpath
        .. ";/Users/frank/.luarocks-5.3/lib/lua/5.3/?.so"
end

-- 项目源码路径
package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

--------------------------------------------------------------------------------
-- 依赖加载
--------------------------------------------------------------------------------

local Protocol  = require("yar.protocol.protocol")
local Request   = require("yar.message.request")
local Server    = require("yar.server")
local Packager  = require("yar.packager.packager")
local Json      = require("yar.packager.json")
local Msgpack   = require("yar.packager.msgpack")

-- C 扩展检测
local has_cjson = pcall(require, "cjson")
local has_cmsgpack = pcall(require, "cmsgpack")

--------------------------------------------------------------------------------
-- 参数解析
--------------------------------------------------------------------------------

local case_map = {
    [1] = { transport = "http",   packager = "json",    label = "HTTP + JSON" },
    [2] = { transport = "http",   packager = "msgpack", label = "HTTP + Msgpack" },
    [3] = { transport = "tcp",    packager = "json",    label = "TCP + JSON" },
    [4] = { transport = "tcp",    packager = "msgpack", label = "TCP + Msgpack" },
}

local case_num = tonumber(arg[1]) or 0
local mode = arg[2] or "all"
local provider_type = arg[3] or "yar-http"

local cfg = case_map[case_num]
if not cfg then
    print("Usage: <runtime> test/bench_transport.lua <case> <mode> [provider]")
    print("  case: 1=http+json  2=http+msgpack  3=tcp+json  4=tcp+msgpack")
    print("  mode: mock | real | all")
    print("  provider: yar-http | resty-http (OpenResty HTTP only)")
    os.exit(1)
end

local packager_name = cfg.packager
local transport_name = cfg.transport
local cext_name = (packager_name == "json") and "cjson" or "cmsgpack"
local has_cext = (packager_name == "json") and has_cjson or has_cmsgpack
local builtin_module = (packager_name == "json") and Json or Msgpack
local cext_lib = has_cext and require(cext_name) or nil

--------------------------------------------------------------------------------
-- benchmark 工具函数
--------------------------------------------------------------------------------

local function bench(name, fn, n)
    -- 预热
    local preheat = math.min(n, 1000)
    for _ = 1, preheat do fn() end
    -- 计时
    local start = os.clock()
    for _ = 1, n do fn() end
    local elapsed = os.clock() - start
    local ops = n / elapsed
    print(string.format("    %-44s %d ops in %5.3fs  -> %10s ops/s",
        name, n, elapsed, tostring(math.floor(ops))))
    return ops
end

--------------------------------------------------------------------------------
-- Mock benchmark（handle_message 全链路，零 I/O 开销）
-- handle_message(data) 接收完整 YAR 二进制消息字符串，
-- 内部完成 parse → dispatch → render 全链路。
--------------------------------------------------------------------------------

local function run_mock_benchmark()
    local api = {
        add = function(a, b) return a + b end,
    }
    local server = Server.new(api)

    -- 构造请求对象
    local request = Request.new({
        method = "add",
        params = { 1, 2 },
        provider = "p",
        token = "t",
    })

    -- 全链路纯 Lua packager
    -- 内置 Json/Msgpack 已在 Packager registry 中注册，直接获取
    local pure_packer = Packager.get(packager_name)
    local msg_pure = Protocol.render(request, pure_packer)

    bench("handle_message (pure-Lua " .. packager_name .. ")", function()
        server.dispatcher:handle_message(msg_pure)
    end, 50000)

    -- 全链路 C 扩展 packager
    -- 注册 C 扩展替换内置实现（packager name 仍为 JSON/MSGPACK，协议兼容）
    if cext_lib then
        Packager.register(packager_name, cext_lib)
        local cext_packer = Packager.get(packager_name)
        local msg_cext = Protocol.render(request, cext_packer)

        bench("handle_message (" .. cext_name .. ")", function()
            server.dispatcher:handle_message(msg_cext)
        end, 50000)

        -- 恢复内置实现
        Packager.register(packager_name, builtin_module)
    else
        print(string.format("    %-44s [SKIP] %s not installed",
            "handle_connection (" .. cext_name .. ")", cext_name))
    end
end

--------------------------------------------------------------------------------
-- 真实 I/O round-trip benchmark
--------------------------------------------------------------------------------

local function run_real_benchmark()
    local Client = require("yar.client")

    local url, server_cmd, kill_cmd

    if transport_name == "http" then
        -- 纯 Lua HTTP 服务端（bench_http_server.lua），全链路纯 Lua
        local port = 9800
        url = "http://127.0.0.1:" .. port .. "/yar"
        server_cmd = "lua test/bench_http_server.lua " .. port .. " > /dev/null 2>&1 &"
        kill_cmd = "pkill -f 'bench_http_server.lua " .. port .. "' 2>/dev/null"
    else
        -- lua-yar TCP server (bench_server.lua)
        local port = 9600
        url = "tcp://127.0.0.1:" .. port
        server_cmd = "lua test/bench_server.lua " .. port .. " > /dev/null 2>&1 &"
        kill_cmd = "pkill -f 'bench_server.lua " .. port .. "' 2>/dev/null"
    end

    -- 启动服务端
    os.execute(server_cmd)
    os.execute("sleep 1")  -- 等待服务端就绪

    -- 检测服务端可达性
    local Socket = require("yar.transport.socket")
    local probe = Socket.tcp()
    if probe then
        local ok = probe:connect("127.0.0.1", transport_name == "http" and 9800 or 9600)
        if not ok then
            print("    [SKIP] server not reachable")
            os.execute(kill_cmd)
            return
        end
        probe:close()
    end

    -- OpenResty 注入 cosocket（真实 cosocket keepalive）
    -- TCP 和 yar-http 模式都需要：TCP 传输用 cosocket 连接，yar-http 用 cosocket 发 HTTP
    -- resty-http 模式不需要（resty.http 内部自行管理 cosocket）
    if is_resty and not (transport_name == "http" and provider_type == "resty-http") then
        local Socket = require("yar.transport.socket")
        Socket.set(ngx.socket)
    end

    -- 设置 HTTP provider（OpenResty resty-http 模式）
    if is_resty and transport_name == "http" and provider_type == "resty-http" then
        local Http = require("yar.transport.http")
        local resty_http = require("resty.http")
        Http.set_provider(function(req_url, opts)
            local httpc = resty_http.new()
            local res, err = httpc:request_uri(req_url, {
                method = "POST",
                body = opts.body,
                headers = opts.headers,
                keepalive_timeout = 60000,
                keepalive_pool = 10,
            })
            if not res then return nil, err end
            return res.body
        end)
    end

    -- 创建客户端（Client.new(uri) 接收 URI 字符串）
    local client = Client.new(url)
    client:set_options({
        packager = packager_name,
        persistent = true,  -- 连接复用（keepalive）
    })

    -- 验证连通性
    local ok, result = pcall(client.call, client, "add", { 1, 2 })
    if not ok then
        print("    [SKIP] client call failed: " .. tostring(result))
        os.execute(kill_cmd)
        return
    end

    -- keepalive round-trip benchmark
    local n = 10000
    if transport_name == "http" and not is_resty then
        n = 2000  -- luasocket HTTP 慢，减少迭代
    end

    bench("round-trip keepalive (" .. packager_name .. ")", function()
        client:call("add", { 1, 2 })
    end, n)

    -- C 扩展 packager round-trip
    if cext_lib then
        local client_cext = Client.new(url)
        client_cext:set_options({
            packager = packager_name,  -- 协议名仍为 JSON/MSGPACK
            persistent = true,
        })
        -- 注册 C 扩展（进程级，影响 client_cext 的 packager 获取）
        Packager.register(packager_name, cext_lib)
        -- 验证连通性
        local ok2 = pcall(client_cext.call, client_cext, "add", { 1, 2 })
        if ok2 then
            bench("round-trip keepalive (" .. cext_name .. ")", function()
                client_cext:call("add", { 1, 2 })
            end, n)
        else
            print("    [SKIP] " .. cext_name .. " client call failed")
        end
        -- 恢复内置实现
        Packager.register(packager_name, builtin_module)
    end

    -- 清理
    if is_resty and transport_name == "http" and provider_type == "resty-http" then
        local Http = require("yar.transport.http")
        Http.set_provider(nil)
    end
    if is_resty and not (transport_name == "http" and provider_type == "resty-http") then
        local Socket = require("yar.transport.socket")
        Socket.set(nil)  -- 恢复默认 luasocket provider
    end
    os.execute(kill_cmd)
end

--------------------------------------------------------------------------------
-- 主入口
--------------------------------------------------------------------------------

print(string.format("BENCH_TRANSPORT\t%s\t%s\tcjson=%s\tcmsgpack=%s\tjit=%s\tprovider=%s",
    runtime_name, cfg.label, tostring(has_cjson), tostring(has_cmsgpack),
    tostring(jit_available), provider_type))
print("")

if mode == "mock" or mode == "all" then
    print("[Mock — handle_message full pipeline]")
    run_mock_benchmark()
    print("")
end

if mode == "real" or mode == "all" then
    print("[Real I/O — keepalive round-trip]")
    run_real_benchmark()
    print("")
end

print("=== done ===")
