# 改造方案反思 v3：handle + run 双模式 + Facade 细化

> 基于 v2 Facade 方向，纳入用户补充的定位思考，细化 `handle`/`run` 双模式 API 设计。
> 状态：反思文档（待确认后更新提案） | 关联：v1 提案、v2 反思、`server-architecture-reflection.md`

---

## 一、定位反思：lua-yar 的真正难点

### 1.1 三种 Yar 实现的定位光谱

| 实现 | daemon 模式 | 宿主模式 | 定位 |
|---|---|---|---|
| **yar-c** | ✅ 自带（pre-fork + libevent） | ❌ | 重 daemon 型——库拥有进程生命周期 |
| **PHP yar** | ❌ | ✅ 依赖 fpm/nginx | 宿主依赖型——库只做协议，宿主做 daemon + transport |
| **lua-yar** | ✅ 要支持 | ✅ 要支持 | **两者都要**——既支持独立 daemon，又支持宿主模式 |

### 1.2 难点

lua-yar 的难点不是「怎么分层」（v1/v2 已解决），而是**一个库要同时服务两种截然不同的运行模式**：

- **daemon 模式**（对标 yar-c）：标准 Lua 下，没有宿主，库自己 bind + accept + 处理。需要 `run()` 阻塞 accept 循环。
- **宿主模式**（对标 PHP yar）：OpenResty / copas / lua-eco 下，宿主已有 accept 循环，库只需处理一个请求/连接。需要 `handle()` 处理单次请求。

**且宿主模式必须轻量级、无依赖**——不能在 OpenResty 下 `require` 一个 daemon 模块（那会引入不必要的 luasocket 依赖）。PHP yar 的 `handle()` 就是极致轻量：一个函数，处理一个请求，结束。

### 1.3 从这个定位看 v1/v2 的问题

v1 提案 A 把 daemon 和 transport 都暴露给调用方，让调用方自己组装。这违反了「两种模式各取所需」的定位：
- 宿主用户只需要 `handle`，不需要 `Daemon`/`Transport` 概念
- daemon 用户只需要 `run`，不需要知道内部 transport 细节

v2 Facade 方向正确（隐藏内部），但用单一 `run()` 内部分发，语义不够清晰——`run` 既做 daemon 又做 hosted，职责模糊。

### 1.4 用户的关键洞察

> 「lua-yar 既支持重 daemon 又要支持宿主模式。让 server 支持 handler 和 run 两个模式是不是也可以。宿主端运行时全部用 handler。」

**两个方法对应两种模式**：
- `server:handle(spec)` — 宿主模式，处理一个请求/连接周期（对标 PHP yar `handle()`）
- `server:run(url)` — daemon 模式，accept 循环（对标 yar-c `run()`）

调用方选哪个方法，就选了哪种模式。不需要 options 判断，不需要感知 Transport/Daemon。

---

## 二、handle + run 双模式 API 设计

### 2.1 API 总览

```lua
-- 构造（统一入口）
local server = Server.new(service, opts?)
-- opts: { timeout, max_body_len, packager, ... } 服务级配置

-- 宿主模式：处理一个请求/连接
server:handle(spec)
-- spec 决定 I/O 机制（socket 或回调）

-- daemon 模式：accept 循环（标准 Lua only）
server:run(url)
-- url 决定 protocol + address
```

### 2.2 handle —— 宿主模式

`handle` 是宿主模式的入口，对标 PHP yar 的 `$server->handle()`。宿主已有 accept 循环，`handle` 只处理一个请求/连接周期。

#### 场景 1：OpenResty HTTP（回调注入）

```lua
-- content_by_lua_block（nginx http {} location）
local server = Server.new(api)

server:handle({
    method = ngx.req.get_method(),       -- "GET" 或 "POST"
    data   = ngx.req.get_body_data(),    -- 请求体（POST 时有值）
    writer = function(resp, content_type)
        ngx.header["Content-Type"] = content_type
        ngx.print(resp)
    end,
})
```

**行为**：
- POST → `handle_message(data)` → `writer(yar_resp, "application/octet-stream")`
- GET → 生成服务列表 HTML → `writer(html, "text/html")`（introspection）

**writer 签名**：`writer(resp, content_type)` — 回调拿到响应字节 + content-type，宿主自己设 header。这符合「库做协议，宿主做 HTTP」的哲学。

#### 场景 2：OpenResty TCP（socket 注入）

```lua
-- content_by_lua_block（nginx stream {} location）
local server = Server.new(api)

server:handle({
    socket    = ngx.req.sock(),
    keepalive = true,
})
```

**行为**：`Framing.receive_message(sock)` → `handle_message(data)` → `sock:send(resp)` → （keepalive 时循环）→ 客户端断开时返回。

#### 场景 3：copas TCP（socket 注入）

```lua
copas.addserver(server_socket, function(client)
    local server = Server.new(api)
    server:handle({socket = client, keepalive = true})
end)
copas.loop()
```

**行为**：同场景 2——copas 的 accept 循环调 `handle`，`handle` 处理一个连接周期。

#### 场景 4：协程 HTTP（socket + protocol）

```lua
-- 标准 Lua 协程，自建 accept 循环
local server = Server.new(api)
while true do
    local sock = accept(listen_sock)
    server:handle({socket = sock, protocol = "http"})
    sock:close()
end
```

**行为**：`handle` 从 socket 解析 HTTP 请求行/头/体 → `handle_message` → 写 HTTP 响应。`protocol = "http"` 告诉 `handle` 用 HTTP 帧格式而非 YAR 帧。

#### handle 的 spec 选项汇总

| spec 字段 | 适用场景 | 含义 |
|---|---|---|
| `socket` | TCP / HTTP socket 模式 | 已连接的 socket 对象 |
| `protocol` | socket 模式 | `"tcp"`（默认）或 `"http"`——决定帧格式 |
| `keepalive` | TCP socket 模式 | 是否循环处理多个请求（默认 false） |
| `method` | HTTP 回调模式 | `"GET"` 或 `"POST"`——GET 触发 introspection |
| `data` | HTTP 回调模式 | 请求体字节（POST 时有值） |
| `writer` | HTTP 回调模式 | `function(resp, content_type)` 回调 |

**两种 I/O 模式**：
- **socket 模式**：`{socket = sock, protocol = "tcp"|"http", keepalive = bool}` — 库管 I/O
- **回调模式**：`{method = str, data = str, writer = fn}` — 宿主管 I/O，库只做协议

### 2.3 run —— daemon 模式

`run` 是 daemon 模式的入口，对标 yar-c 的 `yar_server_run()`。标准 Lua 下没有宿主，`run` 自己 bind + accept + 委托 `handle`。

```lua
-- 标准 Lua TCP daemon
local server = Server.new(api, {keepalive = true})
server:run("tcp://0.0.0.0:8888")

-- 标准 Lua HTTP daemon
local server = Server.new(api)
server:run("http://0.0.0.0:8888")

-- Unix socket daemon（TCP 协议）
local server = Server.new(api)
server:run("unix:///tmp/yar.sock")
```

**URL scheme 决定 protocol**（对标 yar-c 的 `init("tcp://addr")`）：
- `tcp://host:port` → TCP 协议（YAR 帧）
- `http://host:port` → HTTP 协议（HTTP 请求/响应）
- `unix:///path` → Unix socket（TCP 协议）

**run 内部实现**（调用方不可见）：

```lua
function Server:run(url)
    local protocol, addr = parse_url(url)
    local listen_sock = Socket.bind(addr)       -- bind + listen
    while true do
        local client = listen_sock:accept()
        self:handle({                           -- ★ 委托给 handle
            socket    = client,
            protocol  = protocol,
            keepalive = self.opts.keepalive or false,
        })
        if not (protocol == "tcp" and self.opts.keepalive) then
            client:close()
        end
    end
end
```

**关键**：`run` 内部调 `handle`——`handle` 是核心，`run` 只是 accept 循环 + `handle` 的包装。两种模式共享同一个 `handle` 逻辑。

### 2.4 对称性验证

| 场景 | API | 概念数 |
|---|---|---|
| 标准 Lua TCP daemon | `Server.new(api):run("tcp://addr")` | 1（Server） |
| 标准 Lua HTTP daemon | `Server.new(api):run("http://addr")` | 1（Server） |
| OpenResty HTTP | `Server.new(api):handle({data=, writer=})` | 1（Server） |
| OpenResty TCP | `Server.new(api):handle({socket=, keepalive=})` | 1（Server） |
| copas TCP | `Server.new(api):handle({socket=, keepalive=})` | 1（Server） |
| 协程 HTTP | `Server.new(api):handle({socket=, protocol="http"})` | 1（Server） |

**所有场景都是 1 个概念（Server），2 个方法（handle/run）**。HTTP 和 TCP 对称——差异仅在 spec 的字段。

### 2.5 与 yar-c / PHP yar 的对标

| 维度 | yar-c | PHP yar | lua-yar v3 |
|---|---|---|---|
| daemon 启动 | `init("tcp://addr"); run()` | — | `Server.new(api):run("tcp://addr")` |
| 宿主处理 | — | `new(svc); handle()` | `Server.new(api):handle({data=, writer=})` |
| URL 选 transport | ✅ `"tcp://"` | — | ✅ `"tcp://"` / `"http://"` |
| 方法注册 | `register_handler(array)` | 构造时反射 | `:register(name, func)` 链式 |
| 调用方概念 | 1（Server） | 1（Server） | **1（Server）** |
| 模式选择 | 无（只有 daemon） | 无（只有 host） | **方法选择**（handle vs run） |

lua-yar v3 = yar-c 的 `run` + PHP yar 的 `handle`，用两个方法覆盖两种模式。

---

## 三、内部架构（调用方不可见）

### 3.1 模块结构

```
src/yar/server/
  init.lua       ← Server（Facade + 协议核心 handle_message）
  transport/     ← 内部 transport 模块（不直接暴露给调用方）
    http.lua     ← HttpTransport（无状态：read_request/write_response）
    tcp.lua      ← TcpTransport（无状态：read_request/write_response）
  daemon.lua     ← 内部 daemon 模块（run 的实现）
```

### 3.2 Server Facade 内部分发

```lua
-- server/init.lua

local TcpTransport = require("yar.server.transport.tcp")
local HttpTransport = require("yar.server.transport.http")
local Daemon = require("yar.server.daemon")

function Server.new(service, opts)
    local self = setmetatable({}, _M)
    self.core = ServerCore.new(service)  -- 协议核心（原 init.lua 逻辑）
    self.opts = opts or {}
    return self
end

-- 宿主模式
function Server:handle(spec)
    if spec.socket then
        -- socket 模式
        if spec.protocol == "http" then
            return HttpTransport.serve(spec.socket, self.core, self.opts)
        else
            return TcpTransport.serve(spec.socket, self.core, spec, self.opts)
        end
    elseif spec.writer then
        -- 回调模式（HTTP only）
        return self:_handle_callback(spec)
    end
end

-- daemon 模式
function Server:run(url)
    local protocol, addr = parse_url(url)
    return Daemon.run(self, protocol, addr, self.opts)
    -- Daemon 内部：bind + accept + self:handle({socket=client, protocol=protocol})
end

-- 回调模式内部实现
function Server:_handle_callback(spec)
    if spec.method == "GET" then
        local html = self.core:list_methods_html()
        spec.writer(html, "text/html")
    else
        local resp = self.core:handle_message(spec.data)
        spec.writer(resp, "application/octet-stream")
    end
end
```

### 3.3 内部模块职责

| 模块 | 职责 | 暴露给调用方 |
|---|---|---|
| `ServerCore`（原 init.lua） | 协议核心：`handle_message(data)` → resp | ✅ 通过 `Server:handle` / `Server:run` |
| `TcpTransport` | YAR 帧读写：`serve(sock, core, opts)` | ❌ 内部 |
| `HttpTransport` | HTTP 请求解析/响应构造：`serve(sock, core, opts)` | ❌ 内部 |
| `Daemon` | accept 循环：`run(server, protocol, addr, opts)` | ❌ 内部 |

**内部仍三层分离**（可测试、可复用），但调用方只看到 Server。

---

## 四、待打磨的细节

### 4.1 writer 签名

```lua
writer = function(resp, content_type) ... end
```

- `resp`：响应字节（YAR 二进制 或 introspection HTML）
- `content_type`：`"application/octet-stream"` 或 `"text/html"`

**待定**：是否需要给 `status`？当前 HTTP 错误（如 405 Method Not Allowed）由谁处理？
- 方案 A：`handle` 内部处理错误，writer 只收正常响应。错误时 writer 收到错误响应体 + 对应 content_type + status。
- 方案 B：`handle` 返回 `nil, err`，调用方自己处理错误响应。
- **倾向 A**：对标 PHP yar `handle()` 内部处理一切，调用方不需要管错误。writer 签名改为 `writer(resp, content_type, status)`。

### 4.2 GET introspection

当前 HttpServer 的 GET 请求返回 HTML 服务列表。v3 中通过 `method = "GET"` 触发：

```lua
server:handle({
    method = ngx.req.get_method(),
    data   = ngx.req.get_body_data(),
    writer = function(resp, content_type, status)
        ngx.status = status
        ngx.header["Content-Type"] = content_type
        ngx.print(resp)
    end,
})
```

GET 时 `handle` 调 `core:list_methods_html()` → `writer(html, "text/html", 200)`。

**待定**：introspection 的 HTML 格式是否与当前 HttpServer 一致？是否需要可定制模板？

### 4.3 URL 解析

`run("tcp://0.0.0.0:8888")` 需要解析 scheme + host + port。是否复用客户端 `transport/transport.lua` 的 URL 解析逻辑？

**倾向**：复用。客户端已有 `string.match(url, "^tcp://")` 等逻辑，提取为共享函数。

### 4.4 keepalive 的归属

TCP `handle` 的 keepalive 循环在 `TcpTransport.serve` 内部。`run` 调 `handle` 时传 `keepalive` 选项。HTTP `handle` 不支持 keepalive（HTTP/1.0 Connection: close）。

**待定**：`run("tcp://addr")` 默认 keepalive=true 还是 false？当前 TcpServer 默认 false（单连接）。倾向保持 false 默认，opts 显式开启。

### 4.5 错误处理

`handle` 的错误处理策略：
- socket 模式：I/O 错误 → log + 关闭连接（对标当前 `handle_connection` 行为）
- 回调模式：`handle_message` 内部错误 → 返回 YAR error 帧 → `writer(error_resp, "application/octet-stream", 200)`
- `handle` 返回值：`true`（成功）或 `nil, err`（严重错误，如 socket 断开），供调用方 log

### 4.6 是否保留 Transport/Daemon 为公开模块

**倾向**：保留公开，但文档主推 Facade。
- 高级用户可直接用 `TcpTransport.serve(sock, core, opts)` 绕过 Facade
- 文档推荐用 `Server:handle()` / `Server:run()`
- 类似 Lua 标准库：推荐用 `io.open`，但也暴露 `io.lines` 等底层接口

### 4.7 ServerCore 命名

当前 `server/init.lua` 是 Server 协议核心。Facade 后，`init.lua` 变成 Facade，协议核心需要改名：
- 方案 A：`server/core.lua` — 协议核心，`init.lua` 做 Facade
- 方案 B：`init.lua` 保持协议核心，另建 `server/server.lua` 做 Facade
- **倾向 A**：`init.lua` 是模块入口（Facade），`core.lua` 是协议核心。符合 Lua 惯例（init = 入口）。

---

## 五、v1 → v2 → v3 演进总结

| 维度 | v1 提案 A | v2 Facade | v3 handle+run |
|---|---|---|---|
| 设计模式 | handler 注入（copas） | 统一 Facade（yar-c+PHP yar） | **双模式 Facade**（yar-c run + PHP yar handle） |
| 调用方方法 | 3 个概念组装 | 1 个 run 内部分发 | **2 个方法**（handle=宿主, run=daemon） |
| 模式选择 | 调用方组装 | options 判断 | **方法选择**（handle vs run） |
| HTTP/TCP 对称 | ❌ | ✅ | **✅** |
| URL 选 transport | ❌（require） | ✅ | **✅** |
| HTTP 回调注入 | ❌ | ✅ | **✅（writer 回调）** |
| 宿主轻量性 | ❌（要 import Daemon） | ✅ | **✅（handle 无 daemon 依赖）** |
| 业界对标 | copas | yar-c + PHP yar | **yar-c run + PHP yar handle** |

**核心转变**：从 v1 的「让调用方组装三层」→ v2 的「Facade 统一 run」→ v3 的「handle+run 双模式，方法即模式选择」。v3 最贴合 lua-yar「既支持 daemon 又支持宿主」的定位。
