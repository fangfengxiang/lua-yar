# 深度综合 v4：跨语言 I/O 抽象研究 + A+B+C 融汇 + 最终设计

> 综合 WSGI/ASGI/Go/yar-c/PHP yar/copas，提炼 I/O 抽象统一规律，融汇 A+B+C，产出最终设计。
> 验收标准：调用方只感知 1 概念（Server）+ 2 方法（handle/loop）。
> 关联：v1 提案、v2/v3 反思、server-architecture-reflection.md

---

## 一、跨语言 I/O 抽象模式深度研究

### 1.1 研究动机

v1-v3 停留在 Lua 生态内部和 Yar 自身实现。用户指出：在 Lua 找不到方案时，应到其他语言去找。

RPC 服务端的核心问题是 I/O 抽象——如何把「读请求字节 / 写响应字节」从具体传输机制（TCP socket / HTTP 请求体 / 异步事件流）中剥离。

### 1.2 WSGI（Python，PEP 3333）—— 同步回调抽象

```python
def app(environ, start_response):
    data = environ["wsgi.input"].read(int(environ["CONTENT_LENGTH"]))
    start_response("200 OK", [("Content-Type", "application/octet-stream")])
    return [response_bytes]
```

- 读：`wsgi.input` 流对象（`.read(n)`）
- 写：`start_response(status, headers)` 回调 + return body
- 关键：app 不接触 socket——I/O 被「流 + 回调」替代；Server 构造 environ，app 只消费

### 1.3 ASGI 3.0（Python 异步）—— 事件回调对抽象

```python
async def app(scope, receive, send):
    request = await receive()
    await send({"type": "http.response.start", "status": 200, ...})
    await send({"type": "http.response.body", "body": response_bytes})
```

- 读：`receive()` 可调用对象，返回事件字典
- 写：`send(event_dict)` 可调用对象，发送事件
- 关键：同一接口服务 HTTP/WebSocket/HTTP/2——`scope["type"]` 选协议；I/O 是回调函数对，不是 socket

### 1.4 Go net/http —— 接口抽象 + Listen/Serve 分离

```go
type Handler interface { ServeHTTP(w ResponseWriter, r *Request) }
type ResponseWriter interface { Header(); Write([]byte); WriteHeader(int) }

http.ListenAndServe(":8080", handler)  // daemon: 库管 Listen+Accept+Serve
http.Serve(listener, handler)           // hosted: 调用方管 Listen+Accept，库管 Serve
```

- 读：`r *Request`（`r.Body` 是 Reader）
- 写：`ResponseWriter` 接口（`Write` / `Header` / `WriteHeader`）
- 关键：daemon/hosted 二元性通过拆分 Listen 和 Serve 解决；`ListenAndServe` = `net.Listen` + `http.Serve`

### 1.5 统一洞察：I/O 即读写回调对

| 实现 | 读请求 | 写响应 | 本质 |
|---|---|---|---|
| WSGI | `wsgi.input` 流 | `start_response` + return | 流 + 回调 |
| ASGI | `receive()` 可调用 | `send(event)` 可调用 | 回调对 |
| Go | `Request.Body` Reader | `ResponseWriter` 接口 | 接口 |
| TCP socket | `sock:receive(n)` | `sock:send(data)` | 对象方法 |
| HTTP 回调 | `data` 字符串 | `writer(resp)` 回调 | 值 + 回调 |

核心规律：I/O 抽象的本质是「一种拿请求字节的方式 + 一种送响应字节的方式」。

- socket 是这个抽象的一个实现（receive / send 方法对）
- 回调也是这个抽象的一个实现（data 值 / writer 函数对）
- socket 天然满足回调对接口——这是 HTTP 和 TCP 可统一抽象的根本原因

这是 v4 设计的理论基石：`handle(spec)` 中，`socket` 字段和 `data`+`writer` 字段是同一 I/O 抽象的两种实现。对 Server 内部，都是「拿到 data -> handle_message -> 输出 resp」。

---

## 二、A+B+C 融汇贯通

### 2.1 三种模式各自优劣

| 模式 | 代表 | 优势 | 劣势 |
|---|---|---|---|
| A. 胖 daemon | yar-c | URL 选 transport、只看 Server | 不支持宿主 |
| B. 宿主依赖 | PHP yar | 极致轻量、handle() 无参 | 不支持 daemon |
| C. handler 注入 | copas | 通用灵活 | 调用方感知 2+ 概念 |

### 2.2 融汇策略

| 借鉴来源 | 借鉴什么 | lua-yar 体现 |
|---|---|---|
| yar-c | URL scheme 选 transport | `listen("tcp://addr")` / `listen("http://addr")` + `loop()` |
| PHP yar | handle() 处理单请求、极致轻量 | `handle(spec)` 宿主入口 |
| Go net/http | Listen/Serve 分离 | `loop`=ListenAndServe vs `handle`=Serve |
| ASGI | I/O = 回调对 | HTTP 的 `data`+`writer` 与 TCP 的 `socket` 统一 |
| copas | handler 注入（内部用） | Transport 内部存在，Facade 隐藏 |

### 2.3 设计哲学三原则

1. 方法即模式——`handle`=宿主模式，`listen`+`loop`=原生模式。选方法即选模式
2. I/O 即回调对——socket 和 data+writer 是同一抽象的两种实现
3. Facade 隐藏内部——Transport/Daemon 内部存在（可测试可复用），调用方不直接接触

---

## 三、设计模式应用

### 3.1 Facade（外观）

Server 是 Facade，对外只暴露 `new`/`handle`/`listen`/`loop`，内部分发给 Transport/Daemon/Core。
对标：Go `http.Server`、PHP yar `Yar_Server`。

### 3.2 Strategy（策略）

handle 的 spec 中 `socket` 字段和 `data`+`writer` 字段是两种 I/O Strategy。
对标：ASGI 的 `receive`/`send`、Go 的 `ResponseWriter` 接口。

### 3.3 Template Method（模板方法）

handle 固定流程骨架：读请求 -> handle_message -> 写响应 -> [keepalive 循环]。
步骤 1/3 随 I/O 变化（Strategy），步骤 2 固定（invariant）。

### 3.4 Adapter（适配器）

`transport/socket.lua` 已是 Adapter——`wrap(s)` 将 luasocket 包装为「毫秒超时 + cosocket 方法名」契约。复用现有。

### 3.5 Factory（工厂）

URL scheme 是 Factory 选择条件（在 `listen(addr)` 中解析），与客户端 `Transport.get(url)` 对称。

---

## 四、最终设计：handle / listen+loop 双模式 Facade

### 4.1 API 总览

```lua
-- 构造（对标 lua-resty-http http.new()、lua-resty-redis redis.new()）
-- 构造器只做初始化（opts/service），不碰地址、不碰 I/O
-- addr 是身份属性，通过独立方法 listen() 设置（对标 httpc:connect(host, port)）
local server = Server.new(opts?, service?)
-- opts: { timeout, max_body_len, packager, hooks, keepalive, ... }（可选，运行时配置项）
-- service: RPC 方法表（可选，传了 collect_methods 自动收集 public 方法）
--   对标 PHP Yar new Yar_Server($service)、Go rpc.Register(recv)

-- 宿主模式：handle(spec) — 对标 PHP yar handle() + Go Serve()
-- 调用方管 accept，库管单请求/连接周期

-- 场景 1：OpenResty HTTP（回调注入，对标 WSGI start_response）
-- writer(status, headers, body)：参数序=HTTP 线序=回调执行序
server:handle({
    method = ngx.req.get_method(),
    data   = ngx.req.get_body_data(),
    writer = function(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do ngx.header[k] = v end
        ngx.print(body)
    end,
})

-- 场景 2：OpenResty TCP / copas TCP（socket 注入）
server:handle({ socket = ngx.req.sock(), keepalive = true })

-- 场景 3：标准 Lua 协程 HTTP（socket + protocol 标记）
server:handle({ socket = client_sock })

-- 场景 4：标准 Lua 协程 TCP（socket，默认 TCP 协议）
server:handle({ socket = client_sock, keepalive = true })

-- 原生模式：listen(addr) + loop() — 对标 httpc:connect() + copas.loop() + Go ListenAndServe()
-- listen: 解析 addr -> protocol/host/port + bind（早失败，I/O 操作返回 true|nil,err）
-- loop: accept 循环 + handle 委托（无参，addr 已在 listen 时解析）
-- WARNING: loop() is sequential accept, for dev/testing only.
--   One slow request blocks all connections.
--   Lua 无内置并发原语：无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。
--   唯一并发路径：协程 + 非阻塞 I/O + select 调度器（= copas）。
--   生产并发用：OpenResty handle({writer=}) / copas addserver+loop / lua-eco Skynet handle({socket=})

server:listen("tcp://0.0.0.0:8888")  -- 或 "http://0.0.0.0:8888" / "http://0.0.0.0" / "unix:///path"
server:loop()
```

### 4.2 spec 字段汇总

| spec 字段 | 适用场景 | 含义 | 默认值 |
|---|---|---|---|
| `socket` | TCP / HTTP socket 模式 | 已连接 socket（满足 receive/send 契约） | — |
| `keepalive` | TCP socket 模式 | 是否循环处理多个请求 | `false` |
| `method` | HTTP 回调模式 | `"GET"` 或 `"POST"` | — |
| `data` | HTTP 回调模式 | 请求体字节 | — |
| `writer` | HTTP 回调模式 | `function(status, headers, body)` | — |

两种 I/O 模式（Strategy）：
- socket 模式：`{socket=, keepalive=}` — 库管 I/O，协议由 `self.protocol` 决定（listen 时从 addr 解析，默认 `"tcp"`）
- 回调模式：`{method=, data=, writer=}` — 宿主管 I/O，库只做协议（隐式 HTTP）

### 4.3 对称性验证

| 场景 | API | 概念数 |
|---|---|---|
| 标准 Lua TCP daemon | `local s = Server.new(opts, service)`<br>`s:listen("tcp://addr")`<br>`s:loop()` | 1 |
| 标准 Lua HTTP daemon | `local s = Server.new(opts, service)`<br>`s:listen("http://addr")`<br>`s:loop()` | 1 |
| OpenResty HTTP | `Server.new(opts, service):handle({data=, writer=})` | 1 |
| OpenResty TCP | `Server.new(opts, service):handle({socket=, keepalive=})` | 1 |
| copas TCP | `Server.new(opts, service):handle({socket=, keepalive=})` | 1 |
| 协程 HTTP | `local s = Server.new(opts, service)`<br>`s:listen("http://addr")`<br>`s:handle({socket=})` | 1 |
| 协程 TCP | `Server.new(opts, service):handle({socket=, keepalive=})` | 1 |

所有场景：1 概念（Server），3 方法（handle/listen/loop）。HTTP/TCP 完全对称。

> `listen()` 返回 `true|nil, err`（I/O 操作，非链式，对标 `httpc:connect()`）。`handle()` 返回 `true|nil, err`（非链式）。`register_service()`/`set_options()`/`set_packager()`/`setopt()` 返回 `self`（链式）。
>
> service 可选：`Server.new(opts, service)` 传了则内部调 `register_service(service)` 自动收集 public 方法；也可 `Server.new(opts):register_service({...}):listen(addr)` + `s:loop()` 构造后注册。统一单路径注册，对标 Go net/rpc（`Register` 批量）、PHP Yar（`new Yar_Server($service)` 构造时传）。

---

## 五、7 个细节的最终决议

### 5.1 writer 签名 -> `writer(status, headers, body)`

三参数签名。参数序对标 WSGI `start_response(status, headers)` + body 顺延，同时匹配 HTTP 线序（status line → headers → body）和回调内执行序（set status → set headers → write body）。`headers` 是表（如 `{["Content-Type"]="application/octet-stream", ["Content-Length"]=...}`），支持自定义响应头。

```lua
writer = function(status, headers, body)
    -- status: 200 | 400 | 405 | 413 | 500
    -- headers: { ["Content-Type"] = "application/octet-stream" | "application/json" | "text/plain",
    --             ["Content-Length"] = #body, ... }  -- 库填充标准头，调用方可追加自定义头
    -- body: 响应字节（YAR 二进制 或 introspection JSON）
end
```

错误处理矩阵：
- `handle_message` 内部错误 -> YAR error 帧 -> `writer(200, {["Content-Type"]="application/octet-stream"}, error_resp)`
  - YAR 协议层错误用 HTTP 200（对标 PHP yar——HTTP 200 + YAR error body）
- HTTP 层错误（empty body/method not allowed/body too large）-> `writer(400|405|413, {["Content-Type"]="text/plain"}, msg)`
- `handle` 返回 `true`（成功）或 `nil, err`（严重错误如 socket 断开），供调用方 log

### 5.2 GET introspection -> `method = "GET"` 触发，返回 JSON

与当前 HttpServer GET 行为一致（`http.lua:134` 已是 `packager.pack(list_methods())`）。

```lua
if spec.method == "GET" then
    local body = dispatcher:pack(dispatcher:list_methods())
    spec.writer(200, {["Content-Type"] = "application/json"}, body)
    return true
end
```

### 5.3 addr 解析 -> `parse_addr(addr)` 在 listen() 中早失败

客户端 `transport/transport.lua:37` 已有 `string.match(url, "^tcp://")` 逻辑。提取为 `parse_addr(addr)`，在 `Server:listen()` 中解析（早失败），Daemon.run 复用已解析的 protocol/host/port。对标 lua-resty-http `httpc:connect(host, port)` 在连接时解析地址。

### 5.4 keepalive 默认 -> `false`（单连接），opts 显式开启

与当前 TcpServer 行为一致（`tcp.lua:85` `opts.keepalive` 默认 nil）。安全默认，显式开启。

### 5.5 错误处理 -> handle 返回 `true|nil,err`，内部处理 HTTP 错误

对标 PHP yar `handle()` 内部处理一切。YAR 协议层错误用 HTTP 200 + YAR error body（对标 PHP yar）。HTTP 层错误用对应状态码。严重错误返回 `nil, err` 供调用方 log。

### 5.6 Transport/Daemon 公开性 -> 保留公开，文档主推 Facade

对标 Lua 标准库（`io.open` 主推，`io.lines` 也暴露）和 Go net/http（`http.Serve` 公开，主推 `ListenAndServe`）。高级用户可绕过 Facade 直接用 Transport。

### 5.7 模块命名 -> `init.lua`=Facade，`dispatcher.lua`=协议核心

```
src/yar/server/
  init.lua         <- Server Facade（new/handle/listen/loop + 分发 + 委托 dispatcher + addr 解析），模块入口
  dispatcher.lua   <- Dispatcher（handle_message + register_service + list_methods），协议核心
  tcp.lua          <- TcpTransport（serve: YAR 帧读写 + keepalive 循环）
  http.lua         <- HttpTransport（serve: HTTP 请求解析 + 响应构造）
  daemon.lua       <- Daemon（run: accept + handle 委托，bind 已在 listen() 完成）
```

`init.lua` 是 Lua 模块入口（`require("yar.server")` 返回它），Facade 在入口符合惯例。

---

## 六、内部架构（调用方不可见）

### 6.1 Server Facade 内部分发

```lua
-- server/init.lua（Facade）
local Dispatcher     = require("yar.server.dispatcher")
local TcpTransport   = require("yar.server.tcp")
local HttpTransport  = require("yar.server.http")
local Daemon         = require("yar.server.daemon")
local Socket         = require("yar.transport.socket")
local string, tonumber = string, tonumber

local _M = {}
_M.__index = _M

-- addr 解析（早失败：listen 时解析，loop 直接用）
-- 统一 scheme 提取 + host:port 校验
-- http 协议允许省略端口，默认 80（对标 URL 规范 RFC 3986）；tcp 必须显式指定端口
local function parse_addr(addr)
    local scheme, rest = string.match(addr, "^([a-z]+)://(.+)$")
    if not scheme then
        return nil, "unsupported addr scheme: " .. addr
    end
    if scheme == "unix" then
        return "unix", rest, nil
    end
    if scheme ~= "tcp" and scheme ~= "http" then
        return nil, "unsupported protocol: " .. scheme
    end
    -- 尝试匹配 host:port
    local host, port_str = string.match(rest, "^([^:]+):(%d+)$")
    if not host then
        -- http 协议允许省略端口，默认 80（RFC 3986 标准，非静默 fallback）
        if scheme == "http" then
            host = string.match(rest, "^([^:]+)$")
            if host then
                return scheme, host, 80
            end
        end
        return nil, "invalid addr format, expected host:port"
    end
    local port = tonumber(port_str)
    if not port then
        return nil, "invalid port: " .. tostring(port_str)
    end
    return scheme, host, port
end

-- 构造器只做初始化（opts/service），不碰地址、不碰 I/O
-- 对标 lua-resty-http http.new()、lua-resty-redis redis.new()
function _M.new(opts, service)
    local self = setmetatable({}, _M)
    self.dispatcher = Dispatcher.new()
    self.opts = opts or {}
    -- 传递所有 opts 给 Dispatcher（packager/hooks/max_body_len/timeout 等）
    -- Dispatcher:set_options 内部对 packager 调 set_packager，其余复制到 self.options
    self.dispatcher:set_options(self.opts)
    -- socket_provider 是全局副作用（影响 transport 层 socket 提供者），Facade 层处理
    if self.opts.socket_provider then Socket.set(self.opts.socket_provider) end
    -- RPC 方法注册（可选第二参数，对标 Go rpc.Register(recv)、PHP Yar new Yar_Server($service)）
    if service then self.dispatcher:register_service(service) end
    return self
end

-- 宿主模式
function _M:handle(spec)
    if spec.socket then
        return self:_handle_socket(spec)
    elseif spec.writer then
        return self:_handle_callback(spec)
    end
    return nil, "invalid spec: need socket or writer"
end

function _M:_handle_socket(spec)
    local protocol = self.protocol or "tcp"
    if protocol == "http" then
        return HttpTransport.serve(spec.socket, self.dispatcher, self.opts)
    end
    return TcpTransport.serve(spec.socket, self.dispatcher, spec, self.opts)
end

function _M:_handle_callback(spec)
    return HttpTransport.serve_callback(spec, self.dispatcher, self.opts)
end

-- 原生模式：listen(addr) — 解析 addr + bind（对标 httpc:connect(host, port)）
-- I/O 操作，返回 true|nil, err（非链式，对标 lua-resty-http connect 返回值）
function _M:listen(addr)
    if not addr then
        return nil, "listen requires addr: tcp://host:port / http://host:port / unix:///path"
    end
    local protocol, host, port = parse_addr(addr)
    if not protocol then return nil, host end  -- host 是 errmsg
    self.protocol = protocol
    self.host = host
    self.port = port
    -- bind（unix socket 与 TCP bind 不同）
    local listen_sock, err
    if protocol == "unix" then
        listen_sock, err = Socket.bind_unix(host)  -- host 是 unix path
    else
        listen_sock, err = Socket.bind(host, port)
    end
    if not listen_sock then return nil, "bind failed: " .. tostring(err) end
    self.listen_sock = listen_sock
    return true
end

-- 原生模式：loop() — accept 循环 + handle 委托（无参，addr 已在 listen 时解析）
-- 对标 copas.loop()、Go ListenAndServe()、Python serve_forever()
-- WARNING: sequential accept, for dev/testing only. One slow request blocks all connections.
--   Lua 无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。
--   协程并发需非阻塞 I/O + select 调度器（= copas），不内置——并发交给 copas / OpenResty。
--   生产并发用：OpenResty handle({writer=}) / copas addserver+loop / lua-eco Skynet handle({socket=})
function _M:loop()
    if not self.listen_sock then return nil, "no addr configured, call listen(addr) first" end
    return Daemon.run(self)
end

-- 委托 dispatcher：RPC 方法注册（对标 Go rpc.Register(recv)、PHP Yar new Yar_Server($service)）
function _M:register_service(service) self.dispatcher:register_service(service); return self end
function _M:list_methods() return self.dispatcher:list_methods() end
-- 委托 dispatcher：配置方法（补回当前代码的链式配置能力）
function _M:set_packager(name) self.dispatcher:set_packager(name); return self end
function _M:set_options(opts)
    if not opts then return self end
    -- 存到 Facade opts（keepalive/timeout 等 Facade 级配置，Daemon.run 和 Transport 读取）
    for k, v in pairs(opts) do self.opts[k] = v end
    -- 委托给 Dispatcher（packager/hooks/max_body_len 等，Dispatcher:set_options 内部处理 packager 特殊分支）
    self.dispatcher:set_options(opts)
    -- socket_provider 全局副作用（对标当前 tcp.lua/http.lua 的 set_options 处理）
    if opts.socket_provider then Socket.set(opts.socket_provider) end
    return self
end
function _M:setopt(opt, val) return self:set_options({ [opt] = val }) end
```

### 6.2 Daemon 内部实现

```lua
-- server/daemon.lua
local Log = require("yar.log")
local pcall = pcall

local _M = {}

-- bind 已在 Server:listen() 中完成，Daemon 只管 accept 循环
function _M.run(server)
    local listen_sock = server.listen_sock
    if not listen_sock then return nil, "no listen socket" end

    Log.info("Yar server listening on " .. (server.protocol or "?") .. "://"
        .. (server.host or "?") .. (server.port and (":" .. tostring(server.port)) or ""))

    while true do
        local client = listen_sock:accept()
        if client then
            client:settimeout(server.opts.timeout or 5000)
            local ok, handler_err = pcall(function()
                server:handle({
                    socket    = client,
                    keepalive = server.opts.keepalive or false,
                })
            end)
            if not ok then
                Log.error("[daemon] handler error: " .. tostring(handler_err))
            end
            client:close()
        end
    end
end

return _M
```

### 6.3 TcpTransport.serve（socket 模式）

```lua
-- server/tcp.lua
local Framing = require("yar.protocol.framing")
local Log = require("yar.log")
local pcall, tostring = pcall, tostring

local _M = {}

function _M.serve(sock, dispatcher, spec, opts)
    spec = spec or {}
    opts = opts or {}
    local max_body_len = opts.max_body_len or Framing.DEFAULT_MAX_BODY_LEN
    local keepalive = spec.keepalive or false

    local function process_one()
        local data = Framing.receive_message(sock, max_body_len)
        if not data then return nil, "connection closed" end
        local resp, herr = dispatcher:handle_message(data)
        if not resp then
            Log.error("[tcp] handle_message error: " .. tostring(herr))
            return nil, herr
        end
        local _, serr = sock:send(resp)
        if serr then return nil, serr end
        return true
    end

    if keepalive then
        while true do
            local ok, err = process_one()
            if not ok then return nil, err end
        end
    else
        return process_one()
    end
end

return _M
```

### 6.4 HttpTransport（socket 模式 + 回调模式）

```lua
-- server/http.lua
local Http = require("yar.transport.http")  -- 复用 CONTENT_TYPE 常量
local pcall, string, tonumber, tostring =
      pcall, string, tonumber, tostring

local _M = {}

local REASON = {
    [200] = "OK", [400] = "Bad Request", [405] = "Method Not Allowed",
    [413] = "Request Entity Too Large", [500] = "Internal Server Error",
}

local function http_response(status, content_type, body)
    return string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        status, REASON[status] or "Error", content_type, #body, body)
end

-- socket 模式：从 socket 读 HTTP 请求，写 HTTP 响应
function _M.serve(sock, dispatcher, opts)
    opts = opts or {}
    local max_body_len = opts.max_body_len or 1024 * 1024

    local line = sock:receive("*l")
    if not line then return nil, "connection closed" end
    local method = string.match(line, "^(%u+)%s")

    if method == "GET" then
        local body = dispatcher:pack(dispatcher:list_methods())
        sock:send(http_response(200, "application/json", body))
        return true
    end
    if method ~= "POST" then
        sock:send(http_response(405, "text/plain", "method not allowed"))
        return true
    end

    -- POST: 读 headers 获取 Content-Length
    local content_length
    while true do
        line = sock:receive("*l")
        if not line or line == "" then break end
        local k, v = string.match(line, "^([^:]+):%s*(.*)$")
        if k and string.lower(k) == "content-length" then
            content_length = tonumber(v)
        end
    end
    if content_length and content_length > max_body_len then
        sock:send(http_response(413, "text/plain",
            "body too large: " .. content_length .. " bytes (max " .. max_body_len .. ")"))
        return true
    end
    local data = content_length and sock:receive(content_length) or ""
    if not data or data == "" then
        sock:send(http_response(400, "text/plain", "empty body"))
        return true
    end

    local resp, herr = dispatcher:handle_message(data)
    if not resp then
        sock:send(http_response(500, "text/plain", herr or "internal error"))
        return true
    end
    sock:send(http_response(200, Http.CONTENT_TYPE, resp))
    return true
end

-- 回调模式：宿主提供 data + writer，库只做协议
-- writer 签名：writer(status, headers, body) — 参数序=HTTP 线序=回调执行序，对标 WSGI start_response(status, headers)
function _M.serve_callback(spec, dispatcher, opts)
    local writer = spec.writer

    -- 构造 headers 表的辅助函数
    local function make_headers(content_type, body)
        return { ["Content-Type"] = content_type, ["Content-Length"] = #body }
    end

    if spec.method == "GET" then
        local body = dispatcher:pack(dispatcher:list_methods())
        writer(200, make_headers("application/json", body), body)
        return true
    end
    if spec.method ~= "POST" then
        local msg = "method not allowed"
        writer(405, make_headers("text/plain", msg), msg)
        return true
    end

    local data = spec.data
    if not data or data == "" then
        local msg = "empty body"
        writer(400, make_headers("text/plain", msg), msg)
        return true
    end

    local resp, herr = dispatcher:handle_message(data)
    if not resp then
        local msg = herr or "internal error"
        writer(500, make_headers("text/plain", msg), msg)
        return true
    end
    -- YAR 协议层成功：HTTP 200 + YAR 响应体（对标 PHP yar）
    writer(200, make_headers(Http.CONTENT_TYPE, resp), resp)
    return true
end

return _M
```

---

## 七、数据流图

### 7.1 宿主 HTTP 回调模式（OpenResty）

```
nginx worker -> content_by_lua_block
  -> Server.new(opts, service):handle({method="POST", data=YAR请求字节, writer=fn})
    -> HttpTransport.serve_callback(spec, dispatcher, opts)
      -> dispatcher:handle_message(data)           -- 纯协议：解析->派发->渲染
        -> Protocol.parse(data)              -- 解包 packager+header+body
        -> methods[method](params)          -- 派发到业务方法（pcall 隔离）
        -> Protocol.render(response)        -- 渲染 YAR 响应
      -> writer(200, {["Content-Type"]="application/octet-stream"}, resp)  -- 回调输出
        -> ngx.status=200, ngx.header[...]=..., ngx.print(resp)
  -> return true
```

### 7.2 宿主 TCP socket 模式（OpenResty stream / copas）

```
nginx stream / copas accept loop
  -> Server.new(opts, service):handle({socket=sock, keepalive=true})
    -> TcpTransport.serve(sock, dispatcher, spec, opts)
      [keepalive 循环]
        -> Framing.receive_message(sock)     -- 读 YAR 帧
           -> receive_exact(sock, 90) -> header
           -> receive_exact(sock, body_len) -> body
        -> dispatcher:handle_message(data)         -- 纯协议处理
        -> sock:send(resp)                   -- 写 YAR 帧
      [循环直到客户端断开或错误]
  -> return nil, "connection closed"
```

### 7.3 daemon TCP 模式（标准 Lua）

```
local server = Server.new(opts, service)
  -> new 时若传 service -> 内部调 register_service(service) 自动收集 public 方法
server:listen("tcp://0.0.0.0:8888")
  -> listen 时解析 addr -> self.protocol="tcp", host="0.0.0.0", port=8888
  -> Socket.bind("0.0.0.0", 8888) -> self.listen_sock
server:loop()
  -> Daemon.run(server)
    -> 从 server.listen_sock 读已绑定的监听 socket
    [accept 循环]
      -> listen_sock:accept() -> client
      -> server:handle({socket=client, keepalive=server.opts.keepalive})
        -> TcpTransport.serve(...)           -- 同 7.2
      -> client:close()
  -> (无限循环)
```

### 7.4 daemon HTTP 模式（标准 Lua）

```
local server = Server.new(opts, service)
  -> new 时若传 service -> 内部调 register_service(service) 自动收集 public 方法
server:listen("http://0.0.0.0:8888")
  -> listen 时解析 addr -> self.protocol="http", host="0.0.0.0", port=8888
  -> Socket.bind("0.0.0.0", 8888) -> self.listen_sock
server:loop()
  -> Daemon.run(server)
    -> 从 server.listen_sock 读已绑定的监听 socket
    [accept 循环]
      -> listen_sock:accept() -> client
      -> server:handle({socket=client})
        -> HttpTransport.serve(sock, dispatcher)   -- HTTP 请求解析+响应
           -> 读 HTTP 请求行/头/体
           -> dispatcher:handle_message(data)
           -> 写 HTTP 响应
      -> client:close()
```

---

## 八、验收：调用方心智负担

### 8.1 验收标准

用户提出：以降低调用方心智负担作为验收标准。

### 8.2 各场景调用方代码量与概念数

| 场景 | 调用方代码 | 概念数 | 代码行数 |
|---|---|---|---|
| OpenResty HTTP | `Server.new(opts, service):handle({method=,data=,writer=})` | 1 | ~8 行 |
| OpenResty TCP | `Server.new(opts, service):handle({socket=,keepalive=})` | 1 | ~3 行 |
| copas TCP | `copas.addserver(srv, function(c) Server.new(opts,service):handle({socket=c,keepalive=true}) end)` | 1 | ~4 行 |
| 标准 Lua TCP daemon | `local s=Server.new(opts,service)`<br>`s:listen("tcp://addr")`<br>`s:loop()` | 1 | 3 行 |
| 标准 Lua HTTP daemon | `local s=Server.new(opts,service)`<br>`s:listen("http://addr")`<br>`s:loop()` | 1 | 3 行 |

### 8.3 与当前架构对比

| 维度 | 当前架构 | v4 设计 |
|---|---|---|
| 调用方概念数 | 1（HttpServer/TcpServer 分离） | 1（统一 Server） |
| HTTP/TCP 对称 | 否（不同类不同方法） | 是（统一 handle/loop） |
| transport 选择 | 类名（HttpServer vs TcpServer） | URL scheme（对标 yar-c） |
| HTTP 回调注入 | 否（必须走 socket） | 是（writer 回调） |
| 宿主轻量性 | 是（handle_message 无依赖） | 是（handle 无 daemon 依赖） |
| 内部分离 | 否（daemon+transport 混合） | 是（三层分离，Facade 隐藏） |

### 8.4 与 v1/v2/v3 对比

| 维度 | v1 提案 A | v2 Facade | v3 handle+run | v4 最终 |
|---|---|---|---|---|
| 调用方概念 | 3（Server+Transport+Daemon） | 1 | 1 | 1 |
| 模式选择 | 调用方组装 | options 判断 | 方法选择 | 方法选择 |
| HTTP/TCP 对称 | 否 | 是 | 是 | 是 |
| URL 选 transport | 否（require） | 是 | 是 | 是 |
| HTTP 回调注入 | 否 | 是 | 是 | 是 |
| 宿主轻量性 | 否 | 是 | 是 | 是 |
| 跨语言理论支撑 | 无 | 无 | 部分 | 是（WSGI/ASGI/Go） |
| 设计模式 | handler 注入 | Facade | Facade | Facade+Strategy+Template+Adapter+Factory |
| I/O 抽象统一性 | 无 | 无 | 部分 | 是（I/O=回调对） |

---

## 九、文件拆分清单

| 文件 | 动作 | 职责 |
|---|---|---|
| `src/yar/server/init.lua` | 重写 | Server Facade（new(opts,service)/handle/listen/loop + 分发 + 委托 dispatcher + register_service + set_options/set_packager/setopt） |
| `src/yar/server/dispatcher.lua` | 新建（从 init.lua 提取） | Dispatcher（handle_message + register_service + list_methods + pack） |
| `src/yar/server/tcp.lua` | 重写 | TcpTransport.serve（YAR 帧读写 + keepalive） |
| `src/yar/server/http.lua` | 重写 | HttpTransport.serve + serve_callback |
| `src/yar/server/daemon.lua` | 新建 | Daemon.run（accept + handle 委托，bind 已在 listen() 完成） |
| `src/yar/transport/socket.lua` | 更新 | 新增 `bind_unix(path)` 函数（unix domain socket 监听） |
| `src/yar/init.lua` | 更新导出 | `Yar.Server` 指向新 Facade |
| `example/resty_yar_http_server.lua` | 简化 | 改用 `server:handle({method=,data=,writer=})` |
| `example/resty_yar_tcp_server.lua` | 简化 | 改用 `server:handle({socket=,keepalive=})` |
| `example/server_http.lua` | 简化 | 改用 `Server.new(opts,service):listen("http://addr")` + `s:loop()` |
| `example/server_tcp.lua` | 简化 | 改用 `Server.new(opts,service):listen("tcp://addr")` + `s:loop()` |
| `spec/server_*_spec.lua` | 更新 | 测试新 API |
| `docs/api.md` | 更新 | 文档新 API |

---

## 十、总结

### 10.1 核心转变路径

```
v1（让调用方组装三层）
  -> v2（Facade 统一 run，内部分发）
    -> v3（handle+run 双模式，方法即模式）
      -> v4（跨语言理论支撑 + I/O 抽象统一 + 7 细节决议 + 设计模式应用）
```

### 10.2 v4 的理论贡献

v1-v3 是经验层面的设计迭代（看 copas/yar-c/PHP yar 怎么做，然后模仿）。
v4 是原理层面的理论支撑（提炼 I/O 抽象的统一规律，用理论指导设计）：

1. **I/O 即读写回调对**——从 WSGI/ASGI/Go/socket/回调中提炼出的统一规律
2. **socket 天然满足回调对接口**——这是 HTTP 和 TCP 可统一抽象的根本原因
3. **Listen/Serve 分离**——Go 解决 daemon/hosted 二元性的经典模式，映射到 loop/handle
4. **方法即模式**——选方法即选模式，不需要 options 判断，认知负担最低

### 10.3 最终设计的 5 个设计模式

| 模式 | 作用 | 对标 |
|---|---|---|
| Facade | 隐藏 Transport/Daemon/Core，只暴露 Server | Go http.Server, PHP Yar_Server |
| Strategy | I/O 机制可替换（socket vs callback） | ASGI receive/send, Go ResponseWriter |
| Template Method | 读写->处理->读写流程固定 | WSGI app(environ, start_response) |
| Adapter | luasocket/cosocket 适配 | 现有 transport/socket.lua |
| Factory | URL 创建 transport | yar-c init("tcp://addr"), 客户端 Transport.get |

### 10.4 验收结论

**调用方心智负担最小化**——所有场景调用方只感知 1 个概念（Server），3 个方法（handle/listen/loop）。

- 宿主模式：`Server.new(opts?, service?):handle(spec)` — service 可选，传了自动收集
- 原生模式：`Server.new(opts?, service?):listen(addr)` + `s:loop()` — listen 解析 addr 并 bind（I/O 操作返回 `true|nil,err`），loop 无参（addr 已在 listen 时解析），service 可选

方法选择即模式选择，不需要 options 判断，不需要感知 Transport/Daemon。HTTP 和 TCP 完全对称——差异仅在 spec 字段。
