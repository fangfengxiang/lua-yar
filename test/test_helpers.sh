#!/bin/bash
# test/test_helpers.sh
# 测试共享函数库：端口检查、自身进程清理
#
# 用法：source test/test_helpers.sh
#
# 设计原则：
#   1. 不杀别人的端口 — 只清理自己启动的进程（通过 PID 文件 / nginx prefix）
#   2. 端口被占用时等待 5 秒，超时则报错退出
#   3. 端口按 CI job 分段递增分配，同 job 内不复用（见 test/PORTS.md）
#
# 函数：
#   is_port_free <port>       — 检查端口是否空闲
#   wait_port_free <port>     — 等待端口释放（最多 5 秒），超时返回 1
#   cleanup_nginx <prefix>   — 停止自己启动的 nginx（按 prefix）
#   cleanup_pidfile <pidfile> — 按 PID 文件停止自己启动的进程

# 检查端口是否空闲
is_port_free() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -i:"$port" &>/dev/null && return 1 || return 0
    elif command -v ss &>/dev/null; then
        ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && return 1 || return 0
    elif command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | grep -q ":$port " && return 1 || return 0
    else
        # 无检测工具，假设空闲
        return 0
    fi
}

# 等待端口释放（最多 5 秒）
wait_port_free() {
    local port=$1
    local tries=0
    while [ $tries -lt 50 ]; do
        if is_port_free "$port"; then
            return 0
        fi
        if [ $tries -eq 0 ]; then
            echo "  [wait] port $port is occupied, waiting..."
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    echo "  [FAIL] port $port still occupied after 5s, aborting"
    return 1
}

# 停止自己启动的 nginx（按 prefix，不会影响其他 nginx 实例）
cleanup_nginx() {
    local prefix=$1
    local openresty="${OPENRESTY:-openresty}"
    if [ -x /usr/local/openresty/bin/openresty ]; then
        openresty="/usr/local/openresty/bin/openresty"
    fi
    # 只停止自己 prefix 的 nginx（pid 文件在 prefix 目录内）
    if [ -f "$prefix/nginx.pid" ]; then
        $openresty -p "$prefix" -s stop 2>/dev/null || true
    fi
}

# 按 PID 文件停止自己启动的进程
cleanup_pidfile() {
    local pidfile=$1
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null) || true
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.3
        fi
        rm -f "$pidfile"
    fi
}
