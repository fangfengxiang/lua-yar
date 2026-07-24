# 消息层设计决策

消息层（`message/`）定义 YAR 请求与响应的结构体。请求体打包为 `{i=id, m=method, p=params}`，响应体打包为 `{i=id, s=status, r=retval, o=output, e=err}`。

---

## 23. 事务 ID 生成：多熵源 + 不自动播种

- **状态**：已实现
- **决策驱动因素**：健壮性、库不越权
- **关联决策**：#24（trace_id 拒绝自动生成）、#32（纯协议库定位）

### 背景

YAR 协议头的 `id` 字段是 uint32 事务 ID，用于请求-响应匹配。库需要生成唯一 ID，但 `math.randomseed` 是进程级全局副作用——库调用它会覆盖宿主已设置的种子，多 worker 下各 worker 独立播种又会相互覆盖。

### 思考与取舍

> "Setting the seed is the responsibility of the application layer, the library should never set the seed." — Lua 业界惯例（uuid.lua / Tieske）
> "播种是应用层的职责，库永远不应该设置种子。" — Lua 业界惯例（uuid.lua / Tieske）

本库**不调用 `math.randomseed`**。默认 ID 生成器 `default_gen_id()` 混合四个熵源：
1. `os.time()`（秒级时间，取模限制参与位）
2. `sequence`（进程内单调递增计数器，起点用表地址错开多 worker）
3. `process_addr`（`tostring({})` 表地址，ASLR 下每进程不同，模块加载时解析一次）
4. `math.random()`（沿用宿主当前随机状态，不播种）

进程内：`sequence` 单调递增，零冲突。跨进程：`process_addr` + `sequence` 起点偏移提供区分。未播种时 `math.random` 是确定性序列，rand 分量不提供跨进程熵，但其他熵源已将冲突概率压到极低。

提供两个注入点：
- `Yar.seed(fn)` — 业务层提供播种函数，库调用 `fn()` 执行播种（库不决定种子值）
- `Yar.set_id_generator(fn)` — 注入自定义 ID 生成器（如基于 `ngx.worker.pid`）

### 业界参考

- **uuid.lua（Tieske）**：业界标杆库，明确"库不播种"原则。
- **PHP Yar**：`request->id = php_mt_rand()`，PHP 运行时自动播种（`GENERATE_SEED = time + getpid`）。
- **yar-c**：`request->id = 1000`（硬编码 dummy 值，未实现 ID 生成）。
- **Snowflake**：`worker_id` + `sequence` + 时间戳，确定性标识区分节点。

### 代码评价

`request.lua` 的 `default_gen_id` 约 10 行，混合四熵源后 `% UINT32_MOD` 取 uint32。`process_addr` 用 `tostring({})` 提取表地址，模块加载时解析一次（注释说明"跨进程差异源"）。`sequence` 起点用 `process_addr % UINT16_MOD` 错开多 worker。`rand` 用 `math.random()` 无参版本（注释说明跨平台一致性优于 `math.random(0, 0xFFFF)`，后者在 `RAND_MAX=32767` 平台会塌缩）。`seed(fn)` 和 `set_id_generator(fn)` 两个注入点设计清晰。注释详尽（约 30 行设计说明），是有意设计而非疏漏。

### 知识领域

1. *Programming in Lua*（Roberto Ierusalimschy）— `math.random` / `math.randomseed` 语义与全局状态
2. RFC 4122 — *A Universally Unique IDentifier (UUID) URN Namespace*，多熵源 ID 生成原理

---

## 24. trace_id 拒绝自动生成：应用层职责

- **状态**：已实现（有意不做）
- **决策驱动因素**：纯协议库定位
- **关联决策**：#23（事务 ID 生成）、#28（hooks 机制）、#32（纯协议库定位）

### 背景

分布式追踪（如 OpenTelemetry、Jaeger）需要 `trace_id` 贯穿请求链路。库是否应该自动生成 `trace_id` 并注入到 YAR 协议头或 hooks 中？

### 思考与取舍

> "Do one thing and do it well." — Unix 哲学
> "做好一件事。" — Unix 哲学

lua-yar 是**纯协议库**，不是运行时框架。`trace_id` 的生成策略（UUID v4？Snowflake？W3C Trace Context？）和传播方式（HTTP header？协议头扩展？日志关联？）是**应用层架构决策**，不是协议库的职责。

库提供 `hooks` 机制（`on_request` / `on_response`）作为注入点，业务层可在 hook 中生成/传播 `trace_id`。库不越权决定 trace 语义。

备选方案：库内置 trace_id 生成器（如 UUID v4）。但会引入"库选择的 trace 方案"与"业务实际使用的 trace 系统"不匹配的问题，且增加库的复杂度。

### 业界参考

- **OpenTelemetry**：SDK 不自动生成 trace_id，由 tracer provider 配置决定。
- **gRPC-go**：`metadata` 传递 trace context，但 trace_id 由应用层 tracer 生成。
- **PHP Yar**：无 trace_id 概念。

### 代码评价

`request.lua` 和 `response.lua` 中无 `trace_id` 字段。`client.lua` 和 `server/init.lua` 的 `run_hook` 机制提供 `on_request(method, params)` / `on_response(method, retval, err)` 注入点，业务层可在 hook 中注入 trace 逻辑。库的职责边界清晰——提供机制，不提供策略。这是"有意不做"的设计决策，遵循 Unix 哲学和纯协议库定位。

### 知识领域

1. *The Art of Unix Programming*（Eric Raymond）— "Do one thing and do it well" 原则
2. *A Philosophy of Software Design*（John Ousterhout）— 模块职责边界与 deep modules
