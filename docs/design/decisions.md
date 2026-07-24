# lua-yar 设计文档

本目录记录 lua-yar 项目开发过程中做出的全部架构与实现决策。每个决策遵循 ADR（Architecture Decision Record）骨架，并辅以业界名言与经典文献，便于读者理解决策的背景、取舍与知识脉络。

## 设计哲学三原则

lua-yar 是 YAR RPC 协议的纯 Lua 实现，定位为**协议库 / SDK**，不是运行时框架。三条原则贯穿全部决策：

1. **纯协议，不绑定运行时** — 协议核心（`handle_message`）无 I/O、无 yield、可重入，可被任意协程调度器调用。传输层通过 Provider 抽象注入，框架本身不引用 `ngx`。

2. **零依赖，纯 Lua 实现** — 二进制编解码用纯数学（`math.floor` / `string.char`），不依赖 `string.pack`（Lua 5.1 / LuaJIT 兼容）。JSON、MessagePack 编解码器均为手写，不依赖 cjson / cmsgpack。

3. **安全默认，可注入扩展** — `ssl_verify` 默认 true、`max_body_len` 默认上限、深度限制 512。所有扩展点（Socket Provider、HTTP Provider、Packager registry、hooks、Log writer）默认关闭或使用安全实现，注入后生效。

## 模块大纲

41 个设计决策，按 7 个模块组织。每个决策列出驱动因素、名言（中英文对照）、经典文献/标准。看完此大纲即可掌握全貌，无需逐个阅读设计文件。

### 传输层（[transport-layer.md](transport-layer.md)，10 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 1 | 网络层选型：纯 Lua 优先 + Provider 抽象 | 零依赖、跨运行时 | "Make it work, make it right, make it fast." — Kent Beck | Programming in Lua (Ierusalimschy); The Pragmatic Programmer (Hunt & Thomas) |
| 2 | Provider 抽象：socket.lua wrap() + duck typing | 跨运行时、可注入 | "Program to an interface, not an implementation." — Gang of Four | Design Patterns (GoF); Patterns of Enterprise Application Architecture (Fowler) |
| 3 | 三层分离：handle_message / handle_connection / run | 可维护性、可测试性 | "Separation of concerns." — Edsger Dijkstra | The Mythical Man-Month (Brooks); Clean Architecture (Robert Martin) |
| 4 | HTTP Provider 委托：类级 + 实例级 + 默认手动实现 | 跨运行时、可注入 | "Dependency Injection is about connecting clients to services." — Martin Fowler | Inversion of Control (Fowler); Patterns of Enterprise Application Architecture (Fowler) |
| 5 | HTTPS 支持：ssl_verify 默认 true（Breaking Change） | 安全性 | "Secure by default." — 安全工程原则 | Release It! (Nygard); RFC 2818 HTTP Over TLS |
| 6 | resolve 选项：自定义 host→IP 映射（curl/PHP 风格） | 可测试性、可注入 | "Indirection is the root of all complexity." — Andrew Koenig | RFC 7230 HTTP/1.1 Message Syntax; curl 文档 |
| 7 | proxy 选项：HTTP 代理 + HTTPS CONNECT 隧道 | 兼容性 | "Be liberal in what you accept, conservative in what you send." — Jon Postel | RFC 7230 HTTP/1.1 Message Syntax; RFC 7235 Authentication |
| 8 | persistent 连接：socket 缓存 + 归池 | 性能 | "The fastest I/O is no I/O." — Mythical Man-Month | Release It! (Nygard); High Performance MySQL (Zawodny) |
| 9 | Unix socket：复用 TCP 传输层 | 代码复用 | "Don't repeat yourself." — Hunt & Thomas | The Pragmatic Programmer (Hunt & Thomas); POSIX Standard |
| 10 | 常量叶子模块：transport/constants.lua | 可维护性、无循环依赖 | "Constants should be managed by each package, not centralized." — Lua 业界惯例 | Programming in Lua (Ierusalimschy); lua-resty-http http_const 模式 |

### 服务端层（[server-layer.md](server-layer.md)，8 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 11 | packager 自适应：registry + register | 可扩展性、兼容性 | "Favor object composition over class inheritance." — Gang of Four | Design Patterns (GoF); Patterns of Enterprise Application Architecture (Fowler) |
| 12 | body 长度限制：双向校验（server 1MB / framing 10MB） | 安全性 | "Defense in depth." — 安全工程原则 | Release It! (Nygard); OWASP Input Validation |
| 13 | method memoize：构造时建立方法表 | 性能 | "Premature optimization is the root of all evil." — Donald Knuth | The Art of Computer Programming (Knuth); Programming in Lua (Ierusalimschy) |
| 14 | pcall 保护：解析/调用/渲染全包裹 | 健壮性 | "Fail fast, fail safe." — 工程原则 | Release It! (Nygard); Site Reliability Engineering (Google) |
| 38 | 服务端并发模型：run() 顺序阻塞，并发交给运行时 | 职责单一、运行时无关 | "Do one thing and do it well." — Unix 哲学 | The Art of Unix Programming (Raymond); A Philosophy of Software Design (Ousterhout) |
| 39 | HTTP 报文构建：常量管理 + table.concat 优化 | 可维护性、性能、一致性 | "Make the common case fast." — 计算机体系结构原则 | Programming in Lua (Ierusalimschy); lua-resty-http 源码; RFC 7230 HTTP/1.1 Message Syntax |
| 40 | 构造器参数顺序：service 在前，opts 在后 | API 易用性、身份属性优先 | "The most important parameter should come first." — API 设计惯例 | The Pragmatic Programmer (Hunt & Thomas); API Design for C++ (Reddy) |
| 41 | handle_message 在 Facade 上的定位：何时用 handle() vs handle_message | API 一致性、层次分离、Facade 封装 | "Program to an interface, not an implementation." — Gang of Four | Design Patterns (GoF); The Art of Unix Programming (Raymond) |

### 协议层（[protocol-layer.md](protocol-layer.md)，3 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 15 | 纯数学二进制编解码：Lua 5.1 兼容，不用 string.pack | 兼容性、零依赖 | "Simplicity is prerequisite for reliability." — Edsger Dijkstra | Programming in Lua (Ierusalimschy); Lua 5.1 Reference Manual |
| 16 | framing 帧协议：receive_exact + receive_message + check_body_len | 健壮性、安全性 | "Validate everything. Trust nothing." — 安全工程原则 | RFC 6455 WebSocket Framing; RFC 7230 HTTP Message Parsing |
| 17 | header 校验：82 字节 + magic_num 验证 | 安全性、健壮性 | "Validate everything. Trust nothing." — 安全工程原则 | YAR Protocol Spec; RFC 7230 HTTP Message Parsing |

### 打包器层（[packager-layer.md](packager-layer.md)，7 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 18 | closure 可重入解码器：OpenResty 协程安全 | 健壮性、跨运行时 | "Functions are first-class citizens." — Lua 设计哲学 | Programming in Lua (Ierusalimschy); Lua Programming Gems |
| 19 | IEEE754 双精度编解码：math.frexp/ldexp | 兼容性、零依赖 | "Floating point is not real arithmetic." — Gerald Sussman | IEEE 754-2019 Standard; What Every Computer Scientist Should Know About Floating-Point Arithmetic (Goldberg 1991) |
| 20 | 深度限制：JSON + Msgpack max_depth 512 | 安全性 | "Defense in depth." — 安全工程原则 | RFC 8259 JSON; MessagePack Specification; OWASP Input Validation |
| 21 | registry/adapter 模式：register + get | 可扩展性 | "Favor object composition over class inheritance." — Gang of Four | Design Patterns (GoF); Patterns of Enterprise Application Architecture (Fowler) |
| 22 | MessagePack str 类型完整支持：fixstr/str8/str16/str32 | 正确性 | "The devil is in the details." — 工程谚语 | MessagePack Specification; RFC 8259 JSON |
| 35 | JSON 字符串快路径：借鉴 dkjson 模式扫描 | 性能 | "Make it work, make it right, make it fast." — Kent Beck | dkjson 2.5 源码 (David Kolf); Programming in Lua (Ierusalimschy) |
| 36 | int64 负数补码编解码：32 位分块算术避免 2^64 精度丢失 | 正确性、跨运行时 | "Floating point is not real arithmetic." — Gerald Sussman | IEEE 754-2019; What Every Computer Scientist Should Know About Floating-Point Arithmetic (Goldberg 1991) |

### 消息层（[message-layer.md](message-layer.md)，2 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 23 | 事务 ID 生成：多熵源 + 不自动播种 | 健壮性、库不越权 | "Setting the seed is the responsibility of the application layer, the library should never set the seed." — Lua 业界惯例 (uuid.lua/Tieske) | Programming in Lua (Ierusalimschy); RFC 4122 UUID |
| 24 | trace_id 拒绝自动生成：应用层职责 | 纯协议库定位 | "Do one thing and do it well." — Unix 哲学 | The Art of Unix Programming (Raymond); A Philosophy of Software Design (Ousterhout) |

### 客户端层（[client-layer.md](client-layer.md)，3 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 25 | 结构化 Error 对象：5 个错误码 + .code 字段 | 可调试性 | "Errors are values." — Rob Pike | A Philosophy of Software Design (Ousterhout); Release It! (Nygard) |
| 26 | 客户端选项设计：对齐 PHP yar 并扩展 | 兼容性、可维护性 | "Convention over configuration." — Rails 哲学 | YAR PHP Extension Spec; The Pragmatic Programmer (Hunt & Thomas) |
| 27 | 错误分类：传输层 + 协议层 + 服务端 | 可调试性 | "Errors are values." — Rob Pike | A Philosophy of Software Design (Ousterhout); Site Reliability Engineering (Google) |

### 横切关注点（[cross-cutting.md](cross-cutting.md)，8 个决策）

| # | 决策 | 驱动因素 | 名言 | 文献 |
|---|------|---------|------|------|
| 28 | hooks 机制：on_request/on_response + pcall + 零开销 | 可扩展性、性能 | "Make the common case fast." — 计算机体系结构原则 | The Art of Computer Programming (Knuth); Release It! (Nygard) |
| 29 | 日志模块：4 级别 + 可注入 writer | 可调试性 | "Logs are for humans." — 运维哲学 | Site Reliability Engineering (Google); Release It! (Nygard) |
| 30 | LuaLS 类型标注：22 个源文件全覆盖 | 可维护性 | "Code is read more often than it is written." — Guido van Rossum | LuaLS Documentation; The Pragmatic Programmer (Hunt & Thomas) |
| 31 | 跨运行时设计：纯协议核心 + 可注入传输层 | 跨运行时 | "Portability is the ability to move code from one environment to another." — IEEE 1003.0 | The Art of Unix Programming (Raymond); POSIX Standard |
| 32 | 纯协议库定位：非运行时框架 | 职责单一 | "Do one thing and do it well." — Unix 哲学 | The Art of Unix Programming (Raymond); A Philosophy of Software Design (Ousterhout) |
| 33 | 错误返回形式分层：内部字符串 / RPC 结果结构化 Error 对象 | 可调试性、一致性 | "Make everything as simple as possible, but not simpler." — Albert Einstein | A Philosophy of Software Design (Ousterhout); Go Blog "Errors are values" (Rob Pike) |
| 34 | packager 运行时错误从 error() 改为 return nil, err（方案 C） | 一致性、鲁棒性 | "Make everything as simple as possible, but not simpler." — Albert Einstein | Programming in Lua (Ierusalimschy); dkjson 2.5 源码 (Kolf); lua-resty-redis 源码 (agentzh) |
| 37 | 鸭子类型接口的错误处理：对标外部函数签名（pcall 在边界不在内部） | 一致性、鸭子类型、性能 | "Program to an interface, not an implementation." — Gang of Four | Design Patterns (GoF); Programming in Lua (Ierusalimschy) |

## 阅读指南

- **按模块阅读**：从你最关心的模块开始，每个文档自成体系。
- **按决策追踪**：每个决策有"关联决策"字段，可顺藤摸瓜理解决策间的依赖关系。
- **按知识脉络阅读**：每个决策末尾列出 2-3 篇经典文献或标准，供深入理解该领域的理论基础。
- **名言双语对照**：每个决策的"思考与取舍"节首引一句业界名言，中英文对照，标注署名。
