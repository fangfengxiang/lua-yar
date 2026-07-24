# Server 重构报告：从混合层到三层分离 Facade

> 本报告记录 lua-yar 服务端架构重构的全过程：重构前的架构问题、设计演进（v1→v4）、跨语言 I/O 抽象研究、最终设计方案、前后使用对比、设计考量与取舍。
>
> 关联文档：
> - 设计过程：`docs/refactor/` 下 8 篇文档（提案→反思→综合→评审→实施计划）
> - 设计决策：`docs/design/server-layer.md`（ADR #11-14, #38-39）、`docs/design/cross-cutting.md`
> - 源码实现：`src/yar/server/` 下 5 个模块（init/dispatcher/tcp/http/daemon）

---

## 一、概述

### 1.1 重构目标

将服务端从「HttpServer/TcpServer 混合 daemon+transport 的两个类」重构为「Server Facade 统一入口 + Dispatcher/Transport/Daemon 三层分离」的架构。

**核心验收标准**：调用方只感知 1 个概念（Server）+ 3 个方法（handle/listen/loop），所有场景（HTTP/TCP、宿主/原生）完全对称。

### 1.2 重构成果

| 维度 | 重构前 | 重构后 |
|---|---|---|
| 调用方概念数 | 3（Server + HttpServer + TcpServer） | 1（Server） |
| 入口方法 | `run()` / `handle_message()` / `handle_connection()`（3 类各不同） | `handle()` / `listen()` + `loop()`（3 方法统一） |
| HTTP/TCP 对称 | 否（不同类、不同方法、不同签名） | 是（差异仅在 spec 字段） |
| daemon/transport 分离 | 否（耦合在同一类） | 是（三层独立，Facade 隐藏） |
| 客户端/服务端对称 | 否（客户端有统一 transport 工厂，服务端没有） | 是（Facade 对标 Client） |

---

## 二、重构前：架构全景与问题

### 2.1 旧架构全景

重构前，服务端有三个类，每个类混合了不同层次的职责：

```
┌──────────────────────────────────────────────────────────┐
│  server/init.lua  ← 纯协议域（无 I/O）                    │
│  handle_message(data) → resp                             │
│  解析 packager/header/body → 派发方法 → 渲染响应          │
└──────────────────────▲▲──────────────────────────────────┘
                       │ │
┌──────────────────────┘ └────────────────────────────────┐
│  server/http.lua                  server/tcp.lua         │
│  ┌──────────────┐                ┌────────────────────┐ │
│  │ Daemon       │                │ Daemon             │ │
│  │ run(addr)    │                │ run(addr)          │ │
│  │ accept 循环  │                │ accept 循环        │ │
│  ├──────────────┤                ├────────────────────┤ │
│  │ HTTP Transport│               │ YAR Frame Transport│ │
│  │ handle_conn  │                │ handle_conn        │ │
│  │ 读请求行/头/体│                │ Framing.recv_msg   │ │
│  │ 写 HTTP 响应 │                │ 写 YAR 帧          │ │
│  └──────────────┘                └────────────────────┘ │
│  luasocket only                  luasocket + OpenResty  │
│  ❌ OpenResty 不可用              ✅ handle_conn 可复用  │
└──────────────────┘              └──────────────────────┘
```

**每个 Server 类混合了两个领域**：daemon（accept 循环）+ transport adapter（线协议解析）。没有统一 transport 工厂，没有统一 transport 接口。

### 2.2 2×2 决策矩阵问题

调用方面对 4 种路径，每种用不同的类 + 不同的方法：

| 运行时 | 协议 | 实例化 | 调用 |
|---|---|---|---|
| 标准 Lua | HTTP | `HttpServer.new(svc)` | `:run(addr)` |
| 标准 Lua | TCP | `TcpServer.new(svc)` | `:run(addr)` |
| OpenResty http | HTTP | `Server.new(svc)` | `:handle_message(data)` |
| OpenResty stream | TCP | `TcpServer.new(svc)` | `:handle_connection(sock)` |

调用方需要回答两个问题才能写对代码：①我在哪个运行时？②我用哪个协议？对比客户端：不管什么运行时、什么协议，都是 `Client.new(url):call(method, args)` 一行代码。

### 2.3 四个核心问题

| 问题 | 根因 |
|---|---|
| **限界上下文混淆** | HttpServer/TcpServer 混合了 daemon（进程生命周期）和 transport（线协议解析）两个限界上下文，变更驱动因素不同却绑在一起 |
| **调用方心智负担高** | 2×2 决策矩阵——调用方需判断运行时 × 协议，4 种路径用不同的类和方法 |
| **无统一 transport 抽象** | 客户端有 `Transport.get(url)` 工厂 + 统一 `new/open/send/close` 接口；服务端无等价物，`handle_connection` 签名不一致 |
| **HttpServer 在 OpenResty 下完全不可用** | `run()` 是 accept 循环，与 nginx daemon 架构冲突；cosocket 无 `bind()`。TcpServer 的 `handle_connection` 至少能复用，HttpServer 连 `handle_connection` 都多余（nginx 已解析 HTTP） |

### 2.4 旧 API 使用方式

**标准 Lua TCP daemon**：
```lua
local TcpServer = require("yar.server.tcp")
local server = TcpServer.new(api)
server:set_options({ max_body_len = 2^20 })
server:run("0.0.0.0:8888")
```

**标准 Lua HTTP daemon**：
```lua
local HttpServer = require("yar.server.http")
local server = HttpServer.new(api)
server:run("0.0.0.0:8888")
```

**OpenResty HTTP**（~80 行手动处理）：
```lua
local server = init.get_server()
local method = ngx.req.get_method()
if method == "GET" then
    ngx.header["Content-Type"] = "application/json"
    ngx.print(packager.pack(server:list_methods()))
    return
end
if method ~= "POST" then ... end
ngx.req.read_body()
local data = ngx.req.get_body_data()
if not data then ... end
local resp, err = server:handle_message(data)
if not resp then ... end
ngx.header["Content-Type"] = CONTENT_TYPE
ngx.print(resp)
```

**OpenResty TCP**：
```lua
local sock = ngx.req.sock()
sock:settimeout(config.keepalive_idle)
local tcp_server = init.get_tcp_server()
local ok, e = pcall(tcp_server.handle_connection, tcp_server, sock, { keepalive = true })
if not ok then ngx.log(ngx.ERR, ...) end
sock:close()
```

---

## 三、设计演进过程

重构经历了 v1→v2→v3→v4 四轮迭代，每轮解决不同层面的问题：

### 3.1 v1：三层组装提案（方向 A）

**思路**：将 daemon 与 transport adapter 分离为独立模块，对标 copas `handler(skt)` 模式。

```
Server（协议核心，不变）
  ↑
Transport 层（无状态模块，serve 函数）
  ↑
Daemon 层（有状态对象，accept 循环）
```

**问题**：调用方需感知 3 个概念（Server + Transport + Daemon），需手动组装 `Daemon.run(Server.new(api), HttpTransport, addr)`。心智负担从 2×2 矩阵变为「选哪三层」——降低了但未消除。

### 3.2 v2：Facade 统一

**思路**：引入 Facade 模式，Server 统一入口，内部分发给 Transport/Daemon。

**关键变化**：调用方只感知 1 个概念（Server），内部分发由 Facade 处理。HTTP/TCP 通过 options 或类名选择。

**问题**：模式选择靠 options 判断（`opts.protocol`），不够直观；HTTP 回调注入已支持但未形成理论。

### 3.3 v3：handle + run 双模式

**思路**：方法即模式——`handle()` = 宿主模式，`run()` = 原生模式。选方法即选模式，不需要 options 判断。

**关键变化**：认知负担进一步降低——调用方通过选方法选模式，不需要感知 options。

**问题**：缺少跨语言理论支撑，I/O 抽象的统一性未形成规律；v1-v3 是经验层面的设计迭代（看 copas/yar-c/PHP yar 怎么做，然后模仿）。

### 3.4 v4：跨语言理论支撑 + I/O 抽象统一

**触发点**：用户指出「在 Lua 找不到方案时，应到其他语言去找」。

**突破**：跨语言研究 WSGI/ASGI/Go net/http，提炼出 I/O 抽象的统一规律——**I/O 即读写回调对**。socket 天然满足回调对接口，这是 HTTP 和 TCP 可统一抽象的根本原因。

**最终设计**：
- `handle(spec)` 统一入口，spec 字段区分 I/O Strategy（socket vs data+writer）
- `listen(addr)` + `loop()` 分离，对标 lua-resty-http `new()` + `connect()` 分离模式
- 5 个设计模式应用：Facade + Strategy + Template Method + Adapter + Factory
- 7 个细节决议：writer 签名、GET introspection、addr 解析、keepalive 默认、错误处理、Transport/Daemon 公开性、模块命名

```
v1（让调用方组装三层）
  → v2（Facade 统一 run，内部分发）
    → v3（handle+run 双模式，方法即模式）
      → v4（跨语言理论支撑 + I/O 抽象统一 + 7 细节决议 + 设计模式应用）
```

---

## 四、跨语言 I/O 抽象研究

### 4.1 研究动机

v1-v3 停留在 Lua 生态内部和 Yar 自身实现。RPC 服务端的核心问题是 I/O 抽象——如何把「读请求字节 / 写响应字节」从具体传输机制中剥离。跨语言研究为这个问题提供了理论答案。

### 4.2 三大标杆

**WSGI（Python，PEP 3333）—— 同步回调抽象**：
```python
def app(environ, start_response):
    data = environ["wsgi.input"].read(int(environ["CONTENT_LENGTH"]))
    start_response("200 OK", [("Content-Type", "application/octet-stream")])
    return [response_bytes]
```
- 读：`wsgi.input` 流对象
- 写：`start_response(status, headers)` 回调 + return body
- 关键：app 不接触 socket——I/O 被「流 + 回调」替代

**ASGI 3.0（Python 异步）—— 事件回调对抽象**：
```python
async def app(scope, receive, send):
    request = await receive()
    await send({"type": "http.response.start", "status": 200, ...})
    await send({"type": "http.response.body", "body": response_bytes})
```
- 读：`receive()` 可调用对象
- 写：`send(event_dict)` 可调用对象
- 关键：同一接口服务 HTTP/WebSocket/HTTP/2——I/O 是回调函数对，不是 socket

**Go net/http —— 接口抽象 + Listen/Serve 分离**：
```go
type Handler interface { ServeHTTP(w ResponseWriter, r *Request) }
http.ListenAndServe(":8080", handler)  // daemon: 库管 Listen+Accept+Serve
http.Serve(listener, handler)           // hosted: 调用方管 Listen+Accept，库管 Serve
```
- 读：`r *Request`（`r.Body` 是 Reader）
- 写：`ResponseWriter` 接口
- 关键：daemon/hosted 二元性通过拆分 Listen 和 Serve 解决

### 4.3 统一洞察：I/O 即读写回调对

| 实现 | 读请求 | 写响应 | 本质 |
|---|---|---|---|
| WSGI | `wsgi.input` 流 | `start_response` + return | 流 + 回调 |
| ASGI | `receive()` 可调用 | `send(event)` 可调用 | 回调对 |
| Go | `Request.Body` Reader | `ResponseWriter` 接口 | 接口 |
| TCP socket | `sock:receive(n)` | `sock:send(data)` | 对象方法 |
| HTTP 回调 | `data` 字符串 | `writer(resp)` 回调 | 值 + 回调 |

**核心规律**：I/O 抽象的本质是「一种拿请求字节的方式 + 一种送响应字节的方式」。

- socket 是这个抽象的一个实现（receive / send 方法对）
- 回调也是这个抽象的一个实现（data 值 / writer 函数对）
- **socket 天然满足回调对接口**——这是 HTTP 和 TCP 可统一抽象的根本原因

这是 v4 设计的理论基石：`handle(spec)` 中，`socket` 字段和 `data`+`writer` 字段是同一 I/O 抽象的两种实现。对 Server 内部，都是「拿到 data → handle_message → 输出 resp」。

### 4.4 A+B+C 融汇

| 模式 | 代表 | 优势 | 劣势 |
|---|---|---|---|
| A. 胖 daemon | yar-c | URL 选 transport、只看 Server | 不支持宿主 |
| B. 宿主依赖 | PHP yar | 极致轻量、handle() 无参 | 不支持 daemon |
| C. handler 注入 | copas | 通用灵活 | 调用方感知 2+ 概念 |

**融汇策略**：

| 借鉴来源 | 借鉴什么 | lua-yar 体现 |
|---|---|---|
| yar-c | URL scheme 选 transport | `listen("tcp://addr")` / `listen("http://addr")` + `loop()` |
| PHP yar | handle() 处理单请求、极致轻量 | `handle(spec)` 宿主入口 |
| Go net/http | Listen/Serve 分离 | `loop`=ListenAndServe vs `handle`=Serve |
| ASGI | I/O = 回调对 | HTTP 的 `data`+`writer` 与 TCP 的 `socket` 统一 |
| copas | handler 注入（内部用） | Transport 内部存在，Facade 隐藏 |

### 4.5 设计哲学三原则

1. **方法即模式**——`handle`=宿主模式，`listen`+`loop`=原生模式。选方法即选模式
2. **I/O 即回调对**——socket 和 data+writer 是同一抽象的两种实现
3. **Facade 隐藏内部**——Transport/Daemon 内部存在（可测试可复用），调用方不直接接触

---

## 五、最终设计：三层分离 + Facade

### 5.1 架构全景

```
┌─────────────────────────────────────────────────────────┐
│  Server Facade (init.lua)                                │
│  new(opts?, service?) / handle(spec) / listen(addr)      │
│  loop() / register_service / set_options / ...           │
│  对外只暴露 1 概念 + 3 方法                              │
└──────┬──────────┬──────────────┬────────────────────────┘
       │          │              │
       ▼          ▼              ▼
┌──────────┐ ┌──────────┐ ┌──────────────┐
│Dispatcher│ │Transport │ │ Daemon       │
│(协议核心)│ │(I/O 层)  │ │(accept 循环) │
│          │ │          │ │              │
│handle_   │ │TcpTransport│ Daemon.run  │
│message() │ │  .serve()│ │ (bind 已在  │
│register_ │ │HttpTransport│ listen 完成)│
│service() │ │  .serve()│ │              │
│list_     │ │  .serve_  │ │ 委托         │
│methods() │ │  callback│ │ server:handle│
│pack()    │ │          │ │              │
│          │ │          │ │              │
│无 I/O    │ │无状态    │ │有状态        │
│无 yield  │ │模块函数  │ │标准 Lua only │
│reentrant │ │          │ │              │
└──────────┘ └──────────┘ └──────────────┘
```

### 5.2 模块职责

| 模块 | 文件 | 职责 | 对标 |
|---|---|---|---|
| Server Facade | `init.lua` | 统一入口，分发+委托，addr 解析 | Go `http.Server`、PHP `Yar_Server` |
| Dispatcher | `dispatcher.lua` | 协议核心，handle_message + register_service + list_methods + pack。无 I/O，无 yield，reentrant | Python `SimpleXMLRPCDispatcher` |
| TcpTransport | `tcp.lua` | YAR 帧读写 + keepalive 循环，无状态模块函数 | copas `handler(skt)` |
| HttpTransport | `http.lua` | HTTP 请求解析 + 响应构造，socket 模式 + 回调模式 | Go `http.Handler` |
| Daemon | `daemon.lua` | accept 循环（bind 已在 listen() 完成），委托 server:handle | Go `net.Listen` + `http.Serve` |

### 5.3 API 总览

```lua
-- 构造（对标 lua-resty-http http.new()、lua-resty-redis redis.new()）
-- 构造器只做初始化（opts/service），不碰地址、不碰 I/O
local server = Server.new(opts?, service?)
-- opts: { packager, max_body_len, timeout, keepalive, hooks, socket_provider, ... }
-- service: RPC 方法表（可选，传了自动收集 public 方法）
--   对标 PHP Yar new Yar_Server($service)、Go rpc.Register(recv)

-- 宿主模式：handle(spec) — 对标 PHP yar handle() + Go Serve()
server:handle({
    -- 场景 1：OpenResty HTTP（回调注入，对标 WSGI start_response）
    method = ngx.req.get_method(),
    data   = ngx.req.get_body_data(),
    writer = function(status, headers, body) ... end,
})
-- 或
server:handle({
    -- 场景 2：OpenResty TCP / copas TCP（socket 注入）
    socket = sock, keepalive = true,
})

-- 原生模式：listen(addr) + loop() — 对标 httpc:connect() + copas.loop()
server:listen("tcp://0.0.0.0:8888")  -- 或 "http://0.0.0.0:8888" / "unix:///path"
server:loop()
```

### 5.4 spec 字段

| spec 字段 | 适用场景 | 含义 | 默认值 |
|---|---|---|---|
| `socket` | TCP / HTTP socket 模式 | 已连接 socket（满足 receive/send 契约） | — |
| `keepalive` | TCP socket 模式 | 是否循环处理多个请求 | `false` |
| `method` | HTTP 回调模式 | `"GET"` 或 `"POST"` | — |
| `data` | HTTP 回调模式 | 请求体字节 | — |
| `writer` | HTTP 回调模式 | `function(status, headers, body)` | — |

两种 I/O 模式（Strategy）：
- **socket 模式**：`{socket=, keepalive=}` — 库管 I/O，协议由 `self.protocol` 决定（listen 时从 addr 解析，宿主模式默认 `"tcp"`）
- **回调模式**：`{method=, data=, writer=}` — 宿主管 I/O，库只做协议（隐式 HTTP）

### 5.5 5 个设计模式

| 模式 | 作用 | 对标 |
|---|---|---|
| Facade | 隐藏 Transport/Daemon/Core，只暴露 Server | Go `http.Server`、PHP `Yar_Server` |
| Strategy | I/O 机制可替换（socket vs callback） | ASGI `receive`/`send`、Go `ResponseWriter` |
| Template Method | 读写→处理→读写流程固定 | WSGI `app(environ, start_response)` |
| Adapter | luasocket/cosocket 适配 | 现有 `transport/socket.lua` |
| Factory | URL scheme → transport | yar-c `init("tcp://addr")`、客户端 `Transport.get` |

### 5.6 7 个细节决议

| # | 决议 | 内容 |
|---|---|---|
| 1 | writer 签名 | `writer(status, headers, body)` — 参数序=HTTP 线序=回调执行序，对标 WSGI `start_response(status, headers)` |
| 2 | GET introspection | `method = "GET"` 触发，返回 JSON 方法列表 |
| 3 | addr 解析 | `parse_addr(addr)` 在 listen() 中早失败，protocol 从 URL scheme 解析一次 |
| 4 | keepalive 默认 | `false`（单连接），opts 显式开启 |
| 5 | 错误处理 | handle 返回 `true|nil,err`；YAR 协议层错误用 HTTP 200 + YAR error body（对标 PHP yar） |
| 6 | Transport/Daemon 公开性 | 保留公开，文档主推 Facade（对标 Go `http.Serve` 公开，主推 `ListenAndServe`） |
| 7 | 模块命名 | `init.lua`=Facade，`dispatcher.lua`=协议核心，`tcp.lua`/`http.lua`=Transport，`daemon.lua`=Daemon |

---

## 六、重构后：使用方式对比

### 6.1 标准 Lua TCP daemon

```lua
-- 重构前：
local TcpServer = require("yar.server.tcp")
local server = TcpServer.new(api)
server:set_options({ max_body_len = 2^20 })
server:run("0.0.0.0:8888")

-- 重构后：
local Server = require("yar.server")
local server = Server.new({ max_body_len = 2^20 }, api)
server:listen("tcp://0.0.0.0:8888")
server:loop()
```

### 6.2 标准 Lua HTTP daemon

```lua
-- 重构前：
local HttpServer = require("yar.server.http")
local server = HttpServer.new(api)
server:run("0.0.0.0:8888")

-- 重构后：
local Server = require("yar.server")
local server = Server.new(nil, api)
server:listen("http://0.0.0.0:8888")
server:loop()
```

### 6.3 OpenResty HTTP

```lua
-- 重构前（~80 行手动处理）：
local server = init.get_server()
local method = ngx.req.get_method()
if method == "GET" then
    ngx.header["Content-Type"] = "application/json"
    ngx.print(packager.pack(server:list_methods()))
    return
end
if method ~= "POST" then ... end
ngx.req.read_body()
local data = ngx.req.get_body_data()
if not data then ... end
local resp, err = server:handle_message(data)
if not resp then ... end
ngx.header["Content-Type"] = CONTENT_TYPE
ngx.print(resp)

-- 重构后（~8 行）：
local server = init.get_server()
server:handle({
    method = ngx.req.get_method(),
    data   = ngx.req.get_body_data(),
    writer = function(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do ngx.header[k] = v end
        ngx.print(body)
    end,
})
```

### 6.4 OpenResty TCP

```lua
-- 重构前（~6 行）：
local sock = ngx.req.sock()
sock:settimeout(config.keepalive_idle)
local tcp_server = init.get_tcp_server()
local ok, e = pcall(tcp_server.handle_connection, tcp_server, sock, { keepalive = true })
if not ok then ngx.log(ngx.ERR, ...) end
sock:close()

-- 重构后（~4 行）：
local sock = ngx.req.sock()
sock:settimeout(config.keepalive_idle)
local server = init.get_server()
server:handle({ socket = sock, keepalive = true })
sock:close()
```

### 6.5 copas TCP（协程并发）

```lua
-- 重构前：
local TcpServer = require("yar.server.tcp")
local tcp_server = TcpServer.new(api)
copas.addserver(socket.bind("0.0.0.0", 8888), function(client)
    tcp_server:handle_connection(client, { keepalive = true })
end)
copas.loop()

-- 重构后（listen_sock 传给 copas.addserver，listen/loop 分离的关键收益）：
local Server = require("yar.server")
local server = Server.new(nil, api)
server:listen("tcp://0.0.0.0:8888")
copas.addserver(server.listen_sock, function(client)
    server:handle({ socket = client, keepalive = true })
end)
copas.loop()
```

### 6.6 对称性验证

所有场景统一为 1 概念（Server）+ 3 方法（handle/listen/loop）：

| 场景 | API | 概念数 |
|---|---|---|
| 标准 Lua TCP daemon | `Server.new(opts, service):listen("tcp://addr"):loop()` | 1 |
| 标准 Lua HTTP daemon | `Server.new(opts, service):listen("http://addr"):loop()` | 1 |
| OpenResty HTTP | `Server.new(opts, service):handle({method=,data=,writer=})` | 1 |
| OpenResty TCP | `Server.new(opts, service):handle({socket=,keepalive=})` | 1 |
| copas TCP | `Server.new(opts, service):listen("tcp://addr")` + `copas.addserver` + `handle({socket=})` | 1 |

HTTP/TCP 完全对称——差异仅在 spec 字段或 addr scheme。

---

## 七、前后对比总结

### 7.1 架构对比

| 维度 | 重构前 | 重构后 |
|---|---|---|
| 类数 | 3（Server + HttpServer + TcpServer） | 1（Server Facade）+ 4 内部模块 |
| 职责分离 | daemon+transport 耦合在同一类 | 三层独立（Dispatcher/Transport/Daemon），Facade 隐藏 |
| transport 接口 | 无统一接口，签名不一致 | 无状态模块函数 `serve(sock, dispatcher, spec, opts)` |
| protocol 来源 | 类名（TcpServer vs HttpServer） | URL scheme（`listen("tcp://addr")`） |
| HTTP 回调注入 | 不支持（必须走 socket） | 支持（`writer(status, headers, body)` 回调） |
| 客户端/服务端对称 | 否（客户端有统一工厂，服务端没有） | 是（Facade 对标 Client） |

### 7.2 调用方心智负担对比

| 维度 | 重构前 | 重构后 |
|---|---|---|
| 调用方概念数 | 3（Server/HttpServer/TcpServer） | 1（Server） |
| 决策维度 | 2×2 矩阵（运行时 × 协议） | 1（谁当 daemon） |
| 入口方法 | `run()` / `handle_message()` / `handle_connection()` | `handle()` / `listen()` + `loop()` |
| OpenResty HTTP 代码量 | ~80 行（手动处理 HTTP 细节） | ~8 行（writer 回调） |
| 协议选择 | 选哪个类 | `require("yar.server")` + addr scheme |

### 7.3 文件结构对比

```
重构前：                          重构后：
src/yar/server/                   src/yar/server/
  init.lua   (协议核心)             init.lua       (Server Facade，重写)
  http.lua   (HttpServer 类)        dispatcher.lua (Dispatcher，新建，从 init.lua 提取)
  tcp.lua    (TcpServer 类)         tcp.lua        (TcpTransport，重写为模块函数)
                                   http.lua       (HttpTransport，重写为模块函数)
                                   daemon.lua     (Daemon，新建)
```

### 7.4 v1→v4 设计演进对比

| 维度 | v1 提案 A | v2 Facade | v3 handle+run | v4 最终 |
|---|---|---|---|---|
| 调用方概念 | 3（Server+Transport+Daemon） | 1 | 1 | 1 |
| 模式选择 | 调用方组装 | options 判断 | 方法选择 | 方法选择 |
| HTTP/TCP 对称 | 否 | 是 | 是 | 是 |
| URL 选 transport | 否（require） | 是 | 是 | 是 |
| HTTP 回调注入 | 否 | 是 | 是 | 是 |
| 跨语言理论支撑 | 无 | 无 | 部分 | 是（WSGI/ASGI/Go） |
| 设计模式 | handler 注入 | Facade | Facade | Facade+Strategy+Template+Adapter+Factory |
| I/O 抽象统一性 | 无 | 无 | 部分 | 是（I/O=回调对） |

---

## 八、设计考量与取舍

### 8.1 为什么分离 daemon 与 transport

**根因**：HttpServer/TcpServer 把 daemon（accept 循环）和 transport adapter（线协议解析）混在一个类里。这两个上下文有不同的变更驱动因素：
- daemon 的变更：并发模型（单线程/协程/多进程）、socket provider
- transport 的变更：HTTP 协议标准、YAR 帧格式

混合在一起导致：改 daemon 逻辑可能影响 transport 逻辑，反之亦然。违反单一职责。

**业界对标**：copas `handler(skt)` 是纯 transport adapter（读请求、处理、写响应），daemon 是 copas 的 accept 循环 + 协程调度。lua-eco、Skynet 同理。OpenResty 的哲学就是「nginx 做 daemon + transport，Lua 做 protocol」。业界标杆全部采用 daemon + handler 函数分离模式，lua-yar 旧架构的耦合是例外。

### 8.2 为什么 Transport 用无状态模块函数

copas 的 `handler(skt)` 是函数不是对象方法。lua-yar 的 `TcpTransport.serve(sock, dispatcher, spec, opts)` 同理——无状态模块函数（dot notation），配置通过参数传入。

**理由**：
- 无状态=可复用（同一模块可被多 daemon/server 共用）
- dot notation 符合 Lua 惯例（`math.floor`/`table.insert`）
- 配置通过参数显式传入
- 匹配 copas handler 模式

对比 Dispatcher（有状态：`self.methods`/`self.packager`/`self.options`）和 Daemon（有状态：持有 server 引用），Transport 无可变状态，不需要实例化。

### 8.3 为什么 new(opts, service) 两参数，addr 不在构造器

**层次意识**：addr 是身份属性（决定对象是什么），opts 是配置项（决定对象怎么工作），service 是业务注入。三者语义不同，不混在一个参数里。

**对标**：lua-resty-http 的 `http.new()` + `httpc:connect(host, port)` 分离模式——构造器只做初始化，I/O 操作在独立方法中。`listen(addr)` 对标 `httpc:connect()`，返回 `true|nil, err`（I/O 操作，非链式）。

**收益**：listen/loop 分离打开了 copas 集成路径——`listen()` 创建 `listen_sock`，可传给 `copas.addserver()` 实现协程并发，不需要重新实现 copas 的调度器。

### 8.4 为什么 protocol 从 addr 解析，不二次指明

旧架构要求调用方在 new 时选类名（TcpServer/HttpServer），在 handle 时传 spec.protocol——两次指定同一信息。v4 在 `listen(addr)` 时解析一次 URL scheme，handle 时读 `self.protocol`，消除冗余。

**早失败原则**：`parse_addr` 在 listen 时解析，格式错直接 `return nil, err`。对标 Go 的 `net.Listen` 在 Serve 开始时 bind 失败立即返回。

### 8.5 为什么 writer 签名是 (status, headers, body)

三参数签名。参数序对标 WSGI `start_response(status, headers)` + body 顺延，同时匹配 HTTP 线序（status line → headers → body）和回调内执行序（set status → set headers → write body）。`headers` 是表（如 `{["Content-Type"]="application/octet-stream", ["Content-Length"]=#body}`），支持自定义响应头。

**错误处理矩阵**：
- `handle_message` 内部错误 → YAR error 帧 → `writer(200, {["Content-Type"]="application/octet-stream"}, error_resp)` — YAR 协议层错误用 HTTP 200（对标 PHP yar）
- HTTP 层错误（empty body/method not allowed/body too large）→ `writer(400|405|413, {["Content-Type"]="text/plain"}, msg)`
- `handle` 返回 `true`（成功）或 `nil, err`（严重错误如 socket 断开），供调用方 log

### 8.6 为什么统一 register_service，移除 register(name, func)

v4 统一用 `register_service(service)` 单路径注册，对标 Go `rpc.Register(recv)` 和 PHP Yar `new Yar_Server($service)`。

**理由**：
- 单函数注册用 `register_service({ name = func })` 同样简洁
- Python 的双路径（register_function + register_instance）是历史包袱，Lua 无需照搬
- `register_service` 支持多次调用增量 merge，覆盖动态注册场景
- yar-c 的逐个 `register_handler` 更繁琐

**实际实现保留**：最终实现中 `register(name, func)` 仍保留（对标 yar-c `yar_server_register_handler`），但 `register_service` 是主推路径。

### 8.7 为什么 Daemon 顺序 accept，不内置并发

**现状**：Daemon.run 是顺序 accept——一个请求处理完才处理下一个。

**业界对比**：
- Go: goroutine per connection（内置并发）
- Python: ThreadingMixIn（可选线程并发）
- copas: 协程 per connection（自动并发）
- yar-c: 顺序（与 v4 一致）

**定位**：lua-yar 是协议库/SDK，不是并发框架。顺序 accept 与 yar-c 一致，定位为 dev/testing。生产并发由 OpenResty（handle 宿主模式）或 copas（handle + copas.addserver）解决。

**Lua 技术限制**：Lua 无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。唯一并发路径是协程 + 非阻塞 I/O + select 调度器（= copas），不内置——并发交给 copas / OpenResty。

### 8.8 为什么不提供 ServerTransport 工厂

客户端 `Transport.get(url)` 因 URL scheme 动态选择传输方式。服务端调用方编码时就知道是 HTTP 还是 TCP，不需要运行时动态选择。`require("yar.server.http")`/`require("yar.server.tcp")` 就是 Lua 的模块选择方式。避免过度设计。

v4 最终通过 Facade 的 `listen(addr)` 内部分发替代了显式工厂——protocol 从 addr scheme 解析，Facade 内部选择 TcpTransport 或 HttpTransport，调用方不感知。

---

## 九、数据流图

### 9.1 宿主 HTTP 回调模式（OpenResty）

```
nginx worker → content_by_lua_block
  → Server.new(opts, service):handle({method="POST", data=YAR请求字节, writer=fn})
    → HttpTransport.serve_callback(spec, dispatcher, opts)
      → dispatcher:handle_message(data)           -- 纯协议：解析→派发→渲染
        → Protocol.parse(data)              -- 解包 packager+header+body
        → methods[method](params)          -- 派发到业务方法（pcall 隔离）
        → Protocol.render(response)        -- 渲染 YAR 响应
      → writer(200, {["Content-Type"]="application/octet-stream"}, resp)  -- 回调输出
        → ngx.status=200, ngx.header[...]=..., ngx.print(resp)
  → return true
```

### 9.2 宿主 TCP socket 模式（OpenResty stream / copas）

```
nginx stream / copas accept loop
  → Server.new(opts, service):handle({socket=sock, keepalive=true})
    → TcpTransport.serve(sock, dispatcher, spec, opts)
      [keepalive 循环]
        → Framing.receive_message(sock)     -- 读 YAR 帧
           → receive_exact(sock, 90) → header
           → receive_exact(sock, body_len) → body
        → dispatcher:handle_message(data)         -- 纯协议处理
        → sock:send(resp)                   -- 写 YAR 帧
      [循环直到客户端断开或错误]
  → return nil, "connection closed"
```

### 9.3 daemon TCP 模式（标准 Lua）

```
local server = Server.new(opts, service)
  → new 时若传 service → 内部调 register_service(service) 自动收集 public 方法
server:listen("tcp://0.0.0.0:8888")
  → listen 时解析 addr → self.protocol="tcp", host="0.0.0.0", port=8888
  → Socket.bind("0.0.0.0", 8888) → self.listen_sock
server:loop()
  → Daemon.run(server)
    → 从 server.listen_sock 读已绑定的监听 socket
    [accept 循环]
      → listen_sock:accept() → client
      → server:handle({socket=client, keepalive=server.opts.keepalive})
        → TcpTransport.serve(...)           -- 同 9.2
      → client:close()
  → (无限循环)
```

### 9.4 daemon HTTP 模式（标准 Lua）

```
local server = Server.new(opts, service)
server:listen("http://0.0.0.0:8888")
  → listen 时解析 addr → self.protocol="http", host="0.0.0.0", port=8888
  → Socket.bind("0.0.0.0", 8888) → self.listen_sock
server:loop()
  → Daemon.run(server)
    [accept 循环]
      → listen_sock:accept() → client
      → server:handle({socket=client})
        → HttpTransport.serve(sock, dispatcher, opts)   -- HTTP 请求解析+响应
           → 读 HTTP 请求行/头/体
           → dispatcher:handle_message(data)
           → 写 HTTP 响应
      → client:close()
```

---

## 十、重构过程

### 10.1 设计阶段

设计过程通过 8 篇文档迭代完成，保存在 `docs/refactor/` 下：

| 顺序 | 文档 | 阶段 | 核心内容 |
|---|---|---|---|
| 1 | `server-refactor-proposal.md` | 方向 A 提案 | daemon/transport 分离，文件拆分计划，API 变更矩阵，风险评估 |
| 2 | `server-architecture-reflection.md` | 6 问深度反思 | 对称性分析，2×2 矩阵问题，DDD 限界上下文混淆，三个改进方向 |
| 3 | `refinement-v2.md` | v2 精炼 | Facade 统一入口 |
| 4 | `refinement-v3.md` | v3 精炼 | handle+run 双模式，方法即模式 |
| 5 | `deep-synthesis-v4.md` | v4 深度综合 | 跨语言 I/O 抽象研究，A+B+C 融汇，5 设计模式，7 细节决议 |
| 6 | `design-review.md` | v4 评审 | 对比 Go/Python/PHP Yar/yar-c/copas/WSGI/ASGI，6 缺口识别与修复 |
| 7 | `implementation-plan.md` | 实施计划 | 文件结构，函数签名，调用链路，数据流图，前后代码对比 |
| 8 | `daemon-concurrency.md` | 并发讨论 | Lua 并发技术限制，顺序 accept 定位，copas 集成路径 |

### 10.2 实现阶段

| 步骤 | 内容 | 涉及文件 |
|---|---|---|
| 1 | 新建 Dispatcher，从 init.lua 提取协议核心 | `src/yar/server/dispatcher.lua` |
| 2 | 重写 init.lua 为 Server Facade | `src/yar/server/init.lua` |
| 3 | 重写 tcp.lua 为 TcpTransport 模块函数 | `src/yar/server/tcp.lua` |
| 4 | 重写 http.lua 为 HttpTransport 模块函数 | `src/yar/server/http.lua` |
| 5 | 新建 Daemon 模块 | `src/yar/server/daemon.lua` |
| 6 | 更新 socket.lua 新增 bind_unix | `src/yar/transport/socket.lua` |
| 7 | 迁移测试/示例/文档到新 API | 15+ 文件（test/example/docs） |

### 10.3 验证阶段

| 验证项 | 结果 |
|---|---|
| busted 单元测试 | 377 tests pass |
| resty 集成测试 | 6 tests pass |
| E2E 互操作测试 | 50 tests pass（PHP Yar 互操作） |
| luacheck 静态检查 | 0 errors |
| API 迁移完整性 | 15+ 文件全部迁移到 `Server.new(nil, service)` API |

---

## 十一、总结

### 11.1 核心转变

从「3 个类混合 daemon+transport，2×2 决策矩阵」到「1 个 Server Facade + 3 方法（handle/listen/loop），三层分离（Dispatcher/Transport/Daemon）」。

### 11.2 理论贡献

v1-v3 是经验层面的设计迭代（看 copas/yar-c/PHP yar 怎么做，然后模仿）。v4 是原理层面的理论支撑（提炼 I/O 抽象的统一规律，用理论指导设计）：

1. **I/O 即读写回调对**——从 WSGI/ASGI/Go/socket/回调中提炼出的统一规律
2. **socket 天然满足回调对接口**——这是 HTTP 和 TCP 可统一抽象的根本原因
3. **Listen/Serve 分离**——Go 解决 daemon/hosted 二元性的经典模式，映射到 listen/loop
4. **方法即模式**——选方法即选模式，不需要 options 判断，认知负担最低

### 11.3 最终效果

**调用方心智负担最小化**——所有场景调用方只感知 1 个概念（Server），3 个方法（handle/listen/loop）。HTTP 和 TCP 完全对称，差异仅在 spec 字段或 addr scheme。daemon/transport/protocol 三层分离，Facade 隐藏内部，调用方不直接接触 Transport/Daemon。

### 11.4 设计文档索引

| 文档 | 位置 | 内容 |
|---|---|---|
| 本报告 | `docs/reports/server-refactor-report.md` | 重构全流程总结 |
| 设计过程 | `docs/refactor/` | 8 篇迭代文档 |
| 设计决策 | `docs/design/server-layer.md` | ADR #11-14, #38-39 |
| 跨层决策 | `docs/design/cross-cutting.md` | ADR #33（错误分层）, #37（鸭子类型）等 |
| 决策索引 | `docs/design/decisions.md` | 39 个 ADR 总览 |
| API 文档 | `docs/api.md` | 新 API 参考 |
| 教程 | `docs/tutorial.md` | 使用指南 |
