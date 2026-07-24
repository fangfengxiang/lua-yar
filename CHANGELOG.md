# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-19

### Added
- 纯 Lua Yar RPC 框架（Client + Server），零 C 扩展依赖
- JSON / Msgpack 双 packager（纯 Lua 实现）
- HTTP / TCP 双传输，支持 `http://` `https://` `tcp://` `unix://` scheme
- OpenResty cosocket 注入（`Client.set_socket(ngx.socket)`）
- 结构化 Error 对象（5 类错误码：TRANSPORT/TIMEOUT/PROTOCOL/NOT_FOUND/EXCEPTION）
- Hooks 机制（on_request / on_response，pcall 保护）
- 统一日志模块（4 级 + 可注入 writer）
- HTTP Provider 委托机制（类级 + 实例级注入）
- LuaLS 类型注解 + CONTRIBUTING.md 代码风格指南
- 多环境并发示例（OpenResty / lua-eco / Skynet / copas / 原生协程）
- CI 多版本矩阵测试（Lua 5.1 / LuaJIT 2.1 / 5.3）
- `ssl_verify` 传输选项（默认 `true`），HTTPS 证书验证可配置，对齐 lua-resty-http / luasec 业界默认
- HTTPS over proxy 支持：HTTP CONNECT 隧道 + TLS 握手（issue #10），企业内网/云原生代理场景可用
- `.luacov` 覆盖率采集配置 + `codecov.yml` Codecov 上报配置
- CI 无 luasocket 环境测试 job（软依赖优雅降级验证）
- CI luacov 覆盖率报告 + Codecov 上报 + 性能基准测试 step
- `.luacheckrc` 增强变量命名检查（`codes = true` + `no_unused` + 文件级配置）
- busted BDD 测试框架：33 个测试从 `test/client_test.lua` 迁移至 15 个 spec 文件 + `.busted` 配置
- rockspec `test_dependencies` 声明（busted / luafilesystem / luacheck / luacov）
- 并发端到端测试套件：PHP `pcntl_fork` 多进程并发 → Lua Yar 服务端，覆盖 4 场景（3 并发原生 HTTP/TCP 顺序处理 + 50 并发 OpenResty 2-worker 协程并发 HTTP/TCP），验证 requestId 数据完整性 + 日志协程异常检测 + 多 worker 负载分担，JSON + Msgpack 双 packager
- `test/concurrent_e2e.sh` 总编排（原生 + OpenResty，HTTP + TCP）
- `test/concurrent_openresty.sh` OpenResty 编排（nginx 2 workers，HTTP `content_by_lua` + stream `content_by_lua`）
- `test/nginx_concurrent_server.lua` OpenResty HTTP handler（requestId 日志追踪）
- `test/nginx_stream_server.lua` OpenResty stream TCP handler（`ngx.req.socket(true)` + requestId 日志追踪）
- CI `interop` job 增加 `pcntl` 扩展 + 并发测试 step
- CI `openresty` job 增加 PHP + yar + msgpack + pcntl + 并发测试 step

### Changed
- `sslhandshake` 第三参数从硬编码 `false` 改为读取 `transport.ssl_verify`（默认 `true`）
- **BREAKING**: HTTPS 证书验证默认从关闭改为开启（`ssl_verify = true`），自签证书环境需显式设 `ssl_verify = false`
- `server/init.lua` 用 `Framing.HEADER_TOTAL` 常量替换硬编码 `90`
- `transport/http.lua` 移除冗余 `tonumber()` 调用，添加 `self.options` 初始化守卫
- CI 测试命令从 `lua -lluacov test/client_test.lua` 改为 `busted --coverage`
- `json.lua` `encode_string` 增加快路径：无转义字符时 `s:find('[%c"\\]')` 检测后直接拼接，跳过逐字节 buffer 分配（借鉴 dkjson `fsub` 思路）
- `json.lua` `parse_string` 改用 dkjson 风格模式扫描：`str:find('["\\]', lastpos)` 一次定位 + `str:sub` 取整段子串（C 层操作），替代逐字节 `string.char` 累积；`n == 1` 单段不 `table.concat`
- `json.lua` 修复预存边界 bug：字符串以单独 `\` 结尾（未闭合）时统一报 `"unterminated string"`（原代码 `string.char(nil)` 报隐晦错误）
- **packager 错误处理改造（ADR #34，方案 C）**：`json.lua` decode 和 `msgpack.lua` unpack 对运行时错误（畸形数据、深度超限、截断输入）从 `error()` 改为 `return nil, err`，对齐 dkjson.decode（`nil, pos, errmsg` 三返回值）和 lua-resty-redis（`nil, errmsg` 二返回值）惯例；`Protocol.parse` 传播 packager 错误；`client.lua` 移除 2 处 pcall、`server/init.lua` 移除 5 处 pcall（保留用户 RPC 方法调用的 pcall）；移除 `client_spec` 的 THROW packager 测试（pack 契约上是 infallible）、`security_spec` 移除 2 处多余 pcall

### Performance
- JSON 编解码快路径优化（ADR #35）：A/B 对比 Pure Lua `Json.pack` +67.5% / `Json.unpack` +18.0%，LuaJIT `Json.pack` +85.1% / `Json.unpack` +7.8%。零新依赖，API/协议兼容性不变
