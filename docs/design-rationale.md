# Yar-Lua 设计选型与对比

本文档留存 Yar-Lua 在开发过程中的选型思路、类库对比与设计决策，供后续维护与社区参考。

## 一、网络层选型：为什么选择 luasocket

Yar-Lua 默认采用 [luasocket](https://github.com/lunarmodules/luasocket) 作为网络层，并通过 `transport/socket.lua` 提供者抽象允许注入 OpenResty cosocket。这一选择基于以下对比与设计考量。

### 候选类库对比

| 类库 | 协议 | 协程模型 | 纯 Lua 可用 | 维护状态 | 适合 Yar-Lua |
|------|------|----------|-------------|----------|--------------|
| **luasocket**（默认） | TCP/UDP/HTTP 1.0/1.1 | 同步（可由协程运行时调度） | ✅ | 活跃，v3.1.0，lunarmodules 官方 | ✅ 标准、轻量、可注入 |
| [lua-http](https://github.com/daurnimator/lua-http) | HTTP 1.0/1.1/**/2.0**/WebSocket | cqueues 协程 | ⚠️ 依赖 cqueues（C 扩展）、不支持 Windows | v0.4（2021），偏沉寂 | ❌ 过重，YAR 仅 POST 二进制，无需 HTTP/2 |
| [lua-resty-http](https://github.com/ledgetech/lua-resty-http) | HTTP 1.0/1.1 | ngx cosocket | ❌ **仅 OpenResty** | 活跃，v0.18.0 | ⚠️ 不能作纯 Lua 默认；OpenResty 下已通过 cosocket 注入等价覆盖 |
| [lua-eco](https://github.com/zhaojh329/lua-eco)（可选并发） | TCP/UDP | 协程优先（epoll） | ✅ | 活跃 | ✅ 并发场景天然搭配 `handle({ socket = ... })` |
| [Skynet](https://github.com/cloudwu/skynet)（可选并发） | TCP/UDP | Actor + 协程 | ✅ | 活跃 | ✅ 高并发服务端，fd-based socket 适配即可 |

### 设计思想

**1. 纯 Lua 优先，不绑定运行时**

Yar-Lua 的首要定位是"纯净的 Lua RPC 框架代码"。luasocket 是 Lua 生态中**事实标准的网络库**（lunarmodules 官方组织维护，Kong、LuaSec 等均依赖它），纯 Lua 环境开箱即用。若默认依赖 lua-resty-http（OpenResty 专用）或 lua-http（依赖 cqueues C 扩展），则脱离 OpenResty 即不可用，违背"纯 Lua"前提。

**2. 协议够用即可，不引入不必要的复杂度**

YAR over HTTP 仅是 POST 一段二进制 body，用不到 HTTP/2、WebSocket、分块传输等高级特性。lua-http 虽更"先进"（支持 HTTP/2），但引入 cqueues 依赖、破坏跨平台（不支持 Windows）、增加维护风险，收益却为零。luasocket 的 HTTP 1.1 能力完全覆盖 YAR 的传输需求。

**3. 提供者抽象——一份代码覆盖两个生态**

真正的"先进"不在类库本身，而在架构。`transport/socket.lua` 把网络层抽象为可替换的提供者：

- **默认**：luasocket 适配器，超时统一为毫秒（与 cosocket 契约对齐）。
- **OpenResty**：`Yar.client.set_socket(ngx.socket)` 注入 cosocket，零改动复用非阻塞 I/O 与连接池，能力等价于 lua-resty-http 的底层。

这样，纯 Lua 用户用 luasocket（标准），OpenResty 用户注入 cosocket（生产级高并发），**框架代码零 `ngx` 引用、零分支判断**，两个生态共享同一套协议与传输逻辑。

**4. 并发可演进，不提前优化**

默认 `listen(addr) + loop()` 是顺序 accept（阻塞、单连接串行），适合开发调试。`handle({ socket = client })` 已与 accept 循环分离，标准 Lua 下接入 lua-eco（epoll 协程优先）或 Skynet（Actor 协程）即可并发，OpenResty 下交给 nginx worker 协程调度。并发能力按需引入，不把任何并发运行时设为硬依赖。

## 二、与 yar-c 能力对比

[ yar-c](https://github.com/laruence/yar-c) 是 Yar 的 C 语言实现，Yar-Lua 参考其协议规范。两者定位不同：yar-c 是自带进程管理的 daemon（libevent + pre-fork），Yar-Lua 是纯协议库，进程管理交给宿主。

| 能力维度 | yar-c (C) | yar-lua | 评估 |
|---|---|---|---|
| YAR 二进制协议（8B packager + 82B header + body） | ✅ | ✅ | 完整对齐 |
| Msgpack packager | ✅ 唯一支持 | ✅ `msgpack.lua` | 对齐 |
| JSON packager | ❌ | ✅ `json.lua` | yar-lua 多一种 |
| packager 可选/可注册 | ❌ 写死 msgpack | ✅ `Yar.register_packager` | yar-lua 更灵活 |
| TCP 客户端 | ✅ | ✅ `transport/tcp.lua` | 对齐 |
| HTTP 客户端 | ❌ `return NULL`（C 客户端不支持 HTTP） | ✅ `transport/http.lua` | yar-lua 胜出 |
| Unix socket 客户端 | ✅ | ✅ `transport/tcp.lua` + `socket.unix()` | 对齐 |
| TCP 服务端 | ✅ libevent daemon | ✅ `server/tcp.lua` | 对齐（并发模型不同） |
| HTTP 服务端 | ❌（C server 是纯 TCP daemon） | ✅ `server/http.lua` | yar-lua 多一层 |
| 方法注册 `register_handler` | ✅ | ✅ `Server:register`（链式） | 对齐 |
| 协议核心与传输解耦 | ❌ server 绑定 libevent/I/O | ✅ `handle_message` 纯函数、无 I/O | yar-lua 架构更干净 |
| 预 fork 多 worker | ✅ `MAX_CHILDREN` 等 | ❌ 单进程顺序 accept | yar-c 有，yar-lua 缺（但 `handle({ socket = ... })` 已抽出，可交 lua-eco / Skynet / OpenResty 协程并发） |
| daemon 运维选项（PID/LOG/CHILD_USER…） | ✅ 11 项 | ❌ 委托宿主进程 | yar-c 有，yar-lua 有意不做（纯库定位） |
| 持久连接 persistent link | ✅ `YAR_PERSISTENT_LINK` | ✅ `options.persistent` 显式开关 | 对齐 |

**小结**：Yar-Lua 完整实现核心协议能力，在 HTTP 客户端/服务端、JSON packager、协议核心解耦上超越 yar-c；原缺失项（Unix socket 客户端、persistent link 显式开关）已补齐。仍缺 pre-fork worker、daemon 运维选项，属"纯库定位"的有意取舍。

## 三、客户端 / 服务端选项对比

### 客户端选项

| 选项 | yar-c (C) | PHP yar 扩展 | yar-lua | 说明 |
|---|---|---|---|---|
| packager 选择 | ❌ 写死 msgpack | ✅ `YAR_OPT_PACKAGER` | ✅ `packager` | yar-lua 对齐 PHP |
| timeout（调用超时） | ❌（仅 connect timeout） | ✅ `YAR_OPT_TIMEOUT` | ✅ `timeout` | 对齐 PHP |
| connect_timeout | ✅ `YAR_CONNECT_TIMEOUT` | ✅ `YAR_OPT_CONNECT_TIMEOUT` | ✅ `connect_timeout` | 三者都有 |
| persistent link | ✅ `YAR_PERSISTENT_LINK` | ✅ `YAR_OPT_PERSISTENT` | ✅ `persistent` | 对齐 PHP，TCP 跨 call 复用连接 |
| 自定义 header | ❌ | ✅ `YAR_OPT_HEADER` | ✅ `headers` | yar-lua 对齐 PHP |
| token | ❌ | ✅ `YAR_OPT_TOKEN` | ✅ `token` | 对齐 PHP |
| provider | ❌ | ✅ `YAR_OPT_PROVIDER` | ✅ `provider` | 对齐 PHP |
| resolve | ❌ | ✅ `YAR_OPT_RESOLVE` | ✅ `resolve` | 对齐 PHP，格式 `host:port:ip`（curl）或 `host:ip`（PHP） |
| proxy | ❌ | ✅ `YAR_OPT_PROXY` | ✅ `proxy` | 对齐 PHP，HTTP 代理连接 |

> yar-c C 客户端选项极少（仅 2 个），PHP yar 扩展选项丰富。Yar-Lua 的选项设计对齐 PHP yar 扩展，已实现全部 9 项。

### 服务端选项

| 选项 | yar-c (C) | yar-lua | 说明 |
|---|---|---|---|
| STAND_ALONE（独立 daemon） | ✅ | ⚠️ `Server:listen() + Server:loop()` 可独立跑 | 定位不同 |
| READ_TIMEOUT | ✅ | ✅ `options.timeout` | 对齐 |
| PARENT_INIT / CHILD_INIT | ✅ | ❌ | 无 pre-fork，无对应 |
| CHILD_USER / CHILD_GROUP | ✅ | ❌ | 进程权限，委托宿主 |
| MAX_CHILDREN | ✅ | ❌ | 无 worker 模型 |
| CUSTOM_DATA | ✅ | ✅（通过闭包/服务对象自带） | 等价能力 |
| PID_FILE | ✅ | ❌ | 运维项，委托宿主 |
| LOG_FILE / LOG_LEVEL | ✅ | ❌（仅 `print` 错误） | 运维项，委托宿主 |

> Yar-Lua 服务端选项只有 `timeout`。yar-c 的 11 项里大部分是 daemon 运维（pid/log/user/group/children），在 Yar-Lua 的"纯库"定位下有意不做，交给 nginx / systemd / supervisord。

## 四、客户端代理与协议抓包

- **yar-c**：客户端直连 TCP/Unix socket，无 proxy 选项，无法做 HTTP 代理抓包。
- **PHP yar**：有 `YAR_OPT_PROXY`，支持 HTTP 代理。
- **yar-lua 现状**：`client.lua` 的 `DEFAULT_OPTIONS` 已支持 `proxy` 选项；`transport/http.lua` 在有 `options.proxy` 时 connect 到代理地址、请求行用绝对 URI。HTTPS over proxy（CONNECT 隧道）已实现。

Yar-Lua 已实现 `proxy` 选项（对齐 PHP yar），且抓包是 socket 抽象的天然副产品：

1. **`proxy` 选项（已实现）**：`transport/http.lua` 里，若有 `options.proxy`（格式 `http://host:port`，端口可省略默认 8080），改为 connect 到代理地址、请求行用绝对 URI（`POST http://host/path HTTP/1.1`）。HTTPS over proxy 通过 CONNECT 隧道实现：先发 `CONNECT host:port` 请求，代理回 200 后再 sslhandshake（SNI 用目标 host），隧道建立后后续 TLS 握手与请求发送与直连一致。
2. **`resolve` 选项（已实现）**：`options.resolve`（格式 `host:port:ip` curl 风格 或 `host:ip` PHP 风格），connect 前用自定义 IP 替换 host，Host header 保持原 host。HTTP 与 TCP 传输均支持。
3. **socket 提供者注入做抓包（yar-lua 独有优势）**：`Yar.client.set_socket(custom)` 可注入"镜像 socket"——在 `send`/`receive` 里 dump 原始 YAR 二进制帧到文件或 Wireshark 透传。这是协议级抓包，比 HTTP 代理更底层，能抓 TCP 传输的 YAR 帧。yar-c 没有这层抽象，做不到不动核心代码就插入抓包层。

## 五、Unix socket 客户端实现

Yar-Lua 的 Unix socket 客户端复用 TCP 传输器（`transport/tcp.lua`），不新建独立传输模块。理由：

- **协议相同**：TCP 与 Unix socket 都是 `SOCK_STREAM`，YAR 帧格式（packager + header + body）完全一致，`receive_message`/`receive_exact` 逻辑共享。
- **职责分层**：`socket.lua` 拥有 `unix()` 工厂（创建 AF_UNIX socket），`tcp.lua` 委托 socket 创建并按 `unix_path` 分支 connect。这与业界一致——Go `net/http` 复用 Transport 仅改 `DialContext`、Python `requests-unixsocket` 只替换 socket 创建层、curl 用 `CURLOPT_UNIX_SOCKET_PATH` 连接层选项。
- **cosocket 兼容**：cosocket 无独立 unix socket 类型，用 `tcp():connect("unix:"..path)`。由注入的 provider 在其 `unix()` 函数内封装此差异，框架代码不感知 provider 差异。

## 六、事务 ID 生成：为什么不由库播种 `math.randomseed`

Yar 协议头的事务 ID 字段为 uint32（4 字节，大端），用于匹配请求与响应。`_M.gen_id()` 负责生成此 ID。本库**不调用 `math.randomseed` 播种**，理由如下。

### 1. `math.randomseed` 是进程级全局副作用

Lua 的 `math.randomseed` 修改的是整个 Lua VM 的全局随机状态，没有作用域隔离，也没有"恢复原种子"的 API。一旦库调用它，整个进程后续所有 `math.random` 调用都受影响——包括宿主业务代码、第三方库、协程内并发调用。库无法预知宿主是否已播种、播种策略是什么，贸然播种必然破坏宿主预期。

### 2. 覆盖宿主种子，破坏宿主随机序列

若宿主已按自身策略播种（例如 OpenResty `init_by_lua` 阶段用 `ngx.time() + ngx.worker.pid()` 播种一次），库在首次生成 ID 时再次播种，会**覆盖**宿主的种子，使宿主后续 `math.random` 序列重置。这种污染是隐式的、不可逆的，极难排查。

### 3. OpenResty 多 worker 下的种子冲突

OpenResty 多 worker 架构中，每个 worker 是独立 Lua VM。若库懒播种：

- 各 worker 独立调用 `math.randomseed`，种子若含 `os.time()`（秒级），同秒启动的 worker 种子可能相同 → 跨 worker ID 碰撞。
- 即便种子含 `tostring({})` 表地址能区分，库仍修改了每个 worker 的全局随机状态，与宿主在 `init_by_lua` 的播种策略冲突。

### 4. 不播种 ≠ "随机但有碰撞概率"，而是确定性序列

Lua `math.random` 底层是 C 的 `rand()`，未调用 `math.randomseed` 时默认种子=1（C 标准）。这意味着**不播种的 `math.random` 是完全确定性的**——每次进程启动产生相同序列。多进程/多 worker 直接用未播种的 `math.random` 生成 ID，首请求 ID 全相同，跨进程必撞。所以"不播种"不能简单依赖 `math.random`，必须引入其他熵源。

### 5. 业界惯例：库不播种

Lua 生态中处理随机 ID 的成熟库均不由库自身播种：

- [uuid.lua](https://github.com/Tieske/randomlua)（Tieske）：明确不调用 `math.randomseed`，提供可选 `seed()` 便捷函数但需宿主显式调用。
- [lua-resty-uuid](https://github.com/agentzh/lua-resty-uuid)：基于 OpenResty，用 `ngx.time()` 等只读熵源，不碰全局随机状态。

种子管理是**应用层职责**，库只提供生成能力与注入点。

### 6. 本库方案

`_M.gen_id()` 的默认实现 `default_gen_id` **不调用 `math.randomseed`**，改用纯数学方式混合多个熵源成 uint32：

| 熵源 | 贡献 | 说明 |
|------|------|------|
| `os.time()` | 跨秒区分 | 秒级时间戳 |
| `sequence` | 进程内不重复 | 单调递增计数器，保证同进程内 ID 不撞 |
| `tostring({})` 表地址 | 跨进程区分 | 每次进程启动地址不同 |
| `math.random` | 随机分量 | 沿用宿主当前随机状态（不播种） |

混合用纯数学（兼容 Lua 5.1 无位运算），逐步取模避免 double 精度丢失。单进程内靠 `sequence` 保证不重复；跨进程靠时间戳 + 表地址区分。

同时提供 `Yar.set_id_generator(fn)` 注入点：

- 注入后，库不再调用默认实现，彻底隔离宿主的 `math.randomseed` 状态，无时序陷阱。
- OpenResty 多 worker 场景建议注入基于 `ngx.worker.pid()` + `ngx.time()` 的生成器，worker 间天然区分。
- 纯 Lua 单进程若需更强随机性，宿主可自行播种后注入 `function() return math.random(0, 0xFFFFFFFF) end`，种子生命周期由宿主掌控。

### 7. 方案对比

| 方案 | 碰撞风险 | 污染宿主 | 库职责边界 | 采用 |
|------|----------|----------|-----------|------|
| 库懒播种 | 中（秒级种子可能撞） | ✅ 严重 | ❌ 越权 | ❌ |
| 库不播种、纯 `math.random` | 高（确定性序列，多进程必撞） | ✅ 无 | ✅ 纯粹 | ❌ |
| 库不播种、多熵源混合（本方案） | 低 | ✅ 无 | ✅ 纯粹 | ✅ |
| 注入式（本方案提供） | 取决于注入实现 | ✅ 无 | ✅ 纯粹 | ✅（推荐 OpenResty） |

### 8. 种子便利函数（P4）

在"库不越权播种"原则下，本库提供 `Yar.seed(fn)` 便利函数——业务层提供播种函数 `fn`，库调用 `fn()` 执行播种。这只是便利封装（等价于业务层直接调用 `fn()`），库永远不自动播种，仅在显式调用时执行。

**`gen_id` 无需播种即可工作**（有意设计）：默认实现的多熵源混合已将冲突概率压到极低，播种是可选的生产增强，不是前置条件。这与 Lua 业界惯例一致——uuid.lua 提供 `seed()` 便捷函数但不强制调用，库不设"模式"、不做"未播种则报错"的检查。

**OpenResty 播种作用域**：`math.randomseed` 是进程级（per-worker Lua VM）。在 `init_by_lua` 阶段播种一次，对该 worker 的所有协程生效（协程共享同一 Lua VM 的全局随机状态）。每个 worker 是独立 VM，需各自播种。

```lua
-- init_by_lua 阶段
local Yar = require("yar")
Yar.seed(function()
    math.randomseed(ngx.time() + ngx.worker.pid())
end)
```

### 9. 与 PHP Yar / yar-c 的 ID 生成对比

| 实现 | ID 生成方式 | 播种策略 | 冲突风险 |
|------|-----------|----------|----------|
| **PHP Yar**（扩展） | `(long)php_mt_rand()` — 单个 Mersenne Twister 随机数 | PHP 运行时懒播种（`GENERATE_SEED()` = time + getpid） | 低（PHP 自动播种，但仅单随机数无单调计数器） |
| **yar-c**（C 实现） | `request->id = 1000` — **硬编码 dummy 值** | 无 | **高**（所有请求 ID 相同，未实现 ID 生成） |
| **lua-yar**（本库） | 多熵源混合 + 进程内单调递增计数器 | 库不播种，提供 `seed(fn)` 便利函数 | 极低（进程内零冲突，跨进程靠地址+时间+计数器区分） |

**小结**：lua-yar 的 ID 生成比 PHP Yar 和 yar-c 都更健壮——进程内靠 `sequence` 单调递增保证零冲突（PHP Yar 仅靠 `mt_rand` 无此保证），跨进程靠 `tostring({})` 表地址区分（yar-c 根本没实现）。极小概率跨进程冲突是有意设计：事务 ID 仅用于单次请求-响应匹配（uint32），不是全局唯一 ID，YAR 同步请求-响应模型不依赖 ID 匹配响应。生产环境追求更高随机性可调用 `Yar.seed(fn)` 播种。

## 七、为什么不由库自动生成 trace_id

分布式追踪中的 `trace_id`（链路追踪 ID）用于跨服务、跨请求关联调用链。本库**不自动生成 trace_id**，也不在协议头中预留 trace_id 字段，理由如下。

### 1. 纯协议库定位，不做可观测性框架

Yar-Lua 的定位是**纯 YAR 协议库 / SDK**（运行时无关），不是可观测性平台绑定。trace_id 属于应用层的可观测性关注点，其生成策略、传播格式（W3C Trace Context、B3、Jaeger 等）、采样率、上报后端，均因业务与基础设施而异。协议库若内置 trace_id 生成，等于替业务层做了可观测性决策，越权且不可逆。

### 2. trace_id 是应用层职责

trace_id 的生命周期横跨多个 RPC 调用甚至多个服务，其生成与传播策略属于**应用层的横切关注点**。业界惯例：

- OpenTelemetry、Jaeger、Zipkin 等追踪框架均由**应用层或 SDK 显式注入** trace context，不由底层 RPC 库自动生成。
- nginx、envoy 等代理只在请求头透传 trace context，不生成 trace_id。
- 即使是 YAR 协议本身，PHP yar 扩展和 yar-c 也都不生成 trace_id——事务 ID (`id` 字段) 仅用于单次请求-响应匹配，不承担跨调用链追踪职责。

### 3. hooks 已提供注入点

本库的 `on_request` / `on_response` hooks（见 S4）已为应用层提供完整的 trace_id 注入与传播通道：

- **注入**：应用层在 `on_request` hook 中从上游（如 HTTP header `traceparent`）提取 trace_id，写入请求 params 或 provider 字段。
- **传播**：`on_response` hook 中将 trace_id 回写到响应，或记录到日志。
- **生成**：若上游无 trace_id，应用层可在 hook 内调用自有的 trace_id 生成器（如 OpenTelemetry SDK），库不参与。

```lua
server:set_options({
    hooks = {
        on_request = function(method, params)
            -- 应用层从 header 提取或生成 trace_id，注入外部上下文
            -- hooks 是只读回调，不传 request 对象；trace_id 需通过应用层 context 管理
            ctx.trace_id = ngx.var.http_traceparent or generate_trace_id()
        end,
        on_response = function(method, retval, err)
            -- 应用层传播 trace_id 到日志
            log(ctx, ctx.trace_id, method)
        end,
    },
})
```

hooks 是显式的、应用层掌控的注入点，库不隐式生成任何追踪标识。

### 4. 不污染全局状态

自动生成 trace_id 需要维护进程级或请求级的 trace context 状态。这与本库"不持有进程级可变全局状态"的哲学冲突（唯一的全局状态是 `math.randomseed` 相关，已通过 P4 的种子模式 API 显式管理）。trace context 的生命周期与传播规则应由可观测性框架管理，库不应引入隐式的全局状态。

### 5. 协议头无 trace_id 字段

YAR 协议头（82 字节）的设计中，事务 ID (`id`，uint32) 仅用于**单次请求-响应匹配**，不承担跨调用链追踪职责。在协议头中新增 trace_id 字段会破坏与 PHP yar / yar-c 的二进制兼容性。trace_id 若需传播，应通过 body 内的业务字段（params 或自定义字段）携带，由应用层编解码。

### 6. 方案对比

| 方案 | 库职责边界 | 全局状态污染 | 协议兼容 | 采用 |
|------|-----------|-------------|----------|------|
| 库自动生成 trace_id | ❌ 越权（可观测性决策） | ✅ 需维护 trace context | ⚠️ 需改协议头 | ❌ |
| 库提供 trace_id 生成工具函数 | ⚠️ 边界模糊 | ✅ 无 | ✅ 无影响 | ❌（hooks 已覆盖） |
| 库不生成、hooks 注入（本方案） | ✅ 纯粹 | ✅ 无 | ✅ 无影响 | ✅ |

**小结**：trace_id 的生成与传播是应用层可观测性框架的职责。本库通过 hooks 提供显式注入点，应用层可自由集成 OpenTelemetry / Jaeger 等追踪方案，库不越权生成、不持有 trace context、不破坏协议兼容性。
