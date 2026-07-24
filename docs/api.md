# lua-yar API Reference

> Complete API reference for the lua-yar RPC framework.
> Style adapted from [lua-resty-http](https://github.com/ledgetech/lua-resty-http) and [OpenResty](https://openresty.org/) ecosystem conventions.

## Table of Contents

- [Top-Level Module](#top-level-module)
- [Client](#client)
  - [Client.new](#clientnew)
  - [Client.set_socket](#clientset_socket)
  - [Client.set_http_provider](#clientset_http_provider)
  - [Client:set_options](#clientset_options)
  - [Client:setopt](#clientsetopt)
  - [Client:call](#clientcall)
  - [Client Options](#client-options)
  - [HTTP Provider](#http-provider)
- [Server](#server)
  - [Server.new](#servernew)
  - [Server:handle](#serverhandle)
  - [Server:listen](#serverlisten)
  - [Server:loop](#serverloop)
  - [Server:register_service](#serverregister_service)
  - [Server:register](#serverregister)
  - [Server:set_packager](#serverset_packager)
  - [Server:set_options](#serverset_options)
  - [Server:setopt](#serversetopt)
  - [Server:list_methods](#serverlist_methods)
  - [Server:handle_message](#serverhandle_message)
  - [Server Options](#server-options)
- [Packager](#packager)
  - [Yar.register_packager](#yarregister_packager)
  - [Yar.get_packager](#yarget_packager)
  - [Yar.set_options](#yarset_options)
- [Error](#error)
  - [Error.new](#errornew)
  - [Error Codes](#error-codes)
- [Log](#log)
  - [Log.set_level](#logset_level)
  - [Log.set_writer](#logset_writer)
  - [Log.debug / info / warn / error](#logdebug--info--warn--error)
- [Hooks](#hooks)
- [Production Deployment](#production-deployment)
- [Internal Modules](#internal-modules)
  - [Protocol](#protocol)
  - [Header](#header)
  - [Framing](#framing)
  - [Request](#request)
  - [Response](#response)
  - [Transport](#transport)
  - [Socket](#socket)
  - [Resolve](#resolve)
  - [Util](#util)

---

## Top-Level Module

```lua
local Yar = require("yar")
```

The `Yar` module is the main entry point. It exports the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `Yar.VERSION` | string | Framework version (e.g. `"0.1.0"`) |
| `Yar.PROTOCOL_VERSION` | integer | YAR protocol version (currently `1`) |
| `Yar.client` | table | [Client class](#client) |
| `Yar.server` | table | [Server class](#server) (unified Facade: TCP/HTTP/host mode) |
| `Yar.error` | table | [Error module](#error) |
| `Yar.log` | table | [Log module](#log) |
| `Yar.PACKAGER_JSON` | string | JSON packager name constant (`"JSON"`) |
| `Yar.PACKAGER_MSGPACK` | string | Msgpack packager name constant (`"MSGPACK"`) |
| `Yar.HTTP_TRANSPORT_CONTENT_TYPE` | string | HTTP transport Content-Type constant (`"application/octet-stream"`), for OpenResty `content_by_lua` response headers |
| `Yar.register_packager` | function | [Register a packager](#yarregister_packager) |
| `Yar.get_packager` | function | [Get a packager by name](#yarget_packager) |
| `Yar.set_options` | function | [Set global options](#yarset_options) |
| `Yar.seed` | function | Global seed function (convenience API). See [Request.seed](#requestseed) |
| `Yar.set_id_generator` | function | Inject custom ID generator. See [Request.set_id_generator](#requestset_id_generator) |

> `Yar.server` is a unified Server Facade. It replaces the previous separate `HttpServer` / `TcpServer` classes. TCP, HTTP, and host-mode (callback) integrations are all handled by `Server.new()` + `Server:handle()` / `Server:listen()` + `Server:loop()`.

---

## Client

The Client constructs YAR requests, sends them over HTTP or TCP transport, and parses responses.

### Client.new

syntax: `client = Yar.client.new(uri)`

Creates a new Client instance. The `uri` determines the transport:

| URI Scheme | Transport | Example |
|------------|-----------|---------|
| `http://` | HTTP | `http://127.0.0.1:8888/api` |
| `https://` | HTTPS (requires cosocket) | `https://api.example.com/path` |
| `tcp://` | TCP (yar-c style) | `tcp://127.0.0.1:9999` |
| `unix://` | Unix domain socket | `unix:///tmp/yar.sock` |

Options are deep-copied from `DEFAULT_OPTIONS`, so each instance has isolated state.

```lua
local client = Yar.client.new("http://127.0.0.1:8888/api")
```

### Client.set_socket

syntax: `Yar.client.set_socket(provider)`

Sets the socket provider at the class level (process-wide). Inject `ngx.socket` for OpenResty cosocket support (non-blocking I/O + connection pool).

```lua
Yar.client.set_socket(ngx.socket)
```

> After injection, all Client instances use cosocket for outbound connections. The framework code does not reference `ngx` directly.

### Client.set_http_provider

syntax: `Yar.client.set_http_provider(provider)`

Sets the HTTP provider at the class level. The provider is a function `function(url, opts) -> body, err` that replaces the default manual HTTP/1.1 implementation. Use this to inject [lua-resty-http](https://github.com/ledgetech/lua-resty-http) or similar libraries for gzip, HTTP/2.0, or when the runtime lacks an SSL-capable socket (e.g. pure luasocket without luasec).

> The default manual implementation supports HTTP proxy (absolute-URI requests) and HTTPS over proxy (CONNECT tunnel + TLS handshake), provided the socket provider offers `sslhandshake` (cosocket does; luasocket requires luasec).

```lua
Yar.client.set_http_provider(function(url, opts)
    local httpc = require("resty.http").new()
    local res, err = httpc:request_uri(url, {
        method = opts.method,
        body = opts.body,
        headers = opts.headers,
        ssl_verify = opts.ssl_verify,
    })
    if not res then return nil, err end
    return res.body
end)
```

> Lookup order: instance `transport.http_provider` → class-level provider → default manual implementation. When no provider is injected, behavior is identical to the built-in HTTP transport.
>
> **Class-level (process-wide)**: affects all Client instances. Override per-instance via `set_options({ transport = { http_provider = fn } })`.

→ 适配器示例：[`example/resty_http_provider.lua`](../example/resty_http_provider.lua)（lua-resty-http adapter，含状态码检查）

### Client:set_options

syntax: `client:set_options(opts)`

Table-driven option setting. Supports both flat style (backward-compatible) and nested style. See [Client Options](#client-options) for all available keys.

```lua
-- Flat style
client:set_options({
    packager = Yar.PACKAGER_MSGPACK,
    timeout = 3000,
})

-- Nested style
client:set_options({
    protocol = { packager = Yar.PACKAGER_MSGPACK },
    transport = { timeout = 3000, keepalive = { pool_size = 128 } },
})
```

> Both styles are equivalent and can be mixed. `set_options` does not mutate the caller's table.

### Client:setopt

syntax: `client:setopt(opt, val)`

Convenience method for setting a single option. Equivalent to `set_options({[opt] = val})`. Chainable.

```lua
client:setopt("timeout", 3000):setopt("packager", Yar.PACKAGER_MSGPACK)
```

### Client:call

syntax: `retval, err = client:call(method, params)`

Initiates an RPC call. On success, returns the method's return value. On failure, returns `nil` and a structured [Error](#error) object.

```lua
local ret, err = client:call("add", {1, 2})
if not ret then
    if err.code == Yar.error.TIMEOUT then
        -- handle timeout
    elseif err.code == Yar.error.NOT_FOUND then
        -- method does not exist
    end
    ngx.log(ngx.ERR, "rpc failed: " .. tostring(err))
end
```

* `method`: Remote method name (string).
* `params`: Parameters array (table). Defaults to `{}`.

Error classification via `err.code`:

| `err.code` | Trigger |
|------------|---------|
| `Error.TRANSPORT` | Connection failure, send failure, HTTP status error |
| `Error.TIMEOUT` | Connect timeout, read/write timeout |
| `Error.PROTOCOL` | Bad packet, packager mismatch, header validation failure |
| `Error.NOT_FOUND` | Method does not exist (server returns "method not found") |
| `Error.EXCEPTION` | Method execution threw an error |

> `tostring(err)` returns the error message (no prefix). Hooks (`on_request`/`on_response`) fire if configured.

### Client Options

| Option | Type | Default | Nested Path | Description |
|--------|------|---------|-------------|-------------|
| `packager` | string | `"JSON"` | `protocol.packager` | Serializer: `JSON` or `Msgpack` (case-insensitive) |
| `timeout` | number | `5000` | `transport.timeout` | Read/write timeout (ms) |
| `connect_timeout` | number | `1000` | `transport.connect_timeout` | Connect timeout (ms) |
| `provider` | string | `""` | `protocol.provider` | Request source, written to header `provider` field (max 32 bytes) |
| `token` | string | `""` | `protocol.token` | Auth token, written to header `token` field (max 32 bytes) |
| `headers` | table | `{}` | `transport.headers` | Custom HTTP headers (HTTP/HTTPS only) |
| `proxy` | string | `""` | `transport.proxy` | HTTP proxy address (e.g. `http://proxy:8080`, port optional, default 8080) |
| `resolve` | string | `""` | `transport.resolve` | Custom DNS: `host:port:ip` (curl) or `host:ip` (PHP) |
| `max_body_len` | number | `nil` | `transport.max_body_len` | Max body length (bytes). `nil` = default 10MB. TCP: send + receive validation |
| `ssl_verify` | boolean | `true` | `transport.ssl_verify` | HTTPS certificate verification. Set `false` for self-signed certs |
| `persistent` | boolean | `false` | `transport.persistent` | Persistent TCP connection, reused across `call()` |
| `keepalive.pool_size` | number | `64` | `transport.keepalive.pool_size` | cosocket connection pool size (OpenResty only) |
| `keepalive.idle_timeout` | number | `60000` | `transport.keepalive.idle_timeout` | cosocket pool idle timeout (ms) |
| `http_provider` | function | `nil` | `transport.http_provider` | Instance-level HTTP provider (overrides class-level) |
| `socket_provider` | table | `nil` | — | Socket provider (e.g. `ngx.socket`), class-level, equivalent to `Client.set_socket()` |
| `hooks` | table | `nil` | — | Hook config `{ on_request, on_response }`, see [Hooks](#hooks) |

### HTTP Provider

When an HTTP provider is injected (class-level or instance-level), the `opts` table passed to the provider function contains:

| Field | Description |
|-------|-------------|
| `method` | HTTP method (default `"POST"`) |
| `body` | Request body (YAR binary message) |
| `headers` | HTTP headers (includes `Content-Type`, `Content-Length`, `User-Agent` + user custom headers) |
| `timeout` | Read/write timeout (ms) |
| `connect_timeout` | Connect timeout (ms) |
| `proxy` | HTTP proxy address |
| `resolve` | Custom DNS resolution |
| `keepalive` | Connection pool config `{ pool_size, idle_timeout }` |
| `ssl_verify` | HTTPS certificate verification (default `true`) |

---

## Server

```lua
local Yar = require("yar")
local Server = Yar.server  -- or require("yar.server")
```

Unified Server Facade. Replaces the previous separate `HttpServer` / `TcpServer` classes. Supports three modes:

1. **Native mode** (`listen` + `loop`): standalone server with luasocket. TCP or HTTP by address scheme.
2. **Host socket mode** (`handle({ socket = ... })`): integrate with any coroutine runtime (copas, lua-eco, Skynet, OpenResty stream). TCP or HTTP by `server.protocol`.
3. **Host callback mode** (`handle({ method, data, writer })`): integrate with OpenResty `content_by_lua` or any HTTP framework. No socket needed.

### Server.new

syntax: `server = Server.new(service, opts)`

Creates a Server instance. Constructor only does initialization — no I/O, no address binding. Aligns with lua-resty-http `http.new()`, PHP Yar `new Yar_Server($service)`.

* `service` (optional): Service object. A table whose `function` fields become RPC methods (fields starting with `_` are private). A single function is registered as the `"default"` method. Internally calls `register_service()`.
* `opts` (optional): Server options table. See [Server Options](#server-options). `socket_provider` is routed to `Socket.set()`, other keys to the internal Dispatcher.

```lua
-- With service only
local server = Server.new({
    add = function(a, b) return a + b end,
    greet = function(name) return "hello, " .. name end,
})

-- With service + options
local server = Server.new(
    { add = function(a, b) return a + b end },
    { packager = Yar.PACKAGER_MSGPACK, max_body_len = 2 * 1024 * 1024 }
)

-- Single function
local server2 = Server.new(function(...) return "ok" end)
```

> The method table is built once at construction time (memoize). Hot path does not iterate `service` per request. Use `register_service()` for batch additions.

### Server:handle

syntax: `ok, err = server:handle(spec)`

Host mode entry point. Strategy determined by `spec` field presence:

* `spec.socket` → **socket mode**: reads from socket, dispatches, writes response. Transport (TCP/HTTP) determined by `server.protocol` (set by `listen()`, or manually for host mode; defaults to `"tcp"`).
* `spec.{method, data, writer}` → **callback mode**: host injects HTTP method + body, library calls `writer(status, headers, body)` to output response. No socket needed.

```lua
-- Socket mode (TCP, host runtime)
server:handle({ socket = client, keepalive = true })

-- Socket mode (HTTP, host runtime — set protocol first)
server.protocol = "http"
server:handle({ socket = wrapped_sock })

-- Callback mode (OpenResty content_by_lua)
server:handle({
    method = ngx.req.get_method(),
    data = ngx.req.get_body_data() or "",
    writer = function(status, headers, body)
        ngx.status = status
        for k, v in pairs(headers) do ngx.header[k] = v end
        ngx.print(body)
    end,
})
```

**Socket mode** `spec` fields:

| Field | Type | Description |
|-------|------|-------------|
| `socket` | table | Accepted client socket (must support `receive`, `send`, `close`) |
| `keepalive` | boolean | (TCP only) Loop multiple YAR messages per connection. Pairs with Client `persistent = true` |

**Callback mode** `spec` fields:

| Field | Type | Description |
|-------|------|-------------|
| `method` | string | HTTP method (`"GET"`, `"POST"`, etc.) |
| `data` | string | Request body (YAR binary message) |
| `writer` | function | `writer(status, headers, body)` — aligns with WSGI `start_response(status, headers)` |

> `writer` parameter order = HTTP wire order = callback execution order: `status` → `headers` → `body`. The `headers` table contains `Content-Type` and `Content-Length` keys.

### Server:listen

syntax: `ok, err = server:listen(addr)`

Native mode entry 1: parse address + bind. I/O operation, returns `true | nil, err` (non-chaining, aligns with `httpc:connect()`).

Supported address formats:

| Format | Protocol | Port |
|--------|----------|------|
| `tcp://host:port` | TCP | Required |
| `http://host:port` | HTTP | Required |
| `http://host` | HTTP | Default 80 (RFC 3986) |
| `unix:///path` | Unix domain socket | — |

```lua
server:listen("tcp://0.0.0.0:9999")
server:listen("http://0.0.0.0:8888")
server:listen("unix:///tmp/yar.sock")
```

> After `listen()`, `server.protocol` / `server.host` / `server.port` (or `server.unix_path`) are set, and `server.listen_sock` is ready for `loop()` or `copas.addserver()`.

### Server:loop

syntax: `server:loop()`

Native mode entry 2: accept loop. Prerequisite: `server.listen_sock` must be set by `listen()`. Loops forever accepting connections and delegating to `handle({ socket = client })`.

> **Warning**: Sequential accept — one connection at a time, blocking. For concurrency, pass `server.listen_sock` to `copas.addserver()` or use OpenResty. Aligns with `copas.loop()`, Go `ListenAndServe()`, Python `serve_forever()`.

```lua
server:listen("tcp://0.0.0.0:9999")
server:loop()
```

### Server:register_service

syntax: `server = server:register_service(service)`

Registers a service object (batch registration). Auto-collects public methods (function type, not `_` prefixed). Chainable. Aligns with PHP Yar `new Yar_Server($service)`, Go `rpc.Register(recv)`.

```lua
server:register_service({
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
})
```

### Server:register

syntax: `server = server:register(name, func)`

Registers a single method. Validates `name` (alphanumeric + underscore, not `_` prefixed) and `func` (must be function). Chainable. Aligns with yar-c `yar_server_register_handler`, Python `SimpleXMLRPCServer.register_function`.

> Programming errors (invalid name/func type) raise `error(msg, 2)` — fail-fast, not returnable. Use `register_service` for batch registration from a service object.

```lua
server:register("add", function(a, b) return a + b end)
```

### Server:set_packager

syntax: `server = server:set_packager(name)`

Sets the response encoding format. `name` is `Yar.PACKAGER_JSON` or `Yar.PACKAGER_MSGPACK`. Chainable.

> Only affects the fallback packager for GET introspection responses. POST responses always use the packager declared in the request header.

### Server:set_options

syntax: `server = server:set_options(opts)`

Table-driven option setting. `packager` delegates to `set_packager()`, `socket_provider` delegates to `Socket.set()`, other keys are written to `options`. Chainable. See [Server Options](#server-options) for all available keys.

```lua
server:set_options({ packager = Yar.PACKAGER_MSGPACK, timeout = 3000 })
```

### Server:setopt

syntax: `server = server:setopt(opt, val)`

Convenience for single key-value. Equivalent to `set_options({[opt] = val})`. Chainable.

### Server:list_methods

syntax: `names = server:list_methods()`

Returns an array of registered method names. Used for GET introspection / documentation.

### Server:handle_message

syntax: `response, err = server:handle_message(data)`

Pure protocol function: parses a YAR binary request, dispatches to the registered method, and returns the binary response. No I/O, no yield, reentrant.

This is the Server Facade's delegation to `Dispatcher:handle_message()`. Use it for **non-HTTP transports** where you need direct protocol processing without the HTTP transport layer — e.g. YAR over message queues, WebSocket, or custom binary protocols. For HTTP serving (including OpenResty), prefer [`Server:handle()`](#serverhandle) callback mode which handles HTTP semantics (status codes, Content-Type, GET introspection, error responses).

```lua
-- Non-HTTP example: YAR over Redis pub/sub
local request_data = redis:get("yar:request")
local response, err = server:handle_message(request_data)
if response then
    redis:set("yar:response", response)
else
    log.error("handle_message error: ", err)
end
```

> This is the same function used internally by all transport modes (`Server:handle()`, `Server:listen()` + `Server:loop()`). It is I/O-free, yield-free, and reentrant. For direct Dispatcher access without the Facade, `server.dispatcher:handle_message(data)` is also available.

### Server Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `packager` | string | `"JSON"` | Response encoding format (fallback for GET introspection). Delegates to `set_packager()`. POST responses auto-adapt to request packager |
| `timeout` | number | `5000` | Per-message processing timeout (ms). Used by `loop()` standalone mode |
| `max_body_len` | number | `1048576` (1MB) | Max request body length (bytes). HTTP: Content-Length check → 413. TCP: framing `receive_message` limit. Prevents memory exhaustion from oversized bodies |
| `socket_provider` | table | `nil` | Socket provider (e.g. `ngx.socket`), class-level. Delegates to `Socket.set()`. Can be passed in `Server.new(service, opts)` constructor |
| `hooks` | table | `nil` | Request/response hooks `{ on_request, on_response }`. See [Hooks](#hooks) |

> **Advanced**: For direct protocol processing without transport, see [`Server:handle_message`](#serverhandle_message) above. The underlying `server.dispatcher:handle_message(data)` is also accessible for advanced use cases.

---

## Packager

```lua
local Yar = require("yar")
```

Packager factory and registry. Built-in packagers: `JSON` and `MSGPACK` (both pure Lua, zero dependencies).

> The internal packager module is **not** exported (`Yar.Packager` is removed). All packager operations go through the `Yar` facade: `Yar.register_packager`, `Yar.get_packager`, `Yar.set_options`. This aligns with the Lua ecosystem facade convention (lua-cjson, lua-resty-http) — a single entry point, no deep-importing internal submodules.

### Yar.register_packager

syntax: `adapter = Yar.register_packager(name, lib)`

Registers a packager from a library module. Auto-detects the interface: accepts libraries with `pack`/`unpack` or `encode`/`decode` methods (e.g. `cjson`, `cmsgpack`). Constructs an adapter and registers it to the registry.

```lua
local cjson = require("cjson.safe")
Yar.register_packager(Yar.PACKAGER_JSON, {
    encode = cjson.encode,
    decode = cjson.decode,
})

local client = Yar.client.new("http://localhost/api")
client:setopt("packager", Yar.PACKAGER_JSON)
```

* `name`: Packager name (case-insensitive). **Only `Yar.PACKAGER_JSON` / `Yar.PACKAGER_MSGPACK` are allowed** — other names raise `error(msg, 2)`. This enforces protocol compatibility: PHP Yar only recognizes `JSON` and `MSGPACK` in the 8-byte packager name field.
* `lib`: Table with `pack`/`unpack` or `encode`/`decode` function fields.
* Returns: adapter table (with `name`, `pack`, `unpack`).

> **Protocol compatibility**: the YAR protocol header carries an 8-byte packager name field. PHP Yar only recognizes `JSON` and `MSGPACK` (right-padded with `\0`). When registering a C extension (e.g. `cjson`) as a replacement for the built-in pure-Lua implementation, always use `Yar.PACKAGER_JSON` / `Yar.PACKAGER_MSGPACK` as the name — never a custom name like `"CJSON"`, which would break interoperability with PHP Yar.

Validation failures raise `error(msg, 2)` (programming error, fail-fast per [ADR #33](design/cross-cutting.md#33)). Callers need not wrap in `pcall`:
* `name` must be a non-empty string.
* `lib` must be a table.
* `lib` must have function-typed `pack`/`unpack` or `encode`/`decode`.

### Yar.get_packager

syntax: `packager, err = Yar.get_packager(name)`

Returns the packager module by name (case-insensitive). Defaults to JSON if `name` is `nil`.

```lua
local jp = Yar.get_packager(Yar.PACKAGER_JSON)
local mp = Yar.get_packager("msgpack")  -- case-insensitive
```

### Yar.set_options

syntax: `Yar.set_options(opts)`

Sets process-wide global options. Currently supports the `packager` sub-level for configuring the built-in pure-Lua JSON / Msgpack decode depth limits.

```lua
Yar.set_options({
    packager = {
        json_max_depth    = 100,  -- tighten JSON decode nesting to 100 levels
        msgpack_max_depth = 100,  -- tighten Msgpack decode nesting to 100 levels
    },
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `packager.json_max_depth` | number | `512` | JSON decode max nesting depth. Prevents stack overflow from malicious deep JSON. Aligned with PHP `json_decode` default. Over limit → `return nil, nil, errmsg` (dkjson-style), propagated as protocol error → error response |
| `packager.msgpack_max_depth` | number | `512` | Msgpack decode max nesting depth. Prevents stack overflow from malicious deep msgpack. Aligned with JSON. Over limit → `return nil, errmsg`, propagated as protocol error → error response |

> Only affects `decode`/`unpack` (untrusted input). `encode`/`pack` is not limited (data comes from your own code).
>
> **Process-wide global**: not instance-scoped. Affects all decode calls across all Client/Server instances. In OpenResty, each worker process is independent.
>
> These options only apply to the built-in pure-Lua packagers. If you register `cjson` via `Yar.register_packager`, configure its depth limit via `cjson`'s own API (`cjson.encode_max_depth()` / `cjson.decode_max_depth()`).

---

## Error

```lua
local Error = Yar.error  -- or require("yar.error")
```

Structured error object with `.code` field for programmatic matching. Replaces string-prefix conventions.

### Error.new

syntax: `err = Error.new(code, message)`

Creates an Error object.

* `code`: Error code string (see [Error Codes](#error-codes)). If not a string, defaults to `Error.EXCEPTION`.
* `message`: Error message string. Defaults to `""`.

```lua
local err = Error.new(Error.PROTOCOL, "bad packet")
print(err.code)    -- "PROTOCOL"
print(err.message) -- "bad packet"
print(tostring(err)) -- "bad packet"
```

### Error Codes

| Constant | Value | Description |
|----------|-------|-------------|
| `Error.TRANSPORT` | `"TRANSPORT"` | Transport layer (connection, send, HTTP status) |
| `Error.TIMEOUT` | `"TIMEOUT"` | Timeout (connect, read, write) |
| `Error.PROTOCOL` | `"PROTOCOL"` | Protocol parsing (bad packet, packager mismatch) |
| `Error.NOT_FOUND` | `"NOT_FOUND"` | Method not found |
| `Error.EXCEPTION` | `"EXCEPTION"` | Method execution exception |

> `tostring(err)` returns `err.message` (no prefix). Error objects share a metatable for efficiency.

---

## Log

```lua
local Log = Yar.log  -- or require("yar.log")
```

Unified logging with level filtering and injectable writer. Default writer is `print()`, usable in any environment.

### Log.set_level

syntax: `Log.set_level(lvl)`

Sets the minimum log level. Messages below this level are silently dropped.

```lua
Log.set_level(Log.DEBUG)  -- show all
Log.set_level(Log.ERROR)  -- only errors
```

> **Process-wide global**: affects all Client/Server instances. In OpenResty, each worker process is independent (no shared memory between workers).

| Constant | Value | Level |
|----------|-------|-------|
| `Log.DEBUG` | `1` | Debug |
| `Log.INFO` | `2` | Info |
| `Log.WARN` | `3` | Warn (default) |
| `Log.ERROR` | `4` | Error |

### Log.set_writer

syntax: `Log.set_writer(fn)`

Injects a custom writer function. `fn` signature: `function(level, message)`. Pass `nil` to reset to default.

```lua
-- OpenResty
local ngx = ngx
local NGX_LEVELS = { [1]=ngx.DEBUG, [2]=ngx.INFO, [3]=ngx.WARN, [4]=ngx.ERR }
Log.set_writer(function(lvl, msg)
    ngx.log(NGX_LEVELS[lvl] or ngx.ERR, msg)
end)
```

> Default writer outputs `[LEVEL] message` via `print()`. When DEBUG is disabled (default), the log function does a single integer comparison and returns — zero overhead.

### Log.debug / info / warn / error

syntax: `Log.debug(msg)` / `Log.info(msg)` / `Log.warn(msg)` / `Log.error(msg)`

Logs a message at the respective level. No-op if below `current_level`.

---

## Hooks

Lightweight request/response interception via `set_options({ hooks = { ... } })`. Available on both Client and Server.

```lua
hooks = {
    on_request  = function(method, params) end,
    on_response = function(method, retval, err) end,
}
```

| Parameter | Description |
|-----------|-------------|
| `method` | RPC method name (string) |
| `params` | Parameters array (table), `on_request` only |
| `retval` | Return value (on success), `on_response` only |
| `err` | Error object (on failure), `on_response` only; `retval` and `err` are mutually exclusive |

Callback timing:

| Callback | Location | Timing |
|----------|----------|--------|
| Client `on_request` | `call()` after render, before send | Request constructed |
| Client `on_response` | `call()` after parse, before return | Response parsed |
| Server `on_request` | `handle_message()` after parse, before dispatch | Request parsed |
| Server `on_response` | `handle_message()` after dispatch, before render | Method executed |

> Hooks run under `pcall` protection. Hook errors degrade to `Log.warn` and do not affect the main flow. When no hooks are configured, nil check skips — zero overhead. Hooks are read-only callbacks (no request/response object passed); they do not intercept data flow.

→ 完整示例：[`example/hooks.lua`](../example/hooks.lua)（客户端 + 服务端 hooks，含耗时统计）

---

## Production Deployment

This section covers performance-critical configurations for production deployments.

### Persistent Connections (3.9x throughput)

Benchmark shows new-connection vs keepalive = 3.9x throughput difference. The default `persistent = false` creates a new connection per `call()`. For production, enable persistent mode or configure the keepalive connection pool.

**Persistent mode** (TCP only): caches the socket across `call()` invocations. The transport holds the connection; `Client:close()` releases it.

```lua
local client = Yar.client.new("tcp://127.0.0.1:9999")
client:set_options({ transport = { persistent = true } })

-- Multiple calls reuse the same TCP connection
client:call("add", {1, 2})
client:call("add", {3, 4})

-- The persistent connection is held by the Client instance.
-- When the Client is garbage-collected, the transport and its
-- cached socket are also collected (cosocket has __gc metamethod).
```

**Keepalive pool** (cosocket/OpenResty): returns the socket to the cosocket connection pool after each `call()`. The pool reuses connections automatically.

```lua
Yar.client.set_socket(ngx.socket)  -- inject cosocket
local client = Yar.client.new("http://127.0.0.1:8888/api")
client:set_options({
    keepalive = { pool_size = 64, idle_timeout = 60000 }
})
```

> Persistent mode and keepalive pool are mutually exclusive strategies. Persistent caches the socket in the Client instance; keepalive returns it to the cosocket pool. For OpenResty, keepalive pool is recommended (integrates with cosocket pool management). For standard Lua + luasocket, persistent mode is the only option (luasocket has no pool).

### C Extension Injection

The built-in pure-Lua JSON/Msgpack are correct but slower than C extensions at the raw codec level. Inject `cjson`/`cmsgpack` for codec-level speedup:

```lua
local cjson = require("cjson.safe")
Yar.register_packager(Yar.PACKAGER_JSON, {
    encode = cjson.encode,
    decode = cjson.decode,
})

local client = Yar.client.new("http://127.0.0.1:8888/api")
client:setopt("packager", Yar.PACKAGER_JSON)
```

> On LuaJIT/OpenResty, the pure-Lua implementations are already fast (JIT-compiled). C extensions provide 6-10x speedup at the raw codec level on standard Lua, but only ~1.0x in the full pipeline — protocol overhead (header/framing/dispatch) dominates. See [performance-benchmark.md](reports/performance-benchmark.md) for the full matrix. `Yar.register_packager` auto-detects `pack`/`unpack` or `encode`/`decode` interfaces — works with cjson, cmsgpack, and any compatible library.
>
> **Protocol compatibility**: always register C extensions under `Yar.PACKAGER_JSON` / `Yar.PACKAGER_MSGPACK` (not custom names like `"CJSON"`), so the protocol header carries the standard `JSON` / `MSGPACK` name and remains interoperable with PHP Yar.

→ 完整示例：[`example/register_cext.lua`](../example/register_cext.lua)（cjson/cmsgpack 探测 + 注入 + 往返验证）

### Recommended Configurations

| Scenario | persistent | keepalive | packager | Notes |
|----------|-----------|-----------|----------|-------|
| Standard Lua production | `true` | — | cjson/cmsgpack | TCP only; no cosocket pool |
| LuaJIT/OpenResty | `true` | pool=64, idle=60s | pure Lua sufficient | cosocket pool recommended |
| Short-lived low-frequency | `false` | — | any | Connection overhead negligible |

### OpenResty Multi-Worker ID Generation

The default `gen_id` does not call `math.randomseed` (does not pollute host global random state). For OpenResty multi-worker deployments, inject a worker-distinct generator:

```lua
Yar.set_id_generator(function()
    return (ngx.time() * 1000003 + ngx.worker.pid() * 65537 + math.random(0, 0xFFFF)) % 4294967296
end)
```

> Seed once per worker in `init_by_lua` via `Yar.seed(fn)` for additional entropy. See [Yar.set_id_generator](#requestset_id_generator) and [Yar.seed](#requestseed).

---

## Internal Modules

> These modules are internal implementation details. They are documented for contributors and advanced users who need to extend the framework. Application code should use the public API above.

### Protocol

```lua
local Protocol = require("yar.protocol.protocol")
```

#### Protocol.render

syntax: `msg = Protocol.render(message, packager)`

Renders a Request or Response object into a YAR binary message (packager name + header + body).

#### Protocol.parse

syntax: `payload, header, err = Protocol.parse(data, packager)`

Parses a YAR binary message. Returns the decoded body table, the protocol header, and an optional error string.

* `payload`: Decoded body (`{i, m, p}` for requests, `{i, s, r, o, e}` for responses).
* `header`: [Header](#header) object.
* `err`: Error message (`"packet too short"`, `"body length mismatch"`, etc.).

### Header

```lua
local Header = require("yar.protocol.header")
```

82-byte protocol header (big-endian / network byte order).

| Constant | Value | Description |
|----------|-------|-------------|
| `Header.SIZE` | `82` | Header size in bytes |
| `Header.MAGIC_NUM` | `0x80DFEC60` | Magic number |
| `Header.VERSION` | `1` | Protocol version |

#### Header.new

syntax: `h = Header.new(t)`

Constructs a header from table `t`. Fields: `id`, `version`, `magic_num`, `reserved`, `provider`, `token`, `body_len`. Missing fields get defaults.

#### Header:pack

syntax: `s = Header:pack()`

Packs to 82-byte binary string (big-endian).

#### Header.unpack

syntax: `h, err = Header.unpack(data, offset)`

Unpacks from binary string at `offset` (default 1). Validates magic number. Returns `nil, err` on failure.

### Framing

```lua
local Framing = require("yar.protocol.framing")
```

YAR message framing for TCP transport. Shared by client and server TCP modules.

| Constant | Value | Description |
|----------|-------|-------------|
| `Framing.HEADER_TOTAL` | `90` | packager(8) + header(82) |
| `Framing.HEADER_OFFSET` | `9` | Header starts at byte 9 |
| `Framing.DEFAULT_MAX_BODY_LEN` | `10485760` | 10MB max body |

#### Framing.receive_exact

syntax: `data, err = Framing.receive_exact(sock, n)`

Reads exactly `n` bytes from socket. Loops until complete (TCP may return partial).

#### Framing.receive_message

syntax: `data, err = Framing.receive_message(sock, max_body_len)`

Receives a complete YAR message (packager + header + body). Reads 90-byte header first, validates body length, then reads body. `max_body_len` defaults to `DEFAULT_MAX_BODY_LEN`.

#### Framing.check_body_len

syntax: `ok, err = Framing.check_body_len(data, max_body_len)`

Validates body length of a rendered message against `max_body_len`. Defensive check before sending. Returns `true` if within limit, `nil, "body too large: ..."` if exceeded. Short data (< 90 bytes) passes.

### Request

```lua
local Request = require("yar.message.request")
```

#### Request.set_id_generator

syntax: `Request.set_id_generator(fn)`

Injects a custom transaction ID generator (process-wide). After injection, the library no longer calls the default implementation, fully isolating the host's `math.randomseed` state. Pass `nil` to restore the default.

> The default implementation does **not** call `math.randomseed`, to avoid polluting the host process's global random state. For OpenResty multi-worker deployments, inject a generator based on `ngx.worker.pid()` + `ngx.time()` so workers are naturally distinguished. See [design-rationale §6](design-rationale.md) for the rationale.

```lua
local Request = require("yar.message.request")

-- OpenResty: per-worker distinct IDs
Request.set_id_generator(function()
    return (ngx.time() * 1000003 + ngx.worker.pid() * 65537 + math.random(0, 0xFFFF)) % 4294967296
end)
```

#### Request.seed

syntax: `Request.seed(fn)`

Global seed function (process-wide, convenience API). The business layer provides `fn`, the library calls `fn()` to perform seeding. This is a thin wrapper — equivalent to calling `fn()` directly. The library never auto-seeds; this function only runs when explicitly called.

> In OpenResty, `math.randomseed` is process-level (per-worker VM). Seeding in `init_by_lua` once makes it effective for all coroutines in that worker (coroutines share the same Lua VM's global random state). Each worker is a separate VM and needs its own seed.

```lua
local Yar = require("yar")

-- init_by_lua phase (OpenResty)
Yar.seed(function()
    math.randomseed(ngx.time() + ngx.worker.pid())
end)
```

> The default `gen_id` works without seeding (intentional design — see [design-rationale §6](design-rationale.md)). Seeding is optional, recommended for production to further reduce the already-low conflict probability.

#### Request.gen_id

syntax: `id = Request.gen_id()`

Generates a transaction ID (uint32 range). The default implementation does **not** call `math.randomseed`; it mixes `os.time`, an in-process monotonic counter, a table-address entropy source, and the host's current `math.random` state via pure math (Lua 5.1 compatible, no bitwise ops). Override with [Request.set_id_generator](#requestset_id_generator) for environment-specific entropy (e.g. OpenResty `ngx.worker.pid`).

#### Request.new

syntax: `req = Request.new(t)`

Constructs a Request from table `t`. Fields: `method`, `params`, `provider`, `token`, `id` (auto-generated if missing).

#### Request:pack_body

syntax: `t = Request:pack_body()`

Returns the body table `{i=id, m=method, p=params}` for packager encoding.

### Response

```lua
local Response = require("yar.message.response")
```

| Constant | Value | Description |
|----------|-------|-------------|
| `Response.STATUS_OK` | `0` | Success |
| `Response.STATUS_ERROR` | `1` | Error |

#### Response.new

syntax: `resp = Response.new(t)`

Constructs a Response from table `t`. Fields: `id`, `status`, `retval`, `output`, `err`, `provider`, `token`.

#### Response:set_retval

syntax: `resp = Response:set_retval(val)`

Sets success return value. Sets `status = STATUS_OK`. Chainable.

#### Response:set_error

syntax: `resp = Response:set_error(err)`

Sets error state. Sets `status = STATUS_ERROR`. Chainable.

#### Response:pack_body

syntax: `t = Response:pack_body()`

Returns body table `{i=id, s=status, r=retval, o=output, e=err}`.

#### Response.unpack

syntax: `resp = Response.unpack(t)`

Constructs a Response from a decoded body table `{i, s, r, o, e}`.

### Transport

```lua
local Transport = require("yar.transport.transport")
```

Transport factory: selects HTTP or TCP by URL scheme.

#### Transport.get

syntax: `transport = Transport.get(url)`

Returns `Http` for `http://`/`https://`, `Tcp` for `tcp://`/`unix://`.

#### Transport.set_socket

syntax: `Transport.set_socket(mod)`

Sets the socket provider (delegates to `Socket.set()`).

#### Transport.set_http_provider

syntax: `Transport.set_http_provider(provider)`

Sets the HTTP provider (delegates to `Http.set_provider()`).

### Socket

```lua
local Socket = require("yar.transport.socket")
```

Socket abstraction layer. The framework's only network dependency. Defaults to luasocket (soft dependency, lazy-loaded via `pcall`).

| Function | Description |
|----------|-------------|
| `Socket.set(mod)` | Inject socket provider (e.g. `ngx.socket`) |
| `Socket.tcp()` | Create TCP socket |
| `Socket.unix()` | Create Unix domain socket |
| `Socket.bind(host, port)` | Create listening socket (server-side) |
| `Socket.bind_unix(path)` | Create Unix domain socket listening socket (server-side) |
| `Socket.set_timeouts(sock, connect_t, send_t, read_t)` | Set timeouts (cosocket: 3-segment, luasocket: single) |
| `Socket.release(sock, ...)` | Release connection (cosocket: pool, luasocket: close) |
| `Socket.poolable(sock)` | Returns `true` if socket supports connection pooling (cosocket) |

> luasocket sockets are wrapped to provide millisecond timeouts (luasocket uses seconds) and cosocket-compatible method names.

### Resolve

```lua
local Resolve = require("yar.transport.resolve")
```

#### Resolve.apply_resolve

syntax: `ip = Resolve.apply_resolve(host, port, resolve_str)`

Custom DNS resolution. Supports curl-style `host:port:ip` and PHP-style `host:ip`. Returns the custom IP if matched, otherwise the original host.

### Util

```lua
local Util = require("yar.util")
```

Binary utilities. All operations use pure math (no `string.pack`), compatible with Lua 5.1 / LuaJIT / 5.3+.

| Function | Description |
|----------|-------------|
| `Util.pack_u16(n)` | Pack uint16 big-endian (2 bytes) |
| `Util.pack_u32(n)` | Pack uint32 big-endian (4 bytes) |
| `Util.unpack_u16(s, offset)` | Unpack uint16 big-endian |
| `Util.unpack_u32(s, offset)` | Unpack uint32 big-endian |
| `Util.pad_field(s, size)` | Right-pad with `\0` to `size`, truncate if longer |
| `Util.trim_null(s)` | Strip trailing `\0` bytes |
