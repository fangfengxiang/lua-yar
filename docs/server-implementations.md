# 服务端并发实现示例

> lua-yar 是纯协议库，`server:handle(spec)` 无 I/O 依赖（callback 模式）、`server.dispatcher:handle_message(data)` 无 I/O、无 yield，可被任意协程直接调用。并发能力依赖宿主环境注入。本文档列出不同宿主环境下的并发 server 实现示例。

## 目录

- [原生 Lua（顺序）](#原生-lua顺序)
- [原生协程](#原生协程)
- [copas](#copas)
- [lua-eco](#lua-eco)
- [Skynet](#skynet)
- [OpenResty](#openresty)

---

## 原生 Lua（顺序）

标准 Lua + luasocket，单线程顺序 accept。仅供开发/测试。

### HTTP

```lua
local Yar = require("yar")
local server = Yar.server.new({
    add = function(a, b) return a + b end,
})
server:listen("http://0.0.0.0:8888")
server:loop()
```

→ 源码：[`example/server_http.lua`](../example/server_http.lua)

### TCP

```lua
local Server = require("yar.server")
local server = Server.new({
    add = function(a, b) return a + b end,
})
server:listen("tcp://0.0.0.0:9999")
server:loop()
```

→ 源码：[`example/server_tcp.lua`](../example/server_tcp.lua)

> ⚠ `loop()` 为单线程顺序 accept，一个慢请求会阻塞所有连接。

---

## 原生协程

纯 `coroutine` + `socket.select`，不依赖 copas。每个连接在独立协程内调度，socket 设为非阻塞，遇 `timeout` 时 `yield` 让出控制，主循环用 `socket.select` 检测就绪后 `resume`。

```lua
local socket = require("socket")
local Server = require("yar.server")

local server = Server.new({ add = function(a, b) return a + b end })
server.protocol = "http"  -- 宿主模式下默认 "tcp"，HTTP 需显式设置

-- 协程友好的 socket 包装器：非阻塞 I/O 遇 "timeout" 时 yield
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
            -- 同理，遇 timeout 时 yield("write")
        end,
        -- ...
    }
end

-- 主循环：socket.select 检测读/写就绪，resume 对应协程
-- handle 内部按 YAR 帧读取、派发、回写
server:handle({ socket = wrap_socket(client) })
```

约 70 行实现 copas 的等价核心，展示 Lua 原生协程调度原理。

→ 源码：[`example/server_coroutine.lua`](../example/server_coroutine.lua)

---

## copas

[copas](https://github.com/lunarmodules/copas) 是基于 luasocket 的协程调度器，每个连接在独立协程内被调度，实现单线程多连接并发。

```lua
local copas  = require("copas")
local socket = require("socket")
local Server = require("yar.server")

local server = Server.new({ add = function(a, b) return a + b end })

local srv = socket.bind("0.0.0.0", 9999)
copas.addserver(srv, function(client)
    server:handle({ socket = client, keepalive = true })
    client:close()
end)
copas.loop()
```

copas 已将 client 包装为协程安全 socket，`receive`/`send`/`close` 兼容，直接传入 `handle({ socket = ... })` 即可。

→ 安装：`luarocks install copas`
→ 源码：[`example/server_copas.lua`](../example/server_copas.lua)

---

## lua-eco

[lua-eco](https://github.com/zhaojh329/lua-eco) 是基于 Lua 5.4 + epoll 的协程优先网络运行时。每个连接在独立协程内被调度。

```lua
local eco    = require("eco")
local socket = require("eco.socket")
local Server = require("yar.server")

local server = Server.new({ add = function(a, b) return a + b end })

-- 将 lua-eco socket 适配为 luasocket 兼容接口（receive/send/close）
local function adapt(eco_sock)
    return {
        receive = function(_, n)
            local data, err = eco_sock:recv(n)
            if not data then return nil, err end
            return data
        end,
        send = function(_, data)
            local ok, err = eco_sock:send(data)
            if not ok then return nil, err end
            return #data
        end,
        close = function() eco_sock:close() end,
    }
end

local srv = socket.listen_tcp("0.0.0.0", 9999)
while true do
    local client = srv:accept()
    if client then
        eco.run(function()
            local sock = adapt(client)
            server:handle({ socket = sock })
            sock:close()
        end)
    end
end
```

lua-eco 的 socket API（`recv`/`send`）与 luasocket 略有不同，需用 adapter 适配为 `receive`/`send`/`close` 接口。

→ 安装：`luarocks install lua-eco`
→ 源码：[`example/server_luaeco.lua`](../example/server_luaeco.lua)

---

## Skynet

[Skynet](https://github.com/cloudwu/skynet) 是基于 Actor 模型的服务端框架，socket API 为 fd-based（`socket.listen`/`socket.start(fd, cb)`/`socket.read`/`socket.write`）。

```lua
local skynet = require("skynet")
local socket = require("skynet.socket")
local Server = require("yar.server")

local server = Server.new({ add = function(a, b) return a + b end })

-- 将 Skynet fd-based socket 适配为 luasocket 兼容接口
local function adapt(fd)
    return {
        receive = function(_, n)
            local data = socket.read(fd, n)
            if not data or data == "" then return nil, "closed" end
            return data
        end,
        send = function(_, data)
            socket.write(fd, data)
            return #data
        end,
        close = function() socket.close(fd) end,
    }
end

skynet.start(function()
    local listen_fd = socket.listen("0.0.0.0", 9999)
    socket.start(listen_fd, function(fd, _addr)
        local sock = adapt(fd)
        server:handle({ socket = sock })
        sock:close()
    end)
end)
```

Skynet 的 fd-based API（`socket.read(fd, n)` / `socket.write(fd, data)` / `socket.close(fd)`）需用 adapter 包装为 `receive(n)`/`send(data)`/`close()` 对象接口。

→ 安装：[https://github.com/cloudwu/skynet](https://github.com/cloudwu/skynet)
→ 源码：[`example/server_skynet.lua`](../example/server_skynet.lua)

---

## OpenResty

OpenResty 通过 `content_by_lua_block` 处理请求，`ngx.socket`（cosocket）提供非阻塞 I/O + 连接池。

### HTTP（content_by_lua）

```nginx
location /api {
    content_by_lua_block {
        local Yar = require "yar"
        local server = Yar.server.new({
            add = function(a, b) return a + b end,
        })
        ngx.req.read_body()
        server:handle({
            method = ngx.req.get_method(),
            data = ngx.req.get_body_data() or "",
            writer = function(status, headers, body)
                ngx.status = status
                for k, v in pairs(headers) do ngx.header[k] = v end
                ngx.print(body)
            end,
        })
    }
}
```

### TCP（stream 模块）

```nginx
stream {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";
    server {
        listen 9999;
        content_by_lua_block {
            require("example.server_openresty").serve()
        }
    }
}
```

`serve()` 内部通过 `ngx.req.sock()` 获取下游 cosocket，直接传入 `handle({ socket = sock })`，无需 adapter：

```lua
-- example/server_openresty.lua
function _M.serve()
    local sock, err = ngx.req.sock()
    if not sock then
        ngx.log(ngx.ERR, "failed to get downstream socket: " .. tostring(err))
        return
    end
    server:handle({ socket = sock })
    sock:close()
end
```

cosocket 的 `receive`/`send`/`close` 与 luasocket 接口一致，直接传入即可。

→ 源码：[`example/server_openresty.lua`](../example/server_openresty.lua)

### 生产级 OPM 部署

生产环境推荐使用 [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar) OPM 包，提供完整的 init/handler 分层：

| 模块 | 用途 |
|------|------|
| [`example/resty_yar_init.lua`](../example/resty_yar_init.lua) | `init_by_lua` 初始化：注入 cosocket + 创建进程级 Server 实例 + 透传 options |
| [`example/resty_yar_http_server.lua`](../example/resty_yar_http_server.lua) | HTTP `content_by_lua` handler：读 body → `handle(callback)` → writer 输出 |
| [`example/resty_yar_tcp_server.lua`](../example/resty_yar_tcp_server.lua) | TCP stream `content_by_lua` handler：cosocket → `handle(socket)` + 连接保活 |
| [`example/resty_yar_gateway.lua`](../example/resty_yar_gateway.lua) | RPC 网关示例：服务端内部作为客户端调用下游服务（`ngx.thread.spawn` 并行） |

---

## 生产环境

生产环境推荐直接使用 [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)（OpenResty 绑定，开箱即用）。
