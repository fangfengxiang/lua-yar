# Daemon 并发机制分析与业界对比

> 审查对象：v4 设计 `daemon.lua` Daemon.run 的并发模型
> 对标：copas、lua-eco、Skynet、OpenResty、Go net/http、Python、PHP-FPM、yar-c
> 核心问题：开了多少协程？调度机制是什么？与业界方案差距多大？

---

## 一、v4 Daemon 并发模型

### 1.1 当前设计

v4 的 `Daemon.run(server)` 是**顺序 accept**——零协程，一个连接处理完才 accept 下一个：

```
Daemon.run(server)
  │
  ├── Socket.bind(host, port) → listen_sock     # 一次 bind
  │
  └── while true do                              # accept 循环
        │
        ├── client = listen_sock:accept()        # 阻塞等待新连接
        │
        ├── client:settimeout(timeout)           # 设超时
        │
        ├── pcall(server.handle, server, {       # 同步处理（无协程）
        │     socket = client,
        │     keepalive = opts.keepalive
        │   })
        │   │
        │   ├── TcpTransport.serve(...)          # 读帧 → handle_message → 写帧
        │   │   └── while keepalive:              # keepalive 循环（仍同步）
        │   │       receive_message → handle_message → send
        │   │
        │   └── HttpTransport.serve(...)         # 读 HTTP → handle_message → 写 HTTP
        │
        └── client:close()                       # 关连接，回到 accept
      end
```

### 1.2 协程数量

| 模式 | 入口 | 协程数 | 调度器 | 说明 |
|---|---|---|---|---|
| **daemon 模式** (`loop()`) | `Daemon.run` | **0** | 无 | 顺序 accept，一个连接阻塞所有 |
| **宿主模式** (`handle()`) | OpenResty / copas / lua-eco / Skynet | **N**（每连接 1 个） | 宿主运行时 | 并发由宿主管理，lua-yar 不参与调度 |

**关键结论**：daemon 模式零协程，是纯粹的 `while true: accept → handle → close` 循环。并发能力完全依赖宿主模式注入。

### 1.3 设计意图

这不是缺陷，是有意为之的分工：

- **lua-yar 定位**：纯协议库 / SDK，不是并发框架
- **daemon 模式**：dev/testing 用途，对标 yar-c（也是顺序）
- **生产并发**：由宿主环境解决——OpenResty（handle 回调模式）或 copas（handle + copas.addserver）

---

## 二、业界 Lua 并发方案对比

### 2.1 方案总览

| 方案 | 并发模型 | 协程数 | I/O 模型 | 调度机制 | 阻塞行为 |
|---|---|---|---|---|---|
| **v4 daemon** | 顺序 | 0 | 阻塞 luasocket | 无 | 一连接阻塞全部 |
| **copas** | 协程 per conn | N | 非阻塞 luasocket | `socket.select` + yield/resume | 非阻塞 |
| **lua-eco** | 协程 per conn | N | epoll | 事件驱动 + yield/resume | 非阻塞 |
| **Skynet** | Actor + 协程 | N（per actor） | epoll | Skynet 调度器 | 非阻塞 |
| **OpenResty** | Worker + cosocket | N（per worker） | nginx 事件循环 | nginx 调度 | 非阻塞 |
| **Go net/http** | goroutine per conn | N | 非阻塞 net | Go runtime scheduler | 非阻塞 |
| **Python** | 顺序（或线程） | 0（或 N 线程） | 阻塞 socket | OS 线程 | 一连接阻塞（或线程隔离） |
| **PHP Yar** | PHP-FPM 进程 | 0（per process） | 阻塞 | OS 进程 | 进程隔离 |
| **yar-c** | 顺序 | 0 | 阻塞 | 无 | 一连接阻塞全部 |

### 2.2 各方案机制详解

#### copas — 协程调度器

copas 是 luasocket 之上的协程调度器，核心机制：

```
copas.loop()
  │
  └── while true:
        │
        ├── socket.select(read_set, write_set)     # 检测就绪 socket
        │
        ├── listen_sock 就绪 → accept → 创建协程
        │   └── coroutine.create(handler)
        │       └── copas.wrap(client)             # 包装为协程安全 socket
        │
        └── client 就绪 → resume 对应协程
            │
            └── 协程内 I/O 遇 "timeout" → yield("read"/"write")
                → 回到 select 循环
                → socket 就绪 → resume → 继续 I/O
```

**协程数**：每连接 1 个协程，N 个并发连接 = N 个协程。
**调度核心**：`socket.select` 单线程事件循环 + yield/resume 协作式调度。
**I/O 包装**：copas 将 luasocket 包装为非阻塞——`settimeout(0)` + yield on timeout。

#### lua-eco — epoll 协程运行时

lua-eco 基于 Lua 5.4 + epoll，核心机制：

```
eco 事件循环（C 层 epoll）
  │
  ├── srv:accept() → 阻塞当前协程，epoll 等待
  │   └── 新连接 → eco.run(handler)              # 创建新协程
  │       └── handler 内 I/O:
  │           ├── eco_sock:recv() → epoll 等待
  │           │   └── 数据就绪 → 恢复协程
  │           └── eco_sock:send() → epoll 等待
  │               └── 写就绪 → 恢复协程
  │
  └── 所有协程 yield 时 → epoll_wait → 就绪事件 → resume 对应协程
```

**协程数**：每连接 1 个协程，N 个并发连接 = N 个协程。
**调度核心**：C 层 `epoll_wait` 事件驱动，比 copas 的 `socket.select` 更高效（O(1) vs O(n)）。
**与 copas 的区别**：lua-eco 在 C 层用 epoll，copas 在 Lua 层用 `socket.select`（底层也是 select/poll）。

#### Skynet — Actor 模型 + 协程

Skynet 是 Actor 模型框架，每个服务是一个 Actor：

```
Skynet 调度器
  │
  ├── Actor A（Yar Server）
  │   ├── socket.listen → listen_fd
  │   ├── socket.start(listen_fd, callback)
  │   │   └── 新连接 fd → callback(fd, addr)
  │   │       └── Skynet 为 callback 创建协程
  │   │           └── handler 内 I/O:
  │   │               ├── socket.read(fd) → yield → Skynet 调度
  │   │               └── socket.write(fd, data) → yield → Skynet 调度
  │   │
  │   └── Actor 内多协程并发（同一 Actor 内协程共享状态）
  │
  └── Actor B, C, ...（其他服务，消息传递通信）
```

**协程数**：每连接 1 个协程（在 Actor 内），N 个连接 = N 个协程。
**调度核心**：Skynet 内部调度器（C 层），Actor 间消息传递，Actor 内协程调度。
**特点**：Actor 间隔离，Actor 内共享；适合复杂服务端架构。

#### OpenResty — Worker + cosocket

OpenResty 利用 nginx worker 进程 + cosocket：

```
nginx master
  ├── worker 1（独立进程）
  │   ├── nginx 事件循环（epoll）
  │   │   ├── 请求 1 → content_by_lua
  │   │   │   └── Server:handle({method=, data=, writer=})
  │   │   │       └── ngx.socket cosocket（非阻塞，连接池复用）
  │   │   │
  │   │   ├── 请求 2 → content_by_lua（同 worker 内协程并发）
  │   │   │   └── Server:handle(...)
  │   │   │
  │   │   └── ... 请求 N
  │   │
  │   └── 每 worker 独立 Lua VM，独立连接池
  │
  ├── worker 2, 3, ...（多进程，进程级隔离）
  │
  └── master（管理 worker，不处理请求）
```

**协程数**：每请求 1 个协程（per worker），N 个并发请求 = N 个协程。
**调度核心**：nginx 事件循环（epoll），cosocket 非阻塞 I/O。
**特点**：多进程 + 每进程内协程并发；cosocket 与 luasocket API 兼容，无需 adapter。

---

## 三、v4 与各方案的协程调度对比

### 3.1 协程数对比

```
                    ┌─────────────────────────────────────────┐
                    │       并发连接数 →                      │
                    │   1       5       10      50     100  │
                    ├─────────────────────────────────────────┤
  v4 daemon         │  0协程   0协程   0协程   0协程  0协程  │ ← 顺序，不并发
  copas             │  1协程   5协程   10协程  50协程 100协程 │ ← 协程 per conn
  lua-eco           │  1协程   5协程   10协程  50协程 100协程 │ ← 协程 per conn
  Skynet            │  1协程   5协程   10协程  50协程 100协程 │ ← 协程 per conn
  OpenResty/worker  │  1协程   5协程   10协程  50协程 100协程 │ ← 协程 per request
  Go                │  1 grtn  5 grtn  10 grtn 50 grtn 100grtn│ ← goroutine per conn
  Python(顺序)      │  0协程   0协程   0协程   0协程  0协程  │ ← 顺序（同 v4）
  PHP-FPM           │  1进程   5进程   10进程  50进程 100进程 │ ← 进程 per request
                    └─────────────────────────────────────────┘
```

### 3.2 调度机制对比

| 维度 | v4 daemon | copas | lua-eco | OpenResty | Go |
|---|---|---|---|---|---|
| **事件检测** | 无（阻塞 accept） | `socket.select` | C 层 epoll | nginx epoll | Go runtime netpoller |
| **复杂度** | N/A | O(n) per select | O(1) epoll | O(1) epoll | O(1) epoll |
| **协程调度** | 无 | Lua 层 yield/resume | C 层 yield/resume | nginx 内部调度 | Go runtime scheduler |
| **I/O 模型** | 阻塞 | 非阻塞 + yield | 非阻塞 + yield | cosocket 非阻塞 | 非阻塞 net |
| **多核利用** | 单核 | 单核 | 单核 | 多进程多核 | 多核（GOMAXPROCS） |
| **GC 压力** | 低 | 中（协程栈） | 中 | 低（nginx 管理） | 低（goroutine 栈小） |

### 3.3 关键差异分析

**v4 daemon vs copas**：
- copas 只比 v4 daemon 多了一层协程调度——`socket.select` + yield/resume
- 核心代码差异：accept 后 `coroutine.create` vs 直接 `pcall(handle)`
- copas 的 `wrap_socket` 把阻塞 I/O 变成 yield on timeout
- v4 的 `handle_message` 本身无 I/O、无 yield，可直接被 copas 调度

**v4 daemon vs lua-eco**：
- lua-eco 在 C 层用 epoll，比 copas 的 Lua 层 select 更高效
- 但原理相同：协程 per conn + 非阻塞 I/O + yield/resume
- lua-eco 需要 adapter 适配 socket API（recv vs receive）

**v4 daemon vs OpenResty**：
- OpenResty 是多进程 + 每 worker 内协程并发
- v4 的 `handle({method=, data=, writer=})` 回调模式天然适配 OpenResty
- cosocket 与 luasocket API 兼容，无需 adapter

**v4 daemon vs Go**：
- Go 的 goroutine 是语言级并发，runtime scheduler 自动调度
- Go 的 `net/http` 每个 accept 直接 `go handler(conn)`，内置并发
- v4 daemon 如果要协程并发，需要宿主提供调度器

---

## 四、v4 的并发架构图

### 4.1 整体架构：两种模式

```
                    ┌─────────────────────────────────────────────┐
                    │             lua-yar Server                   │
                    │                                             │
                    │   Dispatcher（handle_message）             │
                    │   ↑ 纯协议，无 I/O，无 yield，reentrant     │
                    │   ↑ 可被任意协程/进程直接调用                │
                    │   │                                         │
                    │   ├── handle(spec)  ← 宿主模式入口           │
                    │   │   ├── spec.socket → Transport.serve      │
                    │   │   └── spec.writer → serve_callback      │
                    │   │                                         │
                    │   └── loop()        ← daemon 模式入口       │
                    │       └── Daemon.run(server)                 │
                    ──────────────┬──────────────┬───────────────┘
                                   │              │
                    ┌──────────────┘              └──────────────┐
                    │                                            │
              宿主模式（并发）                              daemon 模式（顺序）
                    │                                            │
     ┌──────────────┼──────────────┐                    ┌───────┴───────┐
     │              │              │                    │               │
  OpenResty       copas        lua-eco/Skynet        Daemon.run     0 协程
  N 协程/worker  N 协程       N 协程                顺序 accept     阻塞
  nginx 调度      select 调度  epoll/actor 调度      while true:
                                                     accept → handle → close
```

### 4.2 daemon 模式时序图（顺序）

```
时间轴 ──────────────────────────────────────────────────────────────→

listen_sock.accept() ──┐
                        │ conn1 到达
                  ┌─────┴─────┐
                  │ accept()  │ → client1
                  └─────┬─────┘
                        │
                  ┌─────┴─────┐
                  │ handle()  │ ← 同步处理 conn1
                  │ (pcall)   │   读帧 → handle_message → 写帧
                  └─────┬─────┘
                        │
                  ┌─────┴─────┐
                  │ close()   │
                  └─────┬─────┘
                        │
listen_sock.accept() ──┤ ← conn1 处理完才能 accept conn2
                        │ conn2 到达
                  ┌─────┴─────┐
                  │ accept()  │ → client2
                  └─────┬─────┘
                        │
                  ┌─────┴─────┐
                  │ handle()  │ ← 同步处理 conn2
                  └─────┬─────┘
                        │
                  ┌─────┴─────┐
                  │ close()   │
                  └─────┬─────┘
                        │
                        ...

问题：conn1 处理期间（含 I/O 等待），conn2 ~ connN 全部阻塞。
```

### 4.3 copas 模式时序图（协程并发）

```
时间轴 ──────────────────────────────────────────────────────────────→

copas.loop()
  │
  ├── select(read, write) ──────────────────────────────────────┐
  │     ↑                                                      │
  │     │ listen 就绪                                          │
  │     │                                                      │
  ├── accept() → client1                                       │
  │     └── coroutine.create(handler1)                        │
  │           └── resume(handler1)                            │
  │                 └── handle_connection(wrap(client1))       │
  │                       └── receive() → timeout → yield("read")
  │                                          ↓                 │
  ├── select(read, write) ←──────────────────┘                 │
  │     ↑                                                      │
  │     │ listen 就绪 + client1 就绪                           │
  │     │                                                      │
  ├── accept() → client2                                       │
  │     └── coroutine.create(handler2)                        │
  │           └── resume(handler2)                            │
  │                 └── handle_connection(wrap(client2))       │
  │                       └── receive() → timeout → yield("read")
  │                                          ↓                 │
  ├── select(read, write) ←──────────────────┘                 │
  │     ↑                                                      │
  │     │ client1 就绪                                         │
  │     │                                                      │
  ├── resume(handler1)                                         │
  │     └── receive() → 数据到达 → 返回                        │
  │         └── handle_message(data) → send() → ...           │
  │                                                              │
  └── ... 循环调度所有协程，conn1 和 conn2 并发处理

关键：conn1 I/O 等待期间（yield），conn2 可以被调度执行。
     N 个连接 = N 个协程，单线程内协作式并发。
```

### 4.4 OpenResty 模式时序图（多进程 + cosocket）

```
nginx master
  │
  ├── worker 1（独立 Lua VM）
  │   ├── nginx 事件循环（epoll）
  │   │
  │   ├── 请求 1 到达 → content_by_lua
  │   │   └── 协程 1: Server:handle({method=, data=, writer=})
  │   │       └── handle_message(data) → writer(resp)
  │   │           （cosocket 非阻塞，nginx 自动调度）
  │   │
  │   ├── 请求 2 到达 → content_by_lua
  │   │   └── 协程 2: Server:handle({...})
  │   │       （与协程 1 并发，nginx 事件循环调度）
  │   │
  │   └── ... 请求 N
  │
  ├── worker 2（独立 Lua VM，进程级隔离）
  │   └── ... 独立处理请求
  │
  └── worker 3, ...

关键：每 worker 独立 Lua VM，worker 间进程隔离。
     worker 内协程并发，cosocket 非阻塞 I/O。
     lua-yar 的 handle({writer=}) 回调模式天然适配——无需 socket adapter。
```

---

## 五、v4 daemon 的并发升级路径

v4 daemon 的顺序模型不是终点，而是分层设计的起点。升级路径清晰：

### 5.1 路径一：copas 集成（最小改动）

```lua
-- 用户代码：daemon 模式 + copas 并发
local copas = require("copas")
local Server = require("yar.server")

local server = Server.new("tcp://0.0.0.0:8888", { keepalive = true }, api)

-- 方式一：用 copas.addserver 替代 loop()
local srv = copas.wrap(server.listen_sock)  -- 需要 Facade 暴露 listen_sock
copas.addserver(srv, function(client)
    server:handle({ socket = client, keepalive = true })
    client:close()
end)
copas.loop()
```

**改动量**：零库代码改动，用户侧 ~5 行。
**前提**：`handle({socket=})` 接受 copas 包装的 socket（API 兼容）。

### 5.2 路径二：内置协程调度（未来可选）

如果未来要在 daemon 模式内置协程并发（不依赖外部 copas），核心改动在 `Daemon.run`：

```
当前（顺序）：
  while true:
    client = listen_sock:accept()
    pcall(server.handle, server, {socket=client})
    client:close()

升级（协程）：
  while true:
    client = listen_sock:accept()
    coroutine.wrap(function()
      pcall(server.handle, server, {socket=wrap(client)})
      client:close()
    end)()
  -- + socket.select 调度循环（~70 行，参考 example/server_coroutine.lua）
```

**改动量**：daemon.lua ~70 行新增（调度循环），Transport 层零改动。
**代价**：增加复杂度，与 copas 功能重叠。
**建议**：不内置。保持 daemon 顺序模型，并发交给 copas/宿主。

### 5.3 路径三：OpenResty 宿主（零改动）

```lua
-- OpenResty content_by_lua
local Server = require("yar.server")
local server = Server.new(nil, nil, api)  -- 无 addr = 宿主模式
server:handle({
    method = ngx.req.get_method(),
    data   = ngx.req.get_body_data(),
    writer = function(resp, ct, st)
        ngx.status = st
        ngx.header["Content-Type"] = ct
        ngx.print(resp)
    end,
})
```

**改动量**：零库代码改动，用户侧 ~8 行。
**并发**：nginx worker + cosocket 自动提供。

---

## 六、结论

### 6.1 v4 daemon 并发模型总结

| 维度 | 值 |
|---|---|
| **协程数** | 0（daemon 模式） |
| **调度器** | 无 |
| **并发能力** | 无（顺序，一连接阻塞全部） |
| **定位** | dev/testing |
| **业界对标** | yar-c（同样顺序）、Python 默认（顺序） |

### 6.2 设计合理性评估

v4 的"daemon 顺序 + 宿主并发"分工是合理的：

1. **协议层无 I/O**：`Dispatcher:handle_message(data)` 是纯函数，可被任意协程/进程直接调用。这是并发的基础——协议核心不阻塞，并发只需在 I/O 层解决。

2. **I/O 抽象正确**：`handle({socket=})` 接受任意具备 `receive/send/close` 的 socket 对象。copas 包装的 socket、lua-eco adapter 包装的 socket、OpenResty cosocket 都直接兼容。

3. **不重复造轮子**：copas 已是成熟的 Lua 协程调度器，lua-eco 已是成熟的 epoll 运行时。lua-yar 内置协程调度会与它们功能重叠。

4. **业界先例**：Go 的 `net/http` 内置并发是因为 goroutine 是语言级特性。Python 的 `HTTPServer` 默认也是顺序，并发靠 `ThreadingMixIn` 混入。lua-yar 的顺序 daemon + 宿主并发与 Python 的模式一致。

### 6.3 唯一需要改进的点（✅ 已完成）

`loop()` 文档已显式标注（implementation-plan.md §2.2 + §2.5、deep-synthesis-v4.md §4.1 + §5.1）：

> **`loop()` is sequential accept, for dev/testing only.**
> One slow request blocks all connections.
> Lua 无内置并发原语：无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。
> 唯一并发路径：协程 + 非阻塞 I/O + select 调度器（= copas）。
> For production concurrency, use:
> - OpenResty: `handle({method=, data=, writer=})` callback mode
> - copas: `handle({socket=})` + `copas.addserver` + `copas.loop()`
> - lua-eco / Skynet: `handle({socket=})` + host coroutine scheduling

---

## 七、附录：各方案完整对比矩阵

| 维度 | v4 daemon | copas | lua-eco | Skynet | OpenResty | Go | Python | PHP-FPM | yar-c |
|---|---|---|---|---|---|---|---|---|---|
| **并发模型** | 顺序 | 协程 per conn | 协程 per conn | Actor + 协程 | Worker + cosocket | goroutine per conn | 顺序/线程 | 进程 per req | 顺序 |
| **协程/线程数** | 0 | N | N | N | N/worker | N | 0 or N | 0/process | 0 |
| **事件检测** | 无 | select | epoll | epoll | epoll | netpoller | 无 | 无 | 无 |
| **多核** | 单核 | 单核 | 单核 | 多核(Actor) | 多进程 | 多核 | 单核/多线程 | 多进程 | 单核 |
| **I/O 阻塞** | 是 | 否 | 否 | 否 | 否 | 否 | 是 | 是 | 是 |
| **需要 adapter** | N/A | 否 | 是 | 是 | 否 | N/A | N/A | N/A | N/A |
| **生产可用** | 否 | 是 | 是 | 是 | 是 | 是 | 可选 | 是 | 否 |
| **lua-yar 兼容** | 原生 | handle({socket=}) | handle({socket=}) | handle({socket=}) | handle({writer=}) | N/A | N/A | N/A | N/A |
