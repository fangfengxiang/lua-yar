# 服务端架构改造方案：Daemon 与 Transport 分离

> 方向 A：将 `HttpServer`/`TcpServer` 中混合的 daemon（accept 循环）与 transport adapter（线协议解析）拆分为独立模块。
> 状态：提案（待确认后进入 OpenSpec 流程） | 关联 ADR：#3（三层分离）、#31（跨运行时）、#32（纯协议库定位）

---

## 一、背景：对称性缺失

客户端有三层抽象：`Transport.get(url)` → `Http/Tcp`（统一 `new/open/send/close`）→ `socket.lua`。

服务端只有两层且 daemon+transport 混在一起：`HttpServer`/`TcpServer` 各自 `run=daemon + handle_connection=transport`。无统一工厂、无统一接口、daemon 与 transport 耦合。

调用方面对 2×2 决策矩阵（运行时 × 协议 = 4 种路径，每种用不同的类 + 方法）。对比客户端一行 `Client.new(url):call(method, args)`。

---

## 二、业界调研

| 项目 | daemon | transport adapter | 分离方式 |
|---|---|---|---|
| **copas** | `copas.loop()` 事件循环 | `handler(skt)` 函数 | 函数注入，完全解耦 |
| **lua-eco** | 内置 epoll 事件循环 | `eco.run(handler)` | 函数注入，完全解耦 |
| **Skynet** | `socket.start(fd, cb)` | callback 函数 | 函数注入，完全解耦 |
| **OpenResty** | nginx 自身 | nginx 自身 | 架构层面分离 |
| **lua-yar（当前）** | `HttpServer:run()` | `:handle_connection()` 方法 | **耦合在同一类** |
| **lua-yar（方案 A）** | `Daemon:run()` | `Transport.serve()` 函数 | **函数注入，完全解耦** |

**copas 核心模式**：`copas.addserver(srv, handler)` 注册 server socket + handler 函数；`copas.loop()` 跑事件循环（accept + 协程调度）；`handler(skt)` 是连接级处理函数（读请求、处理、写响应）。daemon 和 handler 完全解耦，handler 是函数不是类方法。

**lua-eco 核心模式**：`eco.run(handler)` 为每个连接创建协程，handler 在协程中同步执行（底层非阻塞）。与 copas 模式一致。

**OpenResty 哲学**：nginx 做 daemon + transport，Lua 做 protocol。`Server:handle_message` 已是这个哲学的体现——纯协议无 I/O。

**结论**：业界标杆全部采用 daemon + handler 函数分离模式。lua-yar 当前耦合是例外。

---

## 三、方案 A 设计

### 3.1 设计原则

1. **Transport 是无状态模块**（table of functions），不是实例化对象——匹配 copas handler 模式
2. **Daemon 是有状态对象**（持有 server + transport 引用），标准 Lua only
3. **Server 不变**——纯协议核心
4. **Transport.serve 是连接级 handler**——等价 copas `handler(skt)`，接收 server 参数做依赖注入

### 3.2 文件拆分

```
src/yar/server/
  init.lua       ← Server（协议核心）— 不变
  daemon.lua     ← Daemon（accept 循环）— 新增
  http.lua       ← HttpTransport — 从 HttpServer 重构
  tcp.lua        ← TcpTransport — 从 TcpServer 重构
```

命名变更：`HttpServer` → `HttpTransport`（它不是 Server，是 transport adapter）；`TcpServer` → `TcpTransport`；`run` → `Daemon:run`；`handle_connection` → `Transport.serve`。

### 3.3 接口定义

**Server（不变）**：`Server.new(service)` / `:handle_message(data)` / `:register(name, func)` / `:set_packager(name)` / `:set_options(opts)` / `:list_methods()`

**HttpTransport（无状态模块，dot notation）**：
- `HttpTransport.serve(sock, server, opts)` — 连接级 handler：读 HTTP 请求 → `server:handle_message(data)` → 写 HTTP 响应
- `HttpTransport.read_request(sock, opts)` → `data` — 读 HTTP 请求行/头/体
- `HttpTransport.write_response(sock, resp, status)` — 写 HTTP 响应

**TcpTransport（无状态模块，dot notation）**：
- `TcpTransport.serve(sock, server, opts)` — 连接级 handler：读 YAR 帧 → `server:handle_message(data)` → 写 YAR 帧（支持 keepalive 循环）
- `TcpTransport.read_request(sock, opts)` → `data` — `Framing.receive_message(sock)`
- `TcpTransport.write_response(sock, resp)` — `sock:send(resp)`

**Daemon（有状态对象，colon notation）**：
- `Daemon.new(server, transport, opts)` → Daemon — 绑定 server + transport 组合
- `Daemon:run(addr)` — bind + accept 循环，每连接调 `transport.serve(client, server, opts)`
- `Daemon.run(server, transport, addr, opts)` — 静态便捷方法（一行启动）

### 3.4 改造后架构全景图

```
         标准 Lua                         OpenResty / copas / eco / skynet
            │                                        │
            ▼                                        ▼
  ┌──────────────────┐              ┌──────────────────────────────┐
  │  Daemon          │              │  外部 daemon                  │
  │  run(addr)       │              │  (nginx / copas.loop /         │
  │  bind + accept   │              │   eco.run / skynet)            │
  │  → serve()       │              │  → serve()                    │
  └────────┬─────────┘              └──────────────┬───────────────┘
           └──────────────┬───────────────────────┘
                          ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  Transport 层（无状态模块，连接级 handler）                     │
  │  HttpTransport.serve(sock, server, opts)  TcpTransport.serve() │
  │  ┌──────────────────────┐       ┌──────────────────────────┐   │
  │  │ read_request(sock)   │       │ read_request(sock)        │   │
  │  │  HTTP 请求行/头/体    │       │  Framing.receive_message  │   │
  │  │  → data (YAR body)   │       │  → data (YAR msg)         │   │
  │  ├──────────────────────┤       ├──────────────────────────┤   │
  │  │ server:handle_message│       │ server:handle_message     │   │
  │  │  (data) → resp       │       │  (data) → resp            │   │
  │  ├──────────────────────┤       ├──────────────────────────┤   │
  │  │ write_response(sock) │       │ write_response(sock)      │   │
  │  │  HTTP 200 + resp     │       │  YAR 帧 (keepalive 循环)  │   │
  │  └──────────────────────┘       └──────────────────────────┘   │
  └─────────────────────────────────┬───────────────────────────────┘
                                    ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  Server（协议核心，不变）                                        │
  │  handle_message(data) → resp                                   │
  │  纯协议，无 I/O，reentrant                                      │
  └─────────────────────────────────────────────────────────────────┘
```

### 3.5 对称性对比

| 维度 | 客户端 | 服务端（改造后） |
|---|---|---|
| 协议核心 | `Client:call()` | `Server:handle_message()` |
| 传输适配器 | `Http`/`Tcp`（`new/open/send/close`） | `HttpTransport`/`TcpTransport`（`serve/read/write`） |
| 网络抽象 | `transport/socket.lua` | `transport/socket.lua`（共用） |
| daemon | 无（客户端不 accept） | `Daemon:run(addr)`（标准 Lua only） |

---

## 四、数据流图

### 4.1 标准 Lua HTTP

```
Client ──HTTP POST──→ Daemon.accept → HttpTransport.serve
  → read_request: sock:receive("*l") 请求行, headers, sock:receive(N) body
  → server:handle_message(data) → parse + dispatch + render → resp
  → write_response: sock:send(HTTP 200 + resp)
  → Daemon.close → loop
```

### 4.2 OpenResty HTTP（最轻量路径）

```
Client ──HTTP POST──→ nginx(daemon + HTTP transport)
  → ngx.req.get_body_data() → data
  → content_by_lua: server:handle_message(data) → resp
  → ngx.print(resp) → Client
```

OpenResty HTTP 完全不经过 Transport/Daemon 层——nginx 已做 daemon + transport，Lua 只做 protocol。

### 4.3 OpenResty TCP

```
Client ──TCP──→ nginx stream(daemon) → ngx.req.sock() → cosocket
  → content_by_lua: TcpTransport.serve(sock, server, opts)
  → read_request: Framing.receive_message(sock) → data
  → server:handle_message(data) → resp
  → write_response: sock:send(resp)
  → (keepalive: loop)
```

### 4.4 copas TCP

```
Client ──TCP──→ copas.loop(daemon) → copas.addserver handler
  → TcpTransport.serve(client, server, opts)
  → read_request → server:handle_message → write_response
  → (keepalive: loop)
  → copas autoclose: client:close()
```

---

## 五、泳道图

### 5.1 标准 Lua（Daemon + Transport + Server 三泳道）

```
┌─ Daemon ──────────────┬─ Transport ──────────────┬─ Server ───────────────┐
│                      │                          │                        │
│ bind(addr)           │                          │                        │
│ while true:          │                          │                        │
│   client=accept()    │                          │                        │
│   ─────────────────→│ serve(client, server,opts)│                        │
│   settimeout(t)      │                          │                        │
│                      │ read_request(client)     │                        │
│                      │   receive("*l") × N      │                        │
│                      │   receive(N) body        │                        │
│                      │   → data                 │                        │
│                      │ ────────────────────────→│ handle_message(data)   │
│                      │                          │   parse + dispatch     │
│                      │                          │   + render → resp      │
│                      │ ←────────────────────────│ return resp            │
│                      │                          │                        │
│                      │ write_response(client)   │                        │
│                      │   send(HTTP resp)        │                        │
│ ←───────────────────│ return                   │                        │
│   client:close()    │                          │                        │
│   loop              │                          │                        │
└──────────────────────┴──────────────────────────┴────────────────────────┘
```

### 5.2 OpenResty HTTP（nginx + Server 两泳道，无 Transport/Daemon）

```
┌─ nginx ───────────────┬─ Server ─────────────────────────────────────────┐
│                      │                                                  │
│ accept + HTTP parse │                                                  │
│ read_body → data    │                                                  │
│ ───────────────────→│ handle_message(data)                             │
│                      │   parse + dispatch + render → resp              │
│ ←───────────────────│ return resp                                      │
│                      │                                                  │
│ ngx.print(resp)     │                                                  │
│ → Client            │                                                  │
└──────────────────────┴──────────────────────────────────────────────────┘
```

### 5.3 OpenResty TCP（nginx + Transport + Server 三泳道，无 Daemon）

```
┌─ nginx stream ────────┬─ Transport ──────────────┬─ Server ───────────────┐
│                      │                          │                        │
│ accept → cosocket    │                          │                        │
│ sock=req.sock()      │                          │                        │
│ ───────────────────→│ serve(sock, server,opts) │                        │
│                      │                          │                        │
│                      │ read_request(sock)       │                        │
│                      │   Framing.recv_msg       │                        │
│                      │   → data                 │                        │
│                      │ ────────────────────────→│ handle_message(data)  │
│                      │                          │   → resp               │
│                      │ ←────────────────────────│ return resp            │
│                      │                          │                        │
│                      │ write_response(sock)     │                        │
│                      │   send(resp)             │                        │
│                      │   (keepalive: loop)      │                        │
│ ←───────────────────│ return                   │                        │
│ sock:close()        │                          │                        │
└──────────────────────┴──────────────────────────┴────────────────────────┘
```

---

## 六、方案对比与取舍

### 6.1 三方案对比

| 维度 | A：全分离 | B：统一签名 | C：Facade+新模块 |
|---|---|---|---|
| daemon/transport | 完全分离 | 仍耦合 | 新模块分离，旧 facade 耦合 |
| 文件变更 | 4 改/新增 | 2 改签名 | 4 新增+2 保留 |
| API 兼容性 | Breaking | 兼容 | 兼容 |
| 调用方心智 | 最低（对称三层） | 中（仍 2×2 矩阵） | 中（两套 API 并存） |
| 业界对标 | copas/eco/skynet | 无 | 过渡方案 |
| 维护成本 | 低 | 低 | 高（两套 API） |

### 6.2 选方案 A 的理由

1. **对称性**：服务端具备 daemon/transport/protocol 三层，与客户端对等
2. **可复用**：`TcpTransport.serve` 可被任意 daemon 调用，不再绑定 `run()`
3. **语义准确**：Transport ≠ Daemon ≠ Server，命名反映职责
4. **业界对齐**：与 copas `handler(skt)` 模式一致
5. **项目 pre-1.0**：应该 clean break，不背技术债

### 6.3 为什么 Transport 用无状态模块

copas 的 `handler(skt)` 是函数不是对象方法。lua-yar 的 `Transport.serve(sock, server, opts)` 同理——无状态模块函数（dot notation），配置通过 opts 传入。

理由：无状态=可复用（同一模块可被多 daemon/server 共用）；dot notation 符合 Lua 惯例（`math.floor`/`table.insert`）；配置通过 opts 显式传入；匹配 copas handler 模式。

对比 Server（有状态：`self.methods`/`self.packager`/`self.options`）和 Daemon（有状态：绑定 server+transport），Transport 无可变状态，不需要实例化。

### 6.4 为什么不提供 ServerTransport 工厂

客户端 `Transport.get(url)` 因 URL scheme 动态选择传输方式。服务端调用方编码时就知道是 HTTP 还是 TCP，不需要运行时动态选择。`require("yar.server.http")`/`require("yar.server.tcp")` 就是 Lua 的模块选择方式。避免过度设计。

---

## 七、改造影响范围

### 7.1 文件变更清单

| 文件 | 操作 | 变更 |
|---|---|---|
| `src/yar/server/init.lua` | 不变 | Server 协议核心 |
| `src/yar/server/http.lua` | 重构 | HttpServer → HttpTransport，移除 run/new/register/set_*，保留 serve/read_request/write_response |
| `src/yar/server/tcp.lua` | 重构 | TcpServer → TcpTransport，同上 |
| `src/yar/server/daemon.lua` | 新增 | Daemon.new/run + Daemon.run 静态便捷方法 |
| `src/yar/init.lua` | 更新 | lazy 导出 http_server/tcp_server → http_transport/tcp_transport/daemon |
| `example/server_http.lua` | 更新 | `HttpServer.new(api):run(addr)` → `Daemon.run(Server.new(api), HttpTransport, addr)` |
| `example/server_tcp.lua` | 更新 | 同上用 TcpTransport |
| `example/server_coroutine.lua` | 更新 | `HttpServer.handle_connection` → `HttpTransport.serve` |
| `example/server_copas.lua` | 更新 | `TcpServer.handle_connection` → `TcpTransport.serve` |
| `example/server_luaeco.lua` | 更新 | 同上 |
| `example/server_skynet.lua` | 更新 | 同上 |
| `example/server_openresty.lua` | 更新 | `TcpServer.handle_connection` → `TcpTransport.serve` |
| `example/resty_yar_init.lua` | 更新 | 移除 TcpServer 创建，只保留 Server |
| `example/resty_yar_tcp_server.lua` | 更新 | `tcp_server:handle_connection` → `TcpTransport.serve` |
| `example/resty_yar_http_server.lua` | 不变 | 已直接用 `server:handle_message(data)` |
| `spec/http_server_spec.lua` | 重构 | → `http_transport_spec.lua`，测试 `HttpTransport.serve` |
| `spec/tcp_server_spec.lua` | 重构 | → `tcp_transport_spec.lua`，测试 `TcpTransport.serve` |
| `spec/server_spec.lua` | 不变 | Server 核心测试不变 |
| `docs/api.md` | 更新 | API 文档 |
| `docs/design/server-layer.md` | 新增 ADR | 记录 daemon/transport 分离决策 |
| `docs/design/decisions.md` | 更新索引 | 同步新 ADR |

### 7.2 API 变更对照

| 场景 | 旧 API | 新 API |
|---|---|---|
| 标准 Lua HTTP | `HttpServer.new(api):run(addr)` | `Daemon.run(Server.new(api), HttpTransport, addr)` |
| 标准 Lua TCP | `TcpServer.new(api):run(addr)` | `Daemon.run(Server.new(api), TcpTransport, addr)` |
| OpenResty HTTP | `server:handle_message(data)` | 不变 |
| OpenResty TCP | `tcp_server:handle_connection(sock)` | `TcpTransport.serve(sock, server, {keepalive=true})` |
| copas TCP | `tcp_server:handle_connection(client)` | `TcpTransport.serve(client, server, {keepalive=true})` |
| 协程 HTTP | `http_server:handle_connection(sock)` | `HttpTransport.serve(sock, server, opts)` |

### 7.3 调用方心智负担对比

**改造前（2×2 矩阵）**：调用方需判断「运行时 × 协议」→ 4 种路径 → 不同类 + 不同方法。

**改造后（分层选择）**：调用方只需判断「谁当 daemon」：
- 有外部 daemon（OpenResty/copas/eco/skynet）→ 直接调 `Transport.serve(sock, server, opts)`
- 无外部 daemon（标准 Lua）→ `Daemon.run(server, transport, addr)`

协议选择从「选哪个类」变成「require 哪个模块」——Lua 原生方式，无额外认知负担。

---

## 八、风险评估

| 风险 | 等级 | 缓解 |
|---|---|---|
| Breaking change 影响现有用户 | 中 | 项目 pre-1.0，用户量小；CHANGELOG 明确标注；提供迁移指南 |
| HttpTransport 丢失 HttpServer 的 set_options 等 | 低 | 这些方法委托给 Server，Server 已有；Transport 无状态不需要 |
| Daemon.run 静态方法 vs 实例方法混淆 | 低 | 静态 `Daemon.run(a,b,c)` 创建并启动；实例 `daemon:run(addr)` 只启动。命名不同避免混淆 |
| GET introspection 需要 packager | 低 | `HttpTransport.serve` 内用 `server.packager` 或 `Packager.get(Packager.JSON)` |
| 测试重构量大 | 中 | spec 文件机械重构（改类名+方法名），逻辑不变；可并行执行 |

---

## 九、迁移路径

建议通过 OpenSpec 流程执行：

1. **提案**：创建 `openspec/changes/server-daemon-transport-split/` 提案
2. **实现**：按文件变更清单逐个重构
   - 先新增 `daemon.lua`（不影响现有代码）
   - 再重构 `http.lua`/`tcp.lua`（同步更新 spec）
   - 更新 `init.lua` 导出
   - 更新 example/ 文件
3. **测试**：全量 `busted spec/` + 互操作测试
4. **文档**：更新 `docs/api.md` + 新增 ADR 到 `docs/design/server-layer.md`
5. **归档**：OpenSpec archive + git commit

---

## 十、总结

方案 A 将 daemon 与 transport 分离，使服务端具备与客户端对等的三层抽象（daemon/transport/protocol）。设计对标 copas `handler(skt)` 模式——Transport 是无状态模块函数，Daemon 是有状态 accept 循环对象，Server 是不变的协议核心。

**核心收益**：松耦合（三层独立）、可复用（Transport.serve 可被任意 daemon 调用）、语义化（命名反映职责）、对称化（与客户端对等）、降低心智负担（从 2×2 矩阵变为分层选择）。

**核心代价**：Breaking change（pre-1.0 可接受）、标准 Lua 入口略 verbose（`Daemon.run` 静态便捷方法缓解）、重构工作量中等（机械性为主）。
