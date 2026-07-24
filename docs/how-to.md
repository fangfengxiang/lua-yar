# How-to 指南

> 按问题找方案。每条是一个具体任务的解决路径，指向详细文档。
> 如果你是 YAR 新手，建议先读 [Tutorial](tutorial.md)。

---

## 性能优化

| 任务 | 说明 | 链接 |
|------|------|------|
| 开启 persistent 连接复用 | TCP 跨 call 复用 socket，3.9x 吞吐提升 | [api.md — Persistent Connections](api.md#persistent-connections-39x-throughput) |
| 配置 cosocket 连接池 | OpenResty 生产推荐，归池自动复用 | [api.md — Keepalive Pool](api.md#keepalive-pool-cosocketopenresty) |
| 注入 cjson / cmsgpack 加速 | 裸编解码 6-10x，全链路 ~1.0x（协议开销主导） | [api.md — C Extension Injection](api.md#c-extension-injection) |
| 选择推荐配置 | 按场景选 persistent / keepalive / packager | [api.md — Recommended Configurations](api.md#recommended-configurations) |

---

## 部署

| 任务 | 说明 | 链接 |
|------|------|------|
| OpenResty 部署 | cosocket + content_by_lua，生产推荐 | [server-implementations.md — OpenResty](server-implementations.md#openresty) |
| 原生 Lua 顺序 server | 开发/测试用，单线程 accept | [server-implementations.md — 原生 Lua](server-implementations.md#原生-lua顺序) |
| 原生协程并发 | coroutine + socket.select，不依赖 copas | [server-implementations.md — 原生协程](server-implementations.md#原生协程) |
| copas 协程并发 | 基于 luasocket 的协程调度器 | [server-implementations.md — copas](server-implementations.md#copas) |
| lua-eco 并发 | epoll 协程优先网络运行时 | [server-implementations.md — lua-eco](server-implementations.md#lua-eco) |
| Skynet 高并发 | Actor 模型服务端框架 | [server-implementations.md — Skynet](server-implementations.md#skynet) |
| 多 worker ID 生成 | OpenResty 注入 worker-distinct 生成器 | [api.md — OpenResty Multi-Worker ID Generation](api.md#openresty-multi-worker-id-generation) |
| 生产环境推荐 lua-resty-yar | OpenResty 绑定，开箱即用 | [server-implementations.md — 生产环境](server-implementations.md#生产环境) |

---

## 调试与可观测

| 任务 | 说明 | 链接 |
|------|------|------|
| 用 hooks 观测请求/响应 | on_request/on_response，pcall 保护零开销 | [api.md — Hooks](api.md#hooks) |
| 用 hooks 做链路追踪 | trace_id 注入与传播，应用层职责 | [design-rationale.md — trace_id](design-rationale.md#七为什么不由库自动生成-trace_id) |
| 注入自定义 Log writer | 对接 ngx.log 或文件输出 | [api.md — Log.set_writer](api.md#logset_writer) |
| 用 proxy 抓包 | HTTP 代理，请求行用绝对 URI | [design-rationale.md — 代理与抓包](design-rationale.md#四客户端代理与协议抓包) |
| 用 resolve 自定义 DNS | curl/PHP 风格 host→IP 映射 | [design-rationale.md — 代理与抓包](design-rationale.md#四客户端代理与协议抓包) |
| 注入镜像 socket 抓 TCP 帧 | 协议级抓包，比 HTTP 代理更底层 | [design-rationale.md — 代理与抓包](design-rationale.md#四客户端代理与协议抓包) |

---

## 扩展

| 任务 | 说明 | 链接 |
|------|------|------|
| 替换内置 packager | 用 cjson/cmsgpack 替换纯 Lua 实现，只允许标准名称 | [api.md — Yar.register_packager](api.md#yarregister_packager) |
| 注入 HTTP provider | 替换默认手动 HTTP，对接 lua-resty-http | [api.md — Client.set_http_provider](api.md#clientset_http_provider) |
| 注入 socket provider | OpenResty cosocket 注入 | [api.md — Client.set_socket](api.md#clientset_socket) |
| 设置 JSON 深度限制 | 防恶意深嵌套，默认 512 | [api.md — Yar.set_options](api.md#yarset_options) |
| 设置 Msgpack 深度限制 | 防恶意深嵌套，默认 512 | [api.md — Yar.set_options](api.md#yarset_options) |
| 自定义错误处理 | err.code 程序化匹配 5 级错误码 | [api.md — Client:call](api.md#clientcall) |

---

## 协议与互操作

| 任务 | 说明 | 链接 |
|------|------|------|
| 理解 YAR 二进制协议 | packager + header + body 三段式 | [protocol.md](protocol.md) |
| Lua ↔ PHP Yar 互通 | JSON / Msgpack 双 packager | [protocol.md — 跨语言互通](protocol.md#跨语言互通) |
| 切换 JSON / Msgpack | setopt("packager", ...) | [api.md — Client Options](api.md#client-options) |
| TCP 帧拆解 | receive_exact + receive_message | [protocol.md — TCP 帧拆解](protocol.md#tcp-帧拆解) |

---

→ 完整 API 参考：[api.md](api.md)
→ 协议规范：[protocol.md](protocol.md)
→ 设计选型：[design-rationale.md](design-rationale.md)
→ 入门教程：[tutorial.md](tutorial.md)
