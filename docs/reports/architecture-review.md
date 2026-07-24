# Yar-Lua 架构测评报告

> 本文档从项目整体视角，结合业界 RPC 类库、Yar 协议规范、Lua 高 Star 网络库与工程化实践，对 Yar-Lua 进行系统性解读与评估。

---

## 一、项目定位与设计哲学

Yar-Lua 是 PHP Yar RPC 协议的纯 Lua 实现，定位为**协议库而非运行时框架**。这一核心定位决定了所有架构决策：

```
┌─────────────────────────────────────────────────────────────────┐
│                        宿主运行时                                │
│  (OpenResty / lua-eco / Skynet / copas / 标准 Lua + luasocket)  │
├─────────────────────────────────────────────────────────────────┤
│  yar/server/http.lua    yar/server/tcp.lua    yar/server/init   │
│  (HTTP 传输层)           (TCP 传输层)          (纯协议核心)      │
│  handle_connection       handle_connection     handle_message   │
├─────────────────────────────────────────────────────────────────┤
│  yar/protocol/         yar/packager/         yar/message/      │
│  header + framing      json + msgpack        request + response│
├─────────────────────────────────────────────────────────────────┤
│  yar/transport/        yar/client.lua        yar/util.lua      │
│  http + tcp + socket   客户端入口            二进制工具         │
└─────────────────────────────────────────────────────────────────┘
```

**设计哲学三原则**：

1. **零 C 扩展依赖** — JSON、MessagePack、二进制编解码全部纯 Lua 实现
2. **协议核心与传输解耦** — `handle_message(data)` 是纯函数，无 I/O、无 yield、reentrant
3. **提供者抽象** — 一份代码通过 `socket.lua` 抽象覆盖 luasocket 和 cosocket 两个生态

---

## 二、分层架构详解

### 2.1 协议层 (`protocol/`)

**消息布局**：`[packager_name:8B][header:82B][body:N]`

```lua
-- yar/protocol/protocol.lua
function _M.render(message, packager)
    local payload = packager.pack(message:pack_body())
    local packager_name = Util.pad_field(packager.name, PACKAGER_NAME_SIZE)
    local header = Header.new({
        id       = message.id,
        provider = message.provider,
        token    = message.token,
        body_len = #payload,
    })
    return packager_name .. header:pack() .. payload
end
```

**评价**：

- **严格对齐 YAR 规范**：82 字节 header（`id:u32 + version:u16 + magic:u32 + reserved:u32 + provider:[32] + token:[32] + body_len:u32`），magic_num `0x80DFEC60` 与 PHP yar / yar-c 完全一致
- **二进制编解码用纯数学**（`math.floor(n / 0x100) % 0x100`），兼容 Lua 5.1 / LuaJIT（无 `string.pack`）。这是务实的选择 — LuaJIT 是 OpenResty 的运行时基础，不支持 5.3 的 `string.pack`
- **framing.lua 的 `receive_exact`** 实现了精确字节读取循环，正确处理了 TCP 流的 partial read 问题

**与业界对比**：

- gRPC 使用 HTTP/2 + Protobuf，协议复杂度远高于 YAR 的 90 字节固定头 + body
- YAR 的设计更接近 **Thrift TBinaryProtocol** — 固定头 + body 的二进制帧，简单、可互操作
- 相比 yar-c（C 实现），yar-lua 在协议层完全对齐，且多了 JSON packager（yar-c 仅支持 msgpack）

### 2.2 序列化层 (`packager/`)

项目自带两个零依赖序列化器：

| 维度 | `json.lua` | `msgpack.lua` |
|------|-----------|--------------|
| 代码量 | ~240 行 | ~370 行 |
| 编码方式 | 逐字节 `string.byte` + `table.concat` | 类型标记 + `Util.pack_u*` |
| 闭包可重入 | ✅ `decode` 内部闭包持有 `str/pos/len` | ✅ 同上 |
| 协程安全 | ✅ 无全局状态 | ✅ 无全局状态 |
| 特殊处理 | UTF-16 代理对合并 | IEEE754 double 纯数学编解码 |

**亮点**：

1. **闭包保证可重入性** — `json.lua` 的 `decode` 函数将 `str/pos/len` 作为 upvalue，多个协程并发调用各自持有独立状态，无需担心全局变量污染。这是 OpenResty 多协程环境下的关键安全保证

2. **MessagePack IEEE754 double 编解码** — `msgpack.lua` 的 `pack_double` 用 `math.frexp` 分解尾数和指数，纯数学构造 8 字节 IEEE754 大端表示。`unpack_double` 用 `math.ldexp` 反向还原，包括非规格化数、NaN、Inf 的完整处理

3. **数组/对象判断** — 两个 packager 都用 `count == n` 判断是否为连续整数键数组，这是 Lua table 序列化的经典做法

**与业界对比**：

- **cjson**（OpenResty 内置）：C 扩展，性能高但不可用于纯 Lua 环境
- **lua-cmsgpack**：C 扩展，同上
- **dkjson**（纯 Lua JSON）：业界最流行的纯 Lua JSON 库，yar-lua 的实现功能对齐但更精简
- **lua-MessagePack**：纯 Lua msgpack，yar-lua 的实现覆盖了所有常用类型

**取舍评价**：自带序列化器而非依赖外部库，是"零依赖"定位的必然选择。代价是性能不如 C 扩展（逐字节 `string.byte` vs SIMD 优化），但对 YAR 的使用场景（RPC body 通常不大）足够。如果未来需要高性能路径，可通过 `Yar.register_packager` 注入 cjson/cmsgpack 版本，架构已预留扩展点。

### 2.3 传输层 (`transport/`)

传输层是本项目架构设计最精妙的部分：

```
transport/
├── transport.lua    # 工厂：按 URL scheme 选择 http/tcp
├── socket.lua       # ★ 提供者抽象（核心）
├── http.lua         # HTTP 传输（POST 二进制 body）
├── tcp.lua          # TCP 传输（YAR 帧协议）
└── resolve.lua      # DNS 自定义解析
```

**`socket.lua` 的提供者模式**：

```lua
-- yar/transport/socket.lua
local function wrap(s)
    return {
        settimeout = function(_, ms)
            if ms == nil then return s:settimeout(nil) end
            return s:settimeout(ms / 1000)  -- 毫秒统一
        end,
        connect    = function(_, ...) return s:connect(...) end,
        send       = function(_, ...) return s:send(...) end,
        receive    = function(_, ...) return s:receive(...) end,
        close      = function(_, ...) return s:close(...) end,
    }
end
```

这个 wrap 函数做了两件事：
1. **超时统一为毫秒** — luasocket 用秒，cosocket 用毫秒，wrap 层统一为毫秒
2. **方法名对齐** — luasocket 和 cosocket 的 API 本就接近，wrap 消除细微差异

**鸭子类型检测**（`set_timeouts` / `release` / `poolable`）：

```lua
function M.set_timeouts(sock, connect_t, send_t, read_t)
    if sock.settimeouts then        -- cosocket：三段超时
        sock:settimeouts(connect_t, send_t, read_t)
    elseif sock.settimeout then     -- luasocket：退化为单一
        sock:settimeout(read_t)
    end
end
```

cosocket 有 `settimeouts`（三段超时）→ 走三段；luasocket 只有 `settimeout`（单一）→ 退化为单一。`release` 同理：cosocket `setkeepalive` 归池，luasocket `close` 关闭。

**与业界对比**：

| 类库 | 网络抽象方式 | 跨运行时能力 |
|------|-------------|-------------|
| **yar-lua** | 提供者注入 + 鸭子类型 | ✅ luasocket / cosocket / lua-eco / Skynet |
| **lua-resty-http** | 硬绑定 cosocket | ❌ 仅 OpenResty |
| **lua-http** | 硬绑定 cqueues | ❌ 仅 cqueues 环境 |
| **copas** | 包装 luasocket | ⚠️ 仅 luasocket |
| **Go net/http** | `DialContext` 接口 | ✅ 类似思路 |

yar-lua 的提供者抽象与 Go 的 `DialContext` / `Transport` 接口思路一致 — **不绑定具体网络实现，通过接口注入**。这在 Lua 生态中是罕见的设计高度，大多数 Lua 网络库都硬绑定单一运行时。

### 2.4 服务端架构 (`server/`)

**核心分离**：`handle_message`（纯协议） vs `handle_connection`（传输+协议） vs `run`（accept 循环）

```lua
-- yar/server/init.lua
function _M:handle_message(data)
    -- 从消息头部读取 packager 名称，按客户端声明的 packager 解析与响应
    local name = Util.trim_null(string.sub(data, 1, 8))
    local packager = Packager.get(name)
    if not packager then packager = self.packager end
    -- pcall 保护：packager.unpack 可能因畸形数据抛错
    local parse_ok, payload, header, err = pcall(Protocol.parse, data, packager)
    if not parse_ok then err = tostring(payload); payload = nil end
    if not payload then
        -- 构造错误响应并渲染（同样 pcall 保护）
        ...
    end
    local func = self.methods[request.method]  -- memoize 查找
    ...
    local ok, ret = pcall(func, unpack(args))  -- pcall 包裹用户方法
    ...
    local ok, rendered = pcall(Protocol.render, response, packager)
    if not ok then return nil, "render error: " .. tostring(rendered) end
    return rendered
end
```

**关键设计决策**：

1. **服务端按请求头 packager 自适应** — 客户端用 JSON 发，服务端用 JSON 解；用 msgpack 发，用 msgpack 解。响应也用同一 packager 回写。这比 yar-c（写死 msgpack）更灵活

2. **方法表 memoize** — `collect_methods` 在构造时一次性遍历 service 对象建立方法表，热路径直接 `self.methods[request.method]` 查找，不再每请求遍历

3. **`pcall` 包裹用户方法** — 用户方法抛错不会 crash server，错误被捕获写入 YAR response body 的 `e` 字段

4. **`handle_connection` 与 `run` 分离** — 这是并发演进的关键：

```
run(addr)              → 阻塞 accept 循环（开发/测试）
handle_connection(sock) → 连接级处理（可由任意协程调度）
handle_message(data)    → 纯协议处理（无 I/O，reentrant）
```

**与业界对比**：

| 框架 | 协议/传输分离 | 并发模型 |
|------|-------------|---------|
| **yar-lua** | ✅ 三层分离 | 可插拔（OpenResty/eco/Skynet/copas/原生协程） |
| **yar-c** | ❌ server 绑定 libevent | pre-fork + libevent |
| **gRPC-Go** | ✅ `grpc.ServiceDesc` 与传输分离 | goroutine |
| **Twisted** | ✅ Protocol/Transport 分离 | reactor |

yar-lua 的三层分离与 Twisted 的 Protocol/Transport 分离、gRPC 的 ServiceDesc 与传输分离思路一致。**协议核心不感知 I/O** 是 RPC 框架设计的最佳实践。

### 2.5 客户端架构 (`client.lua`)

```lua
-- yar/client.lua
function _M:call(method, params)
    ...
    local message = Protocol.render(request, packager)
    local t
    if self.options.persistent and self._transport then
        t = self._transport                       -- 复用持久连接
    else
        local transport = Transport.get(self.uri)
        t = transport.new()
        t:open(self.uri, self.options)
        if self.options.persistent then
            self._transport = t
        end
    end
    local resp_data, err = t:send(message)
    ...
```

**错误分类设计**：结构化 `Error` 对象（`Error.new(code, msg)` + 5 类 error code：`TRANSPORT`/`TIMEOUT`/`PROTOCOL`/`NOT_FOUND`/`EXCEPTION`），调用方用 `err.code == Error.TIMEOUT` 精确匹配错误类型，无需 `string.match` 字符串前缀。`tostring(err)` 返回消息文本。取代了早期的字符串前缀分类法。（transport-hardening 提案实现）

**persistent 连接复用**：TCP 传输在 persistent 模式下缓存 socket 跨 `call` 复用，发送失败时区分 `sent > 0`（partial send，不可重试）和 `sent == nil/0`（安全重试），这是正确的 TCP 语义处理。

---

## 三、并发模型评估

### 3.1 多运行时适配矩阵

项目提供了 **6 种并发运行时**的示例，这在 Lua 生态中极为罕见：

| 示例 | 运行时 | 并发模型 | 适配方式 |
|------|--------|---------|---------|
| `server_http.lua` | 标准 Lua + luasocket | 顺序（阻塞） | `run()` |
| `server_coroutine.lua` | 标准 Lua + 原生协程 | 协程 + `select` | `handle_connection` + wrap_socket |
| `server_copas.lua` | copas | 协程调度器 | `copas.addserver` + `handle_connection` |
| `server_luaeco.lua` | lua-eco | epoll 协程优先 | `eco.run` + adapter |
| `server_skynet.lua` | Skynet | Actor + 协程 | `socket.start(fd, cb)` + adapter |
| `server_openresty.lua` | OpenResty stream | cosocket | `ngx.req.sock()` 直传 |

**关键洞察**：所有并发示例都调用同一个 `handle_connection` 或 `handle_message`，**核心代码零修改**。这正是三层分离的价值 — 并发能力按需引入，不把任何运行时设为硬依赖。

### 3.2 与 Lua 高 Star 网络库的关系

| 库 | GitHub Stars | 定位 | 与 yar-lua 的关系 |
|----|-------------|------|------------------|
| **luasocket** | ~1.5k | 事实标准网络库 | 默认 socket 提供者 |
| **OpenResty** | ~12k | 生产级 Web 平台 | cosocket 注入目标 |
| **copas** | ~200 | luasocket 协程调度器 | 并发示例之一 |
| **lua-eco** | ~300 | epoll 协程优先运行时 | 并发示例之一 |
| **Skynet** | ~6k | Actor 模型游戏框架 | 并发示例之一 |
| **lua-http** | ~700 | HTTP/2 + cqueues | 设计文档中评估后排除（过重） |
| **lua-resty-http** | ~1.8k | OpenResty HTTP 客户端 | cosocket 注入后等价覆盖 |

**选型评价**：

项目选择 luasocket 作为默认而非 lua-http 或 lua-resty-http，理由充分：

1. **luasocket 是唯一纯 Lua 可用的选择** — lua-http 依赖 cqueues（C 扩展），lua-resty-http 仅 OpenResty 可用
2. **YAR over HTTP 仅需 POST 二进制 body** — 不需要 HTTP/2、WebSocket、分块传输
3. **提供者抽象已覆盖 OpenResty** — 注入 cosocket 后能力等价于 lua-resty-http 底层

这是一个**克制而正确的选型**。没有为了"先进"而引入不必要的依赖。

---

## 四、工程化实践评估

### 4.1 代码质量

| 维度 | 评分 | 说明 |
|------|------|------|
| **模块化** | ★★★★★ | 每个文件职责单一，依赖方向清晰（init → client/server → protocol → packager → util） |
| **文档注释** | ★★★★★ | 每个文件有模块说明，每个公开函数有 ldoc 注释，关键设计决策有行内注释 |
| **错误处理** | ★★★★★ | `pcall` 包裹用户方法、结构化 Error 对象（5 类 error code + `.code` 字段）、partial send 检测 |
| **测试覆盖** | ★★★★☆ | 14 个 spec 文件覆盖协议往返、序列化、服务端派发、选项设置、错误分类、TCP/HTTP 集成、安全边界、软依赖降级；OpenResty E2E 测试已纳入 CI |
| **跨版本兼容** | ★★★★★ | 纯数学二进制操作兼容 5.1/LuaJIT/5.3；`unpack = unpack or table.unpack` |
| **局部化** | ★★★★★ | 全部 22 个源文件标准库 local 化（`local string, math, ... = string, math, ...`），热路径零全局查找 |

### 4.2 测试策略

```
spec/（14 个 spec 文件，busted BDD 框架，112 个 it 块 / 294 个 assert 调用，无需网络）
├── 协议层：json_spec/msgpack_spec/packager_spec（往返 + 深度限制 + 畸形字面量）
├── 协议头：header_spec/framing_spec（打包/解包 + 帧拆解边界）
├── 协议往返：protocol_spec（render/parse）
├── 服务端：server_spec/tcp_server_spec/http_server_spec（派发 + 集成 + keepalive）
├── 客户端：client_spec（选项 + 深拷贝隔离 + 传输错误路径）
├── 错误分类：error_spec（5 类 Error code）
├── 安全边界：security_spec（max_body_len + ssl_verify）
├── 软依赖：soft_dependency_spec（luasocket 缺失降级）
└── 工具：util_spec（二进制编解码）

test/openresty_e2e_test.lua + openresty_http_e2e_test.lua（OpenResty 端到端）
├── cosocket TCP 往返 + 连接池参数透传 + 三段超时
├── HTTP Provider 委托（mock + lua-resty-http）
├── 多协程并发安全 + keepalive 连接池复用
└── 错误分类 + 故障注入（连接中断/慢服务端/脏数据）
```

**亮点**：使用 mock socket（`mock_tcp_socket` / `mock_http_socket`）做集成测试，无需启动真实 server。测试覆盖了 keepalive 多消息帧拆解、连接中途断开等边界场景。

**不足**：缺少与真实 PHP Yar Server 的自动化互通测试（README 中有手动步骤但未纳入 CI）。

### 4.3 CI/CD

```yaml
# .github/workflows/test.yml
矩阵：lua 5.1 / luajit-2.1 / lua 5.3
流程：
  job 1: test（luacheck + busted + luacov 覆盖率）
  job 2: test-no-luasocket（软依赖降级验证）
  job 3: openresty-e2e（cosocket TCP/HTTP 往返 + lua-resty-http provider + nginx content_by_lua）
```

覆盖三个目标运行时，3 个 CI job：标准测试 + 软依赖降级 + OpenResty 端到端。luacheck 0 warnings / 0 errors。codecov 覆盖率采集。合理但可增强：可加入 PHP 互通测试（需要 PHP 环境作为 service container）。

### 4.4 API 设计

**表驱动选项 + 链式调用**：

```lua
-- 表驱动（推荐）
client:set_options({ packager = "MSGPACK", timeout = 3000 })

-- 便捷方法
client:setopt("timeout", 3000):setopt("provider", "my-app")
```

两种风格等价，表驱动适合初始化，`setopt` 适合运行时动态修改。与 PHP yar 扩展的 `YAR_OPT_*` 常量对齐，降低跨语言用户的心智成本。

**选项对齐度**：客户端 12+ 项选项（`packager/timeout/connect_timeout/provider/token/headers/proxy/resolve/persistent/keepalive/ssl_verify/http_provider/max_body_len/hooks`），对齐并超越 PHP yar 扩展（9 项），yar-c 仅 2 项。

---

## 五、与业界 RPC 框架对比

| 维度 | yar-lua | yar-c (C) | gRPC | Thrift | JSON-RPC |
|------|---------|-----------|------|--------|----------|
| **协议复杂度** | 低（90B 头） | 低 | 高（HTTP/2+Protobuf） | 中（TBinaryProtocol） | 低（JSON 文本） |
| **序列化** | JSON/Msgpack | Msgpack | Protobuf | 多种 | JSON |
| **传输** | HTTP/TCP/Unix | TCP/Unix | HTTP/2 | TCP/HTTP | HTTP/TCP |
| **跨语言互通** | ✅ PHP/C/Lua | ✅ PHP/Lua | ✅ 多语言 | ✅ 多语言 | ✅ 多语言 |
| **协议/传输解耦** | ✅ 三层 | ❌ | ✅ | ✅ | 视实现 |
| **并发模型** | 可插拔 | pre-fork | goroutine/thread | 视实现 | 视实现 |
| **零依赖** | ✅ | ❌（libevent） | ❌ | ❌ | 视实现 |
| **服务发现** | ❌ | ❌ | ✅ | ✅ | ❌ |
| **流式调用** | ❌ | ❌ | ✅ | ✅ | ❌ |
| **拦截器/中间件** | ❌ | ❌ | ✅ | ✅ | ❌ |

**定位差异**：

- gRPC/Thrift 是**全功能 RPC 框架** — 有 IDL、代码生成、服务发现、流式调用、拦截器
- Yar（含 yar-lua）是**轻量级 RPC** — 无 IDL、无代码生成、方法名直接字符串调用、参数用原生表传递
- Yar 的设计哲学接近 **JSON-RPC** — 简单、可互操作、低门槛，但用二进制协议提高效率

**yar-lua 在 Yar 生态中的位置**：

| 能力 | yar-c (C) | PHP yar 扩展 | yar-lua |
|------|-----------|-------------|---------|
| 协议完整度 | ✅ | ✅ | ✅ |
| JSON packager | ❌ | ✅ | ✅ |
| HTTP 客户端 | ❌ | ✅ | ✅ |
| HTTP 服务端 | ❌ | ❌ | ✅ |
| 协议核心解耦 | ❌ | ❌ | ✅ |
| 运行时无关 | ❌ | ❌ | ✅ |
| 进程管理 | ✅ | ❌（PHP-FPM） | ❌（委托宿主） |

yar-lua 在协议完整度上对齐 yar-c，在选项丰富度上对齐 PHP yar 扩展，在架构解耦上**超越两者**。

---

## 六、亮点总结

### 1. 提供者抽象模式

`socket.lua` 用 wrap + 鸭子类型实现跨运行时，是 Lua 生态中罕见的架构高度。与 Go `DialContext` 异曲同工 — 不绑定具体网络实现，通过接口注入。

### 2. 三层分离

`handle_message`（纯协议，无 I/O）/ `handle_connection`（连接级，可协程调度）/ `run`（accept 循环，开发测试用）三层分离，并发能力按需引入。与 Twisted Protocol/Transport、gRPC ServiceDesc 同一思路。

### 3. 闭包保证可重入

JSON/Msgpack decoder 用闭包持有解析状态（`str/pos/len` 作为 upvalue），多协程并发安全，无需锁。

### 4. 纯数学二进制编解码

兼容 Lua 5.1/LuaJIT/5.3，不依赖 `string.pack`/`bit32`。IEEE754 double 用 `math.frexp`/`math.ldexp` 完整编解码。

### 5. 六种运行时适配示例

OpenResty/lua-eco/Skynet/copas/原生协程/标准 Lua，全部调用同一核心，零修改。

### 6. Packager 自适应

服务端按请求头声明的 packager 解析和响应，比 yar-c（写死 msgpack）更灵活。

### 7. 结构化 Error 对象

`Error.new(code, message)` + 5 类 error code（TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION）+ `.code` 字段用于程序化匹配。`tostring(err)` 返回消息文本。取代了早期的字符串前缀分类法，下游可用 `err.code == Error.TIMEOUT` 精确匹配，无需 `string.match`。（transport-hardening 提案实现）

### 8. 轻量 Hooks 机制

client + server 各提供 `on_request` / `on_response` 两个回调点，通过 `set_options({ hooks = { ... } })` 配置。hook 在 `pcall` 保护下运行，报错降级为 `Log.warn`，不影响主流程。无 hook 配置时 nil 检查跳过——零开销。支持日志观测、分布式追踪、指标采集、熔断、调试录制、测试桩 6 大场景。（s4-hooks 提案实现）

### 9. Body 长度安全限制

`Framing.check_body_len` + `DEFAULT_MAX_BODY_LEN`（10MB）实现三层校验：framing 层（发送前检查）、server 层（`max_body_len` 选项，默认 1MB）、HTTP 层（Content-Length 检查返回 413）。防止恶意大 body 导致内存耗尽。（transport-hardening + security-hardening 提案实现）

### 10. 注入式 ID 生成

`Yar.set_id_generator(fn)` 注入点 + `Yar.seed(fn)` 便利函数。默认 `gen_id` 不调用 `math.randomseed`（不污染宿主全局随机状态），混合 `os.time` + 进程内单调递增计数器 + table-address 熵源 + `math.random` 状态。遵循"库不越权播种"原则（源自 Tieske/uuid 业界标杆库）。

### 11. C 扩展注入

`Yar.register_packager(name, lib)` 自动检测 `pack`/`unpack` 或 `encode`/`decode` 接口，适配 cjson/cmsgpack 等 C 扩展。标准 Lua 下注入 cjson 在裸编解码层可获 6-10x 加速，但全链路 ~1.0x（协议开销主导）。架构已预留扩展点，零依赖定位不变。

### 12. 统一日志模块

`Log` 模块提供 4 级日志（DEBUG/INFO/WARN/ERROR）+ `Log.set_writer(fn)` 注入点。默认 `print()`，可注入 `ngx.log`。框架内所有 `print()` 已替换为 `Log.warn()` / `Log.error()`。（log-module 提案实现）

---

## 七、设计取舍清单

以下功能**并非缺陷，而是基于 yar-lua "纯协议库"定位的有意取舍**，由宿主运行时或上层包装承担：

### 7.1 进程管理类（委托宿主）

| 不做的功能 | 理由 | 对应的 yar-c 选项 | 谁来负责 |
|-----------|------|-------------------|---------|
| pre-fork 多 worker | 纯库不管理进程生命周期 | `MAX_CHILDREN` | OpenResty worker / systemd / supervisord |
| PID 文件 | 运维项，非协议职责 | `PID_FILE` | systemd / supervisord / nginx |
| 日志文件 / 日志级别 | 运维项，非协议职责 | `LOG_FILE` / `LOG_LEVEL` | nginx error_log / 宿主日志系统 |
| 子进程权限切换 | 进程权限管理，非协议职责 | `CHILD_USER` / `CHILD_GROUP` | nginx master 降权 / systemd |
| 父/子进程初始化回调 | 无 pre-fork 模型，无对应 | `PARENT_INIT` / `CHILD_INIT` | OpenResty `init_by_lua` / `init_worker_by_lua` |

### 7.2 协议层不做的（Yar 协议本身不支持）

| 不做的功能 | 理由 |
|-----------|------|
| 流式调用 / 双向流 | Yar 协议是请求-响应模型，不支持 streaming RPC |
| IDL / 代码生成 | Yar 协议无 IDL 规范，方法名直接字符串调用，参数用原生表传递 |
| 服务发现 / 负载均衡 | Yar 协议无服务发现规范，纯点对点 RPC；由上层网关或服务网格承担 |

### 7.3 框架级不做的（可由上层包装补充）

| 不做的功能 | 理由 | 替代方案 |
|-----------|------|---------|
| 拦截器 / 中间件 | 纯协议库不提供调用链编排 | 包装 `handle_message` 即可插入日志/限流/熔断 |
| ~~结构化 error code~~ | ✅ 已实现（transport-hardening） | `error.lua` 5 类 Error code + `.code` 字段 |
| 连接池管理（上限/空闲超时/健康检查） | 纯库不管理连接池生命周期；cosocket 自带连接池 | OpenResty cosocket 池 / copas 连接管理 |
| Benchmark / 性能基准 | 协议库不绑定性能场景；性能取决于宿主运行时和序列化器选择 | 用户按实际场景自行 benchmark |

### 7.4 传输层待完善项（非取舍，是 TODO）

| 待完善功能 | 状态 | 说明 |
|-----------|------|------|
| ~~HTTPS over proxy~~ | ✅ 已实现 | CONNECT 隧道 + TLS 握手（issue #10），见 `http.lua:112-148` |
| GET 接口文档 | TODO | 当前 GET 返回方法名列表占位，后续按网关地址返回接口文档 |
| 请求头判断服务是否存在 | TODO | 按网关地址路由服务，代码中已标注 |

---

## 八、总体评价

**评分：8.5/10**

| 维度 | 评分 | 理由 |
|------|------|------|
| 架构设计 | 9.5/10 | 三层分离 + 提供者抽象，Lua 生态罕见高度 |
| 协议完整度 | 9/10 | 完整对齐 YAR 规范，超越 yar-c（JSON/HTTP/解耦） |
| 跨运行时能力 | 9.5/10 | 6 种运行时适配，核心零修改 |
| 代码质量 | 8.5/10 | 模块化好、注释充分、局部化可改进 |
| 测试覆盖 | 8/10 | 14 个 spec 文件覆盖核心路径 + OpenResty E2E，缺 PHP 互通自动化 |
| 工程化 | 8.5/10 | CI 3 job + 三版本矩阵 + OpenResty E2E + luacheck 0 warning + codecov 覆盖率 |
| 文档 | 9/10 | README 详尽，设计文档留存选型思路 |
| 生态定位 | 8/10 | 纯库定位清晰，取舍边界明确 |

**一句话总结**：Yar-Lua 是一个**架构设计远超其体量**的项目 — 用 ~1500 行纯 Lua 代码实现了协议完整、跨运行时、零依赖的 RPC 库，其提供者抽象和三层分离模式是 Lua 生态中值得学习的工程实践。项目对"做什么"和"不做什么"有清晰的边界意识：协议核心、传输抽象、序列化器做到极致；进程管理、服务发现、中间件等运行时特性明确委托宿主或上层包装，是"纯协议库"定位下合理的工程取舍。
