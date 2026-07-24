# Server 架构对称性反思：6 问深度分析

> 范围：`server/init.lua`、`server/http.lua`、`server/tcp.lua` 的领域定义、职责边界、对称性问题
> 对标：客户端 `transport/transport.lua` + `transport/http.lua` + `transport/tcp.lua` + `transport/socket.lua`
> 参考业界：lua-resty-http、copas、OpenResty 生态工程实践

---

## 一、当前架构全景图

### 客户端（对称的三层抽象）

```
┌─────────────────────────────────────────────────────────┐
│  Client:call()                                          │
│    构造请求 → transport:send(data) → 解析响应            │
└──────────────────────┬──────────────────────────────────┘
                       │ Transport.get(url) ← 统一工厂
                       ▼
┌──────────┐  ┌─────────────────┐  ┌────────────────────┐
│  Http    │  │  Tcp            │  │  (统一接口)         │
│  new     │  │  new            │  │  new/open/send/close│
│  open    │  │  open           │  │                    │
│  send    │  │  send           │  │                    │
│  close   │  │  close          │  │                    │
└────┬─────┘  └────┬────────────┘  └────────────────────┘
     │             │
     └──────┬──────┘
            ▼
┌─────────────────────────────────────────────────────────┐
│  transport/socket.lua  ← 唯一网络抽象                   │
│  tcp() / unix() / bind() / set_timeouts() / release()  │
│  默认 luasocket，注入 cosocket 即用                     │
└─────────────────────────────────────────────────────────┘
```

**客户端特点**：`Transport.get(url)` 按 URL scheme 选 Http/Tcp，两者实现统一接口 `new/open/send/close`。socket 层是唯一网络抽象，运行时无关。

### 服务端（不对称的混合层）

```
┌──────────────────────────────────────────────────────────┐
│  server/init.lua  ← 纯协议域（无 I/O）                    │
│  handle_message(data) → resp                             │
│  解析 packager/header/body → 派发方法 → 渲染响应          │
└──────────────────────────────────────────────────────────┘
        ▲                          ▲
        │ 调用                     │ 调用
        │                          │
┌───────┴──────────┐  ┌───────────┴──────────────┐
│  server/http.lua  │  │  server/tcp.lua          │
│  ┌──────────────┐│  │  ┌────────────────────┐  │
│  │ Daemon        ││  │  │ Daemon              │  │
│  │ run(addr)     ││  │  │ run(addr)           │  │
│  │ accept 循环   ││  │  │ accept 循环         │  │
│  ├──────────────┤│  │  ├────────────────────┤  │
│  │ HTTP Transport││  │  │ YAR Frame Transport│  │
│  │ handle_conn   ││  │  │ handle_conn        │  │
│  │ 读请求行/头/体 ││  │  │ Framing.recv_msg   │  │
│  │ 写 HTTP 响应  ││  │  │ 写 YAR 帧          │  │
│  └──────────────┘│  │  └────────────────────┘  │
│  luasocket only   │  │  luasocket + OpenResty    │
│  ❌ OpenResty 不可用│  │  ✅ handle_conn 可复用   │
└──────────────────┘  └──────────────────────────┘
```

**服务端特点**：每个 Server 类**混合了两个领域**——daemon（accept 循环）+ transport adapter（协议帧解析）。没有统一 transport 工厂，没有统一 transport 接口。

### OpenResty 下的调用路径（2×2 决策矩阵）

```
                    │  HTTP 协议              │  TCP 协议
─────────────────────┼────────────────────────┼──────────────────────────
 标准 Lua            │ HttpServer.new(svc)    │ TcpServer.new(svc)
 (luasocket)        │   :run(addr)           │   :run(addr)
                    │ 用 daemon+transport     │ 用 daemon+transport
─────────────────────┼────────────────────────┼──────────────────────────
 OpenResty           │ Server.new(svc)        │ TcpServer.new(svc)
 (nginx 是 daemon)  │   :handle_message(data)│   :handle_connection(sock)
                    │ 跳过 daemon+transport   │ 跳过 daemon，复用 transport
```

**这就是不对称的根源**：调用方需要知道「我在哪个运行时」+「我用哪个协议」，才能决定实例化哪个类、调哪个方法。

---

## 二、逐问回答

### Q1：为什么 OpenResty 时，有时 new Server，有时 new HttpServer，有时 new TcpServer？

**答**：因为 OpenResty 的 nginx 在不同 location 类型下「接管了不同层次的职责」，lua-yar 只需补齐 nginx 不做的部分。

| OpenResty 配置 | nginx 接管的层 | lua-yar 需补的层 | 实例化什么 |
|---|---|---|---|
| `http {} → content_by_lua` | daemon + HTTP 传输（nginx 解析 HTTP，给 body） | **仅协议核心** | `Server.new(svc)` → `:handle_message(data)` |
| `stream {} → content_by_lua` | daemon（nginx accept，给 cosocket） | **传输 + 协议** | `TcpServer.new(svc)` → `:handle_connection(sock)` |
| 无 OpenResty（标准 Lua） | 无（需自己 accept） | **daemon + 传输 + 协议** | `HttpServer.new(svc)` → `:run(addr)` |

**本质**：不是「lua-yar 设计了三种 Server」，而是「三种运行时环境接管了不同层次，lua-yar 需要提供对应层次的入口」。`Server` = 纯协议，`HttpServer` = 协议+HTTP传输+daemon，`TcpServer` = 协议+YAR帧传输+daemon。

### Q2：为什么 OpenResty 下不能 new HttpServer / new TcpServer 的 run()？

**答**：因为 `run()` 是 accept 循环 daemon——它调用 `Socket.bind()` + `server:accept()` 在 `while true` 中循环。这与 OpenResty 的根本架构**直接冲突**：

```
HttpServer:run(addr) 的本质：
  local server = Socket.bind(host, port)  ← 尝试绑定端口
  while true do
    local client = server:accept()        ← 尝试 accept 连接
    ...
  end
```

**冲突点**：
1. **端口冲突**：nginx 已经 listen 了该端口，你再 `Socket.bind()` 同一端口会失败（`EADDRINUSE`）。
2. **事件循环冲突**：nginx 的事件循环是 reactor 单线程模型，`while true` 阻塞循环会卡死 worker。
3. **cosocket 无 bind**：OpenResty cosocket API 只有 `tcp()`（客户端连接），**没有 `bind()`**（服务端监听）——cosocket 设计上就不能做 server socket。`socket.lua` 第 103 行 `if not provider.bind then return nil, "current socket provider does not support bind"` 就是这个原因。

**所以**：`run()` 在 OpenResty 下不是「不能用」，是「**根本不可能用**」——架构层面互斥。nginx 是 daemon，你不能再当 daemon。

**但 `handle_connection` 可以复用**：因为它只接受一个已连接的 socket（cosocket），做帧读取 + 派发 + 回写，不涉及 bind/accept。这正是 `example/server_openresty.lua` 和 `example/resty_yar_tcp_server.lua` 做的事。

**HttpServer 的 `handle_connection` 不可复用**：因为它内部做 HTTP 请求行/头解析，而 OpenResty `http{}` 块的 nginx 已经解析完了 HTTP，直接给你 `ngx.req.get_body_data()`。再解析一遍 HTTP 是多余的。所以 OpenResty HTTP 路径直接调 `handle_message(data)`，跳过整个 HttpServer。

### Q3：为什么 handle_message 放在 Server 下？

**答**：因为 `handle_message(data)` 是**纯协议函数**——输入字节，输出字节，无 I/O、无 yield、reentrant。它属于**协议域**，不属于传输域。

**放在 Server 的理由**：

1. **运行时无关**：`handle_message` 不感知 ngx/luasocket/cosocket，任何能给它字节的运行时都能用。这是它的核心契约。

2. **OpenResty HTTP 路径的唯一入口**：nginx 做了 daemon + HTTP 传输，lua-yar 只需协议处理。如果 `handle_message` 在 `HttpServer` 下，OpenResty HTTP 用户就得实例化一个 HttpServer（暗示有 daemon），但实际不跑 daemon——语义误导。

3. **关注点分离**：`Server` = 协议语义（what），`HttpServer`/`TcpServer` = 传输机制（how）。`handle_message` 是「what」，放 Server 正确。

4. **协程安全**：`handle_message` 无共享可变状态（方法表 memoize 在构造时，运行时只读），N 个协程并发调用安全。这是 OpenResty 多协程并发的基石。

**如果放错位置的后果**：假设 `handle_message` 在 `HttpServer` 下，OpenResty TCP 用户想复用协议核心，就得 `require("yar.server.http")`——语义上引入了不相关的 HTTP 依赖，违反最小依赖原则。

### Q4：传输器处理的不对称

**答**：这是当前架构最核心的问题。客户端有统一传输抽象，服务端没有。

**客户端对称的三层**：
```
Transport.get(url)        ← 统一工厂，按 URL scheme 选
  → Http / Tcp            ← 统一接口：new/open/send/close
    → socket.lua           ← 统一网络抽象
```

**服务端不对称的两层**：
```
（无统一工厂）              ← 缺失！
  HttpServer               ← run=daemon + handle_connection=HTTP传输，混合
  TcpServer                ← run=daemon + handle_connection=YAR帧传输，混合
    → socket.lua            ← 统一网络抽象（与客户端共用）
```

**不对称的三个表现**：

1. **无统一 transport 工厂**：客户端 `Transport.get(url)` 按 scheme 选传输器；服务端没有 `ServerTransport.get(protocol)` 这样的工厂。调用方得自己知道用 HttpServer 还是 TcpServer。

2. **无统一 transport 接口**：客户端 Http/Tcp 都实现 `new/open/send/close`；服务端 `HttpServer:handle_connection(client)` 和 `TcpServer:handle_connection(client, opts)` 签名不同（一个有 opts 一个没有），职责不同（一个解析 HTTP 一个读 YAR 帧）。

3. **daemon 与 transport 耦合**：客户端 transport 只管「发数据收响应」，不管 daemon；服务端 `HttpServer`/`TcpServer` 的 `run()`（daemon）和 `handle_connection`（transport）绑在同一个类里，无法分离使用（OpenResty 下只要 transport 不要 daemon，TCP 能复用 handle_connection，HTTP 连 handle_connection 都不能复用）。

**根因**：客户端 transport 是「**主动方**」——它发起连接、发数据、收响应，流程统一（connect→send→receive→close），容易抽象统一接口。服务端 transport 是「**被动方**」——它接收连接、收请求、发响应，但 HTTP 和 TCP 的「收请求」方式根本不同（HTTP 要解析请求行/头，TCP 直接读 YAR 帧），统一接口的抽象成本更高。

但这不意味着不能统一。可以抽象为：
```lua
-- 假想的服务端统一 transport 接口
ServerTransport.read_request(sock)  → data, err   -- 读完整请求字节
ServerTransport.write_response(sock, resp)        -- 写完整响应字节
```
HTTP 和 TCP 的差异封装在各自实现里，对上层暴露统一接口。

### Q5：server.lua、http.lua、tcp.lua 各自的定义、作用、领域

**`server/init.lua` — 协议域（Pure Protocol）**

| 维度 | 内容 |
|---|---|
| **定义** | YAR 协议处理器：接收完整 YAR 二进制消息，返回 YAR 二进制响应 |
| **输入** | `string`（YAR 二进制消息：packager + header + body） |
| **输出** | `string`（YAR 二进制响应消息） |
| **职责** | 解析 packager 名称 → 解包 header/body → 派发 RPC 方法 → 渲染响应 |
| **I/O** | 无（纯函数，不 yield，reentrant） |
| **运行时** | 无关（任何能给字节的运行时都能用） |
| **DDD 限界上下文** | YAR 协议语义（what：请求/响应/方法/错误编码） |
| **变更驱动因素** | YAR 协议变更（PHP Yar 兼容性）、packager 新增、错误码新增 |

**`server/http.lua` — HTTP Daemon + HTTP 传输域**

| 维度 | 内容 |
|---|---|
| **定义** | 独立 HTTP daemon：监听端口，解析 HTTP，委托协议核心，写 HTTP 响应 |
| **输入** | 网络（accept HTTP 连接） |
| **输出** | HTTP 响应（含状态行/头/体） |
| **职责** | `run`：accept 循环（daemon）；`handle_connection`：解析 HTTP 请求行/头/体（transport）→ 委托 `handle_message` → 写 HTTP 响应 |
| **I/O** | luasocket（`Socket.bind` / `server:accept` / `client:receive` / `client:send`） |
| **运行时** | 标准 Lua + luasocket（**OpenResty 下不可用**——nginx 是 HTTP daemon） |
| **DDD 限界上下文** | 混合了两个上下文：进程生命周期管理（daemon）+ HTTP 线协议解析（transport） |
| **变更驱动因素** | HTTP 协议细节、daemon 并发模型、luasocket 行为变化 |

**`server/tcp.lua` — TCP Daemon + YAR 帧传输域**

| 维度 | 内容 |
|---|---|
| **定义** | 独立 TCP daemon：监听端口，读 YAR 帧，委托协议核心，写 YAR 帧 |
| **输入** | 网络（accept TCP 连接） |
| **输出** | YAR 帧响应 |
| **职责** | `run`：accept 循环（daemon）；`handle_connection`：`Framing.receive_message` 读 YAR 帧（transport）→ 委托 `handle_message` → 写 YAR 帧 |
| **I/O** | luasocket 或 cosocket（`handle_connection` 接受任何兼容 socket） |
| **运行时** | 标准 Lua + luasocket（`run`），**或** OpenResty stream（仅 `handle_connection`，nginx 做 daemon） |
| **DDD 限界上下文** | 混合了两个上下文：进程生命周期管理（daemon）+ YAR 帧读写（transport） |
| **变更驱动因素** | YAR 帧协议、daemon 并发模型、keepalive 策略 |

### Q6：从 DDD 和工程化角度看，当前处理方式有什么问题？如何让上游调用感到对称、降低心智负担？

**当前问题（DDD 视角）**：

**问题 1：限界上下文混淆**
`HttpServer`/`TcpServer` 混合了两个限界上下文——「daemon」（进程生命周期、accept 循环）和「transport adapter」（线协议解析）。这两个上下文有不同的变更驱动因素：
- daemon 的变更：并发模型（单线程/协程/多进程）、socket provider
- transport 的变更：HTTP 协议标准、YAR 帧格式

混合在一起导致：改 daemon 逻辑可能影响 transport 逻辑，反之亦然。违反单一职责。

**问题 2：调用方心智负担高（2×2 决策矩阵）**
调用方需要回答两个问题才能写对代码：
1. 我在哪个运行时？（标准 Lua / OpenResty http / OpenResty stream）
2. 我用哪个协议？（HTTP / TCP）

组合出 4 种路径，每种用不同的类 + 不同的方法：

| 运行时 | 协议 | 实例化 | 调用 |
|---|---|---|---|
| 标准 Lua | HTTP | `HttpServer.new()` | `:run(addr)` |
| 标准 Lua | TCP | `TcpServer.new()` | `:run(addr)` |
| OpenResty http | HTTP | `Server.new()` | `:handle_message(data)` |
| OpenResty stream | TCP | `TcpServer.new()` | `:handle_connection(sock)` |

调用方得记住这个矩阵。对比客户端：不管什么运行时、什么协议，都是 `Client.new(url):call(method, args)`——一行代码，URL scheme 决定传输。

**问题 3：服务端无统一 transport 抽象**
客户端有 `Transport.get(url)` 工厂 + 统一 `new/open/send/close` 接口。服务端没有等价物。每个 Server 类自己实现 `handle_connection`，签名不一致，无法多态。

**问题 4：HttpServer 在 OpenResty 下完全不可用**
TcpServer 的 `handle_connection` 至少能在 OpenResty stream 下复用（cosocket API 兼容），但 HttpServer 的 `handle_connection` 在 OpenResty http 下完全多余（nginx 已解析 HTTP）。这导致 HTTP 和 TCP 的对称性进一步被破坏。

---

**对称性改进方向（提案，非实现）**

**方向 A：分离 daemon 与 transport adapter（推荐探索）**

将 `HttpServer`/`TcpServer` 拆分为三层：

```
┌─────────────────────────────────────────────────────┐
│  server/init.lua  ← 协议域（不变）                    │
│  handle_message(data) → resp                         │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────┴──────────────────────────────┐
│  server/transport/  ← 服务端传输域（新增）            │
│  HttpTransport.read_request(sock) → data            │
│  HttpTransport.write_response(sock, resp)            │
│  TcpTransport.read_request(sock) → data              │
│  TcpTransport.write_response(sock, resp)             │
│  （统一接口，可多态）                                  │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────┴──────────────────────────────┐
│  server/daemon.lua  ← daemon 域（标准 Lua only）      │
│  Daemon.run(addr, transport, server)                │
│  accept 循环 → transport.read_request →              │
│  server:handle_message → transport.write_response    │
└─────────────────────────────────────────────────────┘
```

**调用方对称性**：
- 标准 Lua：`Daemon.run(addr, HttpTransport, server)` 或 `Daemon.run(addr, TcpTransport, server)`
- OpenResty HTTP：`server:handle_message(data)`（nginx 是 daemon + transport）
- OpenResty TCP：`TcpTransport.read_request(sock)` → `server:handle_message` → `TcpTransport.write_response`

**收益**：daemon 与 transport 解耦，transport 可独立复用，调用方心智从「2×2 矩阵」降为「我需要补哪层」。

**风险**：改动面大，需重构 http.lua/tcp.lua，调整 example/ 和 test/。需评估投入产出比。

**方向 B：统一 handle_connection 接口（最小改动）**

不拆分，但让 `HttpServer:handle_connection` 和 `TcpServer:handle_connection` 签名统一，都接受 `(client, opts)`，使两者可多态替换。

**收益**：最小改动，签名对称。
**局限**：daemon 与 transport 仍耦合，OpenResty HTTP 路径仍无法复用 HttpServer。

**方向 C：文档化决策矩阵（零代码改动）**

接受 2×2 矩阵是固有的（运行时 × 协议），在 README/docs 中清晰文档化每种路径的用法。

**收益**：零风险，降低认知负担靠文档。
**局限**：不解决代码层面的不对称，调用方仍需记矩阵。

---

**业界对标**：

| 项目 | 服务端架构 | daemon 与 transport 关系 |
|---|---|---|
| lua-resty-http | 无 server（nginx 是 server） | 客户端 only，无此问题 |
| copas | `handler(sock)` 连接级，daemon 由 copas 调度器管 | 分离：copas 做 daemon，handler 做 transport |
| OpenResty 生态 | nginx 是 daemon，Lua 只做协议 | 天然分离（nginx 架构决定） |
| lua-eco | 调度器做 daemon，handler 做 transport | 分离 |

**copas 的启示**：copas 的 `handler(sock)` 就是纯 transport adapter（读请求、处理、写响应），daemon 是 copas 的 accept 循环 + 协程调度。这与「方向 A」的思路一致——daemon 和 transport 分离。

**OpenResty 的启示**：OpenResty 的哲学就是「nginx 做 daemon + transport，Lua 做 protocol」。lua-yar 的 `Server:handle_message` 正是这个哲学的体现。问题是 `HttpServer`/`TcpServer` 的 `run()` 试图在标准 Lua 下重新当 daemon，与 OpenResty 哲学冲突——但这在标准 Lua 下是必要的（没有 nginx）。

---

## 三、总结

| 问题 | 根因 |
|---|---|
| Q1 为什么三种 Server | 三种运行时接管不同层次，lua-yar 补齐剩余层 |
| Q2 OpenResty 不能 run() | run=accept 循环，与 nginx daemon 冲突；cosocket 无 bind |
| Q3 handle_message 在 Server | 纯协议函数，运行时无关，OpenResty HTTP 唯一入口 |
| Q4 传输不对称 | 客户端有统一工厂+接口，服务端无；daemon 与 transport 耦合 |
| Q5 三文件领域 | init=协议域，http/tcp=daemon+transport 混合域 |
| Q6 DDD 问题 | 限界上下文混淆 + 2×2 决策矩阵 + 无统一 transport 抽象 |

**核心洞察**：服务端的不对称源于 `HttpServer`/`TcpServer` 把 daemon 和 transport adapter 混在一个类里。客户端没有这个问题，因为客户端 transport 是主动方（connect/send/receive），流程统一易抽象；服务端 transport 是被动方（accept/read/write），HTTP 和 TCP 的「读请求」方式差异大，统一抽象成本更高。但「成本更高」不等于「不应该做」——方向 A 是值得探索的对称性改进方向。
