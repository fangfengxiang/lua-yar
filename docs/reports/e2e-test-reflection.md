# E2E 测试反思：如何避免协议布局问题在 CI 中漏网

> 日期：2026-09-27

## 问题回顾

协议层将 wire format 从 `[packager(8)][header(82)][body]` 改为 `[header(82)][packager(8)][body]`（与 PHP Yar 源码对齐），但端到端测试未能立即捕获这个变更，因为：

1. **旧 interop.sh 是单体脚本**——4 个场景耦合在一个文件里，CI 日志只报一个 pass/fail，无法定位是哪个场景出错
2. **无环境前置检查**——PHP 扩展缺失时静默 skip，可能掩盖问题
3. **断言不够严格**——旧测试覆盖 add/sub/upper/greet 四个方法，但没有专门验证协议层正确性的最小断言

## 改进措施

### 1. 场景拆分（每场景独立 sh 脚本）

```
test/e2e/
  lua_to_lua_http.sh    — Lua → Lua (HTTP)
  lua_to_lua_tcp.sh     — Lua → Lua (TCP)
  php_to_lua_http.sh    — PHP → Lua (HTTP)
  php_to_lua_tcp.sh     — PHP → Lua (TCP)
  lua_to_php_http.sh    — Lua → PHP (HTTP)
  interop.sh            — 串联 runner
  check_env.sh          — 环境检查
  Dockerfile            — Docker 测试环境（Lua 5.1 + PHP 8.2 + yar/msgpack/pcntl）
  docker.sh             — Docker 一键运行脚本
```

CI 日志中每个场景独立显示 pass/fail，一眼定位出错场景。

### 2. 环境前置检查（check_env.sh）

在跑互通场景前，检查：
- Lua + luasocket
- PHP + yar 扩展 + msgpack 扩展
- 端口可用性

输出明确的 READY/SKIP/BLOCKED 状态，而非静默跳过。

### 3. 严格断言（a+b=c）

每个场景用 `add(a,b)` 函数，断言返回值 = a+b：

| 测试用例 | 预期 |
|---------|------|
| add(10, 20) | 30 |
| add(100, 200) | 300 |
| add(1, 2) | 3 |
| add(0, 0) | 0 |

每组 packager（JSON + Msgpack）各跑 4 个用例 = 8 个断言/场景，5 个场景共 40 个断言。

### 4. 共享客户端脚本

`lua_client.lua` 和 `php_client.php` 接收 URL + packager 参数，所有场景复用同一断言逻辑，避免复制粘贴导致的不一致。

## CI/CD 防护要点

### 协议变更时的检查清单

当改动涉及协议层（header 结构、wire format、packager name、body_len 语义）时：

1. **对比 PHP Yar 源码**——确认每个字段的偏移、大小、语义与 PHP Yar `yar_protocol.h` 一致
2. **跑 e2e 全量测试**——`bash test/e2e/interop.sh`，5 个场景 × 2 packager 必须全绿
3. **检查文档对齐**——protocol.md 中的字节布局图、body_len 描述、报文示例必须与代码同步
4. **检查 framing 常量**——`Framing.HEADER_TOTAL`、`HEADER_OFFSET` 等常量值必须与 wire format 一致

### CI workflow 结构

```yaml
interop:
  steps:
    - name: Build E2E Docker image
      run: docker build -t lua-yar-e2e test/e2e/
    - name: E2E environment check
      run: docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/check_env.sh
    - name: E2E tests — Lua self-interop + PHP interop
      run: docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/interop.sh
```

CI 和本地环境完全一致：Docker 镜像打包全部依赖（Lua 5.1 + luasocket + PHP 8.2 + yar/msgpack/pcntl），开发者无需本地安装任何依赖。

**两种运行方式：**
- Docker 方式（推荐，零依赖安装）：`bash test/e2e/docker.sh`
- 本地直跑（需已装好依赖）：`bash test/e2e/interop.sh`
