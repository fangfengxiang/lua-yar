# test/e2e/Dockerfile
# E2E 测试环境：Lua 5.1 + luasocket + PHP 8.2 + yar/msgpack/pcntl 扩展
#
# 用途：免去开发者本地安装 Lua/PHP/yar 扩展的门槛，一条命令跑完整 E2E
#
# 构建：docker build -t lua-yar-e2e test/e2e/
# 运行：docker run --rm -v "$(pwd):/app" -w /app lua-yar-e2e bash test/e2e/interop.sh
# 便捷：bash test/e2e/docker.sh

FROM php:8.2-cli

# 换用国内 Debian 镜像源（避免 deb.debian.org 502/超时）
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true

# Lua 5.1 + luasocket + 系统工具
# libcurl4-openssl-dev: yar --with-curl 编译 HTTP 传输层必需
# lua5.1-socket 安装到 /usr/share/lua/5.1/socket/，在 Lua 5.1 默认搜索路径内
RUN apt-get update && apt-get install -y --no-install-recommends \
    lua5.1 \
    lua5.1-socket \
    git \
    curl \
    lsof \
    build-essential \
    autoconf \
    libcurl4-openssl-dev \
    && ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
    && rm -rf /var/lib/apt/lists/*

# PHP msgpack 扩展（yar 依赖，必须在 yar 之前安装）
RUN pecl install msgpack \
    && docker-php-ext-enable msgpack

# PHP yar 扩展（从 GitHub 源码编译）
# --enable-msgpack: 启用 Msgpack packager（默认 no，必须显式开启）
# --with-curl: 启用 HTTP 传输层（yar transports/curl.c，PHP 客户端 HTTP 必需）
RUN git clone --depth 1 https://github.com/laruence/yar.git /tmp/yar \
    && cd /tmp/yar \
    && phpize \
    && ./configure --enable-msgpack --with-curl \
    && make -j"$(nproc)" \
    && make install \
    && docker-php-ext-enable yar \
    && rm -rf /tmp/yar

# PHP pcntl 扩展（并发测试必需）
RUN docker-php-ext-install pcntl

WORKDIR /app
