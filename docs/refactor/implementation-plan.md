# 实施方案：核心文件 + 数据流 + 调用链路

> 基于 v4 设计，列出每个文件的函数签名、职责、调用链路。
> 关联：deep-synthesis-v4.md

---

## 一、文件结构

```
src/yar/server/
  init.lua              <- Server Facade（重写）
  dispatcher.lua       <- Dispatcher（从 init.lua 提取，协议核心不变）
  daemon.lua            <- Daemon（新建）
  tcp.lua               <- TcpTransport（重写，原 HttpServer/TcpServer 逻辑迁入）
  http.lua              <- HttpTransport（重写，原 HttpServer 逻辑迁入）
```

注：`http.lua` 和 `tcp.lua` 文件名不变，但内容从旧的 HttpServer/TcpServer（daemon+transport 混合）重写为纯 Transport 模块。旧的 `run` 逻辑迁入 `daemon.lua`，旧的 `handle_connection` 逻辑留在本文件但改为 `serve` 函数。

---

## 二、各文件函数清单

### 2.1 `server/dispatcher.lua`（协议核心，从 init.lua 提取）

职责：纯协议处理，无 I/O，无 yield，reentrant。与当前 `init.lua` 的 `handle_message` 逻辑完全一致，只是换个文件名。

```
文件：src/yar/server/dispatcher.lua

函数：
  Dispatcher.new() -> Dispatcher
    -- 构造，无参（RPC 方法通过 :register_service() 注册）
    -- methods 初始为空表
    -- 对标 yar-c yar_server_init（无 service 参数）、Go rpc.NewServer()

  Dispatcher:register_service(service) -> Dispatcher
    -- RPC 方法注册：collect_methods(service) 自动收集 public 方法
    -- service 是 table：遍历收集 function 类型、非 _ 开头的成员
    -- service 是 function：注册为 "default" 方法
    -- 支持多次调用，增量 merge 到 methods 表
    -- 对标 Go rpc.Register(recv)、PHP Yar new Yar_Server($service)

  Dispatcher:set_packager(name) -> Dispatcher
    -- 设置默认 packager

  Dispatcher:set_options(opts) -> Dispatcher
    -- 表驱动设置（packager/timeout/max_body_len/hooks 等）

  Dispatcher:setopt(opt, val) -> Dispatcher
    -- 单项设置，代理到 set_options

  Dispatcher:list_methods() -> table
    -- 返回方法名数组（GET introspection 用）

  Dispatcher:pack(data) -> string
    -- 包装 self.packager.pack(data)，GET introspection 序列化用
    -- Transport 层通过此方法序列化，不直接访问 dispatcher.packager 字段

  Dispatcher:handle_message(data) -> resp|nil, err
    -- 协议核心入口
    -- 输入：完整 YAR 二进制消息（packager+header+body）
    -- 处理：校验 -> 解析 packager name -> Protocol.parse -> 派发方法 -> Protocol.render
    -- 输出：YAR 二进制响应消息
    -- 无 I/O，纯函数，可被任意协程/OpenResty location 调用
```

与当前 `init.lua` 的关系：`dispatcher.lua` = 当前 `init.lua` 的全部逻辑，类名 `Server` 改为 `Dispatcher`。`handle_message` 的实现一行不改。`new(service)` 签名变为 `new()` 无参——service 参数移到 Facade 层 `new(opts, service)` 的第二参数。`register(name, func)` 移除，统一用 `register_service(service)`（封装当前 `collect_methods` 局部函数）。addr 是 Facade 层属性，不属于 Dispatcher。

### 2.2 `server/init.lua`（Server Facade，重写）

职责：统一入口，对外只暴露 `new`/`handle`/`listen`/`loop`，内部分发给 Dispatcher/Transport/Daemon。

```
文件：src/yar/server/init.lua

依赖：
  local Dispatcher    = require("yar.server.dispatcher")
  local TcpTransport  = require("yar.server.tcp")
  local HttpTransport = require("yar.server.http")
  local Daemon        = require("yar.server.daemon")
  local Socket        = require("yar.transport.socket")

函数：
  Server.new(opts?, service?) -> Server
    -- 构造 Facade（对标 lua-resty-http http.new()、lua-resty-redis redis.new()）
    -- 构造器只做初始化（opts/service），不碰地址、不碰 I/O
    -- opts: { packager, max_body_len, timeout, keepalive, hooks, socket_provider, ... }（可选，运行时配置项）
    -- service: RPC 方法表（可选，传了 collect_methods 自动收集 public 方法）
    --   对标 PHP Yar new Yar_Server($service)、Go rpc.Register(recv)
    -- 内部：self.dispatcher = Dispatcher.new()
    --       self.opts = opts or {}
    --       self.dispatcher:set_options(self.opts)  -- 传递所有 opts（packager/hooks/max_body_len 等）
    --       if opts.socket_provider then Socket.set(opts.socket_provider) end
    --       if service then self.dispatcher:register_service(service) end

  Server:handle(spec) -> true|nil, err
    -- 宿主模式入口
    -- 分发逻辑：
    --   if spec.socket then -> self:_handle_socket(spec)
    --   elseif spec.writer then -> self:_handle_callback(spec)
    --   else -> nil, "invalid spec: need socket or writer"

  Server:_handle_socket(spec) -> true|nil, err
    -- socket 模式分发：
    --   protocol = self.protocol or "tcp"  (self.protocol 由 listen() 设置，宿主模式默认 "tcp")
    --   if protocol == "http" -> HttpTransport.serve(spec.socket, self.dispatcher, self.opts)
    --   else -> TcpTransport.serve(spec.socket, self.dispatcher, spec, self.opts)

  Server:_handle_callback(spec) -> true|nil, err
    -- 回调模式（HTTP only）：
    --   return HttpTransport.serve_callback(spec, self.dispatcher, self.opts)

  Server:listen(addr) -> true|nil, err
    -- 原生模式入口 1：解析 addr + bind（对标 lua-resty-http httpc:connect(host, port)）
    -- I/O 操作，返回 true|nil, err（非链式，对标 httpc:connect 返回值）
    -- addr: "tcp://0.0.0.0:8888" / "http://0.0.0.0:8888" / "http://0.0.0.0" / "unix:///path"
    --   http 协议可省略端口，默认 80（RFC 3986）；tcp 必须指定端口
    -- 内部：parse_addr(addr) -> self.protocol + self.host + self.port（早失败）
    --       if protocol == "unix" then Socket.bind_unix(host) else Socket.bind(host, port) end
    --       self.listen_sock = listen_sock

  Server:loop() -> nil|nil, err
    -- 原生模式入口 2：accept 循环 + handle 委托（无参，addr 已在 listen 时解析）
    -- 前提：self.listen_sock 已在 listen() 中设置（未 listen 则 return nil, "no addr configured, call listen(addr) first"）
    -- 内部：return Daemon.run(self)
    -- 对标 copas.loop()、Go ListenAndServe()、Python serve_forever()
    -- WARNING: sequential accept, for dev/testing only.
    --   One slow request blocks all connections.
    --   Lua 无内置并发原语：无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。
    --   唯一并发路径：协程 + 非阻塞 I/O + select 调度器（= copas，~500 行纯 Lua）。
    --   生产并发用：
    --   - OpenResty: handle({method=, data=, writer=}) 回调模式
    --   - copas:     copas.addserver(server.listen_sock, handler) + copas.loop()
    --   - lua-eco / Skynet: handle({socket=}) + 宿主协程调度

  Server:register_service(service) -> Server
    -- 委托：self.dispatcher:register_service(service); return self
    -- collect_methods 自动收集 public 方法，支持多次调用增量 merge

  Server:set_packager(name) -> Server
    -- 委托：self.dispatcher:set_packager(name); return self

  Server:set_options(opts) -> Server
    -- 存到 self.opts（Facade 级：keepalive/timeout）
    -- 委托 self.dispatcher:set_options(opts)（Dispatcher 级：packager/hooks/max_body_len）
    -- socket_provider 全局副作用：Socket.set(v)

  Server:setopt(opt, val) -> Server
    -- 委托：return self:set_options({ [opt] = val })

  Server:list_methods() -> table
    -- 委托：return self.dispatcher:list_methods()
```

### 2.3 `server/tcp.lua`（TcpTransport，重写）

职责：YAR 帧读写 + keepalive 循环。从当前 `tcp.lua` 的 `handle_connection` 提取。

```
文件：src/yar/server/tcp.lua

依赖：
  local Framing = require("yar.protocol.framing")
  local Log     = require("yar.log")

函数：
  TcpTransport.serve(sock, dispatcher, spec, opts) -> true|nil, err
    -- TCP 连接处理入口
    -- spec: { keepalive = bool }
    -- opts: { max_body_len = number }
    --
    -- 内部流程（Template Method）：
    --   1. process_one():
    --      a. Framing.receive_message(sock, max_body_len) -> data  [读请求]
    --      b. dispatcher:handle_message(data) -> resp              [协议处理]
    --      c. sock:send(resp)                                 [写响应]
    --   2. if keepalive then 循环 process_one() 直到 nil
    --      else 单次 process_one()
    --
    -- 返回：true（成功处理）/ nil, err（连接断开或错误）
```

### 2.4 `server/http.lua`（HttpTransport，重写）

职责：HTTP 请求解析 + 响应构造。从当前 `http.lua` 的 `handle_connection` 提取。支持两种模式：socket 模式和回调模式。

```
文件：src/yar/server/http.lua

依赖：
  local Http = require("yar.transport.http")  -- 复用 CONTENT_TYPE 常量
  local Log  = require("yar.log")

函数：
  HttpTransport.serve(sock, dispatcher, opts) -> true|nil, err
    -- HTTP socket 模式入口
    -- 从 socket 读 HTTP 请求，写 HTTP 响应
    --
    -- 内部流程：
    --   1. 读请求行：sock:receive("*l") -> method
    --   2. GET  -> dispatcher:pack(dispatcher:list_methods()) -> http_response(200, json) -> sock:send
    --   3. POST -> 读 headers 获取 Content-Length -> 校验 max_body_len -> 读 body
    --      -> dispatcher:handle_message(data) -> resp
    --      -> http_response(200, CONTENT_TYPE, resp) -> sock:send
    --   4. 其他 method -> http_response(405, ...) -> sock:send
    --
    -- http_response(status, content_type, body) 构造完整 HTTP 响应字符串（内部函数）

  HttpTransport.serve_callback(spec, dispatcher, opts) -> true|nil, err
    -- HTTP 回调模式入口（OpenResty 用）
    -- spec: { method, data, writer }
    --
    -- 内部流程：
    --   1. GET  -> dispatcher:pack(dispatcher:list_methods()) -> writer(200, {["Content-Type"]="application/json"}, json)
    --   2. POST -> dispatcher:handle_message(spec.data) -> resp
    --      -> writer(200, {["Content-Type"]=CONTENT_TYPE}, resp)
    --   3. 其他 -> writer(405, {["Content-Type"]="text/plain"}, "method not allowed")
    --   4. 空 body -> writer(400, {["Content-Type"]="text/plain"}, "empty body")
    --   5. handle_message 失败 -> writer(500, {["Content-Type"]="text/plain"}, err)
    --
    -- writer 签名：writer(status, headers, body) — 参数序=HTTP 线序=回调执行序，对标 WSGI start_response(status, headers)
```

### 2.5 `server/daemon.lua`（Daemon，新建）

职责：accept 循环，委托 `server:handle`。bind 已在 `Server:listen()` 中完成。

```
文件：src/yar/server/daemon.lua

依赖：
  local Log    = require("yar.log")

函数：
  Daemon.run(server) -> nil|nil, err
    -- daemon 模式入口（顺序 accept，dev/testing 用途）
    -- server: Server Facade 实例（listen_sock 已在 listen() 中创建并绑定）
    -- 不再接收 url，从 server.listen_sock 读已绑定的监听 socket
    --
    -- 并发模型：零协程，顺序 accept → handle → close 循环。
    --   Lua 无多线程（VM 非线程安全）、无 callback-based accept（luasocket 阻塞）。
    --   协程并发需非阻塞 I/O + select 调度器（= copas），不内置——保持 daemon 顺序，
    --   并发交给 copas / OpenResty / lua-eco 等宿主运行时。
    --   对标 yar-c（同样顺序）、Python HTTPServer（默认顺序，并发靠 ThreadingMixIn）。
    --
    -- 内部流程：
    --   1. 从 server.listen_sock 读已绑定的监听 socket
    --   2. while true:
    --        client = listen_sock:accept()
    --        client:settimeout(server.opts.timeout)
    --        pcall(server.handle, server, {
    --            socket = client, keepalive = server.opts.keepalive
    --        })
    --        client:close()
    --
    -- 返回：正常路径无限循环
```

注：`parse_addr(addr)` 是 Facade `init.lua` 的本地函数（早失败），不在 daemon.lua 中定义。bind 也在 `init.lua` 的 `listen()` 中完成。Daemon.run 从 server 实例读已绑定的 `listen_sock`，只管 accept 循环。

---

## 三、调用链路

### 3.1 宿主 HTTP 回调模式（OpenResty）

```
调用方代码：
  local server = Server.new(nil, service)
  server:handle({
      method = ngx.req.get_method(),
      data   = ngx.req.get_body_data(),
      writer = function(status, headers, body)
          ngx.status = status
          for k, v in pairs(headers) do ngx.header[k] = v end
          ngx.print(body)
      end,
  })

调用链：
  Server:handle(spec)                          [init.lua]
    -> Server:_handle_callback(spec)            [init.lua]
       -> HttpTransport.serve_callback(spec, dispatcher, opts)  [http.lua]
          -> dispatcher:list_methods()           [dispatcher.lua]  (GET 时)
          -> dispatcher.packager.pack(...)       [packager]        (GET 时)
          -> dispatcher:handle_message(data)     [dispatcher.lua]  (POST 时)
             -> Protocol.parse(data, packager)   [protocol/protocol.lua]
             -> methods[method](params)          [用户业务方法]
             -> Protocol.render(response)        [protocol/protocol.lua]
          -> spec.writer(status, headers, body) [调用方回调]
```

### 3.2 宿主 TCP socket 模式（OpenResty stream / copas）

```
调用方代码：
  local server = Server.new(nil, service)
  server:handle({ socket = sock, keepalive = true })

调用链：
  Server:handle(spec)                          [init.lua]
    -> Server:_handle_socket(spec)             [init.lua]
       -> TcpTransport.serve(sock, dispatcher, spec, opts)  [tcp.lua]
          [keepalive 循环]
            -> Framing.receive_message(sock, max_body_len)  [protocol/framing.lua]
               -> Framing.receive_exact(sock, 90)   读 header
               -> Framing.receive_exact(sock, body_len) 读 body
            -> dispatcher:handle_message(data)          [dispatcher.lua]
            -> sock:send(resp)                          [socket]
          [循环直到 nil]
```

### 3.3 daemon TCP 模式（标准 Lua）

```
调用方代码：
  -- 方式一：new 传 service（PHP yar 模式）
  local server = Server.new({ keepalive = true }, api)
  server:listen("tcp://0.0.0.0:8888")
  server:loop()

  -- 方式二：register_service 注册
  local server = Server.new({ keepalive = true })
  server:register_service({ add = function(a, b) return a + b end })
  server:listen("tcp://0.0.0.0:8888")
  server:loop()

调用链：
  Server:listen("tcp://0.0.0.0:8888")          [init.lua]
    -> parse_addr(addr) -> self.protocol="tcp", host="0.0.0.0", port=8888
    -> Socket.bind("0.0.0.0", 8888) -> self.listen_sock   [transport/socket.lua]
  Server:loop()                                [init.lua]
    -> Daemon.run(server)                      [daemon.lua]
       -> 从 server.listen_sock 读已绑定的监听 socket
       -> [accept 循环]
            -> listen_sock:accept() -> client
            -> Server:handle({               [init.lua]  委托回 Facade
                 socket = client,
                 keepalive = server.opts.keepalive,
               })
                 -> Server:_handle_socket(spec)  [init.lua]
                    -> protocol = self.protocol  (listen 时已解析为 "tcp")
                    -> TcpTransport.serve(...)  [tcp.lua]
                       (同 3.2 的内部链路)
            -> client:close()
```

### 3.4 daemon HTTP 模式（标准 Lua）

```
调用方代码：
  local server = Server.new(nil, service)
  server:listen("http://0.0.0.0:8888")
  server:loop()

调用链：
  Server:listen("http://0.0.0.0:8888")        [init.lua]
    -> parse_addr(addr) -> self.protocol="http", host="0.0.0.0", port=8888
    -> Socket.bind("0.0.0.0", 8888) -> self.listen_sock
  Server:loop()                                [init.lua]
    -> Daemon.run(server)                      [daemon.lua]
       -> 从 server.listen_sock 读已绑定的监听 socket
       -> [accept 循环]
            -> listen_sock:accept() -> client
            -> Server:handle({               [init.lua]  委托回 Facade
                 socket = client,
               })
                 -> Server:_handle_socket(spec)  [init.lua]
                    -> protocol = self.protocol  (listen 时已解析为 "http")
                    -> HttpTransport.serve(sock, dispatcher, opts)  [http.lua]
                       (HTTP 请求解析 -> handle_message -> HTTP 响应)
            -> client:close()
```

---

## 四、数据流图

### 4.1 宿主 HTTP 回调模式

```
+--------------+     +-------------------------------------------------+
|  调用方      |     |              Server Facade (init.lua)            |
|  (OpenResty) |     |                                                  |
|              |     |  handle({method, data, writer})                  |
|  ngx.req     |---> |    |                                             |
|  get_method  |     |    v                                             |
|  get_body    |     |  _handle_callback(spec)                         |
|              |     |    |                                             |
|              |     |    v                                             |
|              |     |  HttpTransport.serve_callback(spec, dispatcher, opts) |
|              |     |    |                                  +----------+
|              |     |    | GET                               |          |
|              |     |    +-----------------> dispatcher:list_methods()  |
|              |     |    |                  -> packager.pack()          |
|              |     |    |                      |                      |
|              |     |    | POST                 |                      |
|              |     |    +-> dispatcher:handle_message(data)           |
|              |     |    |      |                                     |
|              |     |    |      +-> Protocol.parse                    |
|              |     |    |      +-> methods[method]()  (用户方法)      |
|              |     |    |      +-> Protocol.render                   |
|              |     |    |              |                             |
|              |     |    |              v                             |
|              |     |    |  writer(status, headers, body)              |
|              |     |    |              |                             |
|  ngx.status  |<----|----+--------------                              |
|  ngx.header  |     |                                                  |
|  ngx.print   |     |  return true                                     |
+--------------+     +--------------------------------------------------+
```

### 4.2 宿主 TCP socket 模式

```
+--------------+     +-------------------------------------------------+
|  调用方      |     |              Server Facade (init.lua)            |
|  (OpenResty  |     |                                                  |
|   stream /   |     |  handle({socket, keepalive})                    |
|   copas)     |     |    |                                             |
|  sock =      |---> |    v                                             |
|  ngx.req     |     |  _handle_socket(spec)                           |
|  .sock()     |     |    |                                             |
|              |     |    v                                             |
|              |     |  TcpTransport.serve(sock, dispatcher, spec, opts)|
|              |     |    |                                  +----------+
|              |     |    | [keepalive 循环]                   |          |
|              |     |    |   |                                |          |
|  sock        |<----|----|   v                                |          |
|  :receive    |     |    |   Framing.receive_message(sock)   |          |
|              |---> |    |   |                                |          |
|              |     |    |   +-> receive_exact(sock, 90)  header        |
|              |     |    |   +-> receive_exact(sock, n)   body          |
|              |     |    |   |                                |          |
|              |     |    |   v                                |          |
|              |     |    |   dispatcher:handle_message(data) -> dispatcher.lua |
|              |     |    |   |                                |          |
|              |     |    |   v                                |          |
|  sock        |<----|----|   sock:send(resp)                 |          |
|  :send       |     |    |                                  |          |
|              |     |    |   [循环直到 nil]                   |          |
|              |     |    |                                  |          |
|              |     |    +----------------------------------+          |
|              |     |                                                  |
|              |     |  return nil, "connection closed"               |
+--------------+     +--------------------------------------------------+
```

### 4.3 daemon 模式（TCP / HTTP 统一）

```
+--------------+     +-------------------------------------------------+
|  调用方      |     |              Server Facade (init.lua)            |
|  (标准 Lua)  |     |                                                  |
|              |     |  Server.new(opts, service)                       |
|              |---> |    若传 service -> register_service 自动收集       |
|              |     |                                                  |
|              |     |  listen("tcp://0.0.0.0:8888")                    |
|              |---> |    解析 addr -> self.protocol/host/port           |
|              |     |    Socket.bind(host, port) -> self.listen_sock     |
|              |     |                                                  |
|              |     |  loop()                                          |
|              |---> |    |                                             |
|              |     |    v                                             |
|              |     |  Daemon.run(server)  [daemon.lua]                |
|              |     |    |                                             |
|              |     |    +-> 从 server.listen_sock 读已绑定的监听 socket  |
|              |     |    |                                             |
|              |     |    +-> [accept 循环]                             |
|              |     |          |                                      |
|  listen_sock |     |          v                                      |
|  :accept     |     |          listen_sock:accept() -> client         |
|              |     |          |                                      |
|              |     |          v                                      |
|              |     |          Server:handle({     委托回 Facade       |
|              |     |            socket   = client,                    |
|              |     |            keepalive = server.opts.keepalive,    |
|              |     |          })                                       |
|              |     |            |                                      |
|              |     |            v                                      |
|              |     |          _handle_socket(spec)                    |
|              |     |            |                                     |
|              |     |            +-> self.protocol=="tcp"  -> TcpTransport.serve
|              |     |            +-> self.protocol=="http" -> HttpTransport.serve
|              |     |                                               |   |
|              |     |          client:close() <---------------------+   |
|              |     |                                                  |
+--------------+     +--------------------------------------------------+
```

### 4.4 loop 内部委托 handle 的闭环

```
              +-------------------------------------------+
              |           Server Facade (init.lua)        |
              |                                           |
              |  new(opts, service)                       |
              |    若传 service -> register_service         |
              |                                           |
              |  listen("tcp://addr")                     |
              |    解析 addr -> protocol/host/port       |
              |    Socket.bind -> self.listen_sock        |
              |                                           |
  loop() ---->|  Daemon.run(server)                       |
              |    |                                      |
              |    +- accept (listen_sock 已绑定)          |
              |    |                                      |
              |    +- server:handle({socket, keepalive}) -+
              |                                    |     |
              |                                    v     |
              |  _handle_socket(spec)                |
              |    |                                  |
              |    +-> self.protocol=="tcp"  -> TcpTransport.serve
              |    +-> self.protocol=="http" -> HttpTransport.serve
              |                                    |   |
              |    <------------------------------ +   |
              |    client:close()                      |
              |    [循环 accept]                       |
              +-------------------------------------------+

  关键：loop 内部调 handle，handle 是核心，loop 只是 accept 循环 + handle 的包装。
  两种模式共享同一个 handle 逻辑。protocol 由 self.protocol 决定（listen 时从 addr 解析）。
```

---

## 五、文件改动清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `src/yar/server/dispatcher.lua` | 新建 | 从 init.lua 提取，类名 Server -> Dispatcher，新增 pack 方法，逻辑不变 |
| `src/yar/server/init.lua` | 重写 | Facade，new(opts,service)/handle/listen/loop + 分发 + 委托 dispatcher + addr 解析 + set_options(含 socket_provider) |
| `src/yar/server/daemon.lua` | 新建 | Daemon.run，accept + 委托 handle（bind 已在 listen() 完成） |
| `src/yar/transport/socket.lua` | 更新 | 新增 `bind_unix(path)` 函数（unix domain socket 监听） |
| `src/yar/server/tcp.lua` | 重写 | TcpTransport.serve，原 handle_connection 逻辑保留为 serve 函数，删除 run |
| `src/yar/server/http.lua` | 重写 | HttpTransport.serve + serve_callback，原 handle_connection 逻辑保留，删除 run |
| `src/yar/init.lua` | 更新 | 导出 Yar.Server 指向新 Facade |
| `example/resty_yar_http_server.lua` | 简化 | 改用 server:handle({method=,data=,writer=}) |
| `example/resty_yar_tcp_server.lua` | 简化 | 改用 server:handle({socket=,keepalive=}) |
| `example/server_http.lua` | 简化 | 改用 Server.new(opts,service):listen("http://addr") + s:loop() |
| `example/server_tcp.lua` | 简化 | 改用 Server.new(opts,service):listen("tcp://addr") + s:loop() |
| `spec/server_*_spec.lua` | 更新 | 测试新 API |
| `docs/api.md` | 更新 | 文档新 API |

---

## 六、dispatcher.lua 与当前 init.lua 的对应关系

当前 `init.lua` 的所有函数直接搬到 `dispatcher.lua`，只改类名：

| 当前 init.lua | 新 dispatcher.lua | 变化 |
|---|---|---|
| `Server.new(service)` | `Dispatcher.new()` | 类名改；service 参数移除，RPC 方法通过 :register_service() 注册。addr 是 Facade 层属性，不传给 Dispatcher |
| `Server:register(name, func)` | —（移除） | 移除，统一用 register_service(service) |
| —（新增） | `Dispatcher:register_service(service)` | 封装 collect_methods 局部函数，对标 Go rpc.Register、PHP Yar new Yar_Server |
| `Server:set_packager(name)` | `Dispatcher:set_packager(name)` | 类名改 |
| `Server:set_options(opts)` | `Dispatcher:set_options(opts)` | 类名改 |
| `Server:setopt(opt, val)` | `Dispatcher:setopt(opt, val)` | 类名改 |
| `Server:list_methods()` | `Dispatcher:list_methods()` | 类名改 |
| `Server:handle_message(data)` | `Dispatcher:handle_message(data)` | 类名改，逻辑一行不改 |
| `collect_methods(service)` | `collect_methods(service)` | 不变（局部函数） |
| `is_valid_method_name(name)` | `is_valid_method_name(name)` | 不变（局部函数） |
| `run_hook(hook, ...)` | `run_hook(hook, ...)` | 不变（局部函数） |

**核心：handle_message 的实现一行不改**。它已经是纯协议、无 I/O、reentrant 的。只是从 `init.lua` 搬到 `dispatcher.lua`，让 `init.lua` 腾出来做 Facade。

---

## 七、调用方代码对比（改造前 vs 改造后）

### 7.1 OpenResty HTTP

```
改造前（resty_yar_http_server.lua，~80 行）：
  local server = init.get_server()
  local method = ngx.req.get_method()
  if method == "GET" then
      ngx.header["Content-Type"] = "application/json"
      ngx.print(packager.pack(server:list_methods()))
      return
  end
  if method ~= "POST" then ... end
  ngx.req.read_body()
  local data = ngx.req.get_body_data()
  if not data then ... end
  local resp, err = server:handle_message(data)
  if not resp then ... end
  ngx.header["Content-Type"] = CONTENT_TYPE
  ngx.print(resp)

改造后（~8 行）：
  local server = init.get_server()
  server:handle({
      method = ngx.req.get_method(),
      data   = ngx.req.get_body_data(),
      writer = function(status, headers, body)
          ngx.status = status
          for k, v in pairs(headers) do ngx.header[k] = v end
          ngx.print(body)
      end,
  })
```

### 7.2 OpenResty TCP

```
改造前（resty_yar_tcp_server.lua，~50 行）：
  local sock = ngx.req.sock()
  sock:settimeout(config.keepalive_idle)
  local tcp_server = init.get_tcp_server()
  local ok, e = pcall(tcp_server.handle_connection, tcp_server, sock, { keepalive = true })
  if not ok then ngx.log(ngx.ERR, ...) end
  sock:close()

改造后（~6 行）：
  local sock = ngx.req.sock()
  sock:settimeout(config.keepalive_idle)
  local server = init.get_server()
  server:handle({ socket = sock, keepalive = true })
  sock:close()
```

### 7.3 标准 Lua TCP daemon

```
改造前：
  local TcpServer = require("yar.server.tcp")
  local server = TcpServer.new(api)
  server:set_options({ max_body_len = 2^20 })
  server:run("0.0.0.0:8888")

改造后（方式一：new 传 service，PHP yar 模式）：
  local Server = require("yar.server")
  local server = Server.new({ max_body_len = 2^20 }, api)
  server:listen("tcp://0.0.0.0:8888")
  server:loop()

改造后（方式二：register_service 注册）：
  local Server = require("yar.server")
  local server = Server.new({ max_body_len = 2^20 })
  server:register_service({
      add = function(a, b) return a + b end,
      mul = function(a, b) return a * b end,
  })
  server:listen("tcp://0.0.0.0:8888")
  server:loop()
```

### 7.4 标准 Lua HTTP daemon

```
改造前：
  local HttpServer = require("yar.server.http")
  local server = HttpServer.new(api)
  server:run("0.0.0.0:8888")

改造后（方式一：new 传 service，PHP yar 模式）：
  local Server = require("yar.server")
  local server = Server.new(nil, api)
  server:listen("http://0.0.0.0:8888")
  server:loop()

改造后（方式二：register_service 注册）：
  local Server = require("yar.server")
  local server = Server.new()
  server:register_service({
      add = function(a, b) return a + b end,
      mul = function(a, b) return a * b end,
  })
  server:listen("http://0.0.0.0:8888")
  server:loop()
```
