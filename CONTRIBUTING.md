# lua-yar 贡献指南

## 代码风格

### 命名约定

lua-yar 遵循 Lua 业界命名惯例，对标 OpenResty 官方 lua-resty-* 全家桶、lua-cjson、dkjson 等标杆库。七大类命名规范如下：

| 类别 | 风格 | 示例 | 业界标杆 |
|------|------|------|----------|
| 模块表变量 | `_M` | `local _M = {}` | lua-resty-http、lua-resty-redis、lua-cjson |
| 局部变量 | lowercase | `sock`, `timeout`, `header_str` | Lua 标准库、所有 lua-resty-* |
| 常量 | UPPER_SNAKE | `MAX_BODY_LEN`, `STATUS_OK` | lua-resty-http 的 `http_const` |
| 函数名 | snake_case | `set_options`, `handle_message` | lua-resty-http、dkjson |
| 方法调用语法 | `:` 实例 / `.` 静态 | `client:call()` / `_M.new()` | Lua stdlib (`io.open` vs `f:read`) |
| 私有命名 | `_` 前缀 | `_internal_helper` | lua-resty-core、dkjson |
| 元方法 | `__xxx` 双下划线 | `__index`, `__tostring` | Lua 语言原语 |

**模块表变量用 `_M`**：下划线前缀表明"模块局部"，`M` 代表 Module。OpenResty 生态最广泛的约定。禁止使用 PascalCase（如 `Client`、`Server`）命名模块表变量。

**公开 API 访问点用 snake_case**：`Yar.client`、`Yar.server`、`Yar.error`、`Yar.log`、`Yar.http_server`、`Yar.tcp_server`。对齐 lua-resty-http 的 `http.new()` 等 lowercase 模块访问惯例。

**方法调用 `:` vs `.`**：实例方法（需访问实例数据）用冒号 `:`，如 `client:call()`、`server:handle_message()`；静态工厂方法（创建实例）用点号 `.`，如 `_M.new()`、`Yar.client.new()`。详见 [Lua OOP 第 16 章](https://www.lua.org/pil/16.html)。

### 缩进与格式

- 4 空格缩进，不使用 Tab
- 行宽上限 120 字符（与 `.luacheckrc` 一致）
- 字符串拼接：循环内用 `table.insert` / `#t + 1` + `table.concat`，禁止循环内 `..`
- 错误处理：所有可能抛错的外部调用用 `pcall` 包裹，返回 `nil, err` 模式

### 模块结构

```lua
-- yar/module/name.lua
-- 模块简述（一句话说明职责）
-- 依赖说明、设计决策注释

local Dependency = require("yar.dependency")

local string, math = string, math  -- 标准库 local 化（只声明实际用到的）

local _M = {}

-- 常量定义

-- 公共函数（带 LuaLS 注解）

-- 内部函数（local，可不带注解）

return _M
```

### 标准库 local 化

> **AI 模型必须遵循此规范**：所有源文件顶部将用到的标准库函数绑定为 upvalue，消除全局表查找开销。

这是 Roberto Ierusalimschy（Lua 作者）的 #1 性能建议。全局表查找每次需要哈希查找 `_G` 表；绑定为 upvalue 后变为数组索引访问，零查找开销。业界标杆库（lua-resty-http、dkjson、Tieske/uuid）均采用此模式。

**规则**：

1. **只声明实际用到的函数**：grep 文件中标准库函数使用情况，只 local 化实际调用的。方法名（如 `Json.unpack`）不算全局函数调用，不声明。
2. **保持原名**：`local string, math = string, math`，不重命名。
3. **按使用频率排序**：高频在前，低频在后（便于阅读时快速定位高频依赖）。
4. **位置**：放在 require 之后、模块表定义之前。

```lua
local Dependency = require("yar.dependency")

local string, math, tonumber, type = string, math, tonumber, type

local _M = {}
```

### 错误处理分层规范

> **AI 模型必须遵循此规范**：错误返回类型由模块所在层级决定，不可混用。

lua-yar 采用**分层错误处理**策略：内部模块返回 `nil, err_string`，用户可见 API 返回 `nil, err_obj`（`Error` 对象）。

**原则**：只有**用户可见的外部 API** 返回 `Error` 对象；内部模块返回 `string`。

| 层级 | 模块 | 错误返回类型 | 理由 |
|------|------|-------------|------|
| 用户 API | `client.lua` `call()` | `nil, Error` | 用户需 `err.code` 程序化匹配错误类型 |
| 用户 API | hooks `on_response` 的 `err` 参数 | `Error\|nil` | hook 作者需统一类型，不写 `type()` 防御代码 |
| 内部模块 | `framing.lua` / `packager.lua` / `protocol.lua` | `nil, string` | Lua stdlib 惯例；高频路径零 table 分配 |
| 内部模块 | `transport/tcp.lua` / `http.lua` | `nil, string` | 同上；错误消息仅供上层分类 |
| 内部模块 | `server/init.lua` `handle_message()` 返回值 | `nil, string` | 供 transport 层日志，不需结构化 |

**三条规则**：

1. **Lua 惯例**：`nil, err_string` 是 Lua stdlib 的通用约定（`io.open`、`pcall`、`loadfile` 全如此）。内部模块返回 string 符合 Lua 生态习惯，其他 Lua 开发者读代码零认知成本。

2. **分层正确性**：低层模块（`framing`、`packager`、`protocol`）的错误是技术性的（`"short header"`、`"unsupported packager"`），高层模块（`client.lua`）负责**分类**——把 transport 层的 string 错误归类为 `Error.TIMEOUT` / `Error.TRANSPORT`。这是正确的职责分层。如果 `framing.lua` 也返回 `Error` 对象，`client.lua` 再包一层，就会 double-wrap。

3. **性能**：`Error.new` 每次创建 table + 设 metatable。内部高频路径（如 `framing.receive_exact` 的错误路径）用 string 零分配。

```lua
-- ✅ 正确：内部模块返回 string
local data, err = Framing.receive_exact(sock, 90)
if not data then return nil, err end  -- err 是 string

-- ✅ 正确：用户 API 返回 Error 对象
local ret, err = client:call("add", {1, 2})
if err then
    if err.code == Yar.error.TIMEOUT then ... end  -- 程序化匹配
    print(err)  -- tostring(err) 返回 message（__tostring 保证）
end

-- ❌ 错误：内部模块返回 Error 对象（违反分层）
function _M.receive_exact(sock, n)
    ...
    return nil, Error.new(Error.TRANSPORT, "short read")  -- 禁止
end
```

---

## LuaLS 类型注解规范

> **AI 模型必须遵循此规范**：生成或修改 lua-yar 代码时，所有公共 API 函数必须带 LuaLS 类型注解。

### 1. `---@class` 类声明

放在 `local _M = {}` 之前，声明模块类型和字段：

```lua
---@class Client
---@field uri string Service address
---@field options table Client options
---@field _transport table|nil Cached transport (persistent mode)
local _M = {}
```

### 2. `---@param` 参数注解

类型在前，描述在后。可选参数用 `|nil`：

```lua
---@param method string Remote method name
---@param params table|nil Parameters array (default {})
function _M:call(method, params)
```

### 3. `---@return` 返回值注解

多返回值用多个 `---@return`。失败返回用 `|nil`：

```lua
---@return any retval Success return value
---@return table|nil err Error object or nil on success
function _M:call(method, params)
```

### 4. `---@field` 字段注解

用于 `---@class` 声明的字段：

```lua
---@class Response
---@field id number Transaction ID
---@field status number 0=OK, 1=ERROR
---@field retval any Return value
---@field err string Error message
```

### 5. `---@alias` 类型别名

用于简化重复类型：

```lua
---@alias SocketProvider table
---| table Cosocket provider (ngx.socket)
---| table Luasocket wrapper
```

### 6. `---@type` 变量注解

用于模块字段和常量：

```lua
---@type integer
_M.SIZE = 82
```

### 7. 完整函数示例

```lua
---@param uri string Service address (e.g. "http://host/api", "tcp://host:port")
---@return Client
function _M.new(uri)
    local self = setmetatable({}, { __index = _M })
    self.uri = uri or "http://localhost"
    self.options = deep_copy(DEFAULT_OPTIONS)
    return self
end
```

### 8. 注解语言

- **LuaLS 注解描述**：英文（LuaLS 生态惯例，便于国际化）
- **模块级注释**：中文（与现有代码风格一致）
- **行内注释**：中文或英文均可，保持文件内一致

### 9. 注解与现有 LDoc 注释的关系

现有代码使用 LDoc 风格 `-- @param`（带空格）。升级为 LuaLS 格式 `---@param`（无空格）。保留描述文字，添加类型信息：

```lua
-- Before (LDoc):
--- 设置选项
-- @param opts table 选项键值对
-- @return self

-- After (LuaLS):
---@param opts table Options key-value pairs
---@return self
function _M:set_options(opts)
```

---

## Lua 版本兼容

- 目标：Lua 5.1 / LuaJIT / 5.3+
- 禁止使用 `string.pack` / `string.unpack`（5.3+ 专属）
- 禁止使用 `goto`（5.2+ 专属）
- 使用 `unpack or table["unpack"]` 兼容 5.1 全局 unpack
- 位运算用算术实现（`math.floor` / `%`），LuaJIT `bit` 模块可选加速

## 测试

- 运行 luacheck：`luacheck src/yar/ spec/ example/`
- LuaLS 诊断：编辑器内无红色波浪线
- 功能测试：`busted --coverage`（BDD 风格，自动采集覆盖率）
- 互操作测试：`bash test/interop.sh`（Lua ↔ PHP Yar 双向端到端，JSON + Msgpack；需 PHP + yar/msgpack 扩展）
- OpenResty E2E：`resty test/openresty_e2e_test.lua` + `bash test/openresty_http_e2e.sh`
- 并发测试：`bash test/concurrent_e2e.sh`（PHP → Lua 原生 3 并发 + OpenResty 50 并发，HTTP + TCP，requestId 完整性 + 协程异常日志检测；需 PHP + yar/msgpack/pcntl 扩展 + OpenResty）
- 端口分配：所有测试监听端口集中管理在 [test/PORTS.md](../test/PORTS.md)，新增测试前先查此表避免冲突

## 提交规范

- 提交信息格式：`<type>: <description>`
- type：`feat` / `fix` / `refactor` / `docs` / `test` / `chore`
- 示例：`feat: add LuaLS type annotations to public API`

## 发布流程

发布流程由 GitHub Actions 自动化（`.github/workflows/release.yml`），tag 驱动：

1. 创建版本 rockspec（如 `lua-yar-0.2.0-1.rockspec`），设置 `tag = "v0.2.0"`
2. 更新 `CHANGELOG.md`，将 `[Unreleased]` 改为 `[0.2.0]` 并添加日期
3. 提交 rockspec + CHANGELOG：`git commit -am "release: v0.2.0"`
4. 打 tag：`git tag v0.2.0 && git push origin v0.2.0`
5. CI 自动触发：lint rockspec → 上传 LuaRocks → 创建 GitHub Release

**前置条件：**
- GitHub 仓库 Settings → Secrets 配置 `LUAROCKS_API_KEY`（从 https://luarocks.org/settings/api-keys 获取）

**回滚：**
- 删除 tag：`git tag -d v0.2.0 && git push origin :refs/tags/v0.2.0`
- 删除 LuaRocks 模块版本（Web UI）
- 删除 GitHub Release（Web UI 或 `gh release delete v0.2.0`）
