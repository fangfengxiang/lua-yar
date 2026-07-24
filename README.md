# Lua-Yar — Yar Lua Framework

[English](README.md) | [简体中文](README.zh.md) | [Documentation](https://fangfengxiang.github.io/lua-yar)

[![Lua](https://img.shields.io/badge/Lua-%3E%3D5.1-blue.svg)](https://www.lua.org/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![LuaRocks](https://img.shields.io/luarocks/v/fangfengxiang/lua-yar)](https://luarocks.org/modules/fangfengxiang/lua-yar)
[![OPM](https://img.shields.io/badge/OPM-lua--yar-blue.svg)](https://opm.openresty.org/package/fangfengxiang/lua-yar/)
[![Test](https://github.com/fangfengxiang/lua-yar/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-yar/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/fangfengxiang/lua-yar/branch/main/graph/badge.svg)](https://codecov.io/gh/fangfengxiang/lua-yar)
[![Release](https://github.com/fangfengxiang/lua-yar/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/fangfengxiang/lua-yar/actions/workflows/release.yml)

> **Lightweight, concurrent Lua RPC framework.**
> A zero-dependency, coroutine-friendly, multi-host compatible lightweight RPC framework — pure Lua implementation of the Yar RPC protocol. See [Protocol Specification](docs/protocol.md).

[Yar](https://github.com/laruence/yar) (Yet Another RPC Framework) is a popular lightweight concurrent RPC framework in the PHP ecosystem, enabling cross-language interoperability via binary data streams. Related implementations: [Yar-C](https://github.com/laruence/yar-c), [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar).

Compared to HTTP+JSON, Yar's binary protocol stream eliminates text encoding/decoding overhead; compared to gRPC/Thrift, it requires no IDL compilation or heavy runtime — ideal for lightweight RPC needs in Lua embedded scenarios.

---

## Features

- **Light & Efficient**: Zero-dependency, binary protocol, embeddable, easy to use
- **Multi-transport**: TCP / HTTP / Unix Socket
- **Protocol Compatible**: Strictly adheres to the YAR binary protocol, interoperable with PHP / C / Lua Yar services
- **Cross-environment**: Standard Lua + luasocket out of the box; runs on OpenResty / Skynet / lua-eco / copas and other host environments (see [Server Implementation Examples](docs/server-implementations.md))
- **Coroutine-friendly**: Pure functions with no I/O and no yield, callable directly from any coroutine
- **Zero-dependency & Extensible**: Built-in pure Lua JSON / Msgpack codecs (no cjson / cmsgpack dependency); supports registering custom packagers, injecting HTTP providers, and Hooks interception

## Requirements

- **Lua** 5.1 / 5.3 / LuaJIT 2.1 / OpenResty 1.7+
- **Network layer**: choose by host environment
  - Standard Lua requires luasocket (`luarocks install luasocket`)
  - OpenResty has built-in `ngx.socket`, no extra dependency needed

## Installation

### LuaRocks (Quick Trial)

```bash
# Soft dependency: standard Lua requires luasocket (OpenResty does not)
# If not installed, run first: luarocks install luasocket
luarocks install lua-yar
```

### OPM (OpenResty) (Production Recommended)

```bash
opm install lua-yar
```

### Source (Not Recommended)

Add `src/yar/` to `package.path`, no compilation needed:

```lua
package.path = package.path .. ";/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua"
local Yar = require("yar")
```

## Quick Start

> New to Yar? Read the [Tutorial](docs/tutorial.md) to understand the YAR protocol from scratch and build your first RPC service.

### Client

```lua
local Yar = require("yar")

local client = Yar.client.new("http://127.0.0.1:8888/api")
print(client:call("add", {1, 2}))              -- => 3
```

### Server (Native Lua)

```lua
local Yar = require("yar")

local server = Yar.server.new({
    add = function(a, b) return a + b end,
})

server:listen("http://0.0.0.0:8888")
server:loop()
```

### Server (OpenResty)

```nginx
http {
    lua_package_path "/path/to/lua-yar/src/?.lua;/path/to/lua-yar/src/?/init.lua;;";

    server {
        listen 8888;
        location /api {
            content_by_lua_block {
                local Yar = require "yar"
                -- OpenResty uses content_by_lua callback mode: no socket, no HttpServer transport layer
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

> **On Concurrency**: Lua is typically embedded to collaborate with other systems, and native concurrency solutions are limited. lua-yar delegates concurrency to the host environment. See [Server Implementation Examples](docs/server-implementations.md) for details. For production, [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar) (OpenResty binding, ready out of the box) is recommended.

### Options Example

#### Client

```lua
local client = Yar.client.new("http://127.0.0.1:8888/api")
client:set_options({
    packager        = Yar.PACKAGER_MSGPACK,   -- Serialization format: JSON (default) or MSGPACK
    timeout         = 3000,                    -- Read/write timeout (ms)
    connect_timeout = 2000,                    -- Connect timeout (ms)
    provider        = "my-app",                -- Request source identifier (written to protocol header, max 32 bytes)
    token           = "secret-token",          -- Auth token (written to protocol header, max 32 bytes)
    headers         = { ["X-Trace"] = "abc" }, -- Custom HTTP headers (HTTP/HTTPS only)
    proxy           = "http://proxy:8080",     -- HTTP proxy address
    resolve         = "host:ip",              -- Custom DNS (curl-style host:port:ip or PHP-style host:ip)
    ssl_verify      = true,                   -- HTTPS certificate verification (default true)
    persistent      = false,                  -- Persistent TCP connection (reused across calls)
    keepalive       = {                       -- cosocket connection pool (OpenResty)
        pool_size    = 64,                     --   pool size
        idle_timeout = 60000,                 --   idle timeout (ms)
    },
    hooks = {                                 -- Request/response interception (pcall-protected, zero overhead)
        on_request  = function(method, params) end,
        on_response = function(method, retval, err) end,
    },
})

local ret, err = client:call("add", {1, 2})
if not ret then
    -- err is a Yar.error object; match error type precisely via err.code
    if err.code == Yar.error.TIMEOUT then
        -- timeout handling
    end
end
```

#### Server

```lua
-- Process-level packager options (JSON/Msgpack decode depth limits, only effective for built-in pure Lua implementations)
Yar.set_options({
    packager = {
        json_max_depth    = 512,   -- Max JSON nesting depth
        msgpack_max_depth = 512,   -- Max Msgpack nesting depth
    },
})

-- To accelerate decoding with C extensions, register to replace the built-in pure Lua implementations:
Yar.register_packager(Yar.PACKAGER_JSON, require("cjson"))
-- Yar.register_packager(Yar.PACKAGER_MSGPACK, require("cmsgpack"))

local server = Yar.server.new({
    add   = function(a, b) return a + b end,
    greet = function(name) return "hello, " .. name end,
})

server:set_options({
    packager     = Yar.PACKAGER_JSON,    -- GET introspection response encoding (POST response determined by client request header)
    timeout      = 5000,                 -- Per-message timeout (standalone run mode)
    max_body_len = 1048576,              -- Max request body length (bytes)
    hooks = {                            -- Request/response interception
        on_request  = function(method, params) end,
        on_response = function(method, retval, err) end,
    },
})
```

→ Full options: [API Reference](docs/api.md)

## Deployment Guide

lua-yar is a pure protocol library and does not provide concurrency scheduling itself; concurrency relies on the host environment.

| Environment | Concurrency Approach | Example |
|-------------|----------------------|---------|
| OpenResty | cosocket + `content_by_lua` | [`server_openresty.lua`](example/server_openresty.lua) |
| lua-eco | coroutine scheduling | [`server_luaeco.lua`](example/server_luaeco.lua) |
| Skynet | Skynet scheduler | [`server_skynet.lua`](example/server_skynet.lua) |
| copas | copas coroutine | [`server_copas.lua`](example/server_copas.lua) |
| Native coroutine | `coroutine` + `socket.select` | [`server_coroutine.lua`](example/server_coroutine.lua) |

> For production, [lua-resty-yar](https://github.com/fangfengxiang/lua-resty-yar) (OpenResty binding, ready out of the box) is recommended.

## Testing

| Type | Command | Description |
|------|---------|-------------|
| **BDD Unit/Integration** | `busted --coverage` | 126 test cases, full module coverage (Lua 5.1 / LuaJIT / 5.3 matrix) |
| **OpenResty E2E** | `resty test/openresty_e2e_test.lua` | cosocket TCP round-trip, connection pool, concurrency safety, fault injection |
| **OpenResty HTTP E2E** | `bash test/openresty_http_e2e.sh` | nginx `content_by_lua` full pipeline |
| **Interoperability** | `bash test/interop.sh` | Lua ↔ PHP Yar bidirectional end-to-end (JSON + Msgpack) |
| **Concurrent** | `bash test/concurrent_e2e.sh` | PHP → Lua concurrent (3 native sequential + 50 OpenResty 2-worker), HTTP + TCP, requestId integrity + coroutine log verification |
| **Benchmark** | `lua test/benchmark.lua` | Codec / protocol / cosocket I/O benchmarks |

CI matrix: 4 jobs (`test` multi-version Lua / `no-luasocket` soft-dependency degradation / `openresty` E2E / `interop` PHP interop).

→ Full test system (type breakdown, coverage dimensions, CI matrix, gap planning): [Test Coverage Report](docs/reports/test-coverage.md)

## Module Overview

| Module | Description |
|--------|-------------|
| **Client** | yar-client, HTTP / HTTPS / TCP / Unix transport, table-driven options, structured Error |
| **Server** | Unified Server Facade: TCP/HTTP/host mode, `Server.new(service, opts)` + `handle(spec)` / `listen(addr)` + `loop()` |
| **Packager** | Built-in JSON / Msgpack (pure Lua), configurable via `Yar.set_options` and `Yar.register_packager` |
| **Error** | Structured error object, 5-level error codes (TRANSPORT / TIMEOUT / PROTOCOL / NOT_FOUND / EXCEPTION) |
| **Log** | 4-level logging, injectable writer |
| **Hooks** | Lightweight request/response interception mechanism |

→ Full API details: [API Reference](docs/api.md)

## Directory Structure

```
lua-yar/
├── README.md                    # English README (primary)
├── README.zh.md                 # Chinese README
├── LICENSE
├── CHANGELOG.md                 # Changelog (Keep a Changelog format)
├── lua-yar-scm-1.rockspec       # Dev rockspec (luarocks make)
├── lua-yar-0.1.0-1.rockspec     # Release rockspec (luarocks install)
├── dist.ini                     # OPM packaging config (opm build)
├── docs/
│   ├── api.md                   # API reference (full method signatures + examples)
│   ├── protocol.md              # YAR protocol spec (byte-level layout + packet examples)
│   ├── design-rationale.md      # Design rationale
│   ├── design/                  # Design decision records (ADR)
│   └── reports/                 # Review reports
│       ├── architecture-review.md
│       ├── comprehensive-review.md
│       ├── performance-benchmark.md
│       └── test-coverage.md
├── src/
│   └── yar/
│       ├── init.lua             # Main entry (Client, Server, register_packager, get_packager, set_options, Error, VERSION, PACKAGER_*)
│       ├── util.lua             # Byte-order utilities
│       ├── error.lua            # Structured error object (Error.new + code constants)
│       ├── client.lua           # yar-client
│       ├── server/
│       │   ├── init.lua         # Server Facade (unified entry: new/handle/listen/loop)
│       │   ├── constants.lua    # Server constants (max_body_len, max_headers, etc.)
│       │   ├── dispatcher.lua   # Protocol dispatcher (handle_message, register_service)
│       │   ├── daemon.lua       # Accept loop (Daemon.run, sequential)
│       │   ├── http.lua         # HTTP transport (socket mode + callback mode)
│       │   └── tcp.lua          # TCP transport (socket mode)
│       ├── protocol/
│       │   ├── header.lua       # 82-byte protocol header
│       │   ├── protocol.lua     # Message render/parse
│       │   └── framing.lua      # YAR frame unpacking (for TCP transport)
│       ├── message/
│       │   ├── request.lua      # Request {i,m,p}
│       │   └── response.lua     # Response {i,s,r,o,e}
│       ├── packager/
│       │   ├── packager.lua     # Packager factory
│       │   ├── json.lua         # Pure Lua JSON
│       │   └── msgpack.lua      # Pure Lua MessagePack
│       └── transport/
│           ├── transport.lua    # Transport factory / socket provider management
│           ├── constants.lua    # HTTP constants (status, content-type, methods) — leaf module
│           ├── socket.lua       # Socket provider (luasocket adapter / inject cosocket / bind)
│           ├── resolve.lua      # DNS resolution utility (curl/PHP-style host→IP mapping)
│           ├── http.lua         # HTTP transport
│           └── tcp.lua          # TCP transport
├── example/
│   ├── client.lua
│   ├── server_http.lua
│   ├── server_tcp.lua
│   ├── server_copas.lua         # copas coroutine concurrency example
│   ├── server_coroutine.lua     # native coroutine concurrency example (no copas dependency)
│   ├── server_luaeco.lua        # lua-eco coroutine concurrency example
│   ├── server_skynet.lua        # Skynet high-concurrency example
│   ├── server_openresty.lua     # OpenResty stream cosocket example
│   ├── resty_http_provider.lua  # lua-resty-http adapter example
│   ├── hooks.lua                # hook usage example (log observation + timing stats)
│   └── resty_yar_*.lua          # OpenResty OPM package examples
├── spec/                        # BDD unit/integration tests (126 cases, see docs/reports/test-coverage.md)
└── test/                        # E2E / interoperability / performance benchmarks
```

## YAR Protocol

Yar exchanges RPC messages via binary data streams. A complete message consists of three parts:

```
+-------------------+-------------------+---------------------+
| Packager Name     | Yar Header        | Body                |
| 8 bytes           | 82 bytes          | body_len bytes      |
+-------------------+-------------------+---------------------+
```

- **Request body**: `{i, m, p}` — transaction ID / method name / parameter array
- **Response body**: `{i, s, r, o, e}` — transaction ID / status / return value / output / error
- Multi-byte integers use network byte order (big-endian)

→ Full protocol spec (field details, byte-level layout, packet examples, cross-language interop): [Protocol Specification](docs/protocol.md)

## Appendix

- [Tutorial](docs/tutorial.md) (30-minute guide to building an RPC service from scratch, learn by doing)
- [How-to Guide](docs/how-to.md) (Find solutions by task: performance optimization, deployment, debugging, extension, protocol interop)
- [Development Guide](CONTRIBUTING.md) (LuaLS type annotation conventions, code style guide, project structure)
- [Design Rationale](docs/design-rationale.md) (network layer selection, comparison with yar-c, options comparison)
- [Benchmark Report](docs/reports/performance-benchmark.md)
- [Changelog](CHANGELOG.md)

## License

[Apache License 2.0](LICENSE)
