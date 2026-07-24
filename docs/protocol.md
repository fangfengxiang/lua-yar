# YAR 协议规范

> Yar（Yet Another RPC Framework）二进制协议的完整规范。
> 本文档参考 [PHP Yar](https://github.com/laruence/yar) 与 [yar-c](https://github.com/laruence/yar-c) 实现，描述 lua-yar 所遵循的线上协议格式。

## 目录

- [概述](#概述)
- [消息布局](#消息布局)
- [Packager Name](#packager-name)
- [协议头](#协议头)
  - [字段详解](#字段详解)
  - [字节级布局](#字节级布局)
- [请求体](#请求体)
- [响应体](#响应体)
- [Packager](#packager)
  - [JSON](#json)
  - [Msgpack](#msgpack)
  - [替换内置 Packager](#替换内置-packager)
- [TCP 帧拆解](#tcp-帧拆解)
- [字节序与实现](#字节序与实现)
- [完整报文示例](#完整报文示例)
- [跨语言互通](#跨语言互通)

---

## 概述

Yar 是一个轻量级并发 RPC 框架，所有请求与响应通过**二进制数据流**传输。协议设计简洁高效，一条完整的 YAR 消息由三部分组成：

```
+-------------------+-------------------+---------------------+
| Packager Name     | Yar Header        | Body                |
| 8 字节            | 82 字节           | body_len 字节       |
+-------------------+-------------------+---------------------+
  偏移 0              偏移 8              偏移 90
```

- **Packager Name**（8 字节）：声明 Body 的序列化格式（JSON / Msgpack）。
- **Yar Header**（82 字节）：固定长度的二进制协议头，包含事务 ID、魔数、认证信息等元数据。
- **Body**（变长）：由 packager 编码的请求/响应结构，长度由 Header 中的 `body_len` 字段指定。

最小消息长度 = 8 + 82 = **90 字节**（空 body 时）。实际消息长度 = 90 + `body_len`。

---

## Packager Name

Packager Name 占 8 字节，用于声明 Body 的序列化格式。名称**右补 `\0`** 至 8 字节，超长截断。

| Packager | 线上字节 | 说明 |
|----------|----------|------|
| `JSON` | `4A 53 4F 4E 00 00 00 00` | `JSON\0\0\0\0`，纯 Lua JSON 编解码 |
| `MSGPACK` | `4D 53 47 50 41 43 4B 00` | `MSGPACK\0`，纯 Lua MessagePack 编解码 |

> 名称匹配**大小写不敏感**。服务端按请求头部声明的 packager 自动选择解码器，无需预配置。

---

## 协议头

Yar Header 为 82 字节的 packed 二进制结构，所有多字节整数使用**网络字节序（大端）**。

### 字段详解

| 字段 | 类型 | 长度（字节） | 偏移 | 默认值 | 说明 |
|------|------|------|------|--------|------|
| `id` | uint32 | 4 | 0 | 随机生成 | 事务 ID，请求与响应对应。客户端用多熵源混合（`os.time` + 进程内单调计数器 + 表地址 + `math.random`）生成 uint32 范围 ID，详见 [设计选型 §6](design-rationale.md) |
| `version` | uint16 | 2 | 4 | `1` | 协议版本号，当前固定为 1 |
| `magic_num` | uint32 | 4 | 6 | `0x80DFEC60` | 魔数，用于快速校验是否为 YAR 协议包 |
| `reserved` | uint32 | 4 | 10 | `0` | 保留字段，当前未使用 |
| `provider` | char[32] | 32 | 14 | `""` | 请求来源标识，右补 `\0`。客户端可通过 `setopt("provider", ...)` 设置 |
| `token` | char[32] | 32 | 46 | `""` | 认证令牌，右补 `\0`。客户端可通过 `setopt("token", ...)` 设置 |
| `body_len` | uint32 | 4 | 78 | `0` | 请求/响应体长度（字节），紧跟在 Header 之后 |

**总计**：4 + 2 + 4 + 4 + 32 + 32 + 4 = **82 字节**

### 字节级布局

```
偏移  字段          字节数  类型
────────────────────────────────────
 0    id            4       uint32  (big-endian)
 4    version       2       uint16  (big-endian)
 6    magic_num     4       uint32  (big-endian, 固定 0x80DFEC60)
10    reserved      4       uint32  (big-endian, 通常为 0)
14    provider      32      char[32] (右补 \0)
46    token         32      char[32] (右补 \0)
78    body_len      4       uint32  (big-endian)
────────────────────────────────────
                        82 字节
```

**解析校验**：

1. 读取 82 字节，检查 `magic_num`（偏移 6）是否等于 `0x80DFEC60`，不匹配则拒绝。
2. 读取 `body_len`（偏移 78），确保后续有 `body_len` 字节可用。
3. `provider` 与 `token` 字段解析时去除尾部 `\0`。

> `provider` 和 `token` 最长 32 字节，超出部分截断。这两个字段在响应中通常原样回传（服务端不修改）。

---

## 请求体

请求体（Body）由 packager 编码，逻辑结构为：

```json
{
    "i": 12345,
    "m": "add",
    "p": [1, 2]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `i` | number | 事务 ID，与 Header 中的 `id` 一致 |
| `m` | string | 远程方法名 |
| `p` | array | 参数数组，按位置传参 |

**lua-yar 实现**（`src/yar/message/request.lua`）：

```lua
function _M:pack_body()
    return {
        i = self.id,       -- 事务 ID
        m = self.method,   -- 方法名
        p = self.params,   -- 参数数组
    }
end
```

**事务 ID 生成**：`_M.gen_id()` 生成 uint32 范围 ID。默认实现**不调用 `math.randomseed`**（避免污染宿主进程的全局随机状态），改用纯数学方式混合多熵源：`os.time`（秒级时间）+ 进程内单调递增计数器（保证同进程不重复）+ `tostring({})` 表地址（跨进程区分）+ `math.random`（沿用宿主当前随机状态）。混合用纯数学兼容 Lua 5.1 无位运算，逐步取模避免 double 精度丢失。可通过 `Yar.set_id_generator(fn)` 注入环境特定生成器（OpenResty 多 worker 建议注入基于 `ngx.worker.pid` 的实现）。详见 [设计选型 §6](design-rationale.md)。

---

## 响应体

响应体（Body）由 packager 编码，逻辑结构为：

```json
{
    "i": 12345,
    "s": 0,
    "r": 3,
    "o": "",
    "e": ""
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `i` | number | 事务 ID，与请求的 `i` 一致 |
| `s` | number | 状态码，`0` = 成功，`1` = 错误 |
| `r` | any | 方法返回值（成功时） |
| `o` | string | 标准输出（PHP `echo`/`print` 等捕获的输出，lua-yar 中通常为空） |
| `e` | string | 错误消息（失败时） |

**状态码**：

| 值 | 常量 | 说明 |
|----|------|------|
| `0` | `_M.STATUS_OK` | 成功，返回值在 `r` 字段 |
| `1` | `_M.STATUS_ERROR` | 错误，错误信息在 `e` 字段 |

**lua-yar 实现**（`src/yar/message/response.lua`）：

```lua
function _M:pack_body()
    return {
        i = self.id,       -- 事务 ID
        s = self.status,   -- 状态码 (0=OK, 1=ERROR)
        r = self.retval,   -- 返回值
        o = self.output,   -- 输出
        e = self.err,      -- 错误信息
    }
end
```

> `r` 与 `e` 互斥：成功时 `s=0` 且 `e=""`，失败时 `s=1` 且 `r` 为 nil。客户端通过 `s` 字段判断调用是否成功。

---

## Packager

### JSON

默认 packager，纯 Lua 实现（`src/yar/packager/json.lua`），零 C 扩展依赖。

- 编码：Lua table → JSON 字符串 → 字节流
- 解码：字节流 → JSON 字符串 → Lua table
- 支持：string / number / boolean / table（array + object）/ nil
- Unicode 转义：`\uXXXX` 序列解码为 UTF-8 字节串

线上 packager name：`JSON\0\0\0\0`

### Msgpack

MessagePack 二进制序列化，纯 Lua 实现（`src/yar/packager/msgpack.lua`），零 C 扩展依赖。

- 编码：Lua table → MessagePack 二进制
- 解码：MessagePack 二进制 → Lua table
- 支持：nil / boolean / integer / float / string / array / map
- 与 yar-c 默认 packager 兼容

线上 packager name：`MSGPACK\0`

### 替换内置 Packager

`Yar.register_packager(name, lib)` 用于用第三方 C 扩展编解码库（如 `cjson`、`cmsgpack`）替换内置纯 Lua 实现。**只允许注册 `JSON` 和 `MSGPACK` 两种标准名称**——不允许自定义 packager 类型。

```lua
local cjson = require("cjson.safe")
Yar.register_packager(Yar.PACKAGER_JSON, {
    encode = cjson.encode,
    decode = cjson.decode,
})

-- 客户端使用（名称仍是标准 JSON）
local client = Yar.client.new("http://127.0.0.1:8888/")
client:setopt("packager", Yar.PACKAGER_JSON)
```

`register_packager` 自动检测 `encode/decode` 或 `pack/unpack` 接口，构造适配器并注册。

> **只允许标准名称**：YAR 协议头 packager name 字段为 8 字节，PHP Yar 只认 `JSON` 和 `MSGPACK`（右补 `\0`）。`register_packager` 的 `name` 参数只接受 `Yar.PACKAGER_JSON` / `Yar.PACKAGER_MSGPACK`，传入其他名称会 `error(msg, 2)` fail-fast。语义是"替换内置实现"（如 cjson 替换纯 Lua Json），不是新增 packager 类型。

---

## TCP 帧拆解

HTTP 传输中，YAR 消息作为 HTTP POST 请求体整体发送，Content-Length 即消息总长度。TCP 传输中，由于 TCP 是流式协议，需要**帧拆解**（framing）来正确分割消息边界。

### 帧格式

TCP 流中的每条 YAR 消息即一帧，帧的边界由 Header 中的 `body_len` 隐式界定：

```
[packager_name:8][header:82][body:body_len]  →  下一帧...
```

### 接收流程

lua-yar 的 `Framing` 模块（`src/yar/protocol/framing.lua`）实现了标准的 TCP 消息接收流程：

1. **精确读取 90 字节头部**（packager name 8 字节 + header 82 字节）。
   - TCP `receive(n)` 可能返回少于 n 字节，循环拼接直到收满。
2. **解析 Header**：从第 9 字节开始解包 Header，校验 `magic_num`。
3. **校验 body_len**：与 `max_body_len`（默认 10MB）比较，防止恶意大 body 导致内存耗尽。
4. **精确读取 body_len 字节 body**。
5. **拼接完整消息**：`head .. body`，交给协议层解析派发。

### 防御性校验

| 校验点 | 说明 |
|--------|------|
| `magic_num` | 偏移 6 的 4 字节必须等于 `0x80DFEC60`，否则拒绝 |
| `body_len` 上限 | 默认 10MB（`DEFAULT_MAX_BODY_LEN`），可通过 `max_body_len` 选项配置 |
| `body_len` 一致性 | 声明的 `body_len` 与实际可用字节数比较，不匹配则报错 |
| 短包检测 | 头部不足 90 字节或 body 不足 `body_len` 字节均返回错误 |

### 发送前校验

TCP 传输在发送前也通过 `Framing.check_body_len()` 进行防御性校验，确保渲染后的消息 body 长度不超过 `max_body_len` 限制。

---

## 字节序与实现

### 大端序（网络字节序）

YAR 协议所有多字节整数使用**大端序**（big-endian / network byte order）。即最高有效字节在前。

例如 uint32 值 `0x80DFEC60` 的线上字节为：`80 DF EC 60`。

### 纯数学实现

lua-yar 的二进制编解码使用**纯数学 `div/mod` 运算**实现，不依赖 `string.pack` / `string.unpack`：

```lua
-- 大端 uint32 打包
function _M.pack_u32(n)
    return string.char(
        math.floor(n / 0x1000000) % 0x100,  -- 字节 0 (最高位)
        math.floor(n / 0x10000) % 0x100,    -- 字节 1
        math.floor(n / 0x100) % 0x100,     -- 字节 2
        n % 0x100                           -- 字节 3 (最低位)
    )
end

-- 大端 uint32 解包
function _M.unpack_u32(s, offset)
    local a, b, c, d = string.byte(s, offset, offset + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end
```

> **兼容性**：`string.pack` / `string.unpack` 是 Lua 5.3+ 引入的功能，LuaJIT 不支持。纯数学实现确保框架在 Lua 5.1 / LuaJIT / 5.3+ 上行为一致。

### 字符串填充

`provider` 和 `token` 字段为定长 char[32]，使用 `Util.pad_field()` 右补 `\0` 至 32 字节，超长截断。解析时使用 `Util.trim_null()` 去除尾部 `\0`。

---

## 完整报文示例

### JSON 请求

调用 `add(1, 2)`，事务 ID `0x00003039`（12345）：

```
Packager Name (8 bytes):  4A 53 4F 4E 00 00 00 00    "JSON\0\0\0\0"

Header (82 bytes):
  id:        00 00 30 39                 12345
  version:   00 01                       1
  magic_num: 80 DF EC 60                 0x80DFEC60
  reserved:  00 00 00 00                 0
  provider:  00 00 00 00 ... (32 bytes)  ""
  token:     00 00 00 00 ... (32 bytes)  ""
  body_len:  00 00 00 13                 19

Body (19 bytes, JSON):
  {"i":12345,"m":"add","p":[1,2]}

Total: 8 + 82 + 19 = 109 bytes
```

### JSON 响应

成功返回 `3`：

```
Packager Name (8 bytes):  4A 53 4F 4E 00 00 00 00    "JSON\0\0\0\0"

Header (82 bytes):
  id:        00 00 30 39                 12345 (与请求一致)
  version:   00 01                       1
  magic_num: 80 DF EC 60                 0x80DFEC60
  reserved:  00 00 00 00                 0
  provider:  00 00 00 00 ... (32 bytes)  ""
  token:     00 00 00 00 ... (32 bytes)  ""
  body_len:  00 00 00 23                 35

Body (35 bytes, JSON):
  {"i":12345,"s":0,"r":3,"o":"","e":""}

Total: 8 + 82 + 35 = 125 bytes
```

### Msgpack 请求

同样的 `add(1, 2)` 调用，使用 Msgpack 编码，body 更紧凑：

```
Packager Name (8 bytes):  4D 53 47 50 41 43 4B 00    "MSGPACK\0"

Header (82 bytes):
  id:        00 00 30 39                 12345
  version:   00 01                       1
  magic_num: 80 DF EC 60                 0x80DFEC60
  reserved:  00 00 00 00                 0
  provider:  00 00 00 00 ... (32 bytes)  ""
  token:     00 00 00 00 ... (32 bytes)  ""
  body_len:  00 00 00 0E                 14

Body (14 bytes, Msgpack):
  84 A1 69 39 CD 30 A1 6D A3 61 64 64 A1 70 92 01 02
  (map: {i:12345, m:"add", p:[1,2]})

Total: 8 + 82 + 14 = 104 bytes
```

> Msgpack 的 body 比 JSON 更紧凑（14 vs 19 字节），在大量小消息场景下可节省带宽。

---

## 跨语言互通

YAR 协议是跨语言协议，lua-yar 可与以下实现互通：

| 方向 | 传输 | packager | 说明 |
|------|------|----------|------|
| Lua Client → PHP Yar Server | HTTP | JSON | PHP 端配置 `yar.packager=json` |
| Lua Client → PHP Yar Server | HTTP | Msgpack | PHP 端配置 `yar.packager=msgpack`（需 msgpack 扩展） |
| Lua Client → yar-c Server | TCP | Msgpack | yar-c 默认 msgpack |
| Lua Client → Lua Yar Server | HTTP / TCP | JSON / Msgpack | 客户端 `setopt("packager", ...)` 指定 |
| PHP/Lua Client → Lua Yar Server | HTTP / TCP | JSON / Msgpack | Server 按请求头部 packager 自动适配 |

### 互通要点

1. **字节序一致**：所有实现均使用大端序，无平台差异。
2. **magic_num 一致**：`0x80DFEC60` 是协议级常量，所有实现必须校验。
3. **packager name 一致**：`JSON` 和 `MSGPACK` 是标准名称，大小写不敏感。
4. **body 结构一致**：请求 `{i,m,p}`，响应 `{i,s,r,o,e}`，字段名和语义跨语言一致。
5. **provider/token 透传**：服务端通常原样回传这两个字段，可用于链路追踪。

### 抓包验证

以下四种方法可观察 YAR 二进制格式，按侵入性从低到高排列。

#### 1. tcpdump（系统级，TCP/HTTP 通用）

最简单的方式，无需改代码。抓取 TCP 端口 9999 的流量并以 hex+ASCII 显示：

```bash
# 实时查看（hex + ASCII）
tcpdump -i lo -XX -s 0 'tcp port 9999'

# 保存为 pcap 文件，后续用 Wireshark 分析
tcpdump -i lo -w yar.pcap 'tcp port 9999'
wireshark yar.pcap

# HTTP 端口同理
tcpdump -i lo -XX -s 0 'tcp port 8888'
```

> YAR 帧前 8 字节是 packager name（`JSON\0\0\0\0` 或 `MSGPACK\0`），紧接着 82 字节 header 中偏移 6 处的 `80 DF EC 60` 是魔数，可在 Wireshark 中以此定位 YAR 帧。

#### 2. HTTP 代理抓包（应用级，仅 HTTP 传输）

客户端 `proxy` 选项将 HTTP 请求改走代理，可用 mitmproxy / Charles / Fiddler 抓包：

```lua
local client = Yar.client.new("http://api.example.com/rpc")
client:setopt("proxy", "http://127.0.0.1:8080")  -- 代理地址，端口可省略默认 8080
client:call("add", {1, 2})
```

代理工具中可看到完整 HTTP 请求/响应（含 `Content-Type: application/octet-stream` 头和 YAR 二进制 body）。

> HTTPS over proxy 通过 CONNECT 隧道实现，需 socket 提供者支持 `sslhandshake`（cosocket 原生支持；luasocket 需 luasec）。

#### 3. Socket 提供者注入抓包（协议级，TCP/HTTP 通用）

注入"镜像 socket 提供者"，在 `send`/`receive` 中 dump 原始 YAR 二进制帧到文件。这是 lua-yar 独有优势——能抓 TCP 传输的 YAR 帧，比 HTTP 代理更底层：

```lua
local Yar = require("yar")
local socket = require("socket")
local io = io

-- 包装 luasocket，在 send/receive 时写文件
local function mirror_provider()
    local f = io.open("yar_dump.bin", "wb")
    local function wrap(s)
        return {
            settimeout = function(_, ms)
                if ms == nil then return s:settimeout(nil) end
                return s:settimeout(ms / 1000)
            end,
            connect = function(_, ...) return s:connect(...) end,
            send = function(_, data)
                f:write(data) f:flush()       -- 记录发出的数据
                return s:send(data)
            end,
            receive = function(_, pattern)
                local data, err = s:receive(pattern)
                if data then f:write(data) f:flush() end  -- 记录收到的数据
                return data, err
            end,
            close = function(_, ...)
                f:close()
                return s:close(...)
            end,
        }
    end
    return {
        tcp = function()
            return wrap(socket.tcp())
        end,
    }
end

Yar.client.set_socket(mirror_provider())
local client = Yar.client.new("tcp://127.0.0.1:9999")
client:call("add", {1, 2})
-- yar_dump.bin 包含完整的 YAR 请求 + 响应二进制帧
```

> 镜像 socket 对框架透明——不改协议层代码即可插入抓包层。yar-c 没有这层抽象，做不到不动核心代码就插入抓包。

#### 4. socat 中继（系统级，TCP 专用）

无需改代码，用 `socat` 做 TCP 端口转发 + 日志：

```bash
# 监听 9999，转发到 9998，同时记录所有流量到文件
socat -v TCP-LISTEN:9999,reuseaddr,fork TCP:127.0.0.1:9998 2>&1 | tee yar_traffic.log

# 或用 -x 显示 hex dump
socat -x TCP-LISTEN:9999,reuseaddr,fork TCP:127.0.0.1:9998
```

客户端连 9999（中继端口），真实 server 监听 9998。所有 YAR 帧被 socat 记录。

> lua-yar 的 `example/` 目录提供完整的互通测试示例，可直接运行验证。

---

## 参考

- [PHP Yar 协议文档](https://github.com/laruence/yar/blob/master/tests/yar_protocol.inc)
- [yar-c 协议头定义](https://github.com/laruence/yar-c/blob/master/yar_protocol.h)
- [MessagePack 规范](https://github.com/msgpack/msgpack/blob/master/spec.md)
- [RFC 1700 — Assigned Numbers](https://www.rfc-editor.org/rfc/rfc1700)（网络字节序定义）
