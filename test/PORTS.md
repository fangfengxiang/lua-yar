# 测试端口分配策略

> 端口按 CI job 分段递增分配，同 job 内不复用，跨 job 可重复（独立 runner）。
>
> 设计原则：不杀别人的端口、占用则等待 5 秒、避开常见软件端口。
>
> 最后更新：2026-07-19

---

## 分配策略

### 核心原则

1. **按 CI job 分段**：每个 job 从 base port 开始递增，同 job 内每个测试用唯一端口
2. **跨 job 可重复**：不同 job 在独立 runner 上运行，端口互不影响
3. **不杀别人的端口**：只清理自己启动的进程（nginx prefix / PID 文件），端口被占用时等待 5 秒
4. **避开常见软件端口**：9100 (Prometheus)、9200/9300 (Elasticsearch)、9090、9042 (Cassandra) 等
5. **env 可覆盖**：脚本通过环境变量接受端口，CI workflow 按 job 设置

### 端口段分配

| CI Job | Base | 范围 | 用途 |
|--------|------|------|------|
| `test` | 9600 | 9600-9609 | Lua 多版本矩阵（benchmark） |
| `openresty` | 9700 | 9700-9729 | OpenResty E2E + 并发测试 |
| `interop` | 9800 | 9800-9819 | PHP ↔ Lua 互操作 + 并发测试 |

---

## `test` job（9600-9609）

| 端口 | 用途 | 文件 | 环境变量 |
|------|------|------|----------|
| 9600 | bench_server（luasocket TCP, keepalive） | `bench_server.lua` `benchmark_cosocket.lua` `benchmark_matrix.lua` | `BENCH_SERVER_PORT` |

---

## `openresty` job（9700-9729）

| 端口 | 用途 | 文件 | 环境变量 |
|------|------|------|----------|
| 9700 | E2E cosocket TCP round-trip server | `openresty_e2e_test.lua` | — |
| 9701 | E2E keepalive mode server | `openresty_e2e_test.lua` | — |
| 9702 | HTTP E2E nginx（content_by_lua） | `openresty_http_e2e.sh` `nginx.conf` | `HTTP_E2E_PORT` |
| 9703 | FI: slow server（latency injection） | `openresty_e2e_test.lua` | — |
| 9704 | FI: garbage bytes（脏数据注入） | `openresty_e2e_test.lua` | — |
| 9705 | FI: mid-transaction kill（中断连） | `openresty_e2e_test.lua` | — |
| 9706 | FI: pool exhaustion（连接池耗尽） | `openresty_e2e_test.lua` | — |
| 9707 | 并发测试 OpenResty HTTP（nginx 2 workers） | `concurrent_openresty.sh` | `CONCURRENT_HTTP_PORT` |
| 9708 | 并发测试 OpenResty TCP（nginx stream 2 workers） | `concurrent_openresty.sh` | `CONCURRENT_TCP_PORT` |
| 9709-9711 | mock client URL（无真实 server，mock socket 测试） | `openresty_e2e_test.lua` | — |

---

## `interop` job（9800-9819）

| 端口 | 用途 | 文件 | 环境变量 |
|------|------|------|----------|
| 9800 | PHP 内置 server（互操作） | `interop.sh` `server.php` | `PHP_PORT` |
| 9801 | Lua 原生 HTTP server（互操作） | `interop.sh` `interop_lua_server.lua` | `LUA_HTTP_PORT` |
| 9802 | Lua 原生 TCP server（互操作） | `interop.sh` `interop_lua_tcp_server.lua` | `LUA_TCP_PORT` |
| 9803 | 并发测试 Lua HTTP server | `concurrent_e2e.sh` | `CONCURRENT_LUA_HTTP_PORT` |
| 9804 | 并发测试 Lua TCP server | `concurrent_e2e.sh` | `CONCURRENT_LUA_TCP_PORT` |
| 9805 | 并发测试 OpenResty HTTP（via concurrent_openresty.sh） | `concurrent_e2e.sh` → `concurrent_openresty.sh` | `CONCURRENT_HTTP_PORT` |
| 9806 | 并发测试 OpenResty TCP（via concurrent_openresty.sh） | `concurrent_e2e.sh` → `concurrent_openresty.sh` | `CONCURRENT_TCP_PORT` |

---

## 环境变量传递链

```
CI workflow (per-job env)
  └─ shell script (reads env, passes to subprocess)
       ├─ Lua server: lua test/interop_lua_server.lua "$PORT"
       ├─ PHP client: getenv("LUA_HTTP_PORT")
       └─ nginx.conf: listen 127.0.0.1:$PORT (heredoc 替换)
```

### CI workflow 设置示例

```yaml
# .github/workflows/test.yml
interop:
  env:
    PHP_PORT: 9800
    LUA_HTTP_PORT: 9801
    LUA_TCP_PORT: 9802
    CONCURRENT_LUA_HTTP_PORT: 9803
    CONCURRENT_LUA_TCP_PORT: 9804
    CONCURRENT_HTTP_PORT: 9805
    CONCURRENT_TCP_PORT: 9806

openresty:
  env:
    HTTP_E2E_PORT: 9702
    CONCURRENT_HTTP_PORT: 9707
    CONCURRENT_TCP_PORT: 9708

test:
  env:
    BENCH_SERVER_PORT: 9600
```

---

## 防冲突机制

### 1. 端口占用检测 + 等待（test_helpers.sh）

```bash
wait_port_free <port>   # 端口被占用时等待最多 5 秒，超时则报错退出
```

脚本启动 server 前调用 `wait_port_free`，不杀别人的进程。

### 2. 自身进程清理

- **nginx**：按 prefix 停止（`cleanup_nginx "$prefix"`），不影响其他 nginx 实例
- **Lua/PHP server**：按 PID 文件停止（`cleanup_pidfile`），只杀自己启动的进程
- **trap EXIT**：脚本退出时自动清理

### 3. 串行执行

CI job 内步骤串行执行，不并行启动多个 server。同 job 内每个测试用唯一端口（递增），不复用。

---

## 新增测试端口指南

1. 确定测试属于哪个 CI job
2. 查此表找到该 job 的下一个未用端口
3. 在脚本中用环境变量（带默认值）引用端口
4. 更新此表
5. 若 CI workflow 需要覆盖默认值，在 workflow env 中设置
