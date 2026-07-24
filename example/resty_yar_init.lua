-- example/resty_yar_init.lua
-- lua-resty-yar OPM 包：初始化模块（服务端 + 出向客户端统一注入）
--
--   http {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       init_by_lua_block { require("example.resty_yar_init").setup() }
--       ...
--   }
--   stream {
--       lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
--       ...
--   }
--
-- 本模块做三件事：
--   1. 注入 cosocket —— 通过 Client API 注入，出向调用走 OpenResty 非阻塞 I/O
--   2. 创建进程级 Server 实例 —— 方法表 memoize，worker 内所有协程共享
--   3. 暴露 setup(opts) —— lua-resty-yar 使用方透传 options 给 yar-lua
--
-- ── options 三层归属 ──────────────────────────────────────────
--   连接级（OPM 层管，cosocket 上设）：
--     keepalive_idle  TCP 保活空闲超时（sock:settimeout）
--     不经过 yar-lua，handler 拿 config 直接设在 socket 上
--
--   服务端级（yar-lua Server 实例上设）：
--     packager        Yar.PACKAGER_JSON / Yar.PACKAGER_MSGPACK（响应编码格式）
--     timeout         standalone loop() 模式用（OpenResty 下不用）
--     OPM init 创建实例时设，进程级复用
--
--   客户端级（yar-lua Client 实例上设，per-call）：
--     timeout         出向调用超时（client:setopt）
--     persistent      TCP 持久连接（client:setopt）
--     网关场景每个 Client 独立配置，不走 setup

local Yar = require("yar")

local _M = {}
_M.Yar = Yar

-- ── 默认配置 ──────────────────────────────────────────────────
local config = {
    -- 连接级（OPM 层管）
    keepalive_idle   = 60000,   -- TCP 保活：两次请求间最大空闲等待（ms）

    -- 服务端级（透传给 yar-lua Server）
    packager         = Yar.PACKAGER_JSON,  -- 响应编码格式：Yar.PACKAGER_JSON 或 Yar.PACKAGER_MSGPACK
    timeout          = 5000,    -- standalone loop() 模式的 per-message 超时

    -- 客户端级默认（出向调用，可被 per-client setopt 覆盖）
    client_timeout   = 3000,    -- 出向 RPC 默认超时（ms）
    connect_timeout  = 1000,    -- 出向连接超时（ms）
}

--- 初始化：注入 cosocket + 创建实例 + 透传 options
-- 在 init_by_lua 阶段调用一次，worker 内全局生效
-- @param opts table|nil 用户配置，覆盖默认值
-- @usage
--   require("resty.yar.init").setup {
--       packager        = Yar.PACKAGER_MSGPACK,
--       keepalive_idle  = 30000,
--       client_timeout  = 5000,
--   }
function _M.setup(opts)
    opts = opts or {}

    -- 合并用户配置到 config（浅合并，service 不混入 config）
    for k, v in pairs(opts) do
        if k ~= "service" then
            config[k] = v
        end
    end

    -- 1. 注入 cosocket（通过 Client API，出向客户端路径用）
    Yar.client.set_socket(ngx.socket)

    -- 2. RPC 服务定义（生产环境放独立模块，这里 require 即可）
    local service = opts.service or {
        add   = function(a, b) return a + b end,
        sub   = function(a, b) return a - b end,
        greet = function(name) return "hello, " .. name end,
    }

    -- 3. 创建进程级 Server 实例 + 透传服务端级 options
    --    统一 Server Facade：HTTP 用 callback 模式 handle({method,data,writer})，
    --    TCP 用 socket 模式 handle({socket=sock, keepalive=true})。
    --    宿主模式下 protocol 默认 "tcp"，HTTP 回调模式不检查 protocol。
    local server = Yar.server.new(service)
    server:set_options({ packager = config.packager, timeout = config.timeout })

    -- 缓存到模块级变量
    _M._server = server

    return _M
end

--- 获取进程级复用的 Server 实例（HTTP + TCP 统一）
function _M.get_server()
    if not _M._server then
        error("resty.yar not initialized: call setup() in init_by_lua first")
    end
    return _M._server
end

--- 获取进程级复用的 Server 实例（TCP stream 场景，同 get_server）
-- 保留旧 API 名称以兼容现有 handler 代码
function _M.get_tcp_server()
    return _M.get_server()
end

--- 获取合并后的配置（handler 用来读连接级参数）
function _M.get_config()
    return config
end

--- 构造新的 Server 实例（需要自定义 service 时用）
function _M.new_server(svc)
    return Yar.server.new(svc)
end

return _M
