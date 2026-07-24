-- example/client.lua
-- 客户端示例：演示 HTTP / TCP 两种调用方式

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar = require("yar")
local Client = Yar.client

-- 1. 调用 HTTP Yar Server（PHP 或 Lua 实现）
local http_client = Client.new("http://127.0.0.1:8888/api")
http_client:setopt("timeout", 3000)

local ret, err = http_client:call("add", {1, 2})
print("[HTTP] add(1, 2) =>", ret, err)

local greet = http_client:call("greet", {"world"})
print("[HTTP] greet('world') =>", greet)

-- 2. 调用 TCP Yar Server（yar-c 风格）
local tcp_client = Client.new("tcp://127.0.0.1:9999")
local ret2 = tcp_client:call("add", {10, 20})
print("[TCP]  add(10, 20) =>", ret2)
