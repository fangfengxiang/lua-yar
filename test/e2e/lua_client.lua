-- test/e2e/lua_client.lua
-- E2E 测试共享 Lua 客户端：调用 add(a,b)，断言 a+b=c
--
-- 用法：lua test/e2e/lua_client.lua <url> <packager>
--   url:      服务端地址（http://... 或 tcp://...）
--   packager: "json" 或 "msgpack"
--
-- 测试用例（每组 packager 都跑）：
--   add(10, 20)    = 30
--   add(100, 200)  = 300
--   add(1, 2)      = 3
--   add(0, 0)      = 0
--
-- 退出码：0=全部通过，1=有失败

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Yar      = require("yar")
local Client   = Yar.client
local Packager = require("yar.packager.packager")

local url      = arg[1] or error("usage: lua_client.lua <url> <packager>", 0)
local pkg_name = arg[2] or error("usage: lua_client.lua <url> <packager>", 0)

local pkg = (pkg_name == "msgpack") and Packager.MSGPACK or Packager.JSON

local cases = {
    { 10,  20,  30  },
    { 100, 200, 300 },
    { 1,   2,   3   },
    { 0,   0,   0   },
}

local pass, fail = 0, 0

local client = Client.new(url)
client:setopt("packager", pkg)

for _, c in ipairs(cases) do
    local a, b, expect = c[1], c[2], c[3]
    local r, err = client:call("add", { a, b })
    if r == nil then
        print(string.format("  [FAIL] %s add(%d,%d): err=%s", pkg_name, a, b, tostring(err)))
        fail = fail + 1
    elseif r ~= expect then
        print(string.format("  [FAIL] %s add(%d,%d): expected %d, got %s", pkg_name, a, b, expect, tostring(r)))
        fail = fail + 1
    else
        pass = pass + 1
    end
end

print(string.format("  [%s] %s add: %d passed, %d failed", fail == 0 and "OK" or "FAIL", pkg_name, pass, fail))
if fail > 0 then os.exit(1) end
