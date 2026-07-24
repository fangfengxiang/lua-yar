# 测试建设覆盖报告

> lua-yar 测试体系全景：类型划分、覆盖范围、CI 矩阵、缺口与规划。
>
> 最后更新：2026-07-19（并发端到端测试套件落地后）

---

## 一、测试类型总览

| 类型 | 目录 | 框架/运行时 | 文件数 | 自动化 | CI 覆盖 |
|------|------|-----------|--------|--------|---------|
| BDD 单元/集成测试 | `spec/` | busted（Lua 5.1 / LuaJIT / 5.3） | 14 | ✅ | ✅ matrix |
| 性能基准测试 | `test/benchmark*.lua` | 标准 Lua + OpenResty | 4+1 辅助 | ✅ | ✅ |
| OpenResty 兼容性测试 | `test/resty_test.lua` | resty CLI | 1 | ✅ | ✅ |
| OpenResty E2E 测试（cosocket） | `test/openresty_e2e_test.lua` | resty CLI | 1 | ✅ | ✅ |
| OpenResty HTTP E2E 测试（nginx） | `test/openresty_http_e2e*.lua/sh` | resty CLI + nginx | 3 | ✅ | ✅ |
| 互操作性测试 | `test/interop*.sh` + `test/concurrent*.php/sh` | PHP YAR | 10 | ✅ | ✅ |
| 示例/场景验证 | `example/` | 各运行时 | 14 | ❌ 手动 | ❌ |

---

## 二、BDD 测试细分（`spec/`）

### 单元测试（模块级）

| 文件 | 覆盖模块 | 测试内容 |
|------|---------|---------|
| `util_spec.lua` | `yar.util` | pack/unpack_u32、pad/trim、边界值 |
| `json_spec.lua` | `yar.packager.json` | 编解码、转义、嵌套、Unicode |
| `msgpack_spec.lua` | `yar.packager.msgpack` | 编解码、类型映射、边界值 |
| `header_spec.lua` | `yar.protocol.header` | pack/unpack、字段映射、magic_num |
| `error_spec.lua` | `yar.error` | 错误码常量、Error.new、err.code 匹配 |

### 集成测试（跨模块协作）

| 文件 | 覆盖链路 | 测试内容 |
|------|---------|---------|
| `protocol_spec.lua` | Request → Protocol.render → parse → Response | 协议往返、packager 适配、header 一致性 |
| `framing_spec.lua` | Framing.receive_message / receive_exact | 帧拆解、半包/粘包、边界条件 |
| `packager_spec.lua` | Packager.get / register | packager 工厂、C 扩展注入、库适配器注入 |
| `client_spec.lua` | Client → Transport → Framing → Protocol | 客户端完整调用链、mock socket、错误分类 |
| `server_spec.lua` | Server.handle_message | 服务端核心、方法派发、错误响应 |
| `tcp_server_spec.lua` | TcpServer.handle_connection | TCP 服务端、keepalive 循环、mock socket |
| `http_server_spec.lua` | HttpServer.handle_connection | HTTP 服务端、Content-Length、mock socket |

### 安全测试

| 文件 | 覆盖内容 |
|------|---------|
| `security_spec.lua` | body 长度边界值、JSON 嵌套深度、方法注入、函数参数、token 截断 |

### 软依赖/降级测试

| 文件 | 覆盖内容 |
|------|---------|
| `soft_dependency_spec.lua` | luasocket 不可用时优雅降级、错误返回而非崩溃 |

---

## 三、性能基准测试（`test/benchmark*.lua`）

| 文件 | 运行时 | 测试内容 |
|------|--------|---------|
| `benchmark.lua` | 标准 Lua | JSON/Msgpack 编解码、协议 render/parse |
| `benchmark_matrix.lua` | OpenResty | 跨运行时矩阵、C 扩展加速、cosocket I/O 往返 |
| `benchmark_cosocket.lua` | OpenResty | 真实 cosocket TCP 往返、keepalive vs new-conn |
| `benchmark_cext.lua` | OpenResty | cjson/cmsgpack vs 纯 Lua 编解码对比 |
| `bench_server.lua` | 系统 Lua + luasocket | 基准测试辅助 TCP server（子进程） |

**关键发现**（详见 `docs/reports/performance-benchmark.md`）：
- mock cosocket handle_connection：122K ops/s (JSON) / 148K ops/s (Msgpack)
- 真实 cosocket keepalive：~89K ops/s（I/O 主导，codec 差异稀释）
- keepalive vs new-conn：3.9x 性能差距

---

## 四、OpenResty 测试体系

### 4.1 兼容性测试（`test/resty_test.lua`）

验证 lua-yar 在 OpenResty/LuaJIT 运行时下的基本兼容性：

| # | 测试 | 覆盖 |
|---|------|------|
| 1 | 协议往返（JSON + Msgpack） | 纯数学二进制操作在 LuaJIT 下正确 |
| 2 | Server handle_message | 纯函数在 OpenResty 上下文 reentrant |
| 3 | cosocket 注入 | `Client.set_socket(ngx.socket)` 不报错 |
| 4 | Framing 帧读取 | receive_message 在 mock cosocket 下正确 |
| 5 | handle_connection | TCP server 单消息模式（mock cosocket） |
| 6 | LuaJIT 兼容性 | 无 string.pack 依赖、uint32 边界值 |

### 4.2 E2E 测试 — cosocket TCP（`test/openresty_e2e_test.lua`）

K3 提案落地，验证真实 cosocket 行为：

| # | 测试 | 覆盖 | 验证点 |
|---|------|------|--------|
| 1 | 真实 cosocket TCP 往返 | 启动 TCP server 子进程，cosocket call() | add/sub/echo + Msgpack |
| 2 | 连接池参数透传（M1 回归） | mock setkeepalive 捕获参数 | idle_timeout + pool_size 正确传递 |
| 3 | cosocket 三段超时 | mock settimeouts 捕获参数 | connect/send/receive 超时独立设置 |
| 4 | HTTP Provider 委托（mock） | 注入 mock provider | opts 透传（method/body/headers/timeout/keepalive/ssl_verify） |
| 5 | lua-resty-http 真实委托 | 若 resty.http 可用 | 真实 HTTP 往返（可选） |
| 6 | 多协程并发安全 | ngx.thread 10 协程 | handle_message reentrant 无竞态 |
| 7 | keepalive 模式 | persistent=true | 单连接 5 次 call 复用 |
| 8 | cosocket 错误路径 | 连接端口 1 | 错误分类（TRANSPORT/TIMEOUT） |

### 4.3 E2E 测试 — HTTP content_by_lua（`test/openresty_http_e2e*.lua/sh`）

验证 nginx `content_by_lua` 上下文中的完整链路：

| # | 测试 | 覆盖 |
|---|------|------|
| 1 | cosocket HTTP 往返 | 客户端 cosocket → nginx → content_by_lua → handle_message |
| 2 | lua-resty-http provider 委托 | 真实 HTTP 库注入 + JSON/Msgpack 往返 |
| 3 | HTTP keepalive | 连接池复用 10 次调用 |
| 4 | HTTP 并发 | 10 协程并发 HTTP 请求 |
| 5 | HTTP 错误路径 | 未知方法 → NOT_FOUND 错误码 |

**nginx 配置**：`test/nginx.conf`（listen 127.0.0.1:9702，`content_by_lua_block` 引用 `test/nginx_e2e_server.lua`）

---

## 五、互操作性测试（PHP YAR）

| 文件 | 用途 |
|------|------|
| `test/server.php` | PHP YAR 服务端，供 Lua 客户端调用 |
| `test/client_test.php` | PHP YAR 客户端，调用 Lua 服务端 |

**状态**：✅ 已纳入 CI（`interop` job + `openresty` job）。验证 Lua↔PHP 跨语言协议字节级兼容 + 并发场景。

---

## 五-B、并发端到端测试（PHP `pcntl_fork` 多进程）

| 场景 | 并发数 | 服务端 | 文件 | 验证点 |
|------|--------|--------|------|--------|
| PHP → 原生 Lua HTTP（顺序） | 3 | `interop_lua_server.lua:9803` | `concurrent_php_to_lua_http.php` | 顺序处理不丢请求、不串数据 |
| PHP → 原生 Lua TCP（顺序） | 3 | `interop_lua_tcp_server.lua:9804` | `concurrent_php_to_lua_tcp.php` | 同上，TCP 传输 |
| PHP → OpenResty HTTP（2 workers） | 50 | `nginx_concurrent_server.lua:9205` | `concurrent_php_to_openresty_http.php` | 协程并发、requestId 完整性、日志异常检测、多 worker 负载分担 |
| PHP → OpenResty TCP（2 workers） | 50 | `nginx_stream_server.lua:9209` | `concurrent_php_to_openresty_tcp.php` | 同上，stream 模块 TCP |

**编排脚本**：
- `test/concurrent_e2e.sh` — 总编排（场景 1-4，原生 + OpenResty）
- `test/concurrent_openresty.sh` — OpenResty 编排（场景 3-4，nginx 2 workers）

**OpenResty handler**：
- `test/nginx_concurrent_server.lua` — HTTP `content_by_lua` handler，记录 `[YAR-CONCURRENT] worker=X requestId=Y status=processing/done/error`
- `test/nginx_stream_server.lua` — stream `content_by_lua` handler，用 `ngx.req.socket(true)` 获取下游 socket，记录 `[YAR-STREAM]` 同格式日志

**日志验证**：测试脚本解析 nginx `error.log`，验证：
1. 无 `status=error` 记录（协程无异常）
2. 至少 2 个不同 `worker_id` 参与处理（多 worker 负载分担）
3. JSON + Msgpack 双 packager 覆盖

---

## 六、CI 测试矩阵

```yaml
matrix:
  lua: ['5.1', 'luajit-2.1', '5.3']  # busted BDD 测试 + 覆盖率
```

| CI Job | 运行时 | 测试内容 | 依赖 |
|--------|--------|---------|------|
| `test` (matrix) | Lua 5.1 / LuaJIT / 5.3 | BDD 测试 + 覆盖率 + 基准测试 | busted, luacov, luasocket |
| `no-luasocket` | Lua 5.1 | 软依赖降级测试 | busted（无 luasocket） |
| `openresty` | OpenResty + PHP 8.2 | 兼容性 + E2E cosocket + E2E HTTP + 并发测试（50 并发 HTTP+TCP） | openresty, lua-resty-http, luasocket, php-yar, php-msgpack, php-pcntl |
| `interop` | PHP 8.2 + Lua 5.1 | 互操作测试 + 并发测试（3 并发 HTTP+TCP） | php-yar, php-msgpack, php-pcntl, luasocket |

---

## 七、测试覆盖维度

### 已覆盖

| 维度 | 覆盖情况 |
|------|---------|
| **功能正确性** | ✅ 全模块 BDD 单元 + 集成测试 |
| **协议兼容性** | ✅ JSON/Msgpack 双 packager、header 字段、framing 边界 |
| **安全边界** | ✅ body 长度、注入、嵌套深度、token 截断 |
| **软依赖降级** | ✅ luasocket 不可用时优雅降级 |
| **跨运行时** | ✅ Lua 5.1 / LuaJIT / 5.3 + OpenResty |
| **cosocket 注入** | ✅ 真实 cosocket TCP/HTTP 往返 |
| **连接池** | ✅ setkeepalive 参数透传（M1 回归） |
| **HTTP Provider 委托** | ✅ mock + lua-resty-http 真实委托 |
| **content_by_lua 上下文** | ✅ nginx E2E 测试 |
| **并发安全** | ✅ 10 协程并发 handle_message + HTTP + 50 并发 PHP → OpenResty |
| **错误路径** | ✅ 连接拒绝、超时、未知方法、畸形数据 |
| **性能** | ✅ 编解码/协议/framing/cosocket I/O 基准 |
| **互操作** | ✅ PHP YAR 双向端到端 + 并发（JSON + Msgpack，CI 自动化） |

### 未覆盖 / 缺口

| 缺口 | 说明 | 优先级 |
|------|------|--------|
| HTTPS 真实往返 | 需 TLS 证书 + HTTPS server，当前仅验证 ssl_verify 选项透传 | 低 |
| 连接池 idle 回收 | 需长时间运行验证 cosocket pool idle timeout 回收行为 | 低 |
| 分布式 tracing | hooks 已提供注入点，tracing 集成测试属应用层 | 低 |

---

## 八、测试文件清单

```
spec/                           # BDD 测试（busted）
├── client_spec.lua             # 客户端完整调用链
├── error_spec.lua              # 错误模块
├── framing_spec.lua            # 帧拆解
├── header_spec.lua             # 协议头
├── helpers.lua                 # 共享 mock helpers
├── http_server_spec.lua        # HTTP 服务端
├── json_spec.lua               # JSON packager
├── msgpack_spec.lua            # Msgpack packager
├── packager_spec.lua           # packager 工厂
├── protocol_spec.lua          # 协议 render/parse
├── security_spec.lua           # 安全边界
├── server_spec.lua             # 服务端核心
├── soft_dependency_spec.lua    # 软依赖降级
├── tcp_server_spec.lua         # TCP 服务端
└── util_spec.lua               # 工具函数

test/                           # 性能 + E2E + 互操作
├── benchmark.lua               # 性能基准（标准 Lua）
├── benchmark_matrix.lua        # 跨运行时矩阵基准
├── benchmark_cosocket.lua      # cosocket I/O 基准
├── benchmark_cext.lua          # C 扩展加速基准
├── bench_server.lua            # 基准辅助 TCP server
├── resty_test.lua              # OpenResty 兼容性测试
├── openresty_e2e_test.lua      # OpenResty E2E（cosocket TCP）
├── openresty_http_e2e_test.lua # OpenResty HTTP E2E（nginx）
├── openresty_http_e2e.sh       # HTTP E2E 编排脚本
├── nginx_e2e_server.lua        # nginx content_by_lua handler
├── nginx.conf                  # 测试用 nginx 配置
├── client_test.php             # PHP 互操作（客户端）
├── server.php                  # PHP 互操作（服务端）
├── interop.sh                  # 互操作编排脚本
├── interop_lua_server.lua      # 互操作 Lua HTTP 服务端
├── interop_lua_tcp_server.lua  # 互操作 Lua TCP 服务端
├── concurrent_e2e.sh           # 并发测试总编排（原生 + OpenResty）
├── concurrent_openresty.sh     # 并发测试 OpenResty 编排
├── concurrent_php_to_lua_http.php    # PHP 3 并发 → 原生 Lua HTTP
├── concurrent_php_to_lua_tcp.php     # PHP 3 并发 → 原生 Lua TCP
├── concurrent_php_to_openresty_http.php # PHP 50 并发 → OpenResty HTTP
├── concurrent_php_to_openresty_tcp.php  # PHP 50 并发 → OpenResty TCP
├── nginx_concurrent_server.lua # OpenResty HTTP handler（requestId 日志）
└── nginx_stream_server.lua     # OpenResty stream TCP handler（requestId 日志）

example/                        # 示例/场景验证（手动）
├── client.lua                  # 基本客户端
├── hooks.lua                    # hooks 示例
├── resty_http_provider.lua      # lua-resty-http 适配器
├── resty_yar_gateway.lua        # OpenResty 网关
├── resty_yar_http_server.lua    # OpenResty HTTP server
├── resty_yar_init.lua           # OpenResty 初始化
├── resty_yar_tcp_server.lua     # OpenResty TCP server
├── server_copas.lua             # copas 运行时
├── server_coroutine.lua         # coroutine 运行时
├── server_http.lua              # HTTP server
├── server_luaeco.lua            # lua-eco 运行时
├── server_openresty.lua         # OpenResty server
├── server_skynet.lua            # Skynet 运行时
└── server_tcp.lua               # TCP server
```

---

## 九、运行指南

```bash
# BDD 测试（需 busted）
busted                           # 全部 spec/
busted spec/client_spec.lua      # 单个 spec
busted --coverage                # 带覆盖率

# 性能基准（标准 Lua）
lua test/benchmark.lua

# 性能基准（OpenResty）
resty test/benchmark_matrix.lua
resty test/benchmark_cosocket.lua
resty test/benchmark_cext.lua

# OpenResty 兼容性测试
resty test/resty_test.lua

# OpenResty E2E 测试（cosocket TCP）
resty test/openresty_e2e_test.lua

# OpenResty HTTP E2E 测试（nginx content_by_lua）
bash test/openresty_http_e2e.sh

# PHP 互操作测试（需 PHP YAR 扩展）
php test/client_test.php

# 并发端到端测试（需 PHP + yar/msgpack/pcntl + Lua + luasocket）
bash test/concurrent_e2e.sh

# 并发 OpenResty 测试（需 PHP + yar/msgpack/pcntl + OpenResty）
bash test/concurrent_openresty.sh
```
