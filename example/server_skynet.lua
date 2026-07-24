-- example/server_skynet.lua
-- Yar TCP Server + Skynet 高并发示例
-- 启动：在 Skynet 配置中加载本文件（通过 skynet.start 注册服务）
--
-- Skynet 是基于 Actor 模型的服务端框架，socket API 为 fd-based
-- （socket.listen / socket.start(fd, cb) / socket.read / socket.write）。
-- server:handle({ socket = sock }) 需要 receive(n)/send(data)/close() 的 socket 对象，
-- 这里用 adapter 将 fd-based API 包装为对象接口。
--
-- 安装：https://github.com/cloudwu/skynet
-- 本文件需在 Skynet 运行时内 require，不能独立 lua 命令行运行。

local skynet = require("skynet")
local socket = require("skynet.socket")
local Server = require("yar.server")

local api = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    greet = function(name) return "hello, " .. name end,
}

-- 宿主模式下 protocol 默认 "tcp"，无需 listen()
local server = Server.new(api)

-- 将 Skynet fd-based socket 适配为 luasocket 兼容接口
-- socket.read(fd, sz)：sz 为 nil 时读到一行或缓冲区数据；指定 sz 读指定长度
local function adapt(fd)
    return {
        receive = function(_, n)
            -- 精确读 n 字节：Skynet socket.read(fd, n) 返回字符串
            local data = socket.read(fd, n)
            if not data or data == "" then return nil, "closed" end
            return data
        end,
        send = function(_, data)
            socket.write(fd, data)
            return #data
        end,
        close = function()
            socket.close(fd)
        end,
    }
end

skynet.start(function()
    local host, port = "0.0.0.0", 9999
    local listen_fd = socket.listen(host, port)
    socket.start(listen_fd, function(fd, _addr)
        -- 每个 client 连接在 Skynet 的协程内被调度
        local sock = adapt(fd)
        local ok, err = pcall(function()
            server:handle({ socket = sock })
        end)
        if not ok then
            skynet.error("[Yar skynet] handler error: " .. tostring(err))
        end
        sock:close()
    end)
    skynet.error("Yar Lua TCP server (Skynet) listening on " .. host .. ":" .. port)
end)
