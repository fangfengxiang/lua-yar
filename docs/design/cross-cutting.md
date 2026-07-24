# 横切关注点设计决策

横切关注点是跨模块的架构决策：hooks 扩展机制、日志、类型标注、跨运行时设计、纯协议库定位。这些决策不局限于某个层，而是贯穿整个项目。

---

## 28. hooks 机制：on_request/on_response + pcall + 零开销

- **状态**：已实现
- **决策驱动因素**：可扩展性、性能
- **关联决策**：#24（trace_id 拒绝自动生成）、#14（pcall 保护）、#25（结构化 Error 对象）

### 背景

库需要提供扩展点让业务层注入逻辑（监控、日志、trace、限流），但不能硬编码这些功能。同时，未配置 hooks 时不能有性能开销。

### 思考与取舍

> "Make the common case fast." — 计算机体系结构原则
> "让常见情况快。" — 计算机体系结构原则

`client.lua` 和 `server/init.lua` 都有 `run_hook(hook, ...)` 函数：
```lua
local function run_hook(hook, ...)
    if not hook then return end       -- 零开销：未配置时直接返回
    local ok, err = pcall(hook, ...)  -- pcall 保护：hook 错误不影响主流程
    if not ok then
        Log.warn("hook error: " .. tostring(err))
    end
end
```

两个 hook 点：
- `on_request(method, params)` — 请求发出前 / 服务端处理前
- `on_response(method, retval, err_obj)` — 响应返回后（成功传 retval，失败传 err_obj）

`client.lua` 的 `call()` 有 6 个返回路径，每个都调用 `on_response`（成功传 retval+nil，失败传 nil+err_obj）。`server/init.lua` 的 `handle_message` 有 3 个 hook 路径（method not found / 调用成功 / 调用异常）。

### 业界参考

- **Kong**：`plugins` 机制，`kong.plugins.*:access()` / `:header_filter()` 等 hook，pcall 保护。
- **OpenResty**：`ngx.shared.*` + `phase` 机制，类似 hook 但绑定运行时。
- **Express.js**：`app.use(middleware)` 中间件链，next() 传递控制权。

### 代码评价

`run_hook` 函数简洁（5 行），`if not hook then return end` 实现零开销（未配置时无 pcall 调用）。hook 错误降级为 `Log.warn` 而非崩溃。`client.lua` 的 6 个返回路径全覆盖 `on_response`，`server/init.lua` 的 3 个路径全覆盖。`err_obj` 用 `Error.new` 构造，保证 hook 接收到的错误对象一致。设计干净，无遗漏路径。

### 知识领域

1. *The Art of Computer Programming*（Donald Knuth）— "Make the common case fast" 优化原则
2. *Release It!*（Michael Nygard）— 扩展点与故障隔离

---

## 29. 日志模块：4 级别 + 可注入 writer

- **状态**：已实现
- **决策驱动因素**：可调试性
- **关联决策**：#28（hooks 机制）、#14（pcall 保护）

### 背景

库内部需要日志（连接建立、传输错误、hook 错误等），但不能硬编码输出方式——OpenResty 用 `ngx.log`，标准 Lua 用 `print`，测试可能要捕获日志。需要一个可注入的日志模块。

### 思考与取舍

> "Logs are for humans." — 运维哲学
> "日志是给人看的。" — 运维哲学

`log.lua` 设计：
- 4 个级别：`DEBUG`(1) / `INFO`(2) / `WARN`(3) / `ERROR`(4)
- `set_level(lvl)` — 设置当前级别，低于此级别的日志不输出
- `set_writer(fn)` — 注入自定义 writer 函数 `fn(level, message)`，nil 重置为默认
- 默认 writer：`print("[LEVEL] message")`，全环境可用
- 默认级别：`WARN`（生产环境合理默认，不刷屏）

单实例 + 模块 upvalue 模式：`current_level` 和 `writer` 是模块级局部变量，`Log.debug` / `Log.info` 等通过闭包捕获。

### 业界参考

- **lua-resty-logger**：`ngx.log` 封装，绑定 OpenResty。
- **log4lua**：多 appender + 级别，但依赖配置文件。
- **Python `logging`**：`logging.getLogger(name)` + `setLevel` + `addHandler`，类似但更重。

### 代码评价

`log.lua` 仅 55 行，设计简洁。`set_level` 用 `tonumber(lvl) or Log.WARN` 做输入校验（非数字降级为 WARN）。`LEVEL_NAMES` 映射表让默认 writer 输出可读级别名而非裸数字。`log(lvl, msg)` 内部函数做级别过滤（`lvl < current_level then return`）。`Log.debug` / `info` / `warn` / `error` 是单行封装。单实例模式适合库（不需要 per-logger 配置），注入点够用。

### 知识领域

1. *Site Reliability Engineering*（Google）— 日志级别与可观测性
2. *Release It!*（Michael Nygard）— 日志与故障排查

---

## 30. LuaLS 类型标注：22 个源文件全覆盖

- **状态**：已实现
- **决策驱动因素**：可维护性
- **关联决策**：#32（纯协议库定位）

### 背景

Lua 是动态类型语言，IDE 补全和静态检查弱。LuaLS（Lua Language Server）通过注释标注（`---@class`、`---@field`、`---@param`、`---@return`、`---@type`、`---@cast`）提供类型提示和静态检查。库是否值得花精力做全量标注？

### 思考与取舍

> "Code is read more often than it is written." — Guido van Rossum
> "代码被阅读的次数远多于被编写的次数。" — Guido van Rossum

全量标注。22 个源文件（`init.lua` + `client.lua` + `error.lua` + `log.lua` + `util.lua` + `transport/` 6 个 + `server/` 3 个 + `protocol/` 3 个 + `packager/` 3 个 + `message/` 2 个）全部添加 LuaLS 标注：
- `---@class ClassName` — 声明类
- `---@field name type` — 声明字段
- `---@param name type` — 声明函数参数
- `---@return type` — 声明返回值
- `---@type type` — 声明变量类型
- `---@cast var type` — 类型窄化（如 `---@cast t table`）

标注用英文（LuaLS 国际惯例），代码注释保留中文（业务说明）。

### 业界参考

- **LuaLS**：sumneko 开发的 Lua Language Server，社区标准。
- **lua-resty-http**：部分标注，未全覆盖。
- **Kong**：部分模块标注，但不一致。

### 代码评价

全部 22 个源文件有 `---@class` 声明和 `---@param` / `---@return` 标注。`client.lua` 的 `call()` 方法标注了 5 个错误码分类（注释块列出 `Error.TRANSPORT` / `TIMEOUT` / `PROTOCOL` / `NOT_FOUND` / `EXCEPTION` 的触发条件）。`---@cast t table` 用于类型窄化（如 `local p = Packager.get(...) ---@cast p table`）。`util.lua` 的 `unpack_u16` / `unpack_u32` 等函数标注 `@param offset number` 和 `@return number`。标注质量高，IDE 补全和静态检查友好。

### 知识领域

1. LuaLS Documentation — `---@class` / `---@param` / `---@return` / `---@cast` 标注规范
2. *The Pragmatic Programmer*（Hunt & Thomas）— "Code is read more often than written" 可维护性原则

---

## 31. 跨运行时设计：纯协议核心 + 可注入传输层

- **状态**：已实现
- **决策驱动因素**：跨运行时
- **关联决策**：#2（Provider 抽象）、#3（三层分离）、#18（closure 可重入）、#32（纯协议库定位）

### 背景

Lua 生态有多个运行时：标准 Lua（luasocket 同步）、OpenResty（cosocket 非阻塞 + 协程）、lua-eco（协程 + luasocket）、Skynet（actor 模型）。库如果绑定单一运行时，无法跨生态复用。

### 思考与取舍

> "Portability is the ability to move code from one environment to another." — IEEE 1003.0
> "可移植性是将代码从一个环境迁移到另一个环境的能力。" — IEEE 1003.0

核心设计：**`handle_message(data)` 是纯协议函数，无 I/O、无 yield、可重入**。任意运行时只需：
1. 拿到完整 YAR 二进制消息（通过各自的 socket 读取）
2. 调用 `handle_message(data)` 得到响应二进制消息
3. 写回 socket

传输层通过 Provider 抽象注入：
- 标准 Lua：`socket.lua` 默认适配 luasocket（同步阻塞）
- OpenResty：`Yar.client.set_socket(ngx.socket)` 注入 cosocket（非阻塞 + 连接池）
- lua-eco / Skynet：注入各自的 socket 实现

解码器用闭包保证可重入（#18），多协程并发安全。

### 业界参考

- **POSIX**：标准接口 + 实现可替换，跨 Unix 可移植。
- **gRPC-go**：`grpc.Server` 绑定 Go runtime，不跨语言。
- **PHP Yar**：绑定 PHP 运行时，无跨运行时需求。

### 代码评价

`server/init.lua` 的 `handle_message` 完全无 I/O，注释明确"纯协议处理，不感知任何传输层"。`server/http.lua` 和 `server/tcp.lua` 的 `handle_connection` 是 I/O 层，`run` 是 accept 循环（注释"for dev/testing only"）。`socket.lua` 的 Provider 抽象让 cosocket 注入零代码改动。`json.lua` / `msgpack.lua` 的闭包解码器保证协程安全。跨运行时设计完整，example/ 目录有多个运行时适配示例。

### 知识领域

1. *The Art of Unix Programming*（Eric Raymond）— 可移植性与标准接口
2. POSIX Standard — 可移植操作系统接口设计原则

---

## 32. 纯协议库定位：非运行时框架

- **状态**：已实现
- **决策驱动因素**：职责单一
- **关联决策**：#1（网络层选型）、#3（三层分离）、#23（事务 ID 生成）、#24（trace_id 拒绝）、#31（跨运行时设计）

### 背景

YAR RPC 协议有多个实现：PHP Yar（PHP 扩展）、yar-c（C 库）、yar-lua（本库）。实现到什么程度？是否要做进程管理、健康检查、熔断、重试、负载均衡等"框架级"功能？

### 思考与取舍

> "Do one thing and do it well." — Unix 哲学
> "做好一件事。" — Unix 哲学

lua-yar 定位为**纯协议库 / SDK**（运行时无关），不是平台级绑定。职责边界：
- **做**：YAR 协议编解码、请求-响应、packager 自适应、传输层抽象、错误分类、hooks 注入点
- **不做**：进程管理、健康检查、熔断、重试、负载均衡、服务发现、trace_id 生成、`math.randomseed` 播种

"不做"的功能是**应用层或适配层**的职责。例如 `lua-resty-yar`（未来适配层）可基于 lua-yar 实现 OpenResty phased 优化、cosocket 连接池调优等。

备选方案：做成全功能 RPC 框架（类似 gRPC-go）。但会增加复杂度、绑定运行时、违背"纯 Lua 零依赖"定位。

### 业界参考

- **PHP Yar**：PHP 扩展，绑定 PHP 运行时。
- **yar-c**：C 库，绑定 C 运行时。
- **gRPC-go**：Go 框架，绑定 Go runtime，含负载均衡/重试/熔断。
- **Kong**：平台级 API 网关，非 SDK，定位不同。

### 代码评价

`init.lua` 注释明确"Yar Lua RPC 框架主入口"，公共 API 表面仅 `Client` / `Server` / `Packager` / `Error` / `Log` / `VERSION` / `PACKAGER_*` / `seed` / `set_id_generator`。`server/init.lua` 注释"纯协议处理，不感知任何传输层"。`request.lua` 注释明确"本库不调用 math.randomseed 播种"。无进程管理、无熔断、无重试代码。职责边界清晰，是"有意不做"的设计决策。选型时明确区分"要 SDK 还是要平台"。

### 知识领域

1. *The Art of Unix Programming*（Eric Raymond）— "Do one thing and do it well" 原则
2. *A Philosophy of Software Design*（John Ousterhout）— 模块职责边界与 deep modules

---

## 33. 错误返回形式分层：内部字符串 / RPC 结果结构化 Error 对象

- **状态**：已实现
- **决策驱动因素**：可调试性、一致性
- **关联决策**：#25（结构化 Error 对象）、#27（错误分类）、#14（pcall 保护）

### 背景

Lua 惯例返回 `nil, err`，`err` 通常是字符串。但项目不同层对错误的需求不同：RPC 调用结果需要程序化匹配（业务逻辑按错误类型决定重试与否），内部层错误只是诊断信息（向上传递汇总），设置/配置 API 的参数校验是编程错误（调用方写错代码，fail-fast 不接错误）。若所有层都用结构化 `Error.new` 对象，内部层过度工程化；若所有层都用字符串，RPC 边界又退回脆弱的 `string.match` 前缀匹配。

### 思考与取舍

> "Make everything as simple as possible, but not simpler." — Albert Einstein
> "尽可能简单，但不能更简单。" — Albert Einstein

#### 三步法判定流程

**第零步：判断函数是否属于多态/鸭子类型接口**（详见 ADR #37）

若函数有外部注入的对标函数（如 `cjson.encode` ↔ `Json.pack`），错误处理形式必须与外部对标函数签名一致——对标函数 throw `error()` 则内置实现也 throw `error()`，对标函数 `return nil, err` 则内置实现也 `return nil, err`。调用方必须 pcall 此多态接口（不是因为 pcall 自有函数，而是接口可能分发到第三方实现）。

**第一步：判断错误性质（三分类法）**

| 错误性质 | 定义 | 例子 |
|---|---|---|
| 运行时错误 | 调用方无法预防的外部条件 | 网络断开、超时、畸形数据、端口占用、body 超限 |
| 编程错误 | 调用方写错代码 | 参数类型错、未初始化、方法名非法 |
| 第三方抛错 | 第三方代码自己 `error()`，你无法改 | `ngx.req.socket()`、用户 RPC 方法内 `error()` |

**第二步：运行时错误再按"调用方是谁"决定形式**

```
错误发生
  │
  ├─ 第零步：属于多态/鸭子类型接口？ → 对标外部函数签名（ADR #37）
  │    （有外部注入对标函数，如 cjson.encode ↔ Json.pack）
  │
  ├─ 编程错误？ ──────────────────────→ error(msg, 2)  [无论调用方是谁]
  │
  ├─ 第三方抛错？ ────────────────────→ pcall 包裹
  │
  └─ 运行时错误？ → 看调用方是谁：
        │
        ├─ 调用方 = Yar 内部其他函数
        │     → return nil, err (字符串)
        │       上游外层函数接住，转换给更上层
        │
        ├─ 调用方 = 应用层 + 客户端函数
        │     → return nil, Error.new(code, msg)  [结构化]
        │       app 用 err.code 路由（重试/降级/报错）
        │
        ├─ 调用方 = 应用层 + 服务端函数
        │     → return nil, err (字符串)
        │       app 检查后决定（换端口/退出/log）
        │
        └─ 调用方 = 应用层 + 配置/注入类函数
              → 不会发生运行时错误（配置类只做参数校验=编程错误→error）
```

#### 分层错误形式

| 层 | 错误形式 | 理由 |
|----|---------|------|
| **RPC 调用结果**（`client.lua:call()` 返回） | `Error.new(code, msg)` 结构化对象 | 业务逻辑用 `err.code == Error.TIMEOUT` 精确路由，无需字符串解析 |
| **内部层**（transport/protocol/packager/framing/header） | `nil, "description string"` | 诊断信息向上传递，由 `client.lua` 捕获并包装成 `Error` 对象分类 |
| **设置/配置 API**（`Yar.register_packager`、`Server.register`/`set_packager`） | `error(msg, 2)` | 参数校验是编程错误，调用方是应用层（非库内部函数），fail-fast 不接错误 |

边界清晰：`error.lua` 是分类中枢——只有 `client.lua:call()` 构造 `Error` 对象（7 个返回路径），内部层不重复构造。内部层字符串错误到达 `client.lua` 后，按内容（如 `string.find(e, "timeout")`）分类为 `Error.TIMEOUT` / `Error.TRANSPORT`，再以结构化形式返回给业务层。

**hook 回调例外**：`dispatcher.lua` 的 `handle_message` 在 `on_response` hook 回调路径中构造 `Error.new(Error.NOT_FOUND, ...)` 和 `Error.new(Error.EXCEPTION, ...)`，传给用户注入的 hook 函数。这不违反"内部层不构造 Error 对象"规则——Error 对象此处仅作为 hook 回调参数传递错误类型（让 hook 区分 NOT_FOUND vs EXCEPTION），不作为 RPC 返回值（RPC 响应仍用 `response:set_error(err_msg)` 字符串）。语义区别：内部层返回 Error 对象给调用方 = 违规（调用方需按 code 路由，但内部层不该决定分类）；内部层传 Error 对象给 hook 回调 = 合规（hook 是用户注入的扩展点，用户需要结构化错误类型，与 client.lua 返回 Error 给 app 层同理）。

#### 结构化 Error 使用场景（唯一场景：客户端函数的运行时错误，返回给应用层）

只有 `Client:call()` 的 7 条返回路径：

| 路径 | Error code | 触发条件 |
|---|---|---|
| packager 未知 | `PROTOCOL` | `Packager.get` 返回 nil |
| 连接失败 | `TRANSPORT` | `t:open` 返回 nil |
| 发送/接收失败（非超时） | `TRANSPORT` | `t:send` 返回 nil 且不含 "timeout" |
| 发送/接收失败（超时） | `TIMEOUT` | `t:send` 返回 nil 且含 "timeout" |
| 响应解析失败 | `PROTOCOL` | `Protocol.parse` 返回 nil |
| 方法不存在 | `NOT_FOUND` | 响应 status≠0 且 msg 匹配 "method not found" |
| 方法执行异常 | `EXCEPTION` | 响应 status≠0 且其他错误 |

只有客户端的 app 层调用方需要按 `err.code` 路由不同错误（timeout 重试、not_found 降级、transport 换节点）。其他场景不需要路由。

#### nil, err 字符串使用场景（三类）

**① 内部层的运行时错误（调用方 = Yar 内部函数）**

| 层 | 函数 | 例子 |
|---|---|---|
| transport | `Transport:open/send` | 连接失败、发送失败、HTTP 状态错 |
| protocol | `Protocol.parse/render` | 坏包、packager 不匹配、header 校验失败 |
| framing | `Framing.receive_message` | 截断输入、深度超限 |
| packager | `Packager.get` | 未知 packager 名 |
| header | `Header.unpack` | 短 header |

这些错误向上传递，最终由 `Client:call` 捕获并包装成结构化 `Error` 对象（或由服务端 `handle_message` 编码进 YAR 错误帧）。

**② 服务端函数的运行时错误（调用方 = 应用层）**

| 函数 | 错误 | 处理 |
|---|---|---|
| `TcpServer:run` / `HttpServer:run` | bind 失败（端口占用/权限） | `return nil, "bind failed: " .. err` |

服务端不用结构化 Error——app 只需知道"启动失败"+原因，不需要 code 分类。

**③ 服务端内部 I/O 错误（调用方 = Yar 内部，不传播给 app）**

| 函数 | 错误 | 处理 |
|---|---|---|
| `handle_connection` | 读/写失败、handler 异常 | `pcall` 捕获 + `Log.error` + 关连接，不传播 |

#### error(msg, 2) 使用场景（编程错误，无论调用方）

| 函数 | 校验 | 调用方 |
|---|---|---|
| `Client:call(method, ...)` | method 不是 string | 应用层 |
| `Packager.register(name, lib)` | name/lib 类型错、缺 pack/unpack | 应用层 |
| `Server.register(name, func)` | func 不是 function、name 非法 | 应用层 |
| `Server.set_packager(name)` | 未知 packager | 应用层 |

编程错误不可路由，应 fail-fast 让开发者立刻修。app 不应该写 `if err.code == BAD_PARAM then` 来处理自己的笔误。

#### pcall 使用场景

| 场景 | 包裹对象 | 原因 |
|---|---|---|
| 第三方 API | `ngx.req.socket()`、`tonumber()` | 第三方自己 `error()`，无法改 |
| 用户 RPC 方法 | `func(unpack(args))`（server/init.lua:225） | 用户代码可能 `error()`，要隔离不影响服务端 |
| hook 回调 | `hooks.on_request/on_response` | 用户回调可能 `error()`，不影响主流程 |
| 服务端 handler | `self.handle_connection`（tcp.lua:128） | 单连接异常不崩溃整个服务端 |

#### 服务端 vs 客户端错误处理思路不同

| 维度 | 客户端（`Client:call`） | 服务端（`handle_message`/`run`） |
|---|---|---|
| 运行时错误形式 | 结构化 `Error.new(code, msg)` | `nil, err` 字符串 / 编码进 YAR 错误帧 |
| 错误去向 | 返回给 app 层，app 按 `err.code` 路由 | 内部消化（log / 写进协议响应帧 / 返回 nil,err 给 app） |
| 为什么 | app 需要区分 timeout 重试、not_found 降级、transport 换节点 | 服务端要么 log+继续（单连接错不影响整体），要么启动失败 app 退出；不需要 code 分类 |

#### 一句话总结

> **客户端运行时错误返回给 app → 结构化 `Error.new(code, msg)`；服务端运行时错误返回给 app → `nil, err` 字符串；内部层运行时错误 → `nil, err` 字符串让上游转换；编程错误 → `error(msg, 2)`；第三方抛错 → `pcall`；不确定就同开发者确认。**

### 业界参考

- **Go `os` 包**：低层 `syscall` 返回 `error` 接口值（字符串语义），公共 `os.Open` 返回 `*os.PathError` 结构化错误（含 `Op`/`Path`/`Err` 字段）供类型断言——内层简单、边界结构化。
- **Python**：内部用 `OSError`，公共 API 暴露 `FileNotFoundError` / `PermissionError` 子类供精确捕获。
- **PHP Yar**：`Yar_Client_Exception::getType()` 返回 `YAR_ERR_*` 常量，仅客户端异常结构化。

#### Lua 业界对比

| 库 | 类型 | 参数校验 | 运行时错误 | bind/listen | handler 异常 |
|---|---|---|---|---|---|
| **lua-resty-http** | 纯客户端 | `return nil, err`（全用，无 error()） | `return nil, err` | 无（不做服务端） | N/A |
| **lua-resty-redis** | 纯客户端 | `error(msg, 2)` | `return nil, err`（timeout 时 close） | 无 | N/A |
| **copas** | 服务端框架 | `error(msg, 2)` | `return nil, err` | 不负责 bind（用户侧 `assert(socket.bind())`） | `coroutine.resume` 捕获不崩溃 |
| **lua-yar Client** | 客户端 | `error(msg, 2)` | 结构化 `Error.new(code, msg)` | N/A | N/A |
| **lua-yar Server** | 服务端 | `error(msg, 2)` | 编码进 YAR 错误帧 / `nil, err` | `return nil, err` | `pcall` 捕获 + log |

#### 对齐情况与差异

lua-yar 规则与业界主流（lua-resty-redis / copas）一致：

- 编程错误 → `error(msg, 2)`：与 lua-resty-redis、copas 一致。
- 运行时错误 → `return nil, err`：与 lua-resty-http / redis、copas 一致。
- 第三方抛错 → `pcall`：与 lua-resty-http `pcall ngx.req.socket()` 一致。
- 服务端 handler 异常隔离：与 copas `coroutine.resume` 捕获不崩溃一致。
- 服务端 bind 失败 → `nil, err`：与 copas 推用户侧 `assert()` 方向一致（lua-yar 内部做 bind 并 `return nil, err` 更优雅）。

两处差异（均为合理设计选择，不违背惯例）：

- **lua-resty-http 极端**——连参数校验都 `return nil, err`（不用 `error()`）。lua-yar 选了 lua-resty-redis / copas 路线（参数校验 `error()` fail-fast），与多数业界库一致。
- **lua-yar 客户端结构化 `Error.new(code, msg)`**——业界用 `nil, err` 字符串，lua-yar 是增强（多了 code 供 app 路由）。形式兼容：app 可忽略 code 直接用 `err.msg`，等价于业界 `nil, err`。

### 代码评价

`client.lua:call()` 的 7 个返回路径全部构造 `Error.new(code, msg)`，是 RPC 返回路径唯一构造 `Error` 对象的位置。`dispatcher.lua` 的 `handle_message` 在 `on_response` hook 回调路径中构造 `Error.new(Error.NOT_FOUND, ...)` / `Error.new(Error.EXCEPTION, ...)` 传给用户 hook（hook 回调例外，见上文）。内部层（`framing.lua` `"short header"`、`header.lua` `"invalid magic number: ..."`、`socket.lua` `"luasocket not available"`、`http.lua` `"http status: ..."`、`packager.lua` `"unsupported packager: ..."`）统一用描述式字符串，无函数名前缀，风格一致。`error.lua` 头部注释"结构化错误对象：替代字符串前缀惯例"准确描述了其定位——替代的是 RPC 边界的前缀惯例，非内部层。分层边界清晰，无越界。

### 知识领域

1. *A Philosophy of Software Design*（John Ousterhout）— 错误处理与深层模块
2. Go Blog "Errors are values"（Rob Pike）— 错误即值，分层处理

---

## 34. packager 运行时错误从 error() 改为 return nil, err（方案 C）

- **状态**：已实现
- **决策驱动因素**：一致性、鲁棒性
- **关联决策**：#33（错误返回形式分层）、#14（pcall 保护）、#18（closure 可重入解码器）、#20（深度限制）

### 背景

packager 层（`json.lua` / `msgpack.lua`）的 decode/unpack 对运行时错误（畸形数据、深度超限、截断输入）使用 `error()` 抛错，迫使 `client.lua` 和 `server/init.lua` 用 `pcall` 包裹 `Protocol.render` / `Protocol.parse`。这违反了 Lua 错误处理三分类规则："运行时错误 → `return nil, err`；`error()` 仅用于编程错误；`pcall` 仅用于不可控第三方 API"。packager 是内部层，不应抛 `error()` 迫使上层 pcall 包裹自有函数——这是"内部 pcall 自有函数"反模式。

### 思考与取舍

> "Make everything as simple as possible, but not simpler." — Albert Einstein
> "尽可能简单，但不能更简单。" — Albert Einstein

方案 C（根源修复）：将 packager 层 `error()` 改为 `return nil, err`，上层移除 pcall。

- **`json.lua` decode** 对齐 dkjson.decode 三返回值 `nil, pos, errmsg`——错误由第三返回值 `errmsg` 非 nil 判定，JSON null 合法返回 nil 不误判为错误。
- **`msgpack.lua` unpack** 对齐 lua-resty-redis `_read_reply` 二返回值 `nil, errmsg`——错误由第二返回值 `errmsg` 非 nil 判定，MessagePack nil (0xc0) 合法返回 nil 不误判为错误。
- **`Protocol.parse`** 用 `local payload, _, perr = packager.unpack(body); if perr ~= nil` 模式兼容两种 packager 的返回签名。
- **`Protocol.render`** 的 `packager.pack` 对所有 Lua 值都不会失败（infallible），无需错误返回。
- **`client.lua`** 移除 2 处 pcall（render + parse），直接调用并检查返回值。
- **`server/init.lua`** 移除 5 处 pcall（3 处 render + 1 处 parse + 1 处 final render），保留 `pcall(func, ...)` 包裹用户 RPC 方法（第三方代码）。

备选方案 A（保持 `error()` + pcall）：不改动，但违反三分类规则。方案 B（pcall 包裹再返回 `nil, err`）：治标不治本，引入语义变更风险（函数不再 throw，已有 pcall 调用方的 ok 恒 true）。

### 业界参考

- **dkjson.decode**：返回 `nil, pos, errmsg` 三返回值，不抛 `error()`。
- **lua-resty-redis** `_read_reply`：返回 `nil, errmsg`，不抛 `error()`。
- **lua-resty-mysql / lua-resty-websocket**：同样 `return nil, err` 惯例。
- **PHP Yar**：`yar_packager_unpack` 返回 `NULL` + 错误日志，不抛异常。

### 代码评价

`json.lua` decode 全部 12 处 `error()` 改为 `return nil, nil, errmsg`，递归调用（`parse_array` / `parse_object` / `descend`）添加 `if verr ~= nil then return nil, vpos, verr end` 传播。`msgpack.lua` unpack 全部 `error()` 改为 `return nil, errmsg`，`need(n)` 从 void 改为返回 `true` / `nil, errmsg`，17 处调用点改为 `local ok, nerr = need(N); if not ok then return nil, nerr end`，递归调用（`parse_array` / `parse_map` / `descend`）添加错误传播。`Protocol.parse` 传播 packager 错误。`client.lua` 和 `server/init.lua` 共移除 7 处 pcall。测试适配 3 个 spec 文件（`client_spec` 移除 THROW packager 测试、`security_spec` 移除 2 处 pcall）。193 个测试全部通过，无回归。

### 知识领域

1. *Programming in Lua*（Ierusalimschy）第 16 章 — pcall 与 error level 语义
2. dkjson 2.5 源码（David Kolf）— JSON 解码器 `nil, pos, errmsg` 错误返回惯例
3. lua-resty-redis 源码（agentzh）— `_read_reply` 的 `nil, errmsg` 错误返回惯例

---

## 37. 鸭子类型接口的错误处理：对标外部函数签名

- **状态**：已实现（2026-07-23 修正：pcall 从 render 内部移到边界）
- **决策驱动因素**：一致性、鸭子类型、性能
- **关联决策**：#33（错误返回形式分层）、#34（packager decode 改为 return nil, err）、#14（pcall 保护）、#2（Provider 抽象 duck typing）

### 背景

ADR #33 建立了错误处理三分类法（运行时错误 / 编程错误 / 第三方抛错），ADR #34 将 packager decode 路径从 `error()` 改为 `return nil, err`。但 encode 路径（`packager.pack`）仍用 `error()`——这不是规则例外，而是决策树缺少一个前置节点。

`packager.pack` 是多态接口：运行时可能是内置 `Json.pack`，也可能是通过 `Packager.register` 注入的第三方 `cjson.encode`。内置实现的错误处理形式必须与外部对标函数一致，否则鸭子类型不成立。

### 思考与取舍

> "Program to an interface, not an implementation." — Gang of Four
> "面向接口编程，而非面向实现。" — GoF 设计模式

#### 决策树第零步（置于三分类法之前）

```
错误处理决策
  │
  ├─ 第零步：函数是否属于多态/鸭子类型接口？
  │    （即：是否有外部注入的对标函数，如 cjson.encode ↔ Json.pack）
  │    │
  │    ├─ 是 → 错误处理形式必须与外部对标函数签名一致
  │    │    · 对标函数 throw error() → 内置实现也 throw error()
  │    │    · 对标函数 return nil, err → 内置实现也 return nil, err
  │    │    · 调用方必须 pcall 此多态接口
  │    │      （不是因为 pcall 自有函数，而是接口可能分发到第三方实现）
  │    │
  │    └─ 否 → 进入第一步三分类法（ADR #33 现有规则）
  │
  ├─ 第一步：判断错误性质（三分类法）……
  └─ 第二步：运行时错误按调用方决定形式……
```

#### 三条规则

1. **函数签名对齐**：内置实现的错误处理形式必须与外部对标函数一致。cjson.encode/dkjson.encode 抛 `error()` → `Json.pack` 也抛 `error()`；cjson.decode/dkjson.decode 返回 `nil, err` → `Json.unpack` 也返回 `nil, err`（ADR #34）。

2. **pcall 多态接口合法**：`Protocol.render` 的 `pcall(packager.pack, ...)` 不是"pcall 自有函数"——`packager.pack` 是多态接口，运行时可能是内置 `Json.pack`，也可能是注入的第三方 `cjson.encode`。pcall 是因为鸭子类型不确定性，不是因为 pcall 自有代码。

3. **不对称是生态事实**：encode 和 decode 的错误处理惯例本就不对称（encode 抛 error，decode 返回 nil,err），强行对称是与生态对抗。内置实现跟随各自路径的对标惯例。

#### error(msg, 0) 的定位

不仅错误形式（throw vs return）要对齐，错误消息格式也要对齐。cjson.encode 是 C 函数，其 error 不带 Lua 位置前缀；内置 encode 用 `error(msg, 0)` 抑制位置信息，使两者错误消息格式一致。

### 业界参考

- **cjson.encode**：抛 `error("Cannot serialise cyclic recursive table")`，C 函数无 Lua 位置前缀。
- **dkjson.encode**：抛 `error("too deep nesting in encode")`。
- **cjson.decode / dkjson.decode**：返回 `nil, err`，不抛 error。
- **lua-MessagePack**：encode 抛 `error("cyclic recursive table")`，decode 返回 `nil, err`。

### 代码评价

`json.lua` 和 `msgpack.lua` 的 encode 路径用 `error(msg, 0)`（level 0 抑制位置信息），与 cjson.encode 的错误格式对齐。`Protocol.render` 用 `pcall(packager.pack, ...)` 一处兜底所有 packager（内置或注入）。decode 路径仍用 `return nil, err`（ADR #34 不变）。决策树第零步在 ADR #33 的三分类法之前，确保鸭子类型接口的规则优先级高于内部规则。

### 修正记录：pcall 从 render 内部移到边界（2026-07-23）

**触发原因**：性能回退。`pcall(packager.pack, ...)` 放在 `Protocol.render` 内部导致 LuaJIT JIT 编译器在 pcall 边界中止，整条 encode 路径退化为解释器执行。render 路径性能下降 35%~53%。

**根因分析**：ADR #37 原始推理链第 3 步有误——"接口可能抛 error() → 调用方必须在调用点 pcall"。正确推理应为"接口可能抛 error() → error() 传播到最外层边界 → 在边界处 pcall 捕获"。pcall 属于边界（dispatcher / client / C 层请求处理器），不属于内部函数热路径。

**业界实证**：
- **cjson**：内部不 pcall，`luaL_error()` 直接抛出，调用方在边界 pcall
- **lua-resty-redis**：热路径无 pcall，全部 `return nil, err`，仅模块加载时 pcall（table.new）
- **OpenResty 核心**：C 层请求处理器边界 pcall，Lua 库热路径无 pcall
- **dkjson**：encode/decode 热路径无 pcall，仅可选功能加载时 pcall
- **v1 lua-yar**：pcall 在 dispatcher/client 边界（正确），v3 误移到 render 内部

**修正内容**：
1. `Protocol.render` 移除内部 `pcall(packager.pack, ...)`，恢复直接调用 `packager.pack(message:pack_body())`，encode 错误以 `error()` 传播
2. `Dispatcher.handle_message` 用 `safe_render` 辅助函数在边界处 `pcall(Protocol.render, ...)` 捕获
3. `Client.call` 在边界处 `pcall(Protocol.render, request, packager)` 捕获
4. `Dispatcher.pack`（GET introspection）保留 pcall（非热路径，无性能影响）

**不变内容**：
- encode 仍用 `error(msg, 0)`（与 cjson.encode 对齐）
- decode 仍用 `return nil, err`（ADR #34 不变）
- 鸭子类型第零步规则不变：内置实现的错误处理形式仍与外部对标函数一致
- pcall 仍合法用于多态接口——只是位置从 render 内部移到调用方边界

**决策树第零步修正**：

```
第零步：函数是否属于多态/鸭子类型接口？
  │
  ├─ 是 → 错误处理形式必须与外部对标函数签名一致
  │    · 对标函数 throw error() → 内置实现也 throw error()
  │    · 对标函数 return nil, err → 内置实现也 return nil, err
  │    · error() 传播到调用方边界，由调用方在边界处 pcall 捕获
  │      （pcall 在边界，不在内部热路径——LuaJIT JIT 硬屏障约束）
  │
  └─ 否 → 进入第一步三分类法
```

### 知识领域

1. *Design Patterns*（GoF）— "Program to an interface, not an implementation" 鸭子类型原则
2. *Programming in Lua*（Ierusalimschy）第 16 章 — pcall 与 error level 语义
