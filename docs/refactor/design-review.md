# v4 设计 Review：对比业界实现

> 审查对象：`deep-synthesis-v4.md` + `implementation-plan.md`（已同步）
> 对标：Go net/http + net/rpc、Python SimpleXMLRPCServer、PHP Yar、yar-c、copas、WSGI/ASGI
> 审查维度：API 完整性、架构模式、I/O 抽象、错误处理、命名一致性、缺口与风险

---

## 一、API 表面对比

### 1.1 构造：`Server.new(opts?, service?)`

| 实现 | 构造签名 | addr 身份 | service 注入 | 评价 |
|---|---|---|---|---|
| **lua-yar v4** | `new(opts?, service?)` | 独立方法 `listen(addr)` | 可选第二参数，自动 collect_methods | 构造与 I/O 分离 |
| Go net/http | `http.Server{Addr, Handler, ...}` | 结构体字段 | Handler 字段 | addr 是字段非参数，但语义相同 |
| Python HTTPServer | `HTTPServer(addr, handler)` | 第一参数 | handler 第二参数 | addr 独立第一参数 |
| PHP Yar | `new Yar_Server($service)` | 无 addr（宿主模式 only） | service 唯一参数 | 不支持 daemon，addr 不存在 |
| yar-c | `yar_server_init()` | 无参 | `register_handler` 逐个注册 | addr 在 `run(url)` 时传 |
| lua-resty-http | `http.new()` | 无参 | — | `httpc:connect(host, port)` 分离 |

**评价**：v4 的 `new(opts?, service?)` + `listen(addr)` 分离是业界最正确的——

- 构造器只做初始化（opts/service），不碰地址、不碰 I/O（对标 lua-resty-http `http.new()`、lua-resty-redis `redis.new()`）
- addr 通过独立方法 `listen(addr)` 设置（对标 `httpc:connect(host, port)`），I/O 操作返回 `true|nil, err`
- 比 PHP Yar 多了 addr（支持 daemon）
- 比 Python 多了 opts（运行时配置不混入构造参数）
- 比 yar-c 多了 service 批量注册（不用逐个 register_handler）
- 比 Go 少了 Handler 接口注入（Lua 无接口类型，用 service table 替代）

**层次意识正确**：addr 是身份属性（独立方法 `listen()`），opts 是行为调参（构造参数），service 是业务注入（构造参数）。三者语义不同，不混在一个 opts 里。对标 lua-resty-http 的 `new()` + `connect()` 分离模式——构造与 I/O 分离是 Lua 业界标杆惯例。

### 1.2 宿主入口：`Server:handle(spec)`

| 实现 | 宿主入口 | 签名 | 评价 |
|---|---|---|---|
| **lua-yar v4** | `handle(spec)` | spec 含 socket 或 {method,data,writer} | 两种 I/O Strategy 统一入口 |
| Go net/http | `http.Serve(listener, handler)` | listener + Handler 接口 | 调用方管 accept，库管 Serve |
| PHP Yar | `handle()` | 无参，直接 echo | 极致轻量，但 I/O 硬编码 |
| WSGI | `app(environ, start_response)` | environ + 回调 | 流 + 回调抽象 |
| ASGI | `app(scope, receive, send)` | scope + 回调对 | 事件回调对抽象 |

**评价**：v4 的 `handle(spec)` 用 spec 字段区分 I/O 模式（socket vs data+writer），本质是 Strategy 模式。对标 ASGI 的 receive/send 回调对——socket 天然满足回调对接口（receive/send 方法对），data+writer 是显式回调对。两种策略统一在 handle 入口是正确设计。

**与 PHP Yar 的关键差异**：PHP Yar 的 `handle()` 无参，直接 `echo` 输出——I/O 硬编码到 PHP 运行时。v4 的 `handle(spec)` 把 I/O 抽象出来，支持 OpenResty（writer 回调）和 socket 两种模式。这是 v4 比 PHP Yar 更通用的地方。

### 1.3 daemon 入口：`Server:listen(addr)` + `Server:loop()`

| 实现 | daemon 入口 | 签名 | 并发模型 | 评价 |
|---|---|---|---|---|
| **lua-yar v4** | `listen(addr)` + `loop()` | listen: addr 解析+bind; loop: 无参 | 顺序 accept | 标准 Lua only，生产用 OpenResty/copas |
| Go net/http | `ListenAndServe(addr, handler)` | addr + handler | goroutine per conn | 内置并发 |
| Python | `serve_forever()` | 无参 | 顺序（可混入 ThreadingMixIn） | 可选线程并发 |
| copas | `copas.loop()` | 无参 | 协程 | 自动协程并发 |
| yar-c | `yar_server_run(url)` | url | 顺序 | 与 v4 一致 |
| lua-resty-http | `httpc:connect()` + `httpc:request()` | 分离 | — | 构造与 I/O 分离 |

**评价**：v4 的 `listen(addr)` + `loop()` 分离设计正确——对标 lua-resty-http 的 `connect()` + `request()` 分离模式。listen 做 addr 解析+bind（I/O 操作返回 `true|nil, err`），loop 做 accept 循环（无参，addr 已在 listen 时解析）。对标 copas.loop() 和 Python serve_forever()。

**copas 集成路径**：listen() 创建 `listen_sock`，可传给 `copas.addserver()` 实现协程并发。这是 listen/loop 分离的关键收益——不需要重新实现 copas 的调度器。

**并发缺口**（见 §六.3 详述）：顺序 accept 是 dev/testing 级别。Go/Python/copas 都有并发方案。v4 的定位是"标准 Lua only，生产用 OpenResty/copas"——这个分工合理，但需要在文档中显式标注。

### 1.4 方法注册：`register_service`

| 实现 | 注册方式 | 评价 |
|---|---|---|
| **lua-yar v4** | `register_service(service)` | 统一入口，service table 自动收集 |
| Go net/rpc | `Register(recv)` / `RegisterName(name, recv)` | 批量 only（反射收集） |
| Python | `register_function(func, name)` / `register_instance(obj)` | 两种路径并存 |
| PHP Yar | `new Yar_Server($service)` | 构造时 only |
| yar-c | `register_handler(name, func)` | 单个 only |

**评价**：v4 统一用 `register_service(service)` 单路径注册，对标 Go rpc.Register(recv) 和 PHP Yar new Yar_Server($service)。去掉 `register(name, func)` 简化 API 表面——单函数注册用 `register_service({ name = func })` 同样简洁。Python 的双路径是历史包袱，Lua 无需照搬。`register_service` 支持多次调用增量 merge，覆盖动态注册场景。

---

## 二、架构模式对比

### 2.1 三层分离

| 层 | v4 模块 | 职责 | 业界对标 |
|---|---|---|---|
| Facade | `init.lua` (Server) | 统一入口，分发+委托 | Go `http.Server`、PHP `Yar_Server` |
| Dispatcher | `dispatcher.lua` | 协议核心，无 I/O | Python `SimpleXMLRPCDispatcher` |
| Transport | `tcp.lua`/`http.lua` | I/O 读写 | Go `http.Handler` |
| Daemon | `daemon.lua` | accept 循环（bind 已在 listen() 完成） | Go `net.Listen` + `http.Serve` |

**评价**：三层分离是正确的。当前架构（init.lua 混合协议+Facade、tcp.lua/http.lua 混合 daemon+transport）的问题是职责混杂。v4 把协议核心提取为 Dispatcher、把 daemon 逻辑提取为独立模块，每个模块单一职责。

**Dispatcher 命名**：对标 Python `SimpleXMLRPCDispatcher`——Python 的 Dispatcher 也是纯协议处理（parse XML-RPC request → dispatch to method → render response），无 I/O。v4 的 Dispatcher 职责完全一致（parse YAR request → dispatch → render），命名准确。

### 2.2 Facade 委托模式

v4 Server Facade 委托 Dispatcher 的方法：`register_service`/`set_packager`/`set_options`/`setopt`/`list_methods`。

| 委托方法 | 当前代码 | v4 Facade | 评价 |
|---|---|---|---|
| register_service | TcpServer/HttpServer 各自委托 core | Facade 委托 dispatcher | 统一入口，消除重复 |
| set_packager | 同上 | 同上 | 同上 |
| set_options | 同上 | 同上 | 同上 |
| setopt | 同上 | 同上 | 同上 |
| list_methods | 同上 | 同上 | 同上 |

**评价**：当前 TcpServer 和 HttpServer 各自重复实现委托方法（register/set_packager/set_options/setopt），代码重复。v4 统一到 Facade，消除重复。这是正确的 DRY 改进。

**对标**：Go 的 `http.Server` 不直接暴露 Handler 的方法（Handler 是注入的）。但 lua-yar 的 Dispatcher 不是外部注入的——它在 new 时内部创建。所以 Facade 委托 Dispatcher 的方法是合理的，调用方不需要感知 Dispatcher。

---

## 三、I/O 抽象对比

### 3.1 I/O 抽象模式

| 实现 | 读请求 | 写响应 | 本质 |
|---|---|---|---|
| **lua-yar v4 (socket)** | `sock:receive(n)` | `sock:send(data)` | 对象方法对 |
| **lua-yar v4 (callback)** | `spec.data` 值 | `spec.writer(status, headers, body)` | 值 + 回调 |
| WSGI | `wsgi.input.read(n)` | `start_response() + return` | 流 + 回调 |
| ASGI | `receive()` 可调用 | `send(event)` 可调用 | 回调对 |
| Go net/http | `r.Body.Read()` | `ResponseWriter.Write()` | 接口 |
| PHP Yar | `php://input` | `echo` | 运行时硬编码 |

**评价**：v4 的 I/O 抽象与 ASGI 最接近——ASGI 用 `receive()`/`send()` 回调对，v4 用 `data`/`writer` 值+回调。区别是 ASGI 的 receive 也是回调（异步事件），v4 的 data 是同步值。这是因为 lua-yar 的宿主模式（OpenResty）是同步的——ngx.req.get_body_data() 返回值而非回调。

**socket 天然满足回调对接口**——这是 v4 设计的理论基石。sock:receive/send 是回调对的面向对象语法糖。所以 socket 模式和 callback 模式可以统一在 handle(spec) 入口，只是 spec 字段不同。

### 3.2 protocol 从 addr 解析（v4 改进）

v4 的关键改进：protocol 不在 spec 中二次指明，而是从 `listen(addr)` 时解析。

| 实现 | protocol 来源 | 评价 |
|---|---|---|
| **lua-yar v4** | `listen("tcp://addr")` → `self.protocol` | listen 时确定，早失败 |
| 当前 lua-yar | `spec.protocol` 或类名（TcpServer vs HttpServer） | 二次指明，冗余 |
| Go net/http | `http.ListenAndServe` vs `http.ServeTLS` | 方法名区分 |
| yar-c | `run("tcp://addr")` URL scheme | run 时解析 |

**评价**：v4 的 protocol 从 addr 解析是正确改进。当前代码要求调用方在 new 时选类名（TcpServer/HttpServer），在 handle 时传 spec.protocol——两次指定同一信息。v4 在 listen 时解析一次，handle 时读 self.protocol，消除冗余。

**早失败原则**：parse_addr 在 listen 时解析，格式错直接 return nil, err。对标 Go 的 `net.Listen` 在 Serve 开始时 bind 失败立即返回。比当前代码在 run 时才发现 addr 格式错更好。

---

## 四、错误处理对比

### 4.1 handle 返回值

| 实现 | 返回值 | 错误传输方式 | 评价 |
|---|---|---|---|
| **lua-yar v4** | `true|nil, err` | YAR error 帧 (HTTP 200) / HTTP 状态码 / nil,err | 三层分类 |
| Go net/http | 无返回值（Handler 内部处理） | `http.Error(w, msg, code)` | 库不返回，handler 自己处理 |
| PHP Yar | 无返回值（直接 echo） | YAR error body | 库不返回 |
| Python | 无返回值（handler 写 response） | `send_response(code)` | 库不返回 |

**评价**：v4 的 handle 返回 `true|nil, err` 比业界多了一层——Go/PHP/Python 的 handler 不返回值，错误在内部处理。v4 选择返回值是因为 Lua 没有 Go 的 panic recover、PHP 的异常机制——调用方需要知道 handle 是否成功（如 OpenResty 中 handle 失败要 log）。

**YAR 协议层错误用 HTTP 200**：对标 PHP Yar——YAR 协议错误（method not found、exception 等）编码进 YAR error 帧，用 HTTP 200 传输。这是 YAR 协议规范，不是 HTTP 层错误。v4 的设计正确遵循了这一点。

### 4.2 错误处理分层

| 层 | 错误形式 | 对标 |
|---|---|---|
| Dispatcher (handle_message) | `return resp` (含 error 帧) 或 `nil, err` | Python dispatcher |
| Transport (serve) | `return true|nil, err` | Go Handler |
| Facade (handle) | `return true|nil, err` | — |
| Daemon (run) | 无返回值（无限循环） | Go ListenAndServe |

**评价**：错误处理分层正确。Dispatcher 层的错误编码进 YAR 响应帧（对标 PHP Yar），Transport 层的 I/O 错误返回 nil,err，Facade 层统一返回 true|nil,err。与记忆中的三分类法一致。

---

## 五、命名对比

### 5.1 模块命名

| v4 命名 | 职责 | 业界对标 | 评价 |
|---|---|---|---|
| Server (init.lua) | Facade | Go `http.Server`、PHP `Yar_Server` | 准确 |
| Dispatcher (dispatcher.lua) | 协议核心 | Python `SimpleXMLRPCDispatcher` | 准确 |
| TcpTransport (tcp.lua) | TCP I/O | Go `net.Listener` (部分) | 可接受 |
| HttpTransport (http.lua) | HTTP I/O | Go `http.Handler` (部分) | 可接受 |
| Daemon (daemon.lua) | accept 循环 | Go `net.Listen`+`Serve` | 可接受 |

**评价**：命名整体准确。Dispatcher 对标 Python SimpleXMLRPCDispatcher 是最贴切的——两者职责完全一致（parse request → dispatch to method → render response，无 I/O）。

### 5.2 方法命名

| v4 方法 | 业界对标 | 评价 |
|---|---|---|
| `new(opts, service)` | lua-resty-http `http.new()`, lua-resty-redis `redis.new()` | 准确 |
| `handle(spec)` | Go `Serve()`, PHP `handle()` | 准确 |
| `listen(addr)` | lua-resty-http `httpc:connect()` | 准确 |
| `loop()` | copas `loop()`, Python `serve_forever()` | 准确 |
| `register_service(service)` | Go `Register(recv)`, PHP Yar `new Yar_Server($service)` | 准确 |
| `set_packager(name)` | — | lua-yar 特有，无对标 |
| `set_options(opts)` | — | lua-yar 特有 |
| `setopt(opt, val)` | lua-resty-redis `setopt` | 对标 Lua 生态 |
| `list_methods()` | Python `system.listMethods` | 语义相近 |

**评价**：方法命名与业界对标一致。register_service 对标 Go Register(recv) + PHP Yar new Yar_Server($service)，new/listen/handle/loop 四方法对标 lua-resty-http new/connect + Go Serve/ListenAndServe + copas loop。

---

## 六、缺口与风险

### 6.1 unix:// socket bind 未支持（风险：中）—— ✅ 已修复

> **修复状态**：已在 deep-synthesis-v4.md §6.1 Server:listen() 和 implementation-plan.md §2.2 中修复。listen() 按 protocol 分支：`if protocol == "unix" then Socket.bind_unix(host) else Socket.bind(host, port) end`。文件清单新增 `transport/socket.lua` 更新项（新增 `bind_unix(path)` 函数）。

**问题**：`parse_addr("unix:///path")` 返回 `"unix", path, nil`。但 `listen()` 调用 `Socket.bind(host, port)` —— `Socket.bind` 内部调用 `socket.bind(host, port)`，这是 TCP bind，不支持 unix socket。

**当前 Socket.bind 实现**（`transport/socket.lua:72`）：
```lua
bind = function(host, port)
    local s = socket.bind(host, port)  -- TCP only
    ...
end
```

**影响**：`Server.new():listen("unix:///tmp/yar.sock"):loop()` 会在 bind 时失败或行为异常。

**业界对比**：
- Go: `net.Listen("unix", path)` 显式区分 network 类型
- Python: `socketserver.UnixStreamServer` 独立类
- 客户端 `Transport.get(url)` 已支持 unix://（`transport.lua:37`）

**建议**：listen() 需根据 protocol 分支：
```lua
if protocol == "unix" then
    listen_sock = Socket.bind_unix(host)  -- 新增
else
    listen_sock = Socket.bind(host, port)
end
```

或在 Socket 层新增 `bind_unix(path)` 函数。当前 `socket.unix` 模块已加载（`socket.lua:51`），但只有 `unix()` 客户端连接函数，没有 `bind`。

**取舍**：unix socket 支持是 YAR 协议的合法传输方式（客户端已支持），服务端不支持是不对称的。但 unix socket daemon 使用场景少（标准 Lua 环境），优先级可降低。建议在实现时至少 return nil, "unix socket bind not supported" 明确报错，而不是静默行为异常。

### 6.2 socket_provider 选项丢失（风险：中）—— ✅ 已修复

> **修复状态**：已在 deep-synthesis-v4.md §6.1 Facade set_options 和 implementation-plan.md §2.2 中修复。Facade `set_options` 现在委托 `self.dispatcher:set_options(opts)` 给 Dispatcher，同时 `if opts.socket_provider then Socket.set(opts.socket_provider) end` 处理全局副作用。`new()` 中也通过 `self.dispatcher:set_options(self.opts)` + `Socket.set()` 统一传递。

**问题**：当前 `tcp.lua` 和 `http.lua` 的 `set_options` 对 `socket_provider` 做特殊处理：
```lua
-- 当前 tcp.lua:59 / http.lua:83
elseif k == "socket_provider" then
    Socket.set(v)
```

v4 Facade 的 `set_options` 只对 `packager` 做特殊处理，`socket_provider` 会落入 `self.opts[k] = v` 但永远不会被 `Socket.set()` 应用。

**影响**：OpenResty 环境下注入 cosocket 的能力丢失。虽然 OpenResty 主要走 handle() 宿主模式（不需要 daemon bind），但 `Socket.set()` 也影响客户端 transport。

**建议**：v4 Facade `set_options` 需补回 `socket_provider` 分支：
```lua
function _M:set_options(opts)
    if not opts then return self end
    for k, v in pairs(opts) do
        if k == "packager" then self:set_packager(v)
        elseif k == "socket_provider" then Socket.set(v)
        else self.opts[k] = v end
    end
    return self
end
```

**取舍**：这是实现细节遗漏，不是设计缺陷。但需要在实现时注意。

### 6.3 Daemon 并发模型（风险：低，设计有意为之）

**现状**：Daemon.run 是顺序 accept——一个请求处理完才处理下一个。

**业界对比**：
- Go: goroutine per connection（内置并发）
- Python: ThreadingMixIn（可选线程并发）
- copas: 协程 per connection（自动并发）
- PHP Yar: PHP-FPM 进程级并发（不归 Yar 管）
- yar-c: 顺序（与 v4 一致）

**评价**：v4 的顺序 accept 与 yar-c 一致，定位为 dev/testing。生产并发由 OpenResty（handle 宿主模式）或 copas（handle + copas.addserver）解决。这个分工合理——lua-yar 是协议库/SDK，不是并发框架。

**但需要文档显式标注**：`loop()` 文档应注明 "sequential accept, for dev/testing only. For production concurrency, use OpenResty handle() or copas"。

### 6.4 parse_addr 健壮性（风险：低）—— ✅ 已修复

> **修复状态**：已在 deep-synthesis-v4.md §6.1 parse_addr 中修复。统一 scheme 提取 `string.match(addr, "^([a-z]+)://(.+)$")`。http 协议允许省略端口，默认 80（对标 URL 规范 RFC 3986，非静默 fallback）；tcp 必须显式指定端口。校验链：scheme 合法性 → unix 分支 → host:port 格式（http 无端口时默认 80）→ port 数值有效性。每个失败点 return nil, errmsg。

**问题**：v4 设计中的 parse_addr 示例代码有几个边界问题：

1. `"tcp://0.0.0.0"`（无端口）—— `string.match("0.0.0.0", "^([^:]+):(%d+)$")` 返回 nil，host 为 nil
2. `"tcp://:8888"`（无 host）—— host 为空字符串
3. `"tcp://0.0.0.0:abc"`（非数字端口）—— tonumber 返回 nil，fallback 8888

**建议**：实现时加强校验（http 协议允许省略端口，默认 80，对标 RFC 3986）：
```lua
local function parse_addr(addr)
    local scheme, rest = string.match(addr, "^([a-z]+)://(.+)$")
    if not scheme then return nil, "unsupported addr scheme: " .. addr end
    if scheme ~= "tcp" and scheme ~= "http" and scheme ~= "unix" then
        return nil, "unsupported protocol: " .. scheme
    end
    if scheme == "unix" then
        return "unix", rest, nil
    end
    local host, port_str = string.match(rest, "^([^:]+):(%d+)$")
    if not host then
        -- http 协议允许省略端口，默认 80（RFC 3986 标准，非静默 fallback）
        if scheme == "http" then
            host = string.match(rest, "^([^:]+)$")
            if host then return scheme, host, 80 end
        end
        return nil, "invalid addr format, expected host:port"
    end
    local port = tonumber(port_str)
    if not port then return nil, "invalid port: " .. port_str end
    return scheme, host, port
end
```

**取舍**：这是示例代码，实现时自然会加强。但设计文档应体现校验意图。

### 6.5 hooks 传递路径（风险：低）—— ✅ 已修复

> **修复状态**：已在 deep-synthesis-v4.md §6.1 Facade new() 和 implementation-plan.md §2.2 中修复。`new()` 中 `self.dispatcher:set_options(self.opts)` 将所有 opts（packager/hooks/max_body_len/timeout 等）传递给 Dispatcher。Dispatcher:set_options 内部对 packager 调 set_packager，其余复制到 self.options，handle_message 读 `self.options.hooks` 正常工作。

**现状**：当前 `handle_message` 已有 hooks（on_request/on_response），存储在 `self.options.hooks`。v4 Dispatcher 保留 handle_message 逻辑不变，hooks 存储在 Dispatcher 的 options 中。

**传递路径**：`new(opts, service)` → `self.dispatcher = Dispatcher.new()` → 但 `self.dispatcher.options` 和 `self.opts` 是两个不同的表。hooks 在 `self.opts` 中，但 `handle_message` 读的是 `self.options.hooks`（Dispatcher 的 options）。

**问题**：v4 设计中 Dispatcher.new() 无参，opts 在 Facade 层。但 handle_message 读 `self.options.hooks`（self = Dispatcher）。如果 opts 不传给 Dispatcher，hooks 就丢失了。

**建议**：Dispatcher.new() 需要接收 opts，或 Facade 在 new 后立即 `self.dispatcher:set_options(opts)`。当前 v4 代码只做了 `if opts.packager then self.dispatcher:set_packager(opts.packager) end`——只传了 packager，没传 hooks/timeout/max_body_len 等。

**正确做法**：
```lua
function _M.new(opts, service)
    local self = setmetatable({}, _M)
    self.dispatcher = Dispatcher.new()
    self.opts = opts or {}
    self.dispatcher:set_options(self.opts)  -- 传递所有 opts 给 Dispatcher
    if service then self.dispatcher:register_service(service) end
    return self
end
```

**取舍**：这是设计文档的遗漏，不是架构缺陷。但实现时必须修正，否则 hooks/max_body_len 等配置不生效。

### 6.6 Dispatcher.packager 字段直接访问（风险：低，风格问题）—— ✅ 已修复

> **修复状态**：已在 deep-synthesis-v4.md §5.2/§6.4 和 implementation-plan.md §2.1/§2.4 中修复。Dispatcher 新增 `pack(data)` 方法包装 `self.packager.pack(data)`。Transport 层（http.lua serve/serve_callback）改为 `dispatcher:pack(dispatcher:list_methods())`，不再直接访问 `dispatcher.packager` 字段。

**现状**：v4 设计中 Transport 层直接访问 `dispatcher.packager.pack(...)`——这是字段直接访问，不是方法调用。

**当前代码**：`http.lua:134` `self.packager.pack(self.core:list_methods())` —— 也是字段直接访问。

**业界对比**：
- Go: `ResponseWriter` 是接口，不暴露内部字段
- Python: `dispatcher.encode_introspection()` 封装方法

**评价**：Lua 生态中字段直接访问是常见的（lua-cjson 的 `cjson.encode`、dkjson 的 `json.encode`）。但 Dispatcher 作为协议核心，暴露 packager 字段让 Transport 层直接调用 `dispatcher.packager.pack(...)` 略显粗糙。

**备选方案**：Dispatcher 可封装 `dispatcher:pack(data)` 方法。但这只是风格偏好，不影响正确性。当前直接访问与代码库现有风格一致，可以接受。

---

## 七、总体评估

### 7.1 设计优势

1. **三层分离正确**：Facade/Dispatcher/Transport/Daemon 职责清晰，每个模块单一职责。对标 Go net/http 的 Server/Handler/Listener 分离。

2. **I/O 抽象理论扎实**：从 WSGI/ASGI/Go 提炼出"I/O = 读写回调对"规律，socket 和 data+writer 统一在 handle(spec) 入口。这是 v4 的核心理论贡献。

3. **API 表面最小化**：调用方只感知 1 概念（Server）+ 3 方法（handle/listen/loop）。所有场景 HTTP/TCP/宿主/daemon 对称。心智负担最小。

4. **protocol 从 addr 解析**：消除二次指明冗余，早失败原则。listen 时解析一次，handle 时读 self.protocol。比当前代码（类名选 transport + spec.protocol 二次指定）更简洁。

5. **单路径注册**：register_service 统一入口，对标 Go rpc.Register(recv) + PHP Yar new Yar_Server($service)。比 Python 双路径（register_function + register_instance）更简洁，比 yar-c 逐个 register_handler 更省事。

6. **Dispatcher 命名准确**：对标 Python SimpleXMLRPCDispatcher，职责完全一致。

### 7.2 设计风险

1. **unix:// bind 未支持**（§6.1）——客户端支持但服务端不支持，不对称。需实现时补全或明确报错。

2. **socket_provider 选项丢失**（§6.2）——当前代码有，v4 Facade set_options 遗漏。需实现时补回。

3. **opts 传递给 Dispatcher 不完整**（§6.5）——hooks/max_body_len 等可能丢失。需实现时修正。

4. **Daemon 顺序并发**（§6.3）——有意为之，但需文档显式标注。

5. **parse_addr 健壮性**（§6.4）——示例代码边界处理不足，需实现时加强。

### 7.3 与业界对比总结

| 维度 | v4 设计 | 业界标杆 | 评价 |
|---|---|---|---|
| API 表面 | 1概念+3方法 | Go: 1概念+2方法, lua-resty-http: 1概念+2方法 | v4 多 listen，对标 connect |
| I/O 抽象 | spec Strategy | ASGI 回调对 | 持平 |
| 三层分离 | Facade/Dispatcher/Transport/Daemon | Go Server/Handler/Listener | 持平 |
| 并发模型 | 顺序（生产用 OpenResty/copas） | Go goroutine、copas 协程 | 有意分工，可接受 |
| 错误处理 | 三层分类 + YAR error 帧 | Go http.Error、PHP error body | 持平 |
| 方法注册 | 单路径 register_service | Go/PHP Yar 批量注册 | 持平 |
| protocol 解析 | listen(addr) 解析 | Go 方法名区分 | v4 更简洁 |
| 命名 | Dispatcher | Python SimpleXMLRPCDispatcher | 准确对标 |

### 7.4 结论

v4 设计在 API 表面、I/O 抽象、三层分离、命名对标上与业界标杆持平。理论支撑扎实（WSGI/ASGI/Go 跨语言研究）。6 个缺口中，3 个是实现时需注意的遗漏（socket_provider、opts 传递、parse_addr 健壮性），2 个是有意为之的分工（并发模型、unix socket 优先级），1 个是风格偏好（packager 字段访问）。

**建议**：在实现阶段重点关注 §6.1（unix bind）、§6.2（socket_provider）、§6.5（opts 传递给 Dispatcher）三个遗漏，其余按设计执行。
