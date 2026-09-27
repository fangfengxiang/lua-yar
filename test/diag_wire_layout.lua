-- test/diag_wire_layout.lua
-- 字节级诊断：对比 lua-yar 和 PHP Yar 的 wire layout
--
-- 运行：lua test/diag_wire_layout.lua
-- 输出：lua-yar 渲染的消息前 90 字节 hex dump，标注各字段位置

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local Request   = require("yar.message.request")
local Protocol  = require("yar.protocol.protocol")
local Packager  = require("yar.packager.packager")
local Header    = require("yar.protocol.header")

-- hex dump 工具
local function hex_dump(data, label)
    print("\n=== " .. label .. " (" .. #data .. " bytes) ===")
    for i = 1, math.min(#data, 90), 16 do
        local hex_parts = {}
        local ascii_parts = {}
        for j = i, math.min(i + 15, #data) do
            local b = string.byte(data, j)
            hex_parts[#hex_parts + 1] = string.format("%02X", b)
            ascii_parts[#ascii_parts + 1] = (b >= 32 and b <= 126) and string.char(b) or "."
        end
        local offset_str = string.format("%04X", i - 1)
        local hex_str = table.concat(hex_parts, " ")
        -- pad hex_str to fixed width
        hex_str = hex_str .. string.rep(" ", 47 - #hex_str)
        local ascii_str = table.concat(ascii_parts)
        print(string.format("  %s  %s  |%s|", offset_str, hex_str, ascii_str))
    end
end

-- 字段标注
local function annotate_layout(layout_desc)
    print("\n--- Layout annotation ---")
    for _, field in ipairs(layout_desc) do
        print(string.format("  bytes %3d-%-3d (%2d bytes): %s", field.start, field["end"], field.size, field.name))
    end
end

-- ── 1. lua-yar wire layout ──────────────────────────────────

print("========================================")
print(" lua-yar wire layout diagnostic")
print("========================================")

local packager = Packager.get(Packager.JSON)
local request = Request.new({
    method = "add",
    params = { 10, 20 },
    provider = "LuaTest",
    token = "",
})

local message = Protocol.render(request, packager)
hex_dump(message, "lua-yar rendered message (full)")

annotate_layout({
    { name = "packager_name", start = 1,  ["end"] = 8,  size = 8  },
    { name = "  header.id",       start = 9,  ["end"] = 12, size = 4  },
    { name = "  header.version",  start = 13, ["end"] = 14, size = 2  },
    { name = "  header.magic_num", start = 15, ["end"] = 18, size = 4  },
    { name = "  header.reserved",  start = 19, ["end"] = 22, size = 4  },
    { name = "  header.provider",  start = 23, ["end"] = 54, size = 32 },
    { name = "  header.token",     start = 55, ["end"] = 86, size = 32 },
    { name = "  header.body_len",  start = 87, ["end"] = 90, size = 4  },
    { name = "body (payload)",    start = 91, ["end"] = 90 + #message - 90, size = #message - 90 },
})

-- 验证：读取 packager name 和 header 字段
local pkg_name = string.sub(message, 1, 8)
local header = Header.unpack(message, 9)
print("\n--- lua-yar parsed fields ---")
print(string.format("  packager_name: %q", pkg_name:gsub("%z", "\\0")))
print(string.format("  header.id:        %d", header.id))
print(string.format("  header.magic_num: 0x%08X (expected 0x%08X)", header.magic_num, Header.MAGIC_NUM))
print(string.format("  header.body_len:  %d (body only, NOT including packager name)", header.body_len))
print(string.format("  actual body len:  %d", #message - 90))
print(string.format("  body_len == body_len? %s", header.body_len == #message - 90 and "YES" or "NO"))
print(string.format("  body_len includes packager(8)? %s", header.body_len == #message - 90 + 8 and "YES" or "NO"))

-- ── 2. PHP Yar expected layout (from C source analysis) ────

print("\n========================================")
print(" PHP Yar wire layout (from C source)")
print("========================================")

print([[
  PHP Yar layout: [header:82][packager_name:8][body]

  Bytes  1-  4 ( 4): header.id
  Bytes  5-  6 ( 2): header.version
  Bytes  7- 10 ( 4): header.magic_num (0x80DFEC60)
  Bytes 11- 14 ( 4): header.reserved
  Bytes 15- 46 (32): header.provider
  Bytes 47- 78 (32): header.token
  Bytes 79- 82 ( 4): header.body_len = len(packager_name + body) = 8 + body_len
  Bytes 83- 90 ( 8): packager_name
  Bytes 91+      : body

  Key differences:
  1. Header FIRST (offset 0), packager name AFTER header (offset 82)
  2. body_len INCLUDES the 8-byte packager name

  Source evidence:
  - yar_protocol.c: php_yar_protocol_parse(payload) casts payload[0] as header directly
  - curl.c send:    append header(82) THEN append payload(packager_name+body)
  - curl.c recv:    parse header at offset 0, skip 82 bytes to reach packager+body
  - packager.c:     php_yar_packager_pack returns [packager_name:8][body]
                    php_yar_packager_unpack reads packager_name from first 8 bytes
  - body_len:        php_yar_protocol_render sets body_len = ZSTR_LEN(payload) = 8 + body_len
]])

print("\n========================================")
print(" COMPATIBILITY ANALYSIS")
print("========================================")

print([[
  lua-yar format:  [packager_name:8][header:82][body]   body_len = len(body)
  PHP Yar format:  [header:82][packager_name:8][body]   body_len = 8 + len(body)

  INCOMPATIBLE! The header and packager_name positions are swapped.

  Failure modes:
  - Lua client → PHP server:
    PHP response = [header:82][packager:8][body]
    lua-yar reads bytes 1-8 as packager_name → gets header.id+version bytes (garbage)
    lua-yar reads header at offset 9 → magic_num check reads PHP's provider field
    → "invalid magic number" error

  - PHP client → Lua server:
    Lua response = [packager:8][header:82][body]
    PHP reads header at offset 0 → gets "JSON\0\0\0\0" as header start
    PHP checks magic_num at offset 6 → gets null bytes from packager name padding
    → "malformed response header" error
]])
