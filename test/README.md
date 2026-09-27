# 测试目录说明

> 本目录包含 lua-yar 的全部测试资产：单元测试、端到端互通测试、并发测试、OpenResty 兼容测试、基准测试、协议诊断工具。

---

## 一、目录结构

```
test/
├── e2e/                          # 端到端互通测试（Lua ↔ Lua / PHP ↔ Lua）
│   ├── Dockerfile                # Docker 镜像定义（PHP 8.2 + Lua 5.1 + yar/msgpack/pcntl）
│   ├── docker.sh                 # Docker 一键运行脚本
│   ├── interop.sh                # E2E 串联 runner（5 场景 × 2 packager）
│   ├── check_env.sh              # 环境前置检查（Lua/PHP/扩展/端口）
│   ├── lua_to_lua_http.sh        # 场景 1：Lua → Lua (HTTP)，JSON + Msgpack
│   ├── lua_to_lua_tcp.sh         # 场景 2：Lua → Lua (TCP)，JSON + Msgpack
│   ├── php_to_lua_http.sh        # 场景 3：PHP → Lua (HTTP)，JSON + Msgpack
│   ├── php_to_lua_tcp.sh         # 场景 4：PHP → Lua (TCP)，JSON + Msgpack
│   ├── lua_to_php_http.sh        # 场景 5：Lua → PHP (HTTP)，JSON + Msgpack
│   ├── lua_client.lua            # 共享 Lua 客户端（断言 add(a,b)=a+b）
│   ├── lua_http_server.lua        # Lua HTTP 服务端
│   ├── lua_tcp_server.lua         # Lua TCP 服务端
│   ├── php_client.php             # 共享 PHP 客户端（断言 add(a,b)=a+b）
│   └── php_server.php             # PHP Yar 服务端
│
├── openresty_http_e2e.sh         # OpenResty HTTP E2E runner（nginx content_by_lua）
├── concurrent_e2e.sh             # 并发测试 runner（PHP → Lua 原生，50 并发）
├── concurrent_openresty.sh        # 并发测试 runner（PHP → OpenResty，50 并发）
├── concurrent_php_to_lua_http.php # 并发 PHP 客户端 → Lua HTTP
├── concurrent_php_to_lua_tcp.php # 并发 PHP 客户端 → Lua TCP
├── concurrent_php_to_openresty_http.php  # 并发 PHP 客户端 → OpenResty HTTP
├── concurrent_php_to_openresty_tcp.php   # 并发 PHP 客户端 → OpenResty TCP
│
├── resty_test.lua                 # OpenResty 兼容性测试（resty CLI）
├── openresty_e2e_test.lua        # OpenResty E2E（cosocket TCP + 连接池 + HTTP Provider + 并发安全）
├── openresty_http_e2e_test.lua   # OpenResty HTTP E2E（content_by_lua 上下文）
├── nginx_e2e_server.lua          # nginx E2E 服务端
├── nginx_concurrent_server.lua   # nginx 并发测试服务端
├── nginx_stream_server.lua       # nginx stream（TCP）服务端
├── nginx.conf                    # nginx 测试配置
│
├── interop_lua_server.lua        # 旧版 Lua 互通服务端（HTTP）
├── interop_lua_tcp_server.lua    # 旧版 Lua 互通服务端（TCP）
├── interop_lua_to_lua_tcp.lua    # 旧版 Lua → Lua TCP 客户端
├── interop_lua_to_php.lua        # 旧版 Lua → PHP 客户端
├── interop_php_to_lua.php        # 旧版 PHP → Lua 客户端（HTTP）
├── interop_php_to_lua_tcp.php    # 旧版 PHP → Lua 客户端（TCP）
├── server.php                    # 旧版 PHP 测试服务端
├── client_test.php               # 旧版 PHP 测试客户端
│
├── benchmark.lua                 # 基准测试主入口
├── bench_server.lua              # 基准 TCP 服务端（luasocket，keepalive）
├── bench_http_server.lua         # 基准 HTTP 服务端
├── bench_transport.lua           # 传输层基准测试
├── benchmark_cext.lua            # C 扩展对比基准
├── benchmark_cosocket.lua        # cosocket 基准测试
├── benchmark_matrix.lua          # 基准矩阵（多 packager × transport）
├── benchmark_xlib.lua            # 跨语言基准（Lua 侧）
├── benchmark_xlib.php            # 跨语言基准（PHP 侧）
├── benchmark_xlib.py             # 跨语言基准（Python 侧）
│
├── diag_wire_layout.lua          # 协议 wire format 诊断工具（Lua）
├── diag_php_wire_layout.php      # 协议 wire format 诊断工具（PHP）
├── json_boundary.lua             # JSON 边界测试（特殊字符/大 payload）
│
├── test_helpers.sh               # 共享函数库（端口检查、进程清理）
└── PORTS.md                       # 端口分配策略文档
```

### 文件分类

| 类别 | 说明 | 代表文件 |
|------|------|----------|
| **E2E 互通测试** | Lua ↔ Lua / PHP ↔ Lua 协议互通，5 场景 × 2 packager | `test/e2e/interop.sh` |
| **并发测试** | 50 并发客户端压测，验证连接池/线程安全 | `concurrent_e2e.sh` |
| **OpenResty 兼容** | cosocket 注入、content_by_lua、连接池透传 | `openresty_e2e_test.lua` |
| **基准测试** | JSON vs Msgpack、Lua vs PHP vs Python 性能对比 | `benchmark.lua` |
| **协议诊断** | wire format 字节级验证，排查协议布局问题 | `diag_wire_layout.lua` |
| **基础设施** | 端口管理、进程清理、Docker 环境 | `test_helpers.sh` `PORTS.md` `e2e/Dockerfile` |

---

## 二、端到端测试

### 2.1 测试场景

5 个场景，每个场景跑 JSON + Msgpack 两种 packager，每组 4 个断言（`add(10,20)=30` / `add(100,200)=300` / `add(1,2)=3` / `add(0,0)=0`），共 40 个断言：

| # | 场景 | 方向 | 传输层 | 脚本 |
|---|------|------|--------|------|
| 1 | Lua → Lua (HTTP) | Lua client → Lua server | HTTP | `lua_to_lua_http.sh` |
| 2 | Lua → Lua (TCP) | Lua client → Lua server | TCP | `lua_to_lua_tcp.sh` |
| 3 | PHP → Lua (HTTP) | PHP client → Lua server | HTTP | `php_to_lua_http.sh` |
| 4 | PHP → Lua (TCP) | PHP client → Lua server | TCP | `php_to_lua_tcp.sh` |
| 5 | Lua → PHP (HTTP) | Lua client → PHP server | HTTP | `lua_to_php_http.sh` |

### 2.2 运行方式

#### Docker 方式（推荐，零依赖安装）

Docker 镜像打包了全部依赖（Lua 5.1 + luasocket + PHP 8.2 + yar/msgpack/pcntl 扩展），开发者无需本地安装任何东西：

```bash
# 全套 5 场景
bash test/e2e/docker.sh

# 单个场景
bash test/e2e/docker.sh test/e2e/lua_to_lua_http.sh
bash test/e2e/docker.sh test/e2e/lua_to_lua_tcp.sh
bash test/e2e/docker.sh test/e2e/php_to_lua_http.sh
bash test/e2e/docker.sh test/e2e/php_to_lua_tcp.sh
bash test/e2e/docker.sh test/e2e/lua_to_php_http.sh

# 环境检查
bash test/e2e/docker.sh test/e2e/check_env.sh

# 并发测试
bash test/e2e/docker.sh test/concurrent_e2e.sh
```

源码通过 volume 挂载（`-v "$(pwd):/app"`），改代码后直接重跑，无需 rebuild 镜像。镜像只在依赖变化时才需要 rebuild。

#### 本地直跑（需已装好 Lua + PHP + 扩展）

```bash
# 全套
bash test/e2e/interop.sh

# 单个场景
bash test/e2e/lua_to_lua_http.sh

# 环境检查
bash test/e2e/check_env.sh
```

本地依赖清单：
- Lua 5.1 + luasocket
- PHP 8.x + yar 扩展（`--enable-msgpack --with-curl` 编译）+ msgpack 扩展 + pcntl 扩展

#### 裸 Docker 命令

```bash
# 构建镜像
docker build -t lua-yar-e2e test/e2e/

# 运行
docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/interop.sh
```

### 2.3 测试结果

测试结果通过 stdout 输出。每个场景显示每个 packager 的通过/失败数，最后汇总：

```
[1/5] Lua → Lua (HTTP)
  [test] JSON packager...
  [OK] json add: 4 passed, 0 failed
  [test] Msgpack packager...
  [OK] msgpack add: 4 passed, 0 failed
  [PASS] Lua → Lua (HTTP)
...
============================================
  E2E Test Summary
============================================
  Scenarios: 5 total, 5 passed, 0 failed

=== E2E tests PASSED ===
```

退出码：`0` = 全部通过，`1` = 有失败。CI 通过退出码判定 pass/fail。

### 2.4 CI/CD

CI（`.github/workflows/test.yml` 的 `interop` job）使用 Docker 方式运行，与本地环境完全一致：

```yaml
interop:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Build E2E Docker image
      run: docker build -t lua-yar-e2e test/e2e/
    - name: E2E environment check
      run: docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/check_env.sh
    - name: E2E tests — Lua self-interop + PHP interop (JSON + Msgpack)
      run: docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/interop.sh
    - name: Concurrent tests — PHP → Lua native (3 concurrent, HTTP + TCP)
      run: docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/concurrent_e2e.sh
```

### 2.5 端口分配

E2E 测试使用 9800-9806 端口段，详见 [PORTS.md](./PORTS.md)。

| 端口 | 用途 | 环境变量 |
|------|------|----------|
| 9800 | PHP 内置 server | `PHP_PORT` |
| 9801 | Lua HTTP server | `LUA_HTTP_PORT` |
| 9802 | Lua TCP server | `LUA_TCP_PORT` |
| 9803 | 并发测试 Lua HTTP | `CONCURRENT_LUA_HTTP_PORT` |
| 9804 | 并发测试 Lua TCP | `CONCURRENT_LUA_TCP_PORT` |
