# 服务端层设计决策

服务端核心（`server/init.lua`）是纯协议处理器，不感知任何传输层。HTTP/TCP 服务端只负责 I/O，协议派发委托给 `handle_message`。

---

## 11. packager 自适应：registry + register

- **状态**：已实现
- **决策驱动因素**：可扩展性、兼容性
- **关联决策**：#21（registry/adapter 模式）

### 背景

YAR 协议头首 8 字节是 packager 名称（如 "JSON"、"MSGPACK"）。服务端需要按客户端声明的 packager 解析 body，而不是固定用一种。同时用户可能想用 cjson、cmsgpack 等 C 扩展加速，需要注册入口。

### 思考与取舍

> "Favor object composition over class inheritance." — Gang of Four
> "优先使用对象组合而非类继承。" — 四人组

`packager.lua` 维护 `registry` 表，`register(name, lib)` 注册（自动检测 `pack/unpack` 或 `encode/decode` 接口，构造 adapter），`get(name)` 按名称获取（大小写不敏感）。

`server/init.lua` 的 `handle_message` 从消息头部读取 packager 名称，`Packager.get(name)` 获取对应实现。未知 packager 回退到 `self.packager`（最佳努力）。

### 业界参考

- **yar-c**：`yar_packager` 注册表 + `yar_packager_get(name)`，C 实现。
- **PHP Yar**：`Yar_Packager` 工厂 + `Yar_Packager::factory($name)`。
- **cjson**：`require("cjson")` 直接用，无注册机制。

### 代码评价

`packager.lua` 的 registry 模式干净。`register` 的 adapter 构造逻辑清晰：检测 lib 方法、构造 `{name, pack, unpack}` 表、自动注册。`server/init.lua` 的 `handle_message` 中 `Packager.get(name)` 失败时回退到 `self.packager`，错误响应也用此 packager 渲染（注释说明"最佳努力策略"）。设计周到。

### 知识领域

1. *Design Patterns*（GoF）— Adapter / Registry 模式
2. *Patterns of Enterprise Application Architecture*（Martin Fowler）— Registry / Plugin 模式

---

## 12. body 长度限制：双向校验

- **状态**：已实现
- **决策驱动因素**：安全性
- **关联决策**：#16（framing 帧协议）

### 背景

恶意客户端可发送超大 body 导致服务端内存耗尽（DoS）。需要在接收侧和发送侧都做长度校验。

### 思考与取舍

> "Defense in depth." — 安全工程原则
> "纵深防御。" — 安全工程原则

双层校验：
- **接收侧**：`server/init.lua` 的 `handle_message` 校验 `#data > max_body_len + 90`（默认 1MB，对齐 nginx `client_max_body_size`）。`framing.lua` 的 `receive_message` 校验 `header.body_len > max_body_len`（默认 10MB，防止恶意大 body）。
- **发送侧**：`framing.lua` 的 `check_body_len` 在发送前解析 header 提取 `body_len`，超限则拒绝发送。

两道防线各自独立，任何一道被绕过另一道仍生效。

### 业界参考

- **nginx**：`client_max_body_size` 默认 1MB，413 拒绝。
- **PHP Yar**：无内置 body 长度限制。
- **yar-c**：无内置 body 长度限制。
- **lua-resty-http**：`max_body_size` 选项。

### 代码评价

`server/init.lua` 默认 `DEFAULT_MAX_BODY_LEN = 1024 * 1024`（1MB），`framing.lua` 默认 `DEFAULT_MAX_BODY_LEN = 10 * 1024 * 1024`（10MB）。两者默认值不同是有意的——服务端入口更严格（1MB），传输层更宽松（10MB）作为兜底。`server/http.lua` 在读取 body 前用 `Content-Length` 预校验，超限直接返回 413 不读 body。`tcp.lua` 的 `send()` 在发送前调用 `check_body_len`。纵深防御完整。

### 知识领域

1. *Release It!*（Michael Nygard）— 纵深防御与资源限制
2. OWASP — *Input Validation Cheat Sheet*

---

## 13. method memoize：构造时建立方法表

- **状态**：已实现
- **决策驱动因素**：性能
- **关联决策**：#3（三层分离）

### 背景

服务端每次请求需要根据 method 名查找对应的 Lua 函数。如果每次都遍历 service 表，高频调用时会有不必要的开销。

### 思考与取舍

> "Premature optimization is the root of all evil." — Donald Knuth
> "过早优化是万恶之源。" — Donald Knuth

`Server.new(service)` 构造时调用 `collect_methods(service)` 一次性遍历 service 表，收集所有 `type(func) == "function"` 且 `name` 不以 `_` 开头的字段到 `self.methods` 表。后续 `handle_message` 中 `self.methods[request.method]` 是 O(1) 哈希查找，不再每请求遍历 service。

### 业界参考

- **PHP Yar**：`Yar_Server` 构造时反射类方法，类似 memoize。
- **yar-c**：`yar_server_register_handler` 手动注册，无自动收集。
- **Kong**：plugin loader 启动时加载全部插件，运行时按名查找。

### 代码评价

`server/init.lua` 的 `collect_methods` 函数简洁（10 行），支持 table（收集公共方法）和 function（注册为 "default"）两种 service 形式。`self.methods[name] = func` 在 `register_service()` 和 `register()` 时增量更新。注释明确"memoize：不再每请求遍历 service"。实现正确，开销前置到构造时。

`register(name, func)` 单方法注册 API 对标 yar-c `yar_server_register_handler` 和 Python `SimpleXMLRPCServer.register_function`，与 `register_service`（批量）互补。`is_valid_method_name` 校验方法名（字母数字+下划线，不以 `_` 开头），编程错误用 `error(msg, 2)` fail-fast。`register_service` 信任 service 对象键名（仅 `^_` 过滤），`register` 接受外部 name 字符串（严格校验字符集），校验严格度不对称是有意设计。

### 知识领域

1. *The Art of Computer Programming*（Donald Knuth）— 优化时机与算法复杂度
2. *Programming in Lua*（Roberto Ierusalimschy）— Lua 表的哈希查找语义

---

## 14. pcall 保护：解析/调用/渲染全包裹

- **状态**：已实现
- **决策驱动因素**：健壮性
- **关联决策**：#25（结构化 Error 对象）、#28（hooks 机制）

### 背景

服务端处理请求时有多个可能抛错的环节：packager.unpack（畸形数据）、用户方法调用（业务异常）、Protocol.render（渲染失败）。任何一个抛错如果不捕获，会导致连接断开或进程崩溃。

### 思考与取舍

> "Fail fast, fail safe." — 工程原则
> "快速失败，安全失败。" — 工程原则

`handle_message` 中三处 pcall：
1. `pcall(Protocol.parse, data, packager)` — 解析畸形数据可能抛错
2. `pcall(func, unpack(args))` — 用户方法可能抛业务异常
3. `pcall(Protocol.render, resp, packager)` — 渲染响应可能抛错

每个 pcall 失败后都构造错误响应而非崩溃。解析失败返回错误帧；方法异常返回 `EXCEPTION` 错误；渲染失败返回 `nil, err` 由上层处理。`server/http.lua` 和 `server/tcp.lua` 的 `run()` 还用 `pcall(self.handle_connection, ...)` 包裹连接处理，handler 错误只记日志不断进程。

### 业界参考

- **PHP Yar**：`try/catch` 包裹方法调用，异常转为错误响应。
- **yar-c**：`yar_server_handle` 中 `setjmp/longjmp` 处理异常。
- **Kong**：`pcall` 包裹 plugin 执行，错误记日志后继续。

### 代码评价

`server/init.lua` 的三处 pcall 覆盖了全部抛错路径。错误响应统一用 `Response.new({id=0}):set_error(msg)` 构造，渲染后返回二进制帧。`server/http.lua` 的 `run()` 用 `pcall(function() self:handle_connection(client) end)` 包裹，handler 错误记 `Log.error` 后 `client:close()` 继续下一个连接。`server/tcp.lua` 同理。错误隔离完整，单请求异常不影响其他请求。

### 知识领域

1. *Release It!*（Michael Nygard）— 故障隔离与 Bulkhead 模式
2. *Site Reliability Engineering*（Google）— 错误处理与容错

---

## 38. 服务端并发模型：run() 顺序阻塞，并发交给运行时

- **状态**：已采纳（不内置协程调度器，保持现状）
- **决策驱动因素**：职责单一、运行时无关
- **关联决策**：#3（三层分离）、#31（跨运行时设计）、#32（纯协议库定位）

### 背景

`server/http.lua` 和 `server/tcp.lua` 的 `run()` 是顺序阻塞 accept 循环——一个慢请求会阻塞所有后续连接。`handle_connection` 已设计为协程安全：只依赖传入 client 的 `receive/send/close` 鸭子接口，不碰全局状态；`core:handle_message` 无 I/O、纯协议计算、可重入。`example/` 目录已提供 5 种协程并发实现（纯原生 coroutine、copas、lua-eco、Skynet、OpenResty）。问题：是否在 `run()` 内置原生协程调度器，让用户开箱即用？

### 思考与取舍

> "Do one thing and do it well." — Unix 哲学
> "做好一件事。" — Unix 哲学

不内置，理由有五：

1. **职责单一**——协议库的职责是协议编解码与帧处理，不是并发调度。调度器是独立领域，有自己的正确性难题（select 边界、协程错误隔离、socket 清理、定时器、连接池）。内置等于越界。
2. **运行时无关**（原则一）——内置调度器等于默认绑定一种并发模型。用户可能已有 copas / lua-eco / OpenResty 运行时，内置调度器反而重复造轮子。
3. **业界共识**——copas 把调度器做成独立库（luasocket 不内置）；lua-eco / Skynet 是独立运行时；lua-resty-http 不内置 server 调度。协议/网络库不内置调度器是业界惯例。
4. **接入门槛足够低**——`handle_connection` 协程安全已足够，用户接入任意运行时只需 3-5 行胶水代码（`example/server_coroutine.lua` 用 127 行实现完整纯原生协程调度器即为证明）。
5. **维护负担**——自研调度器需充分测试与长期维护，偏离库的核心价值。

取舍：`run()` 保持顺序阻塞（dev/testing 定位），生产并发由用户选择运行时。代价是用户需写少量胶水代码或引第三方库——但这正是"纯协议库"定位的应有之义。

### 业界参考

- **copas**：独立协程调度器库，luasocket 不内置 server 调度。
- **lua-eco**：独立运行时（epoll + coroutine），协议库不绑定。
- **lua-resty-http**：不内置 server，靠 OpenResty `content_by_lua` 调度。
- **Skynet**：独立 Actor 模型运行时，服务逻辑不内置调度。

### 代码评价

`run()` 注释明确标注定位——`http.lua` 的 `run()` 写 "for dev/testing only: single-threaded sequential accept" 并指向 "a coroutine runtime (see example/server_coroutine.lua)"；`tcp.lua` 的 `run()` 写 "for concurrency use lua-eco / Skynet / OpenResty to schedule handle_connection"。`handle_connection` 注释写 "runnable by any coroutine runtime ... core handle_message is I/O-free and coroutine-safe"。`example/server_coroutine.lua` 用 127 行纯原生 `coroutine` + `socket.select` 实现完整调度器，证明接入门槛低。5 种 example 覆盖主流运行时，文档完备。设计自洽。

### 知识领域

1. *The Art of Unix Programming*（Eric Raymond）— Do one thing well 原则
2. *A Philosophy of Software Design*（John Ousterhout）— 深模块与浅模块、职责单一

---

## 39. HTTP 报文构建：常量管理 + table.concat 优化

- **状态**：已实现
- **决策驱动因素**：可维护性、性能、一致性
- **关联决策**：#10（常量叶子模块）、#3（三层分离）、#30（LuaLS 类型标注）

### 背景

`server/http.lua` 和 `transport/http.lua` 构建 HTTP 报文时存在三个问题：

1. **魔数散落**——HTTP 状态码（`200`、`400`、`405`）、方法（`"POST"`、`"GET"`）、内容类型（`"application/octet-stream"`）、连接头值（`"keep-alive"`、`"close"`）、头数量上限（`100`）等字面量散落在代码各处，不自文档化，修改时需全文搜索。
2. **`..` 拼接性能**——`http_response` 函数用 `string.format` 格式串拼接 11 个片段，每次调用解析格式串 + 分配中间字符串；`manual_request` 的 POST 请求行用 `..` 链式拼接，O(n²) 中间分配。
3. **常量命名按值**——`HTTP_CRLF = "\r\n"` 按值命名（CRLF），而非按功能命名（行定界符），常量名是值的同义反复。

### 思考与取舍

> "Make the common case fast." — 计算机体系结构原则
> "让常见情况快。" — 计算机体系结构原则

#### 重构目标

1. 建立常量定义判定规则，消除"凭感觉定义常量"的随意性。
2. 将散落的 HTTP 字面量集中到叶子模块，统一管理。
3. 对齐 lua-resty-http 的 `table.concat` 报文构建模式。
4. 消除 `server/http.lua` 中重复的 send + error check 模式。

#### 常量定义三条件规则

一个值是否应定义为常量，取决于是否满足以下三条件之一：

1. **按功能命名** — 常量名描述值的*功能/用途*，非值本身。如 `HTTP_LINE_DELIMITER`（命名"定界符"功能，不是"CRLF"值）。
2. **消除魔数** — 值本身不自文档化，不查文档无法理解含义。如 `HTTP_OK = 200`（200 是魔数）、`MAX_HEADER_COUNT = 100`。
3. **有限集枚举** — 值属于标准化的有限集合，常量作为枚举值使集合显式。如 `HTTP_METHOD_GET/POST/CONNECT`（RFC 7231 §4）。

**不满足任一条件的值保持字面量**——值自文档化、不属于有限集、常量名只能是值的同义反复。如 `"HTTP/1.1"`（自文档化，`HTTP_VERSION_1_1` 名=值同义反复）、`"https"`（scheme 不是有限集）。

关键区分：`HTTP_LINE_DELIMITER` 之所以成立，是因为它按*功能*命名（定界符），不是按*值*命名（CRLF）。`HTTP_VERSION` 不成立，因为常量名只能按值命名，没有功能抽象层。

#### table.concat 替代 .. 拼接

`..` 每次拼接创建中间字符串，n 段拼接 O(n²) 分配；`table.concat` 一次分配 O(n)。性能交叉点约 5-6 段。HTTP 报文构建（状态行 + 多个头 + 空行 + body）通常 10+ 段，远超交叉点。

对标 lua-resty-http：请求组装用 `table.concat`，单行 header 用 `..`。lua-yar 对齐此模式——`http_response` 函数 11 段用 `table.concat`，单行 header 拼接仍用 `..`。

#### 重构前后对比

| 维度 | 重构前 | 重构后 |
|------|--------|--------|
| 常量数量 | 5 个（timeout/port 为主） | 21 个（覆盖状态码/方法/内容类型/连接头/原因短语/定界符） |
| `"\r\n"` | `HTTP_CRLF`（按值命名） | `HTTP_LINE_DELIMITER`（按功能命名） |
| `"HTTP/1.1"` | `HTTP_VERSION` 常量 | 字面量（自文档化，不定义常量） |
| 状态码 | `200`/`400`/`405` 魔数 | `HTTP_OK`/`HTTP_BAD_REQUEST`/`HTTP_METHOD_NOT_ALLOWED` |
| 头数量上限 | `100` 魔数 | `MAX_HEADER_COUNT` 常量 |
| 报文构建 | `string.format` / `..` 链式 | `table.concat`（≥6 段）/ `..`（单行） |
| `CONTENT_TYPE` 导出 | `transport/http.lua` 导出别名 | `TransportConst.HTTP_CONTENT_TYPE_OCTET_STREAM`（叶子模块直引） |
| `send_response` | 每处 `sock:send(http_response(...))` + 错误检查 | 集中 helper 函数 |

#### 带来收益

- **可读性**——`HTTP_OK` 比 `200` 自文档化；`MAX_HEADER_COUNT` 比 `100` 语义明确；`HTTP_LINE_DELIMITER` 比 `HTTP_CRLF` 表达用途而非值。
- **可维护性**——常量集中在叶子模块（`transport/constants.lua`、`server/constants.lua`），修改单一定义点，全文引用自动生效。
- **性能**——`table.concat` 避免 O(n²) 中间字符串分配，对高频 RPC 调用有 measurable 收益。
- **一致性**——HTTP 常量统一管理，对标 lua-resty-http `resty.http_const` 模式；`send_response` helper 消除重复的 send + error check 模式。

备选方案：保持 `string.format` 格式串拼接。但格式串解析开销高于 `table.concat`，且格式占位符（`%d`、`%s`）不如直接拼接可读。

### 业界参考

- **lua-resty-http**：请求组装用 `table.concat`，单行 header 用 `..`，`"\r\n"` 硬编码内联（不定义定界符常量）。lua-yar 的 `HTTP_LINE_DELIMITER` 比标杆更严格，但符合三条件规则之"按功能命名"。
- **dkjson**：JSON 编码用 `table.concat` 收集片段，非 `..` 链式。
- **nginx**：HTTP 状态码、方法定义为常量（`NGX_HTTP_OK` 等），魔数不散落。

### 代码评价

`transport/constants.lua` 50 行 21 个常量，命名遵循三条件规则。`server/http.lua` 的 `http_response` 用 `table.concat` 拼接 11 段，`send_response` helper 集中 send + error check。`transport/http.lua` 的 CONNECT/POST 请求组装用 `table.concat`，单行 header 拼接用 `..`。`server/constants.lua` 新增 `MAX_HEADER_COUNT = 100`。`init.lua` 直接引用 `TransportConst.HTTP_CONTENT_TYPE_OCTET_STREAM`，移除了 `transport/http.lua` 的 `CONTENT_TYPE` 导出（消除间接依赖）。86 个测试全部通过，无回归。

### 知识领域

1. *Programming in Lua*（Ierusalimschy）— Lua 字符串不可变性 + `table.concat` 性能特征
2. lua-resty-http 源码 — `table.concat` 请求组装模式 + `resty.http_const` 常量管理
3. RFC 7230 — *HTTP/1.1 Message Syntax*，CRLF 定界符语义（§3.5）

---

## 40. 构造器参数顺序：service 在前，opts 在后

- **状态**：已实现
- **决策驱动因素**：API 易用性、身份属性优先原则
- **关联决策**：#13（method memoize，Server.new(service)）、#38（并发模型）、#3（三层分离）

### 背景

`Server.new(opts, service)` 的参数顺序将配置项（opts，决定"怎么工作"）放在身份属性（service，决定"是什么"）之前。这导致常见用法 `Server.new(nil, service)` 必须传 `nil` 占位才能到达 service 参数——项目中 50+ 个调用点有 48 个传了 `nil`，证明当前顺序与实际使用模式相反。

### 思考与取舍

> "The most important parameter should come first."
> "最重要的参数应该排在前面。"
> — API 设计惯例

跨语言 RPC 库调研分两阵营：

- **阵营 A**（构造器不接 service）：Go net/rpc（`rpc.Register(recv)` 独立注册）、gRPC（`RegisterService(ss, ...)`）、Python XMLRPC（`register_instance` 独立调用）。构造器只做传输层初始化。
- **阵营 B**（构造器接 service）：PHP Yar（`new Yar_Server($obj)`，service 是唯一参数）、Ruby DRb（`DRb.start_service(uri, front, config)`，front 在 config 前）、Java RMI（`UnicastRemoteObject.exportObject(obj, port)`，obj 在 port 前）。service 是构造器的核心参数。

lua-yar 属于阵营 B（构造器接 service），则 service 应为第一参数。PHP Yar 作为最直接的对标（lua-yar 是 YAR 协议的 Lua 实现），`new Yar_Server($service)` 中 service 是唯一构造器参数，进一步支持 service 优先。

Lua 生态惯例印证：`Client.new(uri)` 身份属性（uri）在第一参数；`http.new()`、`cjson.new()` 无身份属性时零参数。有身份属性时放第一，是 Lua 生态共识。

层次意识原则：service 是身份属性（决定 Server 是什么），opts 是配置项（决定 Server 怎么工作）。身份属性是独立第一参数，不埋在 opts 杂项里。

改动：`Server.new(opts, service)` → `Server.new(service, opts)`。service 和 opts 均可选，四种调用形式均合法：

```lua
Server.new()                                    -- 空构造
Server.new({ add = function() end })            -- 仅 service
Server.new({}, { timeout = 5000 })              -- 仅 opts（空 service + 配置）
Server.new({ add = function() end }, { ... })   -- service + opts
```

### 业界参考

- **PHP Yar**：`new Yar_Server($service)` — service 是唯一构造器参数，无 config。
- **Ruby DRb**：`DRb.start_service(uri, front, config)` — front（service 对象）在 config 前。
- **Java RMI**：`UnicastRemoteObject.exportObject(obj, port)` — obj 在 port 前。
- **lua-resty-http**：`http.new()` 零参数构造，身份属性（host）在 `connect()` 阶段传入。
- **lua-cjson**：`cjson.new()` 零参数，无身份属性。

### 代码评价

`src/yar/server/init.lua` 的 `_M.new(service, opts)` 实现简洁：先 `setmetatable`，再 `Dispatcher.new()`，opts 非空则 `set_options`，service 非空则 `register_service`。参数顺序与函数体内使用顺序一致（先 opts 初始化，再 service 注册），但 API 签名按身份优先排列——签名与实现顺序的分离是合理的，API 面向调用方，实现面向执行顺序。

48 个 `Server.new(nil, service)` 调用点全部简化为 `Server.new(service)`，消除 `nil` 占位。两参数调用点（opts + service）交换参数顺序。测试全量通过，无回归。

### 知识领域

1. *The Pragmatic Programmer*（Hunt & Thomas）— "Tracer Bullets" 与 API 设计的反馈循环
2. *API Design for C++*（Martin Reddy）— 参数顺序与语义层次

---

## 41. handle_message 在 Facade 上的定位：何时用 handle() vs handle_message

- **状态**：已实现
- **决策驱动因素**：API 一致性、层次分离、Facade 封装
- **关联决策**：#3（三层分离）、#38（并发模型）、#28（hooks 机制）

### 背景

`Server:handle_message(data)` 是 Server Facade 上的一行委托方法（`return self.dispatcher:handle_message(data)`），用于非 HTTP 传输场景。设计审查中提出疑问：既然 `handle()` 已提供 callback 注入模式，为何还需要 `handle_message`？

### 思考与取舍

> "Program to an interface, not an implementation."
> "面向接口编程，而非面向实现编程。"
> — Gang of Four

核心区分：`handle()` callback 模式是 **HTTP 传输层**，`handle_message` 是 **纯协议层**。

`handle()` callback 模式（`HttpTransport.serve_callback`）在 `handle_message` 之上包了一层 HTTP 语义：HTTP 方法分发（GET→introspection / POST→RPC）、状态码（200/400/413/500）、Content-Type / Content-Length 头、body 长度校验→413、错误响应体。这不是通用"注入闭包"——是 HTTP 专用的。

`handle_message` 是纯 YAR 协议函数：二进制进、二进制出，无 HTTP 语义。用于非 HTTP 传输（消息队列、WebSocket、自定义二进制协议）和单元测试。

**为何保留在 Facade 上**：Facade 上 `register_service`、`register`、`set_packager`、`list_methods` 全是 Dispatcher 的一行委托。`handle_message` 与它们一致。若以"是 Dispatcher 函数"为由移除 `handle_message`，逻辑上得把其他 Dispatcher 委托方法也移除，Facade 就空了。Facade 的价值是封装，不是实现。

**备选方案对比**：
- 移除 Facade 方法，用户访问 `server.dispatcher:handle_message(data)`：破坏 Facade 封装，不一致。
- 扩展 `handle()` 加 "raw" callback 模式：给 `handle()` 加第三种 spec 模式，增加复杂度。`handle_message` 更简单直接。

### 业界参考

- **WSGI**（Python）：`start_response(status, headers)` callback + `response_body` 返回值，HTTP 语义由框架处理。`handle()` callback 模式对标此设计。
- **lua-resty-http**：`httpc:request(...)` 返回 response 对象，HTTP 语义封装在方法内。不暴露纯协议函数。
- **PHP Yar**：`Yar_Server::handle()` 是唯一入口，不区分 HTTP/TCP，因为 PHP 运行时只处理 HTTP。lua-yar 需要支持非 HTTP 传输，故保留 `handle_message`。

### 代码评价

`src/yar/server/init.lua` L251-253 的 `handle_message` 实现是一行委托：`return self.dispatcher:handle_message(data)`。与 `register_service`（L187）、`list_methods`（L241）等 Facade 方法风格一致。源码头注释 L14 已列出此方法。文档（api.md、tutorial.md）已标注"非 HTTP 传输用途"，HTTP 场景引导使用 `handle()` callback 模式。

### 知识领域

1. *Design Patterns*（GoF）— Facade 模式与"面向接口编程"
2. *The Art of Unix Programming*（Raymond）— "Do one thing and do it well"，协议层与传输层职责分离
