# 打包器层设计决策

打包器层（`packager/`）负责 YAR body 的序列化与反序列化。内置 JSON 和 MessagePack 两个纯 Lua 编解码器，通过 registry 模式支持第三方 codec 扩展。

---

## 18. closure 可重入解码器：OpenResty 协程安全

- **状态**：已实现
- **决策驱动因素**：健壮性、跨运行时
- **关联决策**：#31（跨运行时设计）

### 背景

OpenResty 中多个协程可能并发调用 `Json.decode` / `Msgpack.unpack`。如果解码器用模块级变量保存解析位置（`pos`），协程 A 的 `pos` 会被协程 B 的调用覆盖，导致解析错乱。

### 思考与取舍

> "Functions are first-class citizens." — Lua 设计哲学
> "函数是一等公民。" — Lua 设计哲学

`json.lua` 的 `decode(s)` 和 `msgpack.lua` 的 `unpack(s)` 都用**闭包**保存解析状态：
```lua
function _M.decode(s)
    local str, pos, len = s, 1, #s   -- 每次调用创建新的局部状态
    local parse_value, parse_array, parse_object  -- 前向声明
    -- ... 闭包内定义 parse_* 函数，捕获 str/pos/len
end
```

每次调用创建独立的 `str`/`pos`/`len` 闭包变量，多个协程并发调用各自有独立状态，互不干扰。

备选方案：用模块级变量 + 协程 ID 隔离。但 Lua 协程无标准 ID，且实现复杂。闭包是 Lua 语言级解决方案，零成本。

### 业界参考

- **lua-cjson**：C 实现，线程局部存储（TLS）隔离解析状态。
- **cmsgpack**：C 实现，同样用 TLS。
- **lua-resty-json**：用模块级变量，有协程安全问题。

### 代码评价

`json.lua` 的 `decode` 函数内 `local str, pos, len = s, 1, #s` 创建闭包状态，`parse_value` / `parse_array` / `parse_object` 作为 local 函数捕获这些变量。`msgpack.lua` 的 `unpack` 同理。两个解码器的闭包结构一致，注释明确"使用闭包保证可重入，OpenResty 多协程并发安全"。实现正确，是 Lua 语言特性的优雅运用。

### 知识领域

1. *Programming in Lua*（Roberto Ierusalimschy）— 闭包与词法作用域
2. *Lua Programming Gems*（Lua 社区）— 协程安全的模块设计

---

## 19. IEEE754 双精度编解码：math.frexp/ldexp

- **状态**：已实现
- **决策驱动因素**：兼容性、零依赖
- **关联决策**：#15（纯数学编解码）

### 背景

MessagePack 的 float64 类型（0xcb）是 8 字节 IEEE754 双精度浮点。Lua 5.1 无 `string.pack`，需要用纯数学将 double 分解为 8 字节大端序列，以及反向重组。

### 思考与取舍

> "Floating point is not real arithmetic." — Gerald Sussman
> "浮点数不是实数算术。" — Gerald Sussman

`msgpack.lua` 的 `pack_double(n)` 用 `math.frexp(n)` 分解为尾数和指数（`0.5 <= mant < 1`，`mant * 2^exp = n`），然后算术构造 8 字节：
- 符号位（1 bit）
- 偏移指数（11 bit，`biased = exp - 1 + 1023`）
- 尾数（52 bit，`frac = (mant * 2 - 1) * 2^52`）

`unpack_double(s, offset)` 反向重组：读 4+4 字节，提取符号/指数/尾数，用 `math.ldexp` 还原。

特殊值处理：`n == 0`（零）、`n ~= n`（NaN）、`n == math.huge`（Inf）、负零（`1/n < 0` 检测）。

### 业界参考

- **cmsgpack**：C 实现，直接内存拷贝 `double` 到 8 字节。
- **lua-MessagePack**：用 `string.dump` + `string.byte` 提取 IEEE754 字节，依赖 Lua 内部浮点表示。
- **Lua 5.3 `string.pack`**：`">d"` 格式，语言级支持。

### 代码评价

`pack_double` 约 20 行，正确处理了正零/负零/NaN/Inf 四种特殊值。`math.frexp` 分解 + 算术构造 8 字节的逻辑清晰。`unpack_double` 用 `math.ldexp` 重组，正确处理非规格化数（`exp == 0`）和特殊值（`exp == 0x7ff`）。`unpack_float`（float32）同理。纯数学实现，兼容 Lua 5.1 / LuaJIT / 5.3+。

### 知识领域

1. IEEE 754-2019 — *IEEE Standard for Floating-Point Arithmetic*
2. *What Every Computer Scientist Should Know About Floating-Point Arithmetic*（David Goldberg, 1991）— 浮点精度与特殊值

---

## 20. 深度限制：JSON + Msgpack max_depth 512

- **状态**：已实现
- **决策驱动因素**：安全性
- **关联决策**：#12（body 长度限制）、#18（closure 可重入）

### 背景

恶意构造的深度嵌套 JSON/Msgpack 会导致递归解析栈溢出（Lua 栈深度有限，约 200 层）。需要一个深度上限防止 DoS。

### 思考与取舍

> "Defense in depth." — 安全工程原则
> "纵深防御。" — 安全工程原则

`json.lua` 和 `msgpack.lua` 都有 `max_depth = 512`（对齐 PHP `json_decode` 默认 512），并提供 `set_max_depth(n)` 运行时调整。

实现用 `descend(parser)` 包装函数：进入 array/object 时 `depth = depth + 1`，超限则 `return nil, errmsg`（JSON 返回 `nil, nil, errmsg` 对齐 dkjson，Msgpack 返回 `nil, errmsg` 对齐 lua-resty-redis），离开时 `depth = depth - 1`。单一增减点，错误在递归调用前返回，无需多 return 点清理。

### 业界参考

- **PHP `json_decode`**：默认 `depth = 512`，`JSON_UNESCAPED_UNICODE` 等。
- **lua-cjson`**：`set_max_depth` API，默认 1000。
- **Python `json`**：`json.loads(s)` 无深度限制（C 实现靠栈大小兜底）。

### 代码评价

`json.lua` 的 `descend(parser)` 包装 `parse_object` / `parse_array`，`depth` 是闭包变量（与 #18 一致，协程安全）。`msgpack.lua` 的 `descend(parser, n)` 同理包装 `parse_map` / `parse_array`。两者 API 对称（`set_max_depth`），默认值一致（512）。max_depth 配置统一走 `Yar.set_options({ packager = { json_max_depth = N, msgpack_max_depth = N } })` 进程级全局路径，`server:set_options` 不再处理 max_depth。实现完整，对称设计。

### 知识领域

1. RFC 8259 — *The JSON Data Interchange Syntax*，嵌套深度与栈安全
2. MessagePack Specification — 类型系统与嵌套结构

---

## 21. registry/adapter 模式：register + get

- **状态**：已实现
- **决策驱动因素**：可扩展性
- **关联决策**：#11（packager 自适应）

### 背景

YAR 协议支持多种 packager（JSON、Msgpack，未来可能加 PHP serialize 等）。需要一个注册表让用户按名称获取，同时支持注册第三方 C 扩展（cjson、cmsgpack）加速。

### 思考与取舍

> "Favor object composition over class inheritance." — Gang of Four
> "优先使用对象组合而非类继承。" — 四人组

`packager.lua` 提供两个 API：
- `register(name, lib)` — 注册第三方库，自动检测 `pack/unpack` 或 `encode/decode` 接口，构造 adapter 并注册
- `get(name)` — 按名称获取（大小写不敏感，默认 JSON）

`register` 检测 lib 的 `encode/decode` 或 `pack/unpack` 方法，构造 adapter `{name=, pack=, unpack=}` 并自动注册。cjson（`encode/decode`）和 cmsgpack（`pack/unpack`）都能适配。

### 业界参考

- **yar-c**：`yar_packager` 注册表 + `yar_packager_register(name, factory)`。
- **PHP Yar**：`Yar_Packager::factory($name)` 工厂方法。
- **Kong**：`kong.db` DAO 注册表，类似模式。

### 代码评价

`packager.lua` 的 registry 模式干净。`register` 的 adapter 构造逻辑清晰：检测 lib 方法存在性、构造 adapter 表、自动注册。内置 JSON 和 Msgpack 在模块加载时注册到 `registry` 表。`get(name)` 大小写不敏感（`string.upper(name)`），未知 packager 返回 `nil, err`。设计简洁，扩展性好。

**registry 初始状态与 register 后的不对称**：模块加载时 `registry` 直接存入完整模块（`Json`/`Msgpack`，含 `max_depth`/`set_max_depth`/`decode` 等字段），而 `register` 后存入的是 adapter（仅 `name`/`pack`/`unpack`）。协议层（`Protocol.render`/`Protocol.parse`）只使用 `name`/`pack`/`unpack` 三个字段，因此两种存储形式功能等价。若用户通过 `register("JSON", cjson)` 注入 C 扩展，registry 中 JSON 条目从完整模块变为 adapter，但协议层行为不变。

### 知识领域

1. *Design Patterns*（GoF）— Adapter / Registry 模式
2. *Patterns of Enterprise Application Architecture*（Martin Fowler）— Plugin / Registry 模式

---

## 22. MessagePack str 类型完整支持

- **状态**：已实现
- **决策驱动因素**：正确性
- **关联决策**：#19（IEEE754 编解码）、#21（registry/adapter）

### 背景

MessagePack 的 str 类型有四种编码：fixstr（0xa0-0xbf，长度 ≤ 31）、str8（0xd9，长度 ≤ 255）、str16（0xda，长度 ≤ 65535）、str32（0xdb，长度 ≤ 2^32-1）。编解码两端都必须完整支持全部四种。

### 思考与取舍

> "The devil is in the details." — 工程谚语
> "魔鬼藏在细节中。" — 工程谚语

`msgpack.lua` 的 `encode_string(s)` 按长度选择编码：
- `len <= 31` → `string.char(0xa0 + len) .. s`（fixstr）
- `len <= 0xff` → `string.char(0xd9, len) .. s`（str8）
- `len <= 0xffff` → `string.char(0xda) .. Util.pack_u16(len) .. s`（str16）
- else → `string.char(0xdb) .. Util.pack_u32(len) .. s`（str32）

`parse_string(b)` 按类型字节解码：fixstr（`b >= 0xa0 and b <= 0xbf`）、str8（`b == 0xd9`）、str16（`b == 0xda`）、str32（`b == 0xdb`）。每种都做边界检查（`pos + n - 1 > len` 则 error）。

### 业界参考

- **MessagePack Specification**：str 类型族定义（fixstr/str8/str16/str32）。
- **cmsgpack**：C 实现，完整支持全部 str 类型。
- **msgpack-python**：Python 实现，同样完整支持。

### 代码评价

`msgpack.lua` 的 `encode_string` 和 `parse_string` 完整覆盖了四种 str 类型。`parse_value` 中 `0xd9 or 0xda or 0xdb` 分支统一调用 `parse_string(b)`，fixstr 在 `b <= 0xbf` 分支处理。边界检查（`need(n)` / `pos + n - 1 > len`）到位。与 MessagePack 规范完全一致，互通性正确。

### 知识领域

1. MessagePack Specification — str 类型族（fixstr/str8/str16/str32）
2. RFC 8259 — *The JSON Data Interchange Syntax*，字符串编码规范（对比参考）

---

## 35. JSON 字符串快路径：借鉴 dkjson 模式扫描

- **状态**：已实现
- **决策驱动因素**：性能
- **关联决策**：#18（closure 可重入）、#21（registry/adapter）

### 背景

`docs/reports/performance-review.md` Finding 1 & 2 定位到 `encode_string` 和 `parse_string` 的逐字节 Lua 循环——对无转义字符的普通字符串（RPC 常见场景：方法名、参数、token），每个字节都走 `string.byte` + `string.char` + table 累积再 `table.concat`。JSON 编解码占全链路 ~70% CPU。

N3 曾以"cjson 注入后此优化自动消失"为由跳过。重新评估：纯 Lua 编解码器是零依赖 fallback，自身值得优化，不应假设用户一定注入 cjson（cjson 有语义差异，opt-in 注入是正确设计，但不应因此放弃 fallback 路径的自身优化）。

### 思考与取舍

> "Make it work, make it right, make it fast." — Kent Beck
> "先让它工作，再让它正确，最后让它快。" — Kent Beck

借鉴 dkjson 2.5（David Kolf，纯 Lua JSON 标杆库）的模式扫描思路：用 `string.find`（C 层单次扫描）+ `string.sub`（C 层内存拷贝）替代逐字节 Lua 循环。

**encode 快路径**（D1）：`s:find('[%c"\\]')` 无匹配则 `return '"' .. s .. '"'`（单次拼接，零逐字节分配）。`%c` 匹配控制字符 0x00-0x1F，`"` 和 `\\` 匹配双引号和反斜杠——与慢路径 8 种转义分支集合对齐。有特殊字符走慢路径，逻辑不变。

**parse 快路径**（D2/D3）：`str:find('["\\]', lastpos)` 一次扫描找 `"` 或 `\`，`str:sub(lastpos, nextpos - 1)` 取整段子串。`lastpos` 是局部变量跟踪扫描起点，`pos` 仍是闭包 upvalue（#18 协程安全不变）。

**单段不 concat**（D4）：`n == 1` 直接返回 `t[1]`，避免 `table.concat` 对单元素表分配新字符串。

备选：dkjson 的 `fsub` + `gsub` 替换表模式。不采用——现有逐字节逻辑已有结构化分支（8 种转义），改 `gsub` 替换表需重写整个转义逻辑，快路径已解决主要瓶颈。

### 业界参考

- **dkjson 2.5**（David Kolf）：纯 Lua JSON 标杆库，`fsub`（encode）+ `scanstring`（decode）模式扫描，本决策直接借鉴。
- **lua-cjson**：C 实现，直接内存操作，无逐字节循环问题。
- **LPeg**：dkjson 有 LPeg 路径（PEG 解析），性能更高但引入依赖，lua-yar 保持零依赖不采用。

### 代码评价

`json.lua` 的 `encode_string`（50-73 行）快路径在前、慢路径在后，结构清晰。`parse_string`（165-227 行）dkjson 风格 `find`+`sub` 扫描，9 种转义分支（`n`/`t`/`r`/`b`/`f`/`"`/`\\`/`/`/`uXXXX`+代理对）完整保留。`n == 0`/`n == 1`/`n > 1` 三路返回优化到位。

**附带修复**：边界测试发现预存 bug——字符串以单独 `\` 结尾（未闭合）时 `pos` 越界导致 `string.char(nil)` 报隐晦错误，新增 `if pos > len then error("unterminated string") end` 统一报错。此 bug 在优化前的逐字节循环中同样存在（`while pos <= len` 只在循环顶检查，转义分支内 `pos+1` 后不检查）。

**性能基准测试对比**（A/B 对比，`git stash` 隔离 `json.lua` 单文件，同环境同 session，`test/benchmark.lua`）：

Pure Lua 5.5.0：

| 测试 | Before (ops/s) | After (ops/s) | 提升 |
|---|---:|---:|---:|
| **Json.pack** | 59,932 | 95,743 | **+59.8%** |
| **Json.unpack** | 48,488 | 57,827 | **+19.3%** |
| Protocol.render (JSON) | 77,422 | 102,421 | +32.3% |
| Protocol.parse (JSON) | 53,690 | 57,224 | +6.6% |
| Msgpack.pack（对照，未改动） | 109,849 | 108,937 | -0.8%（噪声） |
| Msgpack.unpack（对照，未改动） | 143,101 | 141,484 | -1.1%（噪声） |

LuaJIT 2.1：

| 测试 | Before (ops/s) | After (ops/s) | 提升 |
|---|---:|---:|---:|
| **Json.pack** | 256,018 | 441,969 | **+72.6%** |
| **Json.unpack** | 167,526 | 182,324 | **+8.8%** |
| Protocol.render (JSON) | 314,808 | 427,307 | +35.7% |
| Protocol.parse (JSON) | 186,525 | 202,472 | +8.6% |
| Msgpack.pack（对照，未改动） | 731,855 | 748,374 | +2.3%（噪声） |
| Msgpack.unpack（对照，未改动） | 418,647 | 414,079 | -1.1%（噪声） |

> Msgpack 代码未改动，其 ±1-2% 波动为系统噪声，JSON 提升远超噪声区间。
> LuaJIT `unpack` 提升较小（+8.8%）：LuaJIT 能 JIT 编译逐字节循环，`string.find` 是 C 函数中断 trace，C 层扫描优势部分被 JIT 抵消。Pure Lua `unpack` 受益更大（+19.3%）因 C 层操作远快于 Lua VM 逐字节解释。
> 测试覆盖：`test/json_boundary.lua` 67 项边界测试（Lua 5.5 + LuaJIT 2.1 双运行时全通过），`spec/json_spec.lua` 15/15 回归通过。

### 知识领域

1. dkjson 2.5 源码（David Kolf）— `fsub` / `scanstring` 模式扫描
2. *Programming in Lua*（Ierusalimschy）第 24 章 — 模式匹配与性能

---

## 36. int64 负数补码编解码：32 位分块算术避免 2^64 精度丢失

- **状态**：已实现
- **决策驱动因素**：正确性、跨运行时
- **关联决策**：#15（纯数学编解码）、#19（IEEE754 编解码）、#31（跨运行时）

### 背景

MessagePack int64（0xd3）用 8 字节大端补码存储有符号 64 位整数。Lua 5.1 / LuaJIT 的 `number` 是 IEEE754 double，精确整数范围仅到 2^53。原始实现用 `n + 0x10000000000000000`（2^64）求补码、用 `hi * 0x100000000 + lo - 0x10000000000000000` 还原——两处在 2^64 量级运算，超出 double 精确范围，导致 `-2147483649`（= -(2^31+1)）roundtrip 返回 `-2147483648`（off-by-one）。`spec/msgpack_spec.lua:85` 测试在 Lua 5.1 报错。

### 思考与取舍

> "Floating point is not real arithmetic." — Gerald Sussman
> "浮点数不是实数算术。" — Gerald Sussman

根因：double 在 [2^63, 2^64) 区间的 ULP（最小精度单位）= 2^(63-52) = 2^11 = 2048。`2147483649`（2^31+1）不是 2048 的倍数，故 `2^64 - 2147483649` 舍入到 `2^64 - 2147483648`（2^31 是 2048 的倍数）。

修复用 **32 位分块补码算术**，所有中间量保持在 2^53 以内：

**Pack**（`pack_i64`）：对负数 n，取 m = -n，分 `m_hi = floor(m/2^32)`、`m_lo = m % 2^32`，按位取反 `inv_hi = 0xffffffff - m_hi`、`inv_lo = 0xffffffff - m_lo`，再加 1（处理 lo 溢出进位到 hi）。全程不出现 2^64 量级的数。

**Unpack**（0xd3 分支）：负数（`hi >= 0x80000000`）取反加一求绝对值 `m = (0xffffffff - hi) * 2^32 + (0xffffffff - lo) + 1`，返回 `-m`。同样避免 2^64 量级运算。

备选方案对比：
- `string.dump` type punning：依赖 Lua VM 字节码格式，5.1/5.3/5.5 字节码布局各不相同，跨版本失效。违反 #31 跨运行时原则，不采用。
- `string.pack`（Lua 5.3+）：语言原生但版本锁死，违反 #15 零依赖/Lua 5.1 兼容原则，不采用。
- 限制 int64 范围到 2^32：破坏与 PHP Yar 互操作（PHP 传递大负数时丢精度），不采用。

### 业界参考

- **fperrad lua-MessagePack**：提供两个变体——Lua 5.1+ 通用版（数学分块，与 lua-yar 同类方法）和 Lua 5.3+ 版（`string.pack` 原生）。约束不同选不同路线。
- **cmsgpack**（C 扩展）：直接内存操作 `int64_t` 到 8 字节，无浮点问题。
- **LuaJIT FFI**：`ffi.cast` 整数/浮点 type punning，最快但仅 LuaJIT 可用。

业界不同库选了不同约束下的不同路线。lua-yar 的约束（单份代码跨 Lua 5.1 / LuaJIT / 5.3 / 5.5 + 零依赖）最严，纯数学 32 位分块是唯一能同时满足所有约束的路线。

### 代码评价

`msgpack.lua` 的 `pack_i64`（64-71 行）对负数走 32 位两半求补码（`~m + 1`），`lo = inv_lo + 1; if lo >= 0x100000000 then ... hi = hi + 1 end` 正确处理进位。int64 unpack（433-442 行）对负数走 `(hi - 0x100000000) * 0x100000000 + lo`——先将有符号 hi 转为负数再乘 2^32，中间量 `(-1) * 2^32 = -4294967296` 在 2^53 内精确。两处修复的中间量均 ≤ 2^53，对 Lua 可表示的所有整数（≤ 2^53）精确。测试覆盖：`spec/msgpack_spec.lua` int64 边界测试（-2147483649）在 Lua 5.1.5 / LuaJIT 2.1 / Lua 5.5 全通过。

### 知识领域

1. IEEE 754-2019 — *IEEE Standard for Floating-Point Arithmetic*，double 精度与 ULP
2. *What Every Computer Scientist Should Know About Floating-Point Arithmetic*（David Goldberg, 1991）— 浮点精度丢失与舍入
3. MessagePack Specification — int64（0xd3）补码编码定义
