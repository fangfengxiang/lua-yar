# test/openresty/Dockerfile
# OpenResty 测试环境：OpenResty + Lua 5.1 + PHP 8.2 + yar/msgpack/pcntl 扩展
#
# 用途：免去开发者本地安装 OpenResty/PHP/yar 扩展的门槛，一条命令跑完整 OpenResty 测试
#
# 构建：docker build -t lua-yar-openresty test/openresty/
# 运行：docker run --rm -v "$(pwd):/app" -w /app lua-yar-openresty bash test/openresty/concurrent_openresty.sh
# 便捷：bash test/openresty/docker.sh

# --platform=linux/amd64: OpenResty APT repo 仅提供 i386/amd64 包（无 arm64）。
# CI（ubuntu-latest = amd64）原生运行；Apple Silicon 通过 Rosetta 模拟。
FROM --platform=linux/amd64 php:8.2-cli-bookworm

# 换用国内 Debian 镜像源（避免 deb.debian.org 502/超时）
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true

# OpenResty apt 源（Debian）
RUN apt-get update && apt-get install -y --no-install-recommends wget gnupg \
    && wget -qO - https://openresty.org/package/pubkey.gpg \
       | gpg --dearmor -o /usr/share/keyrings/openresty-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/openresty-archive-keyring.gpg] http://openresty.org/package/debian $(. /etc/os-release && echo $VERSION_CODENAME) openresty" \
       > /etc/apt/sources.list.d/openresty.list \
    && rm -rf /var/lib/apt/lists/*

# OpenResty + Lua 5.1 + luasocket + 系统工具
# liblua5.1-0-dev: Lua 5.1 头文件（luarocks 编译 C rocks 必需，Debian 放 /usr/include/lua5.1/）
# libcurl4-openssl-dev: yar --with-curl 编译 HTTP 传输层必需
RUN apt-get update && apt-get install -y --no-install-recommends \
    openresty \
    openresty-opm \
    lua5.1 \
    liblua5.1-0-dev \
    lua5.1-socket \
    git \
    curl \
    lsof \
    build-essential \
    autoconf \
    libcurl4-openssl-dev \
    && ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
    && rm -rf /var/lib/apt/lists/*

# OpenResty bin 加入 PATH（提前到此处：opm 命令在后续步骤中需要可用）
ENV PATH="/usr/local/openresty/bin:${PATH}"

# LuaRocks + luacov + lua-resty-http
# 不用 luarocks install（依赖 luarocks.org，CI 下网络不稳定）。
# luacov: git clone + luarocks make（对标 test.yml mediator_lua 做法，从 GitHub 拉）
# lua-resty-http: opm get（OpenResty 官方包管理器，从 GitHub 拉）
# Debian 的 liblua5.1-0-dev 头文件在 /usr/include/lua5.1/，luarocks 3.8 不查此路径，
# 用 luarocks config 显式设置 LUA_INCDIR（写入 ~/.luarocks/config-5.1.lua）。
RUN apt-get update && apt-get install -y --no-install-recommends luarocks \
    && mkdir -p /root/.luarocks \
    && luarocks --lua-version 5.1 config variables.LUA_INCDIR /usr/include/lua5.1 \
    && mkdir -p /usr/local/share/lua/5.1 \
    && git clone --depth 1 https://github.com/hishamhm/datafile.git /tmp/datafile \
    && cp /tmp/datafile/datafile.lua /usr/local/share/lua/5.1/ \
    && cp -r /tmp/datafile/datafile /usr/local/share/lua/5.1/ \
    && rm -rf /tmp/datafile \
    && git clone --depth 1 https://github.com/keplerproject/luacov.git /tmp/luacov \
    && cd /tmp/luacov \
    && luarocks --lua-version 5.1 make --deps-mode=none \
    && cd /tmp \
    && rm -rf /tmp/luacov \
    && opm get ledgetech/lua-resty-http \
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
