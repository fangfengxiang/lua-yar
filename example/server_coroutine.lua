-- example/server_coroutine.lua
-- 原生协程并发 HTTP server 示例（不依赖 copas，纯 coroutine + luasocket）
--
-- 核心原理：
--   1. 每个连接在一个协程中处理
--   2. socket 设为非阻塞（settimeout(0)）
--   3. receive/send 遇到 "timeout" 时 coroutine.yield("read"/"write") 让出控制
--   4. 主循环用 socket.select 同时检测读就绪和写就绪，resume 对应协程
--
-- 这是 copas 的极简等价实现（约 70 行），展示 Lua 原生协程调度的核心原理。
-- 生产环境推荐直接用 copas / lua-eco / OpenResty。
--
-- 运行：lua example/server_coroutine.lua
-- 测试：lua example/client.lua（可开多终端并发请求验证并发性）

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local socket = require("socket")
local Server  = require("yar.server")

local server = Server.new({
    add  = function(a, b) return a + b end,
    sub  = function(a, b) return a - b end,
    echo = function(msg) return msg end,
})

-- 宿主模式下 protocol 默认 "tcp"，HTTP 场景需显式设为 "http"
server.protocol = "http"

-- 协程友好的 socket 包装器：非阻塞 I/O 遇到 "timeout" 时 yield
-- yield 值 "read"/"write" 告知调度器下次 select 需要检测的方向
local function wrap_socket(sock)
    sock:settimeout(0)
    return {
        receive = function(_, pattern)
            while true do
                local data, err = sock:receive(pattern)
                if data then return data end
                if err == "timeout" then coroutine.yield("read")
                else return nil, err end
            end
        end,
        send = function(_, data)
            local i = 1
            while i <= #data do
                local sent, err, last = sock:send(data, i)
                if sent then
                    i = sent + 1
                elseif err == "timeout" then
                    if last then i = last + 1 end
                    coroutine.yield("write")
                else
                    return nil, err
                end
            end
            return #data
        end,
        settimeout = function() end,
        close = function() sock:close() end,
    }
end

-- 协程调度表：socket -> { co = coroutine, want = "read"|"write" }
local socks = {}

-- 处理单个连接（协程入口）
local function handle_client(sock)
    server:handle({ socket = wrap_socket(sock) })
end

-- resume 协程并更新其 want 状态；协程结束时清理 socket
local function resume_co(s)
    local info = socks[s]
    if not info or coroutine.status(info.co) == "dead" then return end
    local ok, want = coroutine.resume(info.co)
    if not ok then
        print("[coroutine] error: " .. tostring(want))
    end
    if coroutine.status(info.co) == "dead" then
        socks[s] = nil
        s:close()
    else
        info.want = want or "read"
    end
end

-- 启动
local host, port = "0.0.0.0", 8888
local listen = socket.bind(host, port)
listen:settimeout(0)
print("Yar Lua HTTP server (coroutine mode) listening on " .. host .. ":" .. port)

while true do
    -- 构建 select 读集和写集：listen + 按 want 分类活跃连接
    local read_set = { listen }
    local write_set = {}
    for s, info in pairs(socks) do
        if info.want == "write" then
            table.insert(write_set, s)
        else
            table.insert(read_set, s)  -- "read" 或默认
        end
    end

    local ready_read, ready_write = socket.select(read_set, write_set, 1)

    -- 合并就绪 socket（避免同一 socket 在两个集合中重复 resume）
    local resumed = {}
    for _, s in ipairs(ready_read) do
        if s == listen then
            -- 新连接：创建协程
            local client = listen:accept()
            if client then
                local co = coroutine.create(function()
                    handle_client(client)
                end)
                socks[client] = { co = co, want = "read" }
                resume_co(client)
            end
        else
            resumed[s] = true
            resume_co(s)
        end
    end
    for _, s in ipairs(ready_write) do
        if not resumed[s] then
            resume_co(s)
        end
    end
end
