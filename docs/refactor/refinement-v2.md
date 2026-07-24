# 改造方案反思 v2：纳入 yar-c / PHP yar 评估 + 统一 Server Facade 设计

> 基于 v1 提案（`server-refactor-proposal.md`）的用户反馈，深化四个维度的反思。
> 状态：反思文档（待确认后更新提案） | 关联：v1 提案、`server-architecture-reflection.md`

---

## 一、反思 1：业界对标补全 yar-c 与 PHP yar

### 1.1 完整对标矩阵

v1 只对标了 Lua 生态（copas/lua-eco/Skynet/OpenResty），遗漏了 Yar 自身的两个参考实现。补全后：

| 项目 | daemon 归属 | transport 归属 | 调用方感知的概念数 | 模式 |
|---|---|---|---|---|
| **PHP yar** | 宿主（fpm/nginx） | 宿主（nginx 解析 HTTP） | **1 个**（Server.handle） | 宿主依赖型 |
| **yar-c** | 库自身（pre-fork + libevent） | 库自身（daemon 直接调 protocol 函数） | **1 个**（Server.run） | 胖 daemon 型 |
| **copas** | 外部调度器（copas.loop） | 注入的 handler 函数 | **2 个**（daemon + handler） | handler 注入型 |
| **lua-eco** | 外部调度器（epoll） | 注入的 handler 函数 | **2 个**（daemon + handler） | handler 注入型 |
| **OpenResty** | nginx | nginx | **0 个**（Lua 只做 protocol） | 架构分离型 |
| **lua-yar（当前）** | HttpServer/TcpServer 自身 | 同一类内 handle_connection | **1 个**（Server.run/handle_conn） | 混合型 |
| **lua-yar v1 提案 A** | Daemon 类 | Transport 模块（注入） | **3 个**（Server + Transport + Daemon） | handler 注入型 |

### 1.2 yar-c 的分层方式（源码实证）

yar-c 的 `yar_server.c` 是**胖 daemon**——daemon 拥有整个请求流程，直接调用 protocol 库函数：

```
yar_server_run()
  → yar_server_start_listening()    // bind + listen
  → yar_server_startup_workers()    // pre-fork
  → [worker] event_dispatch()       // libevent 事件循环
      → on_accept(fd)               // accept 新连接
      → on_read(fd, ctx)            // ★ daemon 内部直接调 protocol：
          yar_protocol_parse(header)     // 协议头校验
          yar_request_unpack(request)    // 解包
          handler->handler(req, resp, data)  // ★ 仅业务逻辑用 handler 注入
          yar_response_pack(response)    // 打包
          yar_protocol_render(header)    // 渲染响应头
      → on_write(fd, ctx)           // send 响应
```

**关键发现**：yar-c 的 daemon/transport 分离是**文件级分离**（`yar_server.c` vs `yar_protocol.c`），但**不是注入式分离**。daemon 直接 `#include` 并调用 protocol 函数。handler 注入**仅用于业务逻辑**（RPC 方法），不用于 transport。

**yar-c 的 transport 不是独立可替换的组件**——它是 daemon 的内部库函数。daemon 拥有 accept 循环 + I/O 读写 + 协议解析的完整流程。

### 1.3 PHP yar 的分层方式

PHP yar **完全没有 daemon**——宿主（fpm/nginx）做 daemon + HTTP transport：

```php
// server.php，放在 nginx docroot 下
class API {
    public function someMethod($param) { return "result: " . $param; }
}

$server = new Yar_Server(new API());  // 构造：传入 service 对象
$server->handle();                     // 处理当前 HTTP 请求，输出响应，结束
```

`handle()` 的行为：读 HTTP 请求体（`php://input`）→ 解析 YAR 协议 → 派发方法 → 输出 YAR 响应到 `stdout`（fpm 捕获后返回给 nginx）。**每次请求一个 PHP 进程生命周期**，`handle()` 处理完就结束。

**PHP yar 的 transport = nginx + fpm 的 I/O 机制**。库不感知 transport，只感知「给我字节、我给你字节」。这与 lua-yar 的 `Server:handle_message(data)` 完全一致。

### 1.4 三种模式的核心差异

| 模式 | 代表 | daemon 在哪 | transport 在哪 | 调用方看到什么 |
|---|---|---|---|---|
| **宿主依赖型** | PHP yar | 宿主 | 宿主 | `Server.new(svc):handle()` — 1 个概念 |
| **胖 daemon 型** | yar-c | 库自身 | 库内部（daemon 直接调） | `Server.init(addr):run()` — 1 个概念 |
| **handler 注入型** | copas | 外部调度器 | 注入的 handler 函数 | `daemon + handler(sock)` — 2 个概念 |

**v1 提案 A 选了 handler 注入型（copas 模式）**，导致调用方要感知 3 个概念（Server + Transport + Daemon）。但 yar-c 和 PHP yar 都让调用方只感知 1 个概念。

**反思**：copas 模式适合「通用网络框架」（handler 是任意业务），但 lua-yar 是「YAR 协议库」——transport 的变化只有 HTTP/TCP 两种，不需要让调用方手动注入 transport。yar-c 的「URL 决定 transport」+「调用方只看到 Server」更适合 lua-yar 的定位。

---

## 二、反思 2：yar-c 与 PHP yar 的启动签名

### 2.1 yar-c 启动签名

```c
// 1. 初始化（URL 决定 transport + address）
int yar_server_init(char *hostname);
//   hostname = "tcp://127.0.0.1:8888" 或 "/tmp/yar.sock"
//   ★ URL scheme 决定 transport 类型（tcp vs unix socket）

// 2. 注册方法（flat array，以 NULL 结尾）
int yar_server_register_handler(yar_server_handler *handlers);
//   handlers = { {"default", 7, my_handler}, {"add", 3, add_handler}, {NULL,0,NULL} }

// 3. 启动（阻塞，pre-fork + libevent accept 循环）
int yar_server_run(void);
//   ★ 无参数——address 在 init 时已确定，run 只负责启动
```

完整使用：
```c
int main() {
    yar_server_init("tcp://127.0.0.1:8888");   // ① 地址 + transport
    yar_server_register_handler(handlers);      // ② 方法
    yar_server_run();                           // ③ 启动（阻塞）
    yar_server_destroy();
}
```

### 2.2 PHP yar 启动签名

```php
// 1. 构造（传入 service 对象，反射自动发现 public 方法）
$server = new Yar_Server(Object $service);

// 2. 处理（处理当前 HTTP 请求，输出响应）
$server->handle(void);
//   ★ 无参数——data 来自 php://input，输出到 stdout
//   ★ 无 address——nginx 管理监听地址
```

完整使用：
```php
$server = new Yar_Server(new API());  // ① service
$server->handle();                      // ② 处理一个请求
```

### 2.3 点评

| 维度 | yar-c | PHP yar | lua-yar 当前 | lua-yar v1 提案 A |
|---|---|---|---|---|
| 启动步骤 | 3 步（init/register/run） | 2 步（new/handle） | 2 步（new/run） | 3+ 步（new Server + new Daemon + run） |
| 地址传递 | `init("tcp://addr")` URL | 无（宿主管） | `run(addr)` 参数 | `Daemon:run(addr)` 参数 |
| transport 选择 | URL scheme（`tcp://` vs unix） | 无（宿主决定） | 类名（HttpServer vs TcpServer） | `require` 哪个模块 |
| 方法注册 | `register_handler(array)` | 构造时反射自动发现 | `:register(name, func)` 链式 | `:register(name, func)` 链式 |
| 调用方感知概念 | 1（Server） | 1（Server） | 1（HttpServer/TcpServer） | **3（Server + Transport + Daemon）** |

**关键洞察**：

1. **yar-c 用 URL scheme 选 transport**——`"tcp://"` 选 TCP transport，`"/tmp/xxx.sock"` 选 Unix socket。服务端也用 URL scheme，与客户端 `Transport.get(url)` 对称。v1 提案 A 放弃了这一点，改用 `require` 选模块，反而不如 yar-c 对称。

2. **PHP yar 的 `handle()` 无参数**——data 从宿主来（`php://input`），响应到宿主去（`stdout`）。库不感知 I/O 机制。这是「宿主依赖型」的极致：库 = 纯协议。

3. **两者都让调用方只看到 Server**——不暴露 Transport/Daemon 概念。v1 提案 A 暴露了 3 个概念，是**认知负担倒退**。

---

## 三、反思 3：改造后宿主代码增多的回归问题

### 3.1 代码行数对比（实证）

**OpenResty TCP 场景**：

```
当前：    local s = TcpServer.new(api); s:handle_connection(sock, {keepalive=true})
          → 1 行，1 个概念（TcpServer）

v1 提案： local s = Server.new(api); TcpTransport.serve(sock, s, {keepalive=true})
          → 1 行，2 个概念（Server + TcpTransport）  ← 概念增多
```

**标准 Lua TCP 场景**：

```
当前：    local s = TcpServer.new(api); s:run(addr)
          → 1 行，1 个概念

v1 提案： local s = Server.new(api)
          local d = Daemon.new(s, TcpTransport, opts); d:run(addr)
          → 3 行，3 个概念（Server + Transport + Daemon）  ← 行数+概念双增
```

**copas TCP 场景**：

```
当前：    copas.addserver(srv, function(c) server:handle_connection(c, {keepalive=true}) end)

v1 提案： copas.addserver(srv, function(c) TcpTransport.serve(c, server, {keepalive=true}) end)
          → 行数相同，但调用方要 import TcpTransport 模块  ← 依赖增多
```

### 3.2 问题定性

v1 提案 A 的目标是「降低调用方心智负担」，但实际效果是：

- **内部架构更干净**（三层分离，可测试可复用）✅
- **调用方心智负担更重**（从 1 个概念变 3 个概念）❌

这是**优化了实现者、牺牲了调用方**。与目标「降低调用方心智负担」矛盾。

### 3.3 根因

v1 提案 A 照搬 copas 的 handler 注入模式，但 copas 是**通用网络框架**——handler 是任意业务逻辑，必须注入。lua-yar 是**YAR 协议库**——transport 只有 HTTP/TCP 两种固定选择，不需要让调用方手动注入。把「通用框架」的模式套到「协议库」上，过度暴露了内部抽象。

---

## 四、反思 4：HTTP/TCP 仍不对称 + 统一 Server Facade 设计

### 4.1 v1 提案的残留不对称

```
OpenResty HTTP：  server:handle_message(data)                    ← 不经过 Transport
OpenResty TCP：   TcpTransport.serve(sock, server, opts)          ← 经过 Transport
```

**HTTP 绕过 Transport，TCP 经过 Transport——仍然不对称**。v1 提案没有解决这个根本问题，只是把不对称从「不同类不同方法」变成了「一个经过 Transport 一个不经过」。

### 4.2 用户提出的设计方向

> 「应该是 `new server(serverType, socket, 或者 http 委托, options)`」
> 「调用方不需要感知到服务端 transport 存在和 daemon 存在」
> 「直接执行 `server.accept()` 或者 `server.run()`」

核心思想：**Server 是唯一的外部接口，Transport/Daemon 是内部实现细节**。

### 4.3 统一 Server Facade 设计

#### 4.3.1 调用方视角（统一接口）

```lua
-- 所有场景统一：Server.new(api, spec, opts?) → server:run()
-- spec 决定模式：

-- ① 标准 Lua 独立 daemon（URL 决定 protocol + address，对标 yar-c）：
local server = Server.new(api, "tcp://0.0.0.0:8888", {keepalive = true})
local server = Server.new(api, "http://0.0.0.0:8888", {max_body_len = 2^20})

-- ② OpenResty TCP（注入 socket）：
local server = Server.new(api, {socket = ngx.req.sock(), keepalive = true})

-- ③ OpenResty HTTP（注入 data + writer 回调）：
local server = Server.new(api, {
    data   = ngx.req.get_body_data(),
    writer = function(resp) ngx.print(resp) end,
})

-- 统一调用：
server:run()
```

**对称性**：HTTP 和 TCP 都走 `server:run()`，差异仅在 spec/options。调用方不感知 Transport/Daemon。

#### 4.3.2 HTTP 回调注入机制

用户提出：「http 的 handler message 能不能注入一个闭包函数进去，每个请求结束 handler message callback 进闭包函数，闭包函数把 ngx.print 那些处理了」。

设计：HTTP 的「transport」是一对 reader/writer 回调，替代 socket：

```lua
-- OpenResty HTTP（content_by_lua_block）：
local server = Server.new(api, {
    data   = ngx.req.get_body_data(),       -- reader：宿主提供请求字节
    writer = function(resp)                 -- writer：宿主处理响应字节
        ngx.header["Content-Type"] = "application/octet-stream"
        ngx.print(resp)
    end,
})
server:run()
-- run() 内部：local resp = self:handle_message(opts.data); opts.writer(resp)
```

**为什么这对称**：

| 场景 | 「读请求」来源 | 「写响应」去向 | transport 本质 |
|---|---|---|---|
| TCP（socket） | `sock:receive` / `Framing.receive_message` | `sock:send` | socket 对象 |
| HTTP（回调） | `opts.data`（宿主给的字符串） | `opts.writer(resp)`（宿主的回调） | 回调对 |

两者都是「I/O 机制」——TCP 用 socket 对象，HTTP 用回调对。对 Server 内部，都是「拿到 data → handle_message → 输出 resp」的流程。

#### 4.3.3 内部实现（调用方不可见）

```lua
-- server/init.lua（Server facade）

function Server.new(api, spec, opts)
    local self = setmetatable({}, _M)
    self.core = ServerCore.new(api)   -- 协议核心（原 server/init.lua 逻辑）

    if type(spec) == "string" then
        -- URL 模式：独立 daemon
        local protocol, addr = parse_url(spec)  -- "tcp://0.0.0.0:8888" → "tcp", "0.0.0.0:8888"
        self.mode = "daemon"
        self.protocol = protocol
        self.addr = addr
        self.opts = opts or {}
    elseif spec.socket then
        -- 注入 socket：hosted TCP
        self.mode = "tcp_hosted"
        self.socket = spec.socket
        self.opts = spec
    elseif spec.data and spec.writer then
        -- 注入回调：hosted HTTP
        self.mode = "http_hosted"
        self.data = spec.data
        self.writer = spec.writer
        self.opts = spec
    end
    return self
end

function Server:run()
    if self.mode == "daemon" then
        -- 内部创建 Daemon + Transport，调用方不可见
        local transport = self.protocol == "tcp" and TcpTransport or HttpTransport
        local daemon = Daemon.new(self.core, transport, self.opts)
        daemon:run(self.addr)
    elseif self.mode == "tcp_hosted" then
        -- 内部调 Transport.serve，调用方不可见
        TcpTransport.serve(self.socket, self.core, self.opts)
    elseif self.mode == "http_hosted" then
        -- 内部调 handle_message + writer，调用方不可见
        local resp = self.core:handle_message(self.data)
        self.writer(resp)
    end
end
```

**关键**：Transport 和 Daemon 作为内部模块存在（保持分离可测试），但**调用方不直接接触它们**。Server 是 Facade，根据 spec/options 内部分发。

### 4.4 三种设计对比

| 维度 | 当前架构 | v1 提案 A（三层暴露） | v2 统一 Facade |
|---|---|---|---|
| 调用方概念数 | 1（HttpServer/TcpServer） | 3（Server+Transport+Daemon） | **1（Server）** |
| HTTP/TCP 对称 | ❌（不同类不同方法） | ❌（HTTP 绕过 Transport） | **✅（统一 run，差异在 options）** |
| OpenResty HTTP 路径 | `handle_message(data)` | `handle_message(data)` | `Server.new(api, {data=, writer=}):run()` |
| OpenResty TCP 路径 | `handle_connection(sock)` | `TcpTransport.serve(sock, server)` | `Server.new(api, {socket=}):run()` |
| 标准 Lua 路径 | `HttpServer.new(api):run(addr)` | `Daemon.run(Server.new(api), Transport, addr)` | `Server.new(api, "tcp://addr"):run()` |
| 内部分离 | ❌（混合） | ✅（三层分离） | ✅（三层分离，但隐藏在 Facade 后） |
| 业界对标 | 无 | copas（handler 注入） | **yar-c（URL + 统一 Server）+ PHP yar（回调注入）** |
| 宿主代码量 | 最少 | 最多（+概念） | 少（与当前持平） |

### 4.5 v2 Facade 的核心收益

1. **调用方只看到 Server**——对标 yar-c 和 PHP yar，不暴露 Transport/Daemon 概念
2. **HTTP/TCP 真正对称**——统一 `Server.new(api, spec):run()`，差异仅在 spec
3. **URL 选 transport**——对标 yar-c 的 `"tcp://addr"`，与客户端 `Transport.get(url)` 对称
4. **HTTP 回调注入**——HTTP 的 transport 是 reader/writer 回调对，与 TCP 的 socket 对称
5. **内部仍分离**——Transport/Daemon 作为内部模块存在，保持可测试可复用
6. **宿主代码不增**——与当前架构持平，不增加调用方负担

### 4.6 待讨论的取舍点

1. **URL 解析**：`"tcp://0.0.0.0:8888"` 需要解析 scheme + host + port。是否复用客户端的 URL 解析逻辑？
2. **HTTP 回调的粒度**：`writer = function(resp)` 只给响应体。是否需要给更多上下文（如 status code、GET introspection 需要返回 HTML）？可能需要 `writer = function(resp, content_type, status)` 或 `writer = function(http_response)` 让 Server 构造完整 HTTP 响应。
3. **GET introspection**：当前 HttpServer 的 GET 请求返回 HTML 服务列表。Facade 模式下，HTTP hosted 场景的 GET 怎么处理？可能需要 `opts.on_introspect = function() ... end` 回调。
4. **Daemon 模式的 opts**：`Server.new(api, "tcp://addr", {keepalive=true, max_body_len=...})` 的 opts 透传给内部 Daemon/Transport。
5. **是否保留 Daemon/Transport 作为公开模块**：Facade 模式下，高级用户是否还能直接用 `TcpTransport.serve()`？建议保留公开（高级用法），但文档主推 Facade。

---

## 五、总结：v1 → v2 的方向调整

| 维度 | v1 提案 A | v2 反思方向 |
|---|---|---|
| 设计模式 | handler 注入型（copas） | **统一 Facade 型（yar-c + PHP yar）** |
| 调用方概念 | 3 个（Server+Transport+Daemon） | **1 个（Server）** |
| HTTP/TCP 对称 | 不对称（HTTP 绕过 Transport） | **对称（统一 run，差异在 options）** |
| transport 选择 | `require` 模块 | **URL scheme（对标 yar-c）** |
| HTTP transport | 无（直接 handle_message） | **回调对（data + writer）** |
| 内部分离 | 三层暴露 | **三层隐藏在 Facade 后** |
| 业界对标 | copas only | **yar-c + PHP yar + copas** |

**核心转变**：从「让调用方组装三层」变为「让调用方只看到 Server，内部自动组装」。对标 yar-c 的 `init("tcp://addr"):run()` 和 PHP yar 的 `new Server(svc):handle()`，但用 options 注入支持 hosted 场景（PHP yar 不支持的场景）。

---

## 六、下一步

1. 确认 v2 Facade 方向是否可行
2. 细化 HTTP 回调的 API（writer 签名、GET introspection 处理）
3. 细化 URL 解析（是否复用客户端逻辑）
4. 确认是否保留 Transport/Daemon 作为公开高级模块
5. 更新 v1 提案文档或产出 v2 提案
