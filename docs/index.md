# lua-yar

> **Lightweight, concurrent Lua RPC framework.**
> A zero-dependency, coroutine-friendly, multi-host compatible lightweight RPC framework — pure Lua implementation of the Yar RPC protocol.

[Yar](https://github.com/laruence/yar) (Yet Another RPC Framework) is a popular lightweight concurrent RPC framework in the PHP ecosystem, enabling cross-language interoperability via binary data streams.

Compared to HTTP+JSON, Yar's binary protocol stream eliminates text encoding/decoding overhead; compared to gRPC/Thrift, it requires no IDL compilation or heavy runtime — ideal for lightweight RPC needs in Lua embedded scenarios.

## Features

- **Light & Efficient**: Zero-dependency, binary protocol, embeddable, easy to use
- **Multi-transport**: TCP / HTTP / Unix Socket
- **Protocol Compatible**: Strictly adheres to the YAR binary protocol, interoperable with PHP / C / Lua Yar services
- **Cross-environment**: Standard Lua + luasocket out of the box; runs on OpenResty / Skynet / lua-eco / copas and other host environments
- **Coroutine-friendly**: Pure functions with no I/O and no yield, callable directly from any coroutine
- **Zero-dependency & Extensible**: Built-in pure Lua JSON / Msgpack codecs; supports registering custom packagers, injecting HTTP providers, and Hooks interception

## Quick Start

### Install

```bash
luarocks install lua-yar
```

### Client

```lua
local Yar = require("yar")
local client = Yar.client.new("tcp://127.0.0.1:8888")
local result = client:call("add", {1, 2})  -- returns 3
```

### Server

```lua
local Yar = require("yar")
local server = Yar.server.new({
    add = function(a, b) return a + b end,
})
server:listen("tcp://0.0.0.0:8888")
server:loop()
```

## Documentation

- [Tutorial](tutorial.md) — Step-by-step guide from first client call to production server
- [Protocol Specification](protocol.md) — YAR binary protocol format
- [API Reference](api.md) — Server / Client / Packager / Transport API
- [Server Implementations](server-implementations.md) — OpenResty / copas / lua-eco / Skynet integration
- [How-To Guide](how-to.md) — Custom packager, HTTP provider, hooks, TLS, unix socket
- [Design Decisions](design/decisions.md) — 32 architecture decision records

## Requirements

- **Lua** 5.1 / 5.3 / LuaJIT 2.1 / OpenResty 1.7+
- **Network layer**: luasocket (standard Lua) or `ngx.socket` (OpenResty)
