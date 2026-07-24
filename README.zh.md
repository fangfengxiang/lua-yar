# Lua-Yar — Yar Lua 框架

[English](README.md) | [简体中文](README.zh.md) | [文档](https://fangfengxiang.github.io/lua-yar)

[![Lua](https://img.shields.io/badge/Lua-%3E%3D5.1-blue.svg)](https://www.lua.org/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![LuaRocks](https://img.shields.io/luarocks/v/fangfengxiang/lua-yar)](https://luarocks.org/modules/fangfengxiang/lua-yar)
[![OPM](https://img.shields.io/badge/OPM-lua--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-yar/)
[![Test](https://github.com/fangfengxiang/lua-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-yar/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/fangfengxiang/lua-yar/branch/main/graph/badge.svg)](https://codecov.io/gh/fangfengxiang/lua-yar)
[![Release](https://github.com/fangfengxiang/lua-yar/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-yar/actions/workflows/release.yml)

> **轻量、并发的 Lua RPC 框架。**
> Yar RPC 协议纯 Lua 实现的零依赖、协程亲和、多宿主兼容的轻量级 RPC 框架。详见 [协议规范](docs/protocol.md)。

[Yar](https://github.com/laruence/yar)（Yet Another RPC Framework）是 PHP生态流行的轻量级并发 RPC 框架，可基于二进制数据流实现跨语言互通。相关实现：[Yar-C](https://github.com/laruence/yar-c)、[lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)。

相比 HTTP+JSON 方案，Yar可用二进制协议流省去文本编解码开销；相比 gRPC/Thrift，无需 IDL 编译和重型运行时，适合 Lua 嵌入式场景的轻量 RPC 需求。

---

## 特性

- **轻量高效**：零依赖、二进制协议、可嵌入、易用
- **多传输**：支持 TCP / HTTP / Unix Socket
- **协议兼容**：严格遵守 YAR 二进制协议，与 PHP / C / Lua 的 Yar 服务互通
- **跨环境兼容**：标准 Lua + luasocket 即用，OpenResty / Skynet / lua-eco / copas 等宿主环境均可运行（详见 [服务端实现示例](docs/server-implementations.md)）
- **协程友好**：纯函数无 I/O、无 yield，可被任意协程直接调用
- **零依赖可扩展**：内置纯 Lua JSON / Msgpack 编解码，不依赖 cjson / cmsgpack；支持注册自定义打包器、注入 HTTP provider、Hooks 拦截

## 环境要求

- **Lua** 5.1 / 5.3 / LuaJIT 2.1 / OpenResty 1.7+
- **网络层**：按宿主环境选择
  - 标准 Lua 需安装 luasocket（`luarocks install luasocket`）
  - OpenResty 内置 `ngx.socket`，无需额外依赖

## 安装

### LuaRocks （快速试用）

```bash
# 软依赖：标准 Lua 环境需要 luasocket（OpenResty 无需）
# 如未安装，先执行：luarocks install luasocket
luarocks install lua-yar
```

### OPM（OpenResty）（生产推荐）

```bash
opm install lua-yar
```

### 源码安装（不推荐）

将 `src/yar/` 加入 `package.path`，无需编译：

```lua
package.path = package.path .. ";/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua"
local Yar = require("yar")
```

## 快速开始

> [新手教程](docs/tutorial.md)，从零理解 YAR 协议并构建第一个 RPC 服务。

### Client

```lua
local Yar = require("yar")

local client = Yar.client.new("http://127.0.0.1:8888/api")
print(client:call("add", {1, 2}))              -- => 3
```

### Server（Lua原生）

```lua
local Yar = require("yar")

local server = Yar.server.new({
    add = function(a, b) return a + b end,
})

server:listen("http://0.0.0.0:8888")
server:loop()
```

### Server（OpenResty）

```nginx
http {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    server {
        listen 8888;
        location /api {
            content_by_lua_block {
                local Yar = require "yar"
                -- OpenResty 用 content_by_lua 回调模式：无 socket，无需 HttpServer 传输层
                local server = Yar.server.new({
                    add = function(a, b) return a + b end,
                })
                ngx.req.read_body()
                server:handle({
                    method = ngx.req.get_method(),
                    data = ngx.req.get_body_data() or "",
                    writer = function(status, headers, body)
                        ngx.status = status
                        for k, v in pairs(headers) do ngx.header[k] = v end
                        ngx.print(body)
                    end,
                })
            }
        }
    }
}
```

> **关于并发**：Lua 多作为嵌入语言与其他系统协作，原生并发方案较少。lua-yar 将并发能力交由宿主环境提供。详见 [服务端实现示例](docs/server-implementations.md)。生产环境推荐 [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)（OpenResty 绑定，开箱即用）。

### 选项配置示例

#### Client

```lua
local client = Yar.client.new("http://127.0.0.1:8888/api")
client:set_options({
    packager        = Yar.PACKAGER_MSGPACK,   -- 序列化格式：JSON（默认）或 MSGPACK
    timeout         = 3000,                    -- 读写超时（毫秒）
    connect_timeout = 2000,                    -- 连接超时（毫秒）
    provider        = "my-app",                -- 请求来源标识（写入协议头，最长 32 字节）
    token           = "secret-token",          -- 认证令牌（写入协议头，最长 32 字节）
    headers         = { ["X-Trace"] = "abc" }, -- 自定义 HTTP 头（HTTP/HTTPS only）
    proxy           = "http://proxy:8080",     -- HTTP 代理地址
    resolve         = "host:ip",              -- 自定义 DNS（curl 风格 host:port:ip 或 PHP 风格 host:ip）
    ssl_verify      = true,                   -- HTTPS 证书验证（默认 true）
    persistent      = false,                  -- 持久 TCP 连接（跨 call 复用）
    keepalive       = {                       -- cosocket 连接池（OpenResty）
        pool_size    = 64,                     --   连接池大小
        idle_timeout = 60000,                 --   空闲超时（毫秒）
    },
    hooks = {                                 -- 请求/响应拦截（pcall 保护，零开销）
        on_request  = function(method, params) end,
        on_response = function(method, retval, err) end,
    },
})

local ret, err = client:call("add", {1, 2})
if not ret then
    -- err 是 Yar.error 对象，通过 err.code 精确匹配错误类型
    if err.code == Yar.error.TIMEOUT then
        -- 超时处理
    end
end
```

#### Server

```lua
-- 进程级 packager 选项（JSON/Msgpack 解码深度限制，仅对内置纯 Lua 实现生效）
Yar.set_options({
    packager = {
        json_max_depth    = 512,   -- JSON 解码最大嵌套深度
        msgpack_max_depth = 512,   -- Msgpack 解码最大嵌套深度
    },
})

-- 如需用 C 扩展加速解码，注册即可替换内置纯 Lua 实现：
Yar.register_packager(Yar.PACKAGER_JSON, require("cjson"))
-- Yar.register_packager(Yar.PACKAGER_MSGPACK, require("cmsgpack"))

local server = Yar.server.new({
    add   = function(a, b) return a + b end,
    greet = function(name) return "hello, " .. name end,
})

server:set_options({
    packager     = Yar.PACKAGER_JSON,    -- GET 自省响应编码格式（POST 响应由客户端报文头决定）
    timeout      = 5000,                 -- 单消息超时（standalone run 模式）
    max_body_len = 1048576,              -- 最大请求体长度（字节）
    hooks = {                            -- 请求/响应拦截
        on_request  = function(method, params) end,
        on_response = function(method, retval, err) end,
    },
})
```

→ 完整选项见 [API 参考](docs/api.md)

## 部署指南

lua-yar 是纯协议库，自身不提供并发调度，并发能力依赖宿主环境注入。

| 环境 | 并发方案 | 示例 |
|------|----------|------|
| OpenResty | cosocket + `content_by_lua` | [`server_openresty.lua`](example/server_openresty.lua) |
| lua-eco | 协程调度 | [`server_luaeco.lua`](example/server_luaeco.lua) |
| Skynet | Skynet 调度 | [`server_skynet.lua`](example/server_skynet.lua) |
| copas | copas 协程 | [`server_copas.lua`](example/server_copas.lua) |
| 原生协程 | `coroutine` + `socket.select` | [`server_coroutine.lua`](example/server_coroutine.lua) |

> 生产环境推荐使用 [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)（OpenResty 绑定，开箱即用）。

## 测试

| 类型 | 命令 | 说明 |
|------|------|------|
| **BDD 单元/集成** | `busted --coverage` | 126 用例，覆盖全模块（Lua 5.1 / LuaJIT / 5.3 矩阵） |
| **OpenResty E2E** | `resty test/openresty_e2e_test.lua` | cosocket TCP 往返、连接池、并发安全、故障注入 |
| **OpenResty HTTP E2E** | `bash test/openresty_http_e2e.sh` | nginx `content_by_lua` 完整链路 |
| **互操作测试** | `bash test/interop.sh` | Lua ↔ PHP Yar 双向端到端（JSON + Msgpack） |
| **并发测试** | `bash test/concurrent_e2e.sh` | PHP → Lua 并发（3 原生顺序 + 50 OpenResty 2-worker），HTTP + TCP，requestId 完整性 + 协程日志异常检测 |
| **性能基准** | `lua test/benchmark.lua` | 编解码 / 协议 / cosocket I/O 基准 |

CI 矩阵：4 个 job（`test` 多版本 Lua / `no-luasocket` 软依赖降级 / `openresty` E2E / `interop` PHP 互通）。

→ 完整测试体系（类型划分、覆盖维度、CI 矩阵、缺口规划）：[测试覆盖报告](docs/reports/test-coverage.md)

## 模块概览

| 模块 | 说明 |
|------|------|
| **Client** | yar-client，HTTP / HTTPS / TCP / Unix 传输，表驱动选项，结构化 Error |
| **Server** | 统一 Server Facade：TCP/HTTP/宿主模式，`Server.new(service, opts)` + `handle(spec)` / `listen(addr)` + `loop()` |
| **Packager** | 内置 JSON / Msgpack（纯 Lua），通过 `Yar.set_options` 和 `Yar.register_packager` 配置 |
| **Error** | 结构化错误对象，5 级错误码（TRANSPORT / TIMEOUT / PROTOCOL / NOT_FOUND / EXCEPTION） |
| **Log** | 4 级日志，可注入 writer |
| **Hooks** | 轻量 request/response 拦截机制 |

→ 完整 API 详情：[API 参考](docs/api.md)

## 目录结构

```
lua-yar/
├── README.md                    # 英文 README（主）
├── README.zh.md                 # 中文 README
├── LICENSE
├── CHANGELOG.md                 # 变更日志（Keep a Changelog 格式）
├── lua-yar-scm-1.rockspec       # 开发版 rockspec（luarocks make）
├── lua-yar-0.1.0-1.rockspec     # 发布版 rockspec（luarocks install）
├── dist.ini                     # OPM 打包配置（opm build）
├── docs/
│   ├── api.md                   # API 参考文档（完整方法签名 + 示例）
│   ├── protocol.md              # YAR 协议规范（字节级布局 + 报文示例）
│   ├── design-rationale.md      # 设计选型思路
│   ├── design/                  # 设计决策记录（ADR）
│   └── reports/                 # 评估报告
│       ├── architecture-review.md
│       ├── comprehensive-review.md
│       ├── performance-benchmark.md
│       └── test-coverage.md
├── src/
│   └── yar/
│       ├── init.lua             # 主入口（Client, Server, register_packager, get_packager, set_options, Error, VERSION, PACKAGER_*）
│       ├── util.lua             # 字节序工具
│       ├── error.lua            # 结构化错误对象（Error.new + code 常量）
│       ├── client.lua           # yar-client
│       ├── server/
│       │   ├── init.lua         # Server Facade（统一入口：new/handle/listen/loop）
│       │   ├── constants.lua    # 服务端常量（max_body_len、max_headers 等）
│       │   ├── dispatcher.lua   # 协议派发器（handle_message、register_service）
│       │   ├── daemon.lua       # Accept 循环（Daemon.run，顺序）
│       │   ├── http.lua         # HTTP 传输（socket 模式 + 回调模式）
│       │   └── tcp.lua          # TCP 传输（socket 模式）
│       ├── protocol/
│       │   ├── header.lua       # 82 字节协议头
│       │   ├── protocol.lua     # 消息渲染/解析
│       │   └── framing.lua      # YAR 帧拆解（TCP 传输用）
│       ├── message/
│       │   ├── request.lua      # 请求 {i,m,p}
│       │   └── response.lua     # 响应 {i,s,r,o,e}
│       ├── packager/
│       │   ├── packager.lua     # 打包器工厂
│       │   ├── json.lua         # 纯 Lua JSON
│       │   └── msgpack.lua      # 纯 Lua MessagePack
│       └── transport/
│           ├── transport.lua    # 传输器工厂 / socket 提供者管理
│           ├── constants.lua    # HTTP 常量（状态码、Content-Type、方法）— 叶子模块
│           ├── socket.lua       # socket 提供者（luasocket 适配 / 注入 cosocket / bind）
│           ├── resolve.lua      # DNS 解析工具（curl/PHP 风格 host→IP 映射）
│           ├── http.lua         # HTTP 传输
│           └── tcp.lua          # TCP 传输
├── example/
│   ├── client.lua
│   ├── server_http.lua
│   ├── server_tcp.lua
│   ├── server_copas.lua         # copas 协程并发示例
│   ├── server_coroutine.lua     # 原生协程并发示例（不依赖 copas）
│   ├── server_luaeco.lua        # lua-eco 协程并发示例
│   ├── server_skynet.lua        # Skynet 高并发示例
│   ├── server_openresty.lua     # OpenResty stream cosocket 示例
│   ├── resty_http_provider.lua  # lua-resty-http 适配器示例
│   ├── hooks.lua                # hook 使用示例（日志观测 + 耗时统计）
│   └── resty_yar_*.lua          # OpenResty OPM 包示例
├── spec/                        # BDD 单元/集成测试（126 用例，详见 docs/reports/test-coverage.md）
└── test/                        # E2E / 互操作 / 性能基准测试
```

## YAR 协议

Yar 以二进制数据流交换 RPC 消息，一条完整消息由三部分组成：

```
+-------------------+-------------------+---------------------+
| Packager Name     | Yar Header        | Body                |
| 8 字节            | 82 字节           | body_len 字节       |
+-------------------+-------------------+---------------------+
```

- **请求体**：`{i, m, p}` — 事务 ID / 方法名 / 参数数组
- **响应体**：`{i, s, r, o, e}` — 事务 ID / 状态 / 返回值 / 输出 / 错误
- 多字节整数使用网络字节序（大端）

→ 完整协议规范（字段详解、字节级布局、报文示例、跨语言互通）：[协议规范](docs/protocol.md)

## 附录

- [入门教程](docs/tutorial.md)（30 分钟从零构建 RPC 服务，边做边学）
- [How-to 指南](docs/how-to.md)（按问题找方案：性能优化、部署、调试、扩展、协议互操作）
- [开发指南](CONTRIBUTING.md)（LuaLS 类型注解规范、代码风格指南、项目结构）
- [设计选型](docs/design-rationale.md)（网络层选型、与 yar-c 能力对比、选项对比）
- [压测报告](docs/reports/performance-benchmark.md)
- [变更日志](CHANGELOG.md)

## 许可证

[Apache License 2.0](LICENSE)
