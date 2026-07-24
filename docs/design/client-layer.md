# 客户端层设计决策

客户端层（`client.lua`）是用户调用 RPC 的入口。负责构造请求、选择传输器、发送/接收、解析响应、错误分类。

---

## 25. 结构化 Error 对象：5 个错误码 + .code 字段

- **状态**：已实现
- **决策驱动因素**：可调试性
- **关联决策**：#27（错误分类）、#14（pcall 保护）

### 背景

Lua 惯例是返回 `nil, err`，`err` 通常是字符串。但字符串错误难以程序化匹配——调用方要 `string.find(err, "timeout")` 做前缀匹配，脆弱且易漏。

### 思考与取舍

> "Errors are values." — Rob Pike
> "错误也是值。" — Rob Pike

`error.lua` 定义 5 个错误码常量（字符串值，自文档化）：
- `Error.TRANSPORT` — 传输层错误（连接失败、发送失败、HTTP 状态错误）
- `Error.TIMEOUT` — 超时（连接超时、读写超时）
- `Error.PROTOCOL` — 协议解析错误（畸形包、packager 不匹配、header 校验失败）
- `Error.NOT_FOUND` — 方法未找到（服务端 status=1，"method not found" 前缀）
- `Error.EXCEPTION` — 方法执行异常（服务端 status=1，其他错误）

`Error.new(code, message)` 返回 `{code=, message=}` 表，带共享 metatable（`__tostring` 返回 `message`）。调用方用 `err.code == Error.TIMEOUT` 精确匹配，无需字符串解析。

### 业界参考

- **Go errors**：`errors.New()` 返回 error 接口值，可类型断言。
- **Python exceptions**：异常类层级，`except TimeoutError` 精确捕获。
- **PHP Yar**：`Yar_Client_Exception` 异常类，有 `getType()` 方法分类。

### 代码评价

`error.lua` 仅 37 行，设计简洁。错误码用字符串值（`"TRANSPORT"` 等）而非数字，debug 时可直接辨识。共享 metatable `Error_mt` 避免每次 `Error.new` 创建新 metatable + 闭包。`Error.new` 对 `code` 类型校验（非字符串则降级为 `EXCEPTION`）。`client.lua` 的 `call()` 在每个错误返回路径构造 `Error.new(code, msg)` 并传给 `on_response` hook，一致性好。

### 知识领域

1. *A Philosophy of Software Design*（John Ousterhout）— 错误处理与深层模块
2. *Release It!*（Michael Nygard）— 错误分类与故障模式

---

## 26. 客户端选项设计：对齐 PHP yar 并扩展

- **状态**：已实现
- **决策驱动因素**：兼容性、可维护性
- **关联决策**：#4（HTTP Provider 委托）、#5（HTTPS 支持）、#6（resolve）、#7（proxy）、#8（persistent）

### 背景

PHP Yar 扩展定义了 `YAR_OPT_*` 常量（`YAR_OPT_PACKAGER`、`YAR_OPT_PERSISTENT`、`YAR_OPT_PROVIDER`、`YAR_OPT_TOKEN`、`YAR_OPT_TIMEOUT`、`YAR_OPT_CONNECT_TIMEOUT`、`YAR_OPT_PROXY`、`YAR_OPT_RESOLVE`、`YAR_OPT_HEADER`）。lua-yar 的客户端选项应与之对齐，同时补充 Lua 生态需要的扩展项。

### 思考与取舍

> "Convention over configuration." — Rails 哲学
> "约定优于配置。" — Rails 哲学

`client.lua` 的 `DEFAULT_OPTIONS` 采用**嵌套结构**：
```lua
{
    protocol = { packager, provider, token },
    transport = { timeout, connect_timeout, persistent, headers, proxy,
                  resolve, max_body_len, http_provider, ssl_verify, keepalive },
}
```

同时支持**扁平 key 路由**（`FLAT_KEY_MAP`）：`setopt("timeout", 3000)` 自动路由到 `transport.timeout`，向后兼容旧 API。

对齐 PHP Yar 的选项：`packager`/`provider`/`token`/`timeout`/`connect_timeout`/`persistent`/`proxy`/`resolve`/`headers`。扩展项：`max_body_len`（安全）、`http_provider`（HTTP 委托）、`ssl_verify`（HTTPS 安全）、`keepalive`（连接池参数）。

`deep_copy` + `deep_merge`（Kong 风格递归合并）保证每个 Client 实例有独立的 options 副本，避免共享引用。

### 业界参考

- **PHP Yar**：`Yar_Client::__call()` + `setOpt(YAR_OPT_*, value)`，扁平选项。
- **Kong**：`kong.tools.table.merge` 递归合并，嵌套选项结构。
- **lua-resty-http**：`httpc:connect(host, port, opts)`，扁平 opts。

### 代码评价

`client.lua` 的 `DEFAULT_OPTIONS` 嵌套结构清晰，`FLAT_KEY_MAP` 路由表实现向后兼容。`deep_copy` 处理循环引用（`seen` 表），`deep_merge` 深度限制 100 防无限递归。`set_options(opts)` 构建中间 `routed` 表再合并，不修改调用方 opts。`setopt(opt, val)` 是 `set_options({[opt]=val})` 的便利封装。设计周到，API 统一。

### 知识领域

1. YAR PHP Extension 规范 — `YAR_OPT_*` 选项常量
2. *The Pragmatic Programmer*（Hunt & Thomas）— "Convention over Configuration" 原则

---

## 27. 错误分类：传输层 + 协议层 + 服务端

- **状态**：已实现
- **决策驱动因素**：可调试性
- **关联决策**：#25（结构化 Error 对象）、#14（pcall 保护）

### 背景

RPC 调用可能在三个层面失败：传输层（连接/发送/HTTP 状态）、协议层（解析/渲染）、服务端（方法未找到/执行异常）。调用方需要知道错误来自哪个层面，以决定重试策略（传输错误可重试，协议错误不可重试）。

### 思考与取舍

> "Errors are values." — Rob Pike
> "错误也是值。" — Rob Pike

`client.lua` 的 `call()` 在 6 个返回路径构造不同 `Error.code`：
1. packager 获取失败 → `Error.PROTOCOL`
2. 请求渲染失败（pcall） → `Error.PROTOCOL`
3. 传输错误，消息含 "timeout" → `Error.TIMEOUT`
4. 传输错误，其他 → `Error.TRANSPORT`
5. 响应解析失败（pcall） → `Error.PROTOCOL`
6. 服务端 status=1，"method not found" 前缀 → `Error.NOT_FOUND`
7. 服务端 status=1，其他 → `Error.EXCEPTION`

每个错误路径都调用 `run_hook(hooks.on_response, method, nil, err_obj)`，保证 hook 一致性。

### 业界参考

- **gRPC status codes**：`OK`/`CANCELLED`/`UNKNOWN`/`INVALID_ARGUMENT`/`DEADLINE_EXCEEDED` 等 17 个码。
- **HTTP status codes**：1xx/2xx/3xx/4xx/5xx 分类。
- **PHP Yar**：`Yar_Client_Exception::getType()` 返回 `YAR_ERR_*` 常量。

### 代码评价

`client.lua` 的 `call()` 错误分类逻辑清晰。传输错误用 `string.find(e, "timeout", 1, true)` 精确匹配（plain 模式，无模式匹配开销）区分 `TIMEOUT` 和 `TRANSPORT`。服务端错误用 `string.match(msg, "^method not found")` 区分 `NOT_FOUND` 和 `EXCEPTION`。每个错误路径都构造 `Error.new` 并传给 hook，保证 `on_response` 回调的一致性。6 个返回路径全覆盖，无遗漏。

### 知识领域

1. *A Philosophy of Software Design*（John Ousterhout）— 错误分类与模块边界
2. *Site Reliability Engineering*（Google）— 错误分类与故障排查
