# Performance Review — Code-Level Analysis

> Date: 2026-07-19  
> Scope: Static code review of all hot-path source files, cross-referenced with `performance-benchmark.md` runtime data.  
> Goal: Identify actionable optimization opportunities, ranked by impact-to-effort ratio.

---

## 1. Executive Summary

The project is **already well-optimized** for a pure-Lua RPC library. The existing benchmark report (`docs/reports/performance-benchmark.md`) establishes the runtime baseline:

| Metric | Value |
|--------|-------|
| Protocol parse+render share of pipeline | ~70% |
| Framing I/O share | ~15% |
| Dispatch share | ~3% |
| LuaJIT vs standard Lua speedup | 3.5–4.4× |
| C extension speedup on LuaJIT | 1.2–1.9× |
| C extension speedup on standard Lua | 1.4–1.9× |
| keepalive vs new-connection | 3.2× faster |

**Conclusion**: The codec layer (JSON/Msgpack encode+decode) is the dominant cost center at ~70% of the full pipeline. All other layers (framing, transport, dispatch) are already at or near optimal for pure-Lua implementations. The findings below focus on the codec layer, with diminishing-returns items noted for completeness.

**No critical performance bugs were found.** The findings are optimization opportunities, not defects.

---

## 2. Hot Path Analysis

The RPC hot path traverses these layers per call:

```
Client:call()
  ├─ Packager.get(name)          ← per-call registry lookup
  ├─ Protocol.render(request, packager)
  │   ├─ message:pack_body()     ← builds {i,m,p} / {i,s,r,o,e}
  │   ├─ packager.pack(body)     ← ★ CODEC ENCODE (~35% of pipeline)
  │   ├─ Header.new(...) + :pack()
  │   └─ name .. header .. payload  ← 3-way concat
  ├─ Transport.send(message)     ← I/O (network-bound)
  ├─ Protocol.parse(resp_data, packager)
  │   ├─ Header.unpack(data)
  │   ├─ string.sub(body)        ← body copy
  │   └─ packager.unpack(body)   ← ★ CODEC DECODE (~35% of pipeline)
  └─ Response.unpack(payload)
```

The two `★` items account for ~70% of CPU time. Everything else is I/O-bound or negligible.

---

## 3. Findings — Ranked by Impact

### Finding 1: JSON `encode_string` byte-by-byte loop (HIGH impact)

**Location**: `src/yar/packager/json.lua:50-67`

```lua
local function encode_string(s)
    local t = { '"' }
    for i = 1, #s do
        local b = string.byte(s, i)
        ...
        else                     t[#t + 1] = string.char(b)  -- per-byte allocation
    end
    t[#t + 1] = '"'
    return table.concat(t)
end
```

**Issue**: For strings without any special characters (the common case in RPC — method names, tokens, normal text), every byte is individually converted via `string.char(b)` and pushed into a table, then `table.concat`'d. A 100-byte string with no escapes creates 100 table entries and 100 `string.char` calls.

**Optimization**: Add a fast path — scan for special chars first; if none found, return `'"' .. s .. '"'` directly (single concatenation, zero per-byte allocation).

```lua
local function encode_string(s)
    -- Fast path: no chars needing escape
    if not s:find('[%c"\\]') then
        return '"' .. s .. '"'
    end
    -- Slow path: existing byte-by-byte logic
    local t = { '"' }
    ...
end
```

**Expected gain**: Significant for string-heavy payloads. The `string.find` with a pattern is a single C-level scan, far cheaper than per-byte Lua loop + table allocation. Benchmark data shows JSON encode is a major codec cost; this directly targets the hottest function within it.

**Risk**: Low. `string.find` pattern `[%c"\\]` matches control chars, double-quote, backslash — exactly the set the slow path handles. Semantically identical.

---

### Finding 2: JSON `parse_string` byte-by-byte loop (HIGH impact)

**Location**: `src/yar/packager/json.lua:155-201`

```lua
local function parse_string()
    pos = pos + 1
    local t = {}
    while pos <= len do
        local b = string.byte(str, pos)
        if b == 0x22 then ...
        elseif b == 0x5C then ...
        else
            t[#t + 1] = string.char(b)  -- per-byte allocation for normal chars
            pos = pos + 1
        end
    end
    ...
end
```

**Issue**: Same pattern as Finding 1, but in the decode direction. For strings without escapes, each byte is individually `string.char`'d and table-inserted.

**Optimization**: Fast path — find the closing `"` (and check for `\` before it); if no backslash exists before the closing quote, extract the substring directly via `string.sub`.

```lua
local function parse_string()
    local start = pos + 1  -- after opening "
    local next_quote = str:find('"', start)
    -- If no backslash before closing quote, fast path
    local next_backslash = str:find('\\', start)
    if next_backslash == nil or next_backslash > next_quote then
        pos = next_quote + 1
        return str:sub(start, next_quote - 1)
    end
    -- Slow path: existing escape-handling logic
    ...
end
```

**Expected gain**: High — decode is the other half of the ~70% codec cost. Most JSON strings in RPC (method names, params, tokens) have no escape sequences.

**Risk**: Low. The fast path condition (`no backslash before closing quote`) is semantically equivalent to "no escapes to process". Edge case: escaped quote `\"` — handled by checking backslash position vs closing quote position.

---

### Finding 3: Array detection double-pass (MEDIUM impact)

**Location**: `src/yar/packager/json.lua:81-109`, `src/yar/packager/msgpack.lua:144-191`

```lua
local function encode_table(t)
    ...
    local n, count = 0, 0
    local is_array = true
    for k in pairs(t) do           -- Pass 1: detect array-ness
        count = count + 1
        ...
    end
    if is_array and count == n then
        for i = 1, n do             -- Pass 2: encode
            parts[i] = encode(t[i])
        end
    end
end
```

**Issue**: Both JSON and Msgpack traverse the table twice: once to detect if it's a sequential array, once to encode. For arrays (the common RPC case — params is always an array), this is 2× traversal.

**Optimization options**:
1. **Acceptable as-is**: The double-pass is the standard pure-Lua approach (dkjson, lua-cjson's pure-Lua fallback both do this). The detection pass is key-only (`for k in pairs(t)`), which is cheaper than value encoding.
2. **Alternative**: Use `#t` (Lua length operator) as a fast array hint. If `#t > 0` and `t[#t] ~= nil and t[#t+1] == nil`, treat as array without full scan. But `#t` is O(log n) and has undefined behavior with holes — risky for correctness.

**Recommendation**: **Leave as-is.** The detection pass is lightweight (key-only iteration, no encoding). The double-pass overhead is small compared to the encoding pass itself. Optimizing this risks introducing array/map misclassification bugs. The existing benchmark data confirms codec time is dominated by string encoding (Findings 1 & 2), not table traversal.

---

### Finding 4: `Protocol.render` 3-way concatenation (LOW impact)

**Location**: `src/yar/protocol/protocol.lua:30`

```lua
return packager_name .. header:pack() .. payload
```

**Issue**: Three-way `..` concatenation. For large payloads (e.g., 1MB body), this creates an intermediate string of `packager_name + header` (90 bytes) then concatenates with the full payload, effectively copying the payload twice.

**Optimization**: Use `table.concat`:

```lua
return table.concat({ packager_name, header:pack(), payload })
```

**Expected gain**: Minimal. `table.concat` with 3 elements has table-allocation overhead that may negate the benefit. Lua's `..` is optimized for small numbers of operands. For large payloads, the single `..` chain is already efficient because Lua 5.1/LuaJIT's `..` avoids intermediate copies when chaining (the VM batches consecutive `..` operations).

**Recommendation**: **Leave as-is.** The 90-byte prefix is negligible compared to any real payload. Not worth the code complexity.

---

### Finding 5: `Packager.get()` per-call lookup (LOW impact)

**Location**: `src/yar/client.lua:202`, `src/yar/packager/packager.lua:56-63`

```lua
-- client.lua:202 — called per RPC
local packager, packager_err = Packager.get(proto.packager)

-- packager.lua:56-63
function _M.get(name)
    name = (name and string.upper(name)) or _M.JSON
    local p = registry[name]
    ...
end
```

**Issue**: Every `Client:call()` does `string.upper(name)` + table lookup. The packager name rarely changes between calls on the same client instance.

**Optimization**: Cache the resolved packager on the client instance, invalidate on `set_options` when `protocol.packager` changes.

**Expected gain**: Negligible. `string.upper` on an 8-byte string + one table lookup is ~nanoseconds. The codec layer (70% of pipeline) dwarfs this by 3+ orders of magnitude.

**Recommendation**: **Leave as-is.** Adds state-management complexity (cache invalidation) for unmeasurable gain. Violates the project's "simple, readable" principle.

---

### Finding 6: `Header:pack()` 7-way concatenation (LOW impact)

**Location**: `src/yar/protocol/header.lua:45-53`

```lua
function _M:pack()
    return Util.pack_u32(self.id)
        .. Util.pack_u16(self.version)
        .. Util.pack_u32(self.magic_num)
        .. Util.pack_u32(self.reserved)
        .. Util.pad_field(self.provider, 32)
        .. Util.pad_field(self.token, 32)
        .. Util.pack_u32(self.body_len)
end
```

**Issue**: 7 `..` concatenations producing an 82-byte string.

**Optimization**: `table.concat` with a pre-allocated table.

**Expected gain**: Negligible. 82 bytes total, 7 segments. LuaJIT's `..` chaining is optimized. The header pack runs once per RPC — even a 2× improvement here saves nanoseconds against the ~70% codec cost.

**Recommendation**: **Leave as-is.** Not worth the readability trade-off.

---

### Finding 7: `pcall` in hot path (NECESSARY, not an issue)

**Location**: `src/yar/client.lua:213, 257`

```lua
local render_ok, message = pcall(Protocol.render, request, packager)
...
local parse_ok, payload, _, perr = pcall(Protocol.parse, resp_data, packager)
```

**Analysis**: `pcall` has measurable overhead (~30-50ns per call on LuaJIT). However, these are **necessary** — `packager.pack`/`unpack` can throw on malformed input (deeply nested JSON, invalid msgpack), and uncaught errors would crash the client. The error-layering design (ADR #33) requires `client:call()` to catch and classify these into `Error.PROTOCOL` objects.

**Recommendation**: **Keep.** Correctness > micro-optimization. The pcall overhead is dwarfed by the codec work inside it.

---

### Finding 8: Msgpack `pack_double` manual bit manipulation (LOW impact)

**Location**: `src/yar/packager/msgpack.lua:74-95`

```lua
local function pack_double(n)
    ...
    local mant, exp = math.frexp(n)
    local biased = exp - 1 + 1023
    local frac = (mant * 2 - 1) * (2 ^ 52)
    local hi = sign * 0x80000000 + biased * 0x100000 + math.floor(frac / 0x100000000)
    local lo = frac % 0x100000000
    return string.char(0xcb) .. Util.pack_u32(hi) .. Util.pack_u32(lo)
end
```

**Issue**: Manual IEEE754 double encoding via `math.frexp` + arithmetic. On Lua 5.3+, `string.pack(">d", n)` would be a single C call. On LuaJIT, `math.frexp` is not JIT-compiled (it's a C function), creating a trace exit.

**Optimization**: Version-gated fast path for Lua 5.3+:

```lua
local pack_double
if string.pack then
    pack_double = function(n)
        return string.char(0xcb) .. string.pack(">d", n)
    end
else
    -- existing manual implementation
end
```

**Expected gain**: Low. Floats are rare in RPC payloads (most numbers are integer IDs, counts, status codes). The integer fast paths (`encode_number` lines 101-127) already handle the common cases efficiently.

**Recommendation**: **Optional.** Low ROI given float rarity. If implemented, must be version-gated (LuaJIT has no `string.pack`).

---

## 4. Summary Table

| # | Finding | Location | Impact | Action |
|---|---------|----------|--------|--------|
| 1 | JSON `encode_string` byte loop | `json.lua:50-67` | HIGH | **Optimize** — add fast path |
| 2 | JSON `parse_string` byte loop | `json.lua:155-201` | HIGH | **Optimize** — add fast path |
| 3 | Array detection double-pass | `json.lua:81`, `msgpack.lua:144` | MEDIUM | Leave as-is |
| 4 | `Protocol.render` 3-way concat | `protocol.lua:30` | LOW | Leave as-is |
| 5 | `Packager.get()` per-call | `client.lua:202` | LOW | Leave as-is |
| 6 | `Header:pack()` 7-way concat | `header.lua:45-53` | LOW | Leave as-is |
| 7 | `pcall` in hot path | `client.lua:213,257` | — | Keep (necessary) |
| 8 | Msgpack `pack_double` manual | `msgpack.lua:74-95` | LOW | Optional |

---

## 5. Recommendations

### Immediate (high ROI)

1. **Implement Finding 1 & 2** (JSON string fast paths). These are the only two changes with measurable impact, targeting the ~70% codec cost center. Both are low-risk, semantically identical fast paths with `string.find`/`string.sub` C-level operations replacing per-byte Lua loops.

### Already optimal (no action needed)

- **Framing** (`framing.lua`): `receive_exact` loop + `table.concat` is the standard TCP pattern. No improvement possible without C extensions.
- **Transport** (`tcp.lua`, `http.lua`): Connection pooling (persistent mode) already implemented. keepalive benchmark confirms 3.2× gain.
- **Header pack/unpack** (`header.lua`, `util.lua`): Pure-math byte operations, no `string.pack` dependency (LuaJIT-compatible). Already optimal for Lua 5.1/LuaJIT.
- **Client hot path** (`client.lua`): `deep_copy` in constructor (not hot path), `pcall` protection (necessary), `Packager.get` lookup (negligible).

### Already documented (in benchmark report)

- **C extensions** (cjson/cmsgpack): 1.2–1.9× speedup available via `Packager.register`. The project already supports this opt-in acceleration. No code change needed — users register C extensions for production workloads.
- **LuaJIT**: 3.5–4.4× over standard Lua. Deployment recommendation, not a code issue.

---

## 6. Conclusion

The lua-yar codebase is **performance-mature**. The architecture correctly concentrates optimization budget on the codec layer (the 70% cost center), and the existing C-extension opt-in path (`Packager.register`) provides a production-grade acceleration route without forcing C dependencies.

The only actionable code-level optimizations are **Finding 1 and Finding 2** — adding fast paths to JSON string encode/decode. All other findings are either negligible, necessary, or already at the optimal pure-Lua approach.
