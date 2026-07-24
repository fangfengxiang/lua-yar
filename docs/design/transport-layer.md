# 传输层设计决策

传输层是 lua-yar 与外部网络交互的唯一通道。核心设计是 **Provider 抽象**——框架不直接引用 `ngx` 或 luasocket，只依赖 `transport.socket` 抽象层，注入即可适配任意运行时。

---

## 1. 网络层选型：纯 Lua 优先 + Provider 抽象

- **状态**：已实现
- **决策驱动因素**：零依赖、跨运行时、可注入
- **关联决策**：#2（Provider 抽象）、#32（纯协议库定位）

### 背景

YAR 协议需要网络传输能力。Lua 生态有三个候选：luasocket（纯 Lua，同步阻塞）、lua-http（异步，依赖 libevent/libev）、lua-resty-http（OpenResty 专用，基于 cosocket）。选哪一个决定了库的运行时绑定程度。

### 思考与取舍

> "Make it work, make it right, make it fast." — Kent Beck
> "先让它跑起来，再让它正确，最后让它快。" — Kent Beck

选 luasocket 作为默认实现：纯 Lua、无 C 依赖、全平台可用。但 luasocket 同步阻塞，不适合 OpenResty 生产环境。解法不是换库，而是**抽象掉网络层**——`socket.lua` 是传输层唯一的网络抽象点，默认适配 luasocket，注入 cosocket 即用。

备选方案：直接依赖 lua-resty-http（OpenResty 专用）会绑定运行时；直接依赖 lua-http 会引入 libevent/libev 编译依赖。两者都违背"纯协议库"定位。

### 业界参考

- **lua-resty-http**：OpenResty 生态标准 HTTP 客户端，但绑定 ngx cosocket，无法在标准 Lua 环境（lua-eco、Skynet）使用。
- **luasocket**：Lua 社区事实标准网络库，同步阻塞，适合开发/测试/非高并发场景。
- **Kong**：用 lua-resty-http 但封装了 `resty.http` 常量叶子模块，值得借鉴的是常量管理而非架构绑定。

### 代码评价

`socket.lua` 用 `pcall(require, "socket")` 延迟加载 luasocket，失败则 `socket = nil`，`tcp()` 工厂返回错误而非崩溃。`transport.lua` 按 URL scheme 分发到 `Http` 或 `Tcp`，两者都只引用 `Socket` 抽象，不直接引用 `ngx`。当前实现干净，职责清晰。

### 知识领域

1. *Programming in Lua*（Roberto Ierusalimschy）— Lua 模块加载与 `require` 语义
2. *The Pragmatic Programmer*（Hunt & Thomas）— "Tracer Bullets" 原型开发模式

---

## 2. Provider 抽象：socket.lua wrap() + duck typing

- **状态**：已实现
- **决策驱动因素**：跨运行时、可注入、零依赖
- **关联决策**：#1（网络层选型）、#4（HTTP Provider 委托）

### 背景

luasocket 和 cosocket 的 API 不完全一致：luasocket 用 `settimeout(seconds)`，cosocket 用 `settimeouts(connect, send, read)` 毫秒；luasocket 无 `setkeepalive`，cosocket 有连接池。需要一个统一抽象让上层传输代码无感知切换。

### 思考与取舍

> "Program to an interface, not an implementation." — Gang of Four
> "面向接口编程，而非面向实现。" — 四人组

`wrap(s)` 将 luasocket 对象包装为"毫秒超时 + cosocket 方法名"契约：`settimeout(ms)` 内部 `/1000` 转秒。`set_timeouts` / `release` / `poolable` 用 **duck typing**——检测 `settimeouts` / `setkeepalive` 方法是否存在，有则用三段超时/归池，无则降级为单一超时/close。

备选方案：定义 `SocketProvider` 接口类要求实现方实现全部方法。但 luasocket 天然不具备 `setkeepalive`，强制实现会引入空函数。duck typing 更轻量，零成本适配。

### 业界参考

- **lua-resty-http**：内部直接调用 `ngx.socket.tcp()`，无抽象层，绑定 OpenResty。
- **Kong**：用 `kong.tools.utils` 封装 socket 操作，但同样绑定 ngx。
- **luasocket**：本身无 Provider 概念，是"被适配"方。

### 代码评价

`socket.lua` 的 `wrap()` / `wrap_server()` 闭包包装干净。`set_timeouts` 的 duck typing 检测 `sock.settimeouts` 优先、`sock.settimeout` 降级，逻辑清晰。`poolable(sock)` 返回 `sock.setkeepalive ~= nil`，用于决定 `Connection` 头默认值（keep-alive 或 close），是优雅的运行时自适配。

### 知识领域

1. *Design Patterns: Elements of Reusable Object-Oriented Software*（GoF）— "Program to an interface" 原则
2. *Patterns of Enterprise Application Architecture*（Martin Fowler）— Gateway / Adapter 模式

---

## 3. 三层分离：handle_message / handle_connection / run

- **状态**：已实现
- **决策驱动因素**：可维护性、可测试性、跨运行时
- **关联决策**：#31（跨运行时设计）、#32（纯协议库定位）

### 背景

服务端需要同时处理"协议解析"和"网络 I/O"。如果混在一起，换运行时（luasocket → cosocket → lua-eco）就要重写协议逻辑。

### 思考与取舍

> "Separation of concerns." — Edsger Dijkstra
> "关注点分离。" — Edsger Dijkstra

三层分离：
- `handle_message(data)` — 纯协议，接收二进制消息，返回二进制响应。无 I/O、无 yield、可重入。
- `handle_connection(client)` — I/O 层，从 socket 读数据交给 `handle_message`，写回响应。
- `run(addr)` — accept 循环，监听端口，每连接调用 `handle_connection`。

`handle_message` 是核心契约，任意运行时（OpenResty `content_by_lua`、lua-eco 协程、Skynet）可直接调用它，无需适配。

### 业界参考

- **yar-c**（C 实现）：`yar_server` 混合了 accept + 协议处理，换传输方式需大改。
- **gRPC-go**：`grpc.Server` 分离 `transport` 和 `service`，但绑定 Go runtime。
- **PHP Yar**：`Yar_Server` 只跑在 PHP 运行时内，无跨运行时需求。

### 代码评价

`server/init.lua` 的 `handle_message` 完全无 I/O，可被任意协程调用。`server/http.lua` 和 `server/tcp.lua` 的 `handle_connection` 只管 HTTP/TCP 帧读写，协议派发委托给 `self.core:handle_message`。`run` 是 luasocket 顺序 accept 循环（注释明确"for dev/testing only"），生产环境用 OpenResty 或协程运行时调度 `handle_connection`。分层干净，注释到位。

### 知识领域

1. *The Mythical Man-Month*（Fred Brooks）— 概念完整性与关注点分离
2. *Clean Architecture*（Robert Martin）— Entity / Use Case / Interface Adapter 分层

---

## 4. HTTP Provider 委托：类级 + 实例级 + 默认手动实现

- **状态**：已实现
- **决策驱动因素**：跨运行时、可注入、兼容性
- **关联决策**：#2（Provider 抽象）、#5（HTTPS 支持）

### 背景

默认的 `manual_request` 手写 HTTP 实现功能完整（支持 proxy、resolve、HTTPS、chunked），但在 OpenResty 生产环境，用户更想用 `lua-resty-http`（cosocket 原生、连接池、更健壮的 HTTP 解析）。需要一个注入点让用户替换 HTTP 实现。

### 思考与取舍

> "Dependency Injection is about connecting clients to services." — Martin Fowler
> "依赖注入就是将客户端与服务连接起来。" — Martin Fowler

三层 fallback：
1. 实例级 `transport_opts.http_provider`（per-Client 覆盖）
2. 类级 `http_provider`（`Http.set_provider()` 进程级注入）
3. 默认 `manual_request`（手写 HTTP）

provider 是**函数**而非对象：`provider(url, opts) → body, err`。lua-yar 将嵌套选项展平为 flat opts 传给 provider，provider 不感知 yar 选项结构。这比"要求 provider 实现 Http 接口类"更轻量。

### 业界参考

- **lua-resty-http**：提供 `httpc:request(uri, opts)` 接口，天然适配 provider 函数签名。
- **Kong**：`kong.resty.http` 封装 lua-resty-http，但无注入点，绑定单一实现。
- **Python requests**：`requests.Session.adapters` 允许注入 transport adapter，但对象级而非函数级。

### 代码评价

`http.lua` 的 `send()` 方法实现三层 fallback 逻辑清晰。`manual_request` 作为默认实现功能完整（proxy CONNECT 隧道、chunked 解码、大小写不敏感头覆盖）。provider 函数签名简单，lua-resty-http 适配器约 37 行即可桥接。展平 opts 时透传 `ssl_verify`、`keepalive` 等参数，设计周到。

### 知识领域

1. *Inversion of Control Containers and the Dependency Injection Pattern*（Martin Fowler）— DI 原理
2. *Patterns of Enterprise Application Architecture*（Martin Fowler）— Service Stub / Gateway 模式

---

## 5. HTTPS 支持：ssl_verify 默认 true

- **状态**：已实现（Breaking Change）
- **决策驱动因素**：安全性
- **关联决策**：#4（HTTP Provider 委托）、#7（proxy 选项）

### 背景

YAR over HTTPS 需要 TLS 握手。`sslhandshake` 的 `verify` 参数控制是否验证服务端证书。默认 false 则接受任意证书（中间人攻击风险），默认 true 则自签证书场景需显式关闭。

### 思考与取舍

> "Secure by default." — 安全工程原则
> "默认安全。" — 安全工程原则

`client.lua` 默认 `ssl_verify = true`，`http.lua` 用 `transport_opts.ssl_verify ~= false` 判定（只有显式 false 才关闭）。这是 **Breaking Change**——从"默认不验证"到"默认验证"，自签证书的存量用户需显式设 `ssl_verify = false`。

备选方案：默认 false（向后兼容）。但安全默认应优先于兼容性——lua-resty-http 和 luasec 均默认验证证书。

### 业界参考

- **lua-resty-http**：`ssl_verify` 默认 true（`connect_options.ssl_verify` 未设时走 luasec 默认 true）。
- **luasec**：`ssl.wrap(sock, params)` 中 `mode` 和 `verify` 默认要求证书验证。
- **curl**：默认验证证书，`-k` 才跳过。

### 代码评价

`http.lua` 的 HTTPS 实现完整：直连时 `sslhandshake(nil, host, ssl_verify)`；HTTPS over proxy 时先发 CONNECT 隧道请求，代理回 200 后再 sslhandshake（SNI 用目标 host 而非代理 host）。注释明确"生产环境必须开启证书验证"。provider 路径透传 `ssl_verify` 给第三方 HTTP 库。

### 知识领域

1. *Release It! Design and Deploy Production-Ready Software*（Michael Nygard）— 安全默认与故障隔离
2. RFC 2818 — *HTTP Over TLS*，证书验证规则

---

## 6. resolve 选项：自定义 host→IP 映射

- **状态**：已实现
- **决策驱动因素**：可测试性、可注入、兼容性
- **关联决策**：#7（proxy 选项）、#4（HTTP Provider 委托）

### 背景

测试或灰度场景需要将请求指向特定 IP（如本地 mock 服务、灰度实例），但 `Host` 头仍保持原域名。curl 的 `--resolve host:port:ip` 和 PHP Yar 的 `YAR_OPT_RESOLVE` 都解决此问题。

### 思考与取舍

> "Indirection is the root of all complexity." — Andrew Koenig
> "间接是所有复杂性的根源。" — Andrew Koenig

`resolve.lua` 的 `apply_resolve(host, port, resolve_str)` 支持两种格式：
- curl 风格 `host:port:ip`（同时匹配 host 和 port）
- PHP 风格 `host:ip`（仅匹配 host）

只替换连接目标的 IP，`Host` 头保持原 host。这是"最小间接"——不改 DNS 解析流程，只在连接前做一次映射查表。

### 业界参考

- **curl**：`--resolve host:port:ip` 选项，语义完全一致。
- **PHP Yar**：`YAR_OPT_RESOLVE` 选项，`host:ip` 格式。
- **nginx**：`proxy_pass` + `resolver` 组合实现类似效果，但配置更重。

### 代码评价

`resolve.lua` 实现简洁（26 行）。curl 格式匹配成功后 port 不匹配则直接返回原 host（不回退到 PHP 格式，避免畸形 IP）。HTTP 和 TCP 传输层都调用 `Resolve.apply_resolve`，provider 路径透传 `resolve` 给第三方库。逻辑正确，边界处理到位。

### 知识领域

1. RFC 7230 — *HTTP/1.1 Message Syntax*，Host 头语义
2. curl 文档 — `--resolve` 选项规范

---

## 7. proxy 选项：HTTP 代理 + HTTPS CONNECT 隧道

- **状态**：已实现
- **决策驱动因素**：兼容性
- **关联决策**：#5（HTTPS 支持）、#6（resolve 选项）

### 背景

企业内网常需通过 HTTP 代理访问外部服务。HTTP 代理走绝对 URI 请求行；HTTPS 代理需先 CONNECT 建隧道，再 TLS 握手。

### 思考与取舍

> "Be liberal in what you accept, conservative in what you send." — Jon Postel
> "接收时宽容，发送时保守。" — Jon Postel

`parse_proxy(proxy_str)` 支持多种格式：`http://host:port`、`host:port`、`http://host`、`host`（默认端口 8080）。直连用相对 path 请求行，走代理用绝对 URI（省略默认端口）。HTTPS over proxy 时先发 CONNECT 请求，读代理响应状态行必须 200，消费剩余 headers 后再 sslhandshake。

### 业界参考

- **curl**：`-x proxy` 或 `http_proxy` 环境变量，CONNECT 隧道实现是事实标准。
- **PHP Yar**：`YAR_OPT_PROXY` 选项。
- **lua-resty-http**：无内置 proxy 支持，需用户自行处理。

### 代码评价

`http.lua` 的 `manual_request` 完整实现了 HTTP/HTTPS over proxy 两种路径。CONNECT 请求用 authority 形式（`host:port`），`Host` 头同步。隧道建立后 TLS 握手与直连完全一致（SNI 用目标 host）。请求行绝对 URI 省略默认端口的逻辑正确。代码约 50 行覆盖了代理的全部边界。

### 知识领域

1. RFC 7230 — *HTTP/1.1 Message Syntax*，绝对 URI 请求行
2. RFC 7235 — *Authentication*，代理认证（预留扩展）

---

## 8. persistent 连接：socket 缓存 + 归池

- **状态**：已实现
- **决策驱动因素**：性能
- **关联决策**：#2（Provider 抽象）

### 背景

每次 RPC 调用都新建 TCP 连接会增加握手开销。persistent 模式缓存 socket 跨 call 复用；非 persistent 模式用完归还连接池（cosocket）或关闭（luasocket）。

### 思考与取舍

> "The fastest I/O is no I/O." — Mythical Man-Month
> "最快的 I/O 是不 I/O。" — 人月神话

`client.lua` 的 `persistent` 选项：true 时缓存 `_transport` 实例，socket 跨 call 复用；false 时每次 call 新建 transport，用完 `Socket.release(sock, idle_timeout, pool_size)` 归池。`tcp.lua` 的 `self.sock` 缓存 persistent socket，发送失败时关闭旧连接重建。`keepalive` 子组 `{pool_size, idle_timeout}` 透传给 cosocket `setkeepalive(max_idle, pool_size)`。

### 业界参考

- **lua-resty-http**：`httpc:connect` + `httpc:set_keepalive`，连接池复用。
- **PHP Yar**：`YAR_OPT_PERSISTENT` 选项，持久连接。
- **Kong**：cosocket 连接池是 OpenResty 的内置能力。

### 代码评价

`tcp.lua` 的 persistent 逻辑处理了边界：缓存的 socket 发送失败时关闭重建；发送成功但接收失败时关闭不缓存（服务端可能已处理请求，不可重发）；partial send（`sent > 0`）时返回错误不重试。`client.lua` 在 transport 错误时清空 `_transport` 缓存并 close。逻辑健壮，考虑了连接复用的全部失败场景。

### 知识领域

1. *Release It! Design and Deploy Production-Ready Software*（Michael Nygard）— 连接池与故障隔离
2. *High Performance MySQL*（Zawodny et al.）— 连接复用性能模型

---

## 9. Unix socket：复用 TCP 传输层

- **状态**：已实现
- **决策驱动因素**：代码复用
- **关联决策**：#2（Provider 抽象）、#3（三层分离）

### 背景

Unix domain socket 是本机进程间通信的高效方式（无 TCP 握手开销）。YAR 协议基于流式 socket，Unix socket 也是流式，帧协议完全相同。

### 思考与取舍

> "Don't repeat yourself." — Hunt & Thomas
> "不要重复自己。" — Hunt & Thomas

`transport.get(url)` 对 `unix://` scheme 返回 `Tcp`（而非新建 Unix 传输类）。`tcp.lua` 的 `open()` 解析 `unix_path`，`send()` 用 `Socket.unix()` 工厂创建 socket，`connect(unix_path)` 连接。YAR 帧协议（`Framing.receive_message`）完全复用，零重复代码。

### 业界参考

- **PHP Yar**：支持 Unix socket 传输。
- **nginx**：`listen unix:/path` 与 TCP listen 共享 upstream 协议处理。
- **lua-resty-http**：不直接支持 Unix socket，需用户自行处理。

### 代码评价

`transport.lua` 用一行 `string.match(url, "^unix://")` 将 Unix socket 路由到 Tcp，是"流式 socket 协议相同"认知的简洁体现。`tcp.lua` 的 `self.unix_path` 分支在 `open` / `send` / `connect` 三处保持一致。`socket.lua` 的 `unix()` 工厂用 luasocket 的 `socket.unix` 模块，cosocket 注入时 provider 需自行包装 path→`"unix:"..path` 翻译。设计干净。

### 知识领域

1. *The Pragmatic Programmer*（Hunt & Thomas）— DRY 原则
2. POSIX Standard — `AF_UNIX` 流式 socket 语义

---

## 10. 常量叶子模块：transport/constants.lua

- **状态**：已实现
- **决策驱动因素**：可维护性、无循环依赖
- **关联决策**：#1（网络层选型）

### 背景

传输层的 `DEFAULT_TIMEOUT`、`HTTP_PORT`、`HTTPS_PORT` 等常量被 `http.lua`、`tcp.lua`、`client.lua` 共享。放哪里？集中到 `init.lua` 会引入循环依赖（`init.lua` require `client` → `client` require 常量 → 常量 require `init.lua`）。

### 思考与取舍

> "Constants should be managed by each package, not centralized." — Lua 业界惯例
> "常量应由各包自管理，不集中化。" — Lua 业界惯例

`transport/constants.lua` 是**叶子模块**——零依赖、无循环风险。`http.lua`、`tcp.lua`、`client.lua` 各自 `require("yar.transport.constants")` 引用。参考 lua-resty-http 的 `resty.http_const` 模式。语义不同的同名值各自定义：`DEFAULT_TIMEOUT`（传输层收发超时）vs `server/constants.lua` 的 `DEFAULT_TIMEOUT`（服务端处理超时），各自管理，不强求复用。

备选方案：集中到 `init.lua`。但会引入"惰性 require 绕循环依赖"的反模式——那是绕远路。

### 业界参考

- **lua-resty-http**：`resty.http_const` 叶子模块，包内共享常量集中管理。
- **lua-resty-uuid**：常量定义在模块内部局部变量，不跨包共享。
- **Kong**：`kong.constants` 集中常量，但 Kong 是平台而非 SDK，定位不同。

### 代码评价

`constants.lua` 50 行，定义 21 个常量，覆盖超时、端口、HTTP 状态码、方法、内容类型、Connection 头值、原因短语表、报文行定界符，零依赖。常量命名遵循三条件规则：按功能命名（`HTTP_LINE_DELIMITER`，非 `HTTP_CRLF`）、消除魔数（`HTTP_OK = 200`）、有限集枚举（`HTTP_METHOD_GET/POST/CONNECT`）；自文档化值保持字面量（`"HTTP/1.1"`、`"https"`）。`server/constants.lua` 同为叶子模块，定义 `DEFAULT_TIMEOUT`、`DEFAULT_MAX_BODY_LEN`、`MAX_HEADER_COUNT`，遵循 Lua 业界惯例。

### 知识领域

1. *Programming in Lua*（Roberto Ierusalimschy）— Lua 模块加载与 `require` 语义、循环依赖机制
2. lua-resty-http 源码 — `resty.http_const` 叶子模块模式
