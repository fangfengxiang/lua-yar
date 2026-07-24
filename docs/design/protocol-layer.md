# 协议层设计决策

协议层（`protocol/`）负责 YAR 二进制消息的渲染与解析。消息布局：`[packager_name:8][yar_header:82][body:body_len]`，最小帧 90 字节。

---

## 15. 纯数学二进制编解码：Lua 5.1 兼容

- **状态**：已实现
- **决策驱动因素**：兼容性、零依赖
- **关联决策**：#19（IEEE754 双精度编解码）、#32（纯协议库定位）

### 背景

YAR 协议头是大端字节序二进制（u16/u32）。Lua 5.3+ 有 `string.pack`/`unpack`，但 Lua 5.1 和 LuaJIT 没有。如果用 `string.pack`，库就无法在 Lua 5.1 / LuaJIT 环境运行。

### 思考与取舍

> "Simplicity is prerequisite for reliability." — Edsger Dijkstra
> "简单是可靠的前提。" — Edsger Dijkstra

`util.lua` 用纯数学实现二进制编解码：
- `pack_u16(n)` → `string.char(math.floor(n/0x100)%0x100, n%0x100)`
- `pack_u32(n)` → 4 字节大端，同理
- `unpack_u16(s, offset)` → `string.byte` 取两字节，`a*0x100 + b`
- `unpack_u32(s, offset)` → 4 字节，算术组合

无位运算（Lua 5.1 无 `&` `|` `<<`），无 `string.pack`，纯算术。兼容 Lua 5.1 / LuaJIT / 5.3+ 全系列。

### 业界参考

- **Lua 5.3 `string.pack`**：语言级二进制编解码，但不向后兼容。
- **LuaJIT `bit` 模块**：位运算，但非标配（需 `require("bit")`）。
- **lua-resty-string**：用 `string.format` + 位运算，依赖 LuaJIT。

### 代码评价

`util.lua` 的 4 个编解码函数共约 30 行，实现简洁。`pack_u32` 用 `math.floor(n/0x1000000)%0x100` 逐字节提取，正确处理大端序。`unpack_u32` 用 `a*0x1000000 + b*0x10000 + c*0x100 + d` 算术组合。`pad_field` 右补 `\0` 到指定长度，`trim_null` 去尾部 `\0`。全部纯数学，零依赖。

> `unicode_to_utf8`（Unicode codepoint → UTF-8 字节串）已内联到 `json.lua`，因其仅 JSON `\uXXXX` 转义解码使用，不属于通用二进制工具。

### 知识领域

1. *Programming in Lua*（Roberto Ierusalimschy）— Lua 数字精度与字符串操作
2. Lua 5.1 Reference Manual — `string.byte` / `string.char` 语义

---

## 16. framing 帧协议：receive_exact + receive_message + check_body_len

- **状态**：已实现
- **决策驱动因素**：健壮性、安全性
- **关联决策**：#12（body 长度限制）、#17（header 校验）

### 背景

TCP 是流式协议，`receive(n)` 可能返回少于 n 字节。YAR 消息有固定头部（90 字节）+ 变长 body，需要精确读取完整帧。客户端发送前和服务端接收时都需要长度校验。

### 思考与取舍

> "Validate everything. Trust nothing." — 安全工程原则
> "验证一切，不信任任何输入。" — 安全工程原则

`framing.lua` 提供三个函数：
- `receive_exact(sock, n)` — 循环读取直到凑满 n 字节，处理 `receive(n)` 返回少于 n 字节的情况
- `receive_message(sock, max_body_len)` — 先读 90 字节头部，解析 `body_len`，校验不超限，再读 body，拼接返回完整消息
- `check_body_len(data, max_body_len)` — 发送侧防御，从已渲染的消息中解析 header 提取 `body_len`，超限拒绝发送

接收侧和服务端 `handle_message` 双重校验 body 长度，发送侧 `tcp.lua` 在发送前调用 `check_body_len`。

### 业界参考

- **HTTP/1.1**：`Content-Length` + `Transfer-Encoding: chunked`，类似的帧边界处理。
- **WebSocket**（RFC 6455）：固定头部 + 长度字段 + payload，帧协议设计类似。
- **yar-c**：`yar_protocol_parse` 解析头部 + body，无独立 framing 模块。

### 代码评价

`framing.lua` 的 `receive_exact` 用 `chunks` 表循环拼接，处理了 `#chunk == 0`（连接关闭）的边界。`receive_message` 先读头部、解析 `body_len`、校验上限、再读 body，逻辑清晰。`check_body_len` 的注释说明"header 解析失败时 best-effort 放行（返回 true）"——调用方已持有完整 data，校验仅作防御性前置检查，解析失败交由后续 `Protocol.parse` 统一报错。设计务实。

### 知识领域

1. RFC 6455 — *The WebSocket Protocol*，帧边界与长度字段设计
2. RFC 7230 — *HTTP/1.1 Message Syntax*，`Content-Length` 与分块传输

---

## 17. header 校验：82 字节 + magic_num 验证

- **状态**：已实现
- **决策驱动因素**：安全性、健壮性
- **关联决策**：#15（纯数学编解码）、#16（framing 帧协议）

### 背景

YAR 协议头是 82 字节固定结构：`id(u32) version(u16) magic_num(u32) reserved(u32) provider([32]) token([32]) body_len(u32)`。`magic_num = 0x80DFEC60` 是协议标识，用于快速识别 YAR 消息。

### 思考与取舍

> "Validate everything. Trust nothing." — 安全工程原则
> "验证一切，不信任任何输入。" — 安全工程原则

`header.lua` 的 `unpack(data, offset)` 校验：
1. 长度校验：`#data < offset + 82 - 1` 则返回错误
2. magic_num 校验：`unpack_u32(data, offset+6)` 不等于 `0x80DFEC60` 则返回 "invalid magic number"
3. 字段解析：`id`、`version`、`reserved`、`provider`（trim_null）、`token`（trim_null）、`body_len`

magic_num 校验是快速失败——非 YAR 消息在头部解析阶段就被拒绝，不会进入 body 解析。

### 业界参考

- **yar-c**：`YAR_PROTOCOL_MAGIC` 校验，C 实现。
- **PHP Yar**：`YAR_PROTOCOL_MAGIC` 常量，`unpack` 时校验。
- **gzip**：magic number `0x1f 0x8b`，文件格式识别。

### 代码评价

`header.lua` 的 `unpack` 校验逻辑清晰。magic_num 校验在字段解析之前，快速失败。`provider` 和 `token` 字段用 `Util.trim_null` 去尾部 `\0`（因为 `pad_field` 右补 `\0` 到 32 字节）。`pack()` 用 `Util.pad_field` 填充到固定长度。`Header.new` 提供默认值（`magic_num = 0x80DFEC60`、`version = 1`）。实现正确，与 yar-c / PHP Yar 协议头格式完全一致。

### 知识领域

1. YAR Protocol Specification — 协议头字段布局与 magic number
2. RFC 7230 — *HTTP/1.1 Message Syntax*，固定头部 + 变长 body 的解析模式
