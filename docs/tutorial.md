# 30 分钟入门 lua-yar

> **学习导向教程**：面向 YAR 新手，边做边学。
> 如果你已熟悉 RPC 概念，只需解决方案，请直接看 [How-to 指南](how-to.md)。

本教程带你从零理解 YAR RPC 协议，并用 lua-yar 构建第一个可运行的服务。每步都有可执行代码和概念讲解。

---

## 你将学到

- 什么是 YAR RPC、它解决什么问题
- 请求/响应循环的工作原理
- 从零构建一个可运行的 RPC 服务
- packager、transport、hooks 如何协作
- 迁移到 OpenResty 生产环境

## 前置准备

```bash
# 安装 lua-yar 和 luasocket
luarocks install lua-yar
luarocks install luasocket

# 验证
lua -e 'local Yar = require("yar"); print(Yar.VERSION)'
```

---

## 第 1 步：理解 YAR 协议（5 分钟）

YAR（Yet Another RPC Framework）是 PHP 生态的轻量级 RPC 协议。RPC（Remote Procedure Call）让你像调用本地函数一样调用远程服务：

```lua
-- 本地调用
local result = add(1, 2)  -- => 3

-- RPC 调用（看起来一样，但 add 在另一台机器上）
local result = client:call("add", {1, 2})  -- => 3
```

YAR 用**二进制数据流**交换消息。一条完整消息由三段组成：

```
+-------------------+-------------------+---------------------+
| Packager Name     | Yar Header        | Body                |
| 8 字节            | 82 字节           | body_len 字节       |
+-------------------+-------------------+---------------------+
```

- **Packager Name**（8 字节）：声明 Body 用什么格式编码（`JSON` 或 `Msgpack`）
- **Yar Header**（82 字节）：固定头，含事务 ID、魔数 `0x80DFEC60`、认证信息
- **Body**（变长）：序列化后的请求或响应数据

**请求体**长这样（JSON 编码时）：
```json
{"i": 12345, "m": "add", "p": [1, 2]}
```
- `i` = 事务 ID（匹配请求与响应）
- `m` = 方法名
- `p` = 参数数组

**响应体**长这样：
```json
{"i": 12345, "s": 0, "r": 3, "o": "", "e": ""}
```
- `s` = 状态（0 成功，1 错误）
- `r` = 返回值
- `e` = 错误消息

> 不用记这些细节，只需知道：客户端发 `{i,m,p}`，服务端回 `{i,s,r,o,e}`。完整规范见 [protocol.md](protocol.md)。

---

## 第 2 步：你的第一个 Server（5 分钟）

我们来写一个计算器 RPC 服务。创建 `my_server.lua`：

```lua
local Yar = require("yar")

local server = Yar.server.new({
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    mul = function(a, b) return a * b end,
})
server:listen("http://0.0.0.0:8888")
server:loop()
```

运行它：

```bash
lua my_server.lua
```

**发生了什么？**

1. `Yar.server.new({...})` 创建了一个 Server，`service` 表里的函数变成 RPC 方法
2. `:listen("http://0.0.0.0:8888")` 在 8888 端口监听，`:loop()` 启动 accept 循环
3. server 收到 HTTP POST 请求时，解析 YAR 二进制消息，找到 `add` 方法，调用它，把结果编码成 YAR 响应返回

用 `curl` 发一个原始 YAR 请求看看（Body 是二进制，这里用管道生成）：

```bash
# 用 lua-yar client 测试更方便，见下一步
curl -X POST http://127.0.0.1:8888/ -d "$(lua -e 'print("")')" 2>/dev/null | xxd | head
```

> ⚠ `loop()` 是单线程顺序 accept，一个慢请求会阻塞所有连接。仅供开发/测试。生产方案见 [第 6 步](#第-6-步迁移到-openresty5-分钟)。

---

## 第 3 步：你的第一个 Client（5 分钟）

server 跑着，另开一个终端写 client：

```lua
local Yar = require("yar")

local client = Yar.client.new("http://127.0.0.1:8888/")

print(client:call("add", {1, 2}))  -- => 3
print(client:call("sub", {10, 3})) -- => 7
print(client:call("mul", {4, 5}))  -- => 20
```

→ 完整示例（HTTP + TCP 双模式）：[`example/client.lua`](../example/client.lua)

**请求/响应循环**：

1. `client:call("add", {1, 2})` 生成事务 ID（如 12345）
2. 构造请求体 `{i=12345, m="add", p={1,2}}`，用 JSON 编码
3. 拼 YAR 消息：`JSON\0\0\0\0` + 82 字节头 + JSON body
4. 通过 HTTP POST 发给 server
5. server 解析、调用 `add(1,2)`、返回 `{i=12345, s=0, r=3, o="", e=""}`
6. client 用事务 ID 12345 匹配响应，取出 `r=3` 返回给你

**错误处理**：

```lua
local ret, err = client:call("div", {1, 0})  -- 假设 div 除零报错
if not ret then
    -- err 是 Yar.error 对象，通过 err.code 精确匹配
    if err.code == Yar.error.EXCEPTION then
        print("方法执行出错: " .. tostring(err))
    end
end
```

---

## 第 4 步：切换 packager（5 分钟）

YAR 支持两种序列化格式。我们切换到 Msgpack 看看区别：

```lua
local Yar = require("yar")

local client = Yar.client.new("http://127.0.0.1:8888/")
client:set_options({ packager = Yar.PACKAGER_MSGPACK })

print(client:call("add", {1, 2}))  -- => 3，结果一样
```

**区别在哪？**

| Packager | 请求 Body 大小（add(1,2)） | 格式 |
|----------|---------------------------|------|
| JSON | 19 字节 | 文本 `{"i":12345,"m":"add","p":[1,2]}` |
| Msgpack | 14 字节 | 二进制，更紧凑 |

server 会自动从请求头读取 packager name，用对应格式解码。响应也用同一种 packager 编码。这就是**协议自适应**——你不用告诉 server 用什么格式，它在消息头里声明了。

> Msgpack 在大量小消息场景下可节省带宽。JSON 更易调试（可读）。

---

## 第 5 步：加 hooks 观测（5 分钟）

hooks 是请求/响应的拦截点，用于日志、追踪、统计：

```lua
local Yar = require("yar")

local client = Yar.client.new("http://127.0.0.1:8888/")
client:set_options({
    hooks = {
        on_request = function(method, params)
            print(string.format("[REQ] %s(%s)", method, table.concat(params, ", ")))
        end,
        on_response = function(method, retval, err)
            if retval then
                print(string.format("[RESP] %s => %s", method, tostring(retval)))
            else
                print(string.format("[RESP] %s => ERROR: %s", method, tostring(err)))
            end
        end,
    },
})

client:call("add", {1, 2})
client:call("mul", {3, 4})
```

输出：
```
[REQ] add(1, 2)
[RESP] add => 3
[REQ] mul(3, 4)
[RESP] mul => 12
```

**hooks 特点**：
- `pcall` 保护——hook 报错不影响主流程，降级为 `Log.warn`
- 零开销——未配置时 nil 检查跳过
- 只读回调——不传 request/response 对象，不拦截数据流

> server 端也有 hooks，用法一样：`server:set_options({ hooks = {...} })`。

---

## 第 6 步：迁移到 OpenResty（5 分钟）

原生 Lua 的 `loop()` 是单线程顺序的。生产环境用 OpenResty 获得协程并发：

### Server（OpenResty）

```nginx
http {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    server {
        listen 8888;
        location / {
            content_by_lua_block {
                local Yar = require "yar"
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

**关键变化**：
- 不用 `server:loop()` 顺序 accept，改用 `Server.new()` + `handle()` callback 模式
- `handle()` 的 callback 模式自动处理 HTTP 语义：状态码（200/400/413/500）、Content-Type 头、GET introspection、错误响应
- `writer(status, headers, body)` 回调签名对标 WSGI `start_response`，参数顺序 = HTTP 线序 = 回调执行序
- 并发由 nginx worker + cosocket 提供，不是库操心的事

### Client（OpenResty）

```lua
local Yar = require "yar"
Yar.client.set_socket(ngx.socket)  -- 注入 cosocket
local client = Yar.client.new("http://127.0.0.1:8888/")
client:set_options({
    keepalive = { pool_size = 64, idle_timeout = 60000 },  -- 连接池
})
ngx.say(client:call("add", {1, 2}))
```

**这就是 lua-yar 的设计哲学**：
- **纯协议核心**——协议处理与 I/O 分离，可被任意协程调度
- **并发由宿主提供**——OpenResty / lua-eco / Skynet / copas / 原生协程均可
- 库不绑定运行时，不引用 `ngx`，通过注入获得能力

> 生产环境推荐直接用 [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar)（OpenResty 绑定，开箱即用）。

---

## 下一步

恭喜！你已掌握 lua-yar 的核心用法。继续深入：

| 想做什么 | 去哪里 |
|----------|--------|
| 查完整 API 签名 | [api.md](api.md) |
| 理解协议字节级布局 | [protocol.md](protocol.md) |
| 按问题找方案 | [how-to.md](how-to.md) |
| 理解设计选型 | [design-rationale.md](design-rationale.md) |
| 看设计决策记录 | [design/](design/decisions.md) |
| 看多宿主并发示例 | [server-implementations.md](server-implementations.md) |
