-- yar/message/request.lua
-- Yar 请求：{id, method, params, provider, token}
-- 请求体打包为 {i=id, m=method, p=params}

local math = math
local type, error, string, tostring, tonumber, os, setmetatable =
    type, error, string, tostring, tonumber, os, setmetatable

---@class Request
---@field id number Transaction ID
---@field method string Remote method name
---@field params table Parameters array
---@field provider string Request source
---@field token string Auth token
local _M = {}
_M.__index = _M

-- 散列常数（Knuth 乘法散列变体，纯数学兼容 Lua 5.1 无位运算）。
-- 说明：Lua 5.1 无语言级位运算符（& | ~ <<），bit 模块仅 LuaJIT 可用且非标配；
--       乘法散列常数为奇素数（非 2 的幂），无法用移位替代，必须算术乘法；
--       2^32 取模在 double 上即 % UINT32_MOD，与位运算 & 0xFFFFFFFF 等价且无精度损失。
local UINT16_MOD      = 0x10000      -- 2^16，uint16 取模基数（地址取模与 rand 进位共用）
local UINT32_MOD      = 0x100000000  -- 2^32，uint32 取模基数
local TIME_HASH_MOD   = 100000       -- 时间戳取模基数，限制参与散列的时间位
local TIME_HASH_MULT  = 1000003      -- 乘法散列常数（素数，分散时间位）
local ADDR_HASH_MULT  = 0x10001      -- 2^16+1，地址乘法散列常数
local RAND_SCALE      = 0x10000      -- math.random() 浮点映射基数（2^16）

-- 进程级表地址（tostring({}) 形如 "table: 0x7f8a5b0c1234"），模块加载时解析一次。
-- 跨进程差异源：未播种的 math.random 是确定性序列，不能用于跨 worker 随机偏移；
-- 业界惯例（Snowflake worker_id / MongoDB ObjectId 的 hostname+pid）靠确定性标识区分节点，
-- 纯 Lua 下 tostring({}) 表地址是唯一可靠的跨进程差异源，加载时固定即可，无需每次调用重取。
local process_addr = tonumber(string.match(tostring({}), "0x(%x+)"), 16) or 0

-- 进程内单调递增计数器，保证同进程内 ID 不重复。起点用表地址错开多 worker。
local sequence = process_addr % UINT16_MOD

-- 默认事务 ID 生成器。
-- ════════════════════════════════════════════════════════════════════════════
-- 设计说明（有意为之，非疏漏）：
--
-- 本库不调用 math.randomseed 播种。理由：math.randomseed 是进程级全局副作用，
-- 库无法安全管理其生命周期（宿主可能已播种，库的播种会覆盖之；多 worker 下各 worker
-- 独立播种又会相互覆盖）。业界惯例（uuid.lua / lua-resty-uuid）均不由库播种。
--
-- 熵源：os.time（秒级时间）+ sequence（进程内单调递增，起点带地址偏移）+ 表地址（跨进程区分）+
--       math.random（沿用宿主当前随机状态，不播种）。
--
-- 冲突概率分析：
--   - 进程内：sequence 单调递增，保证零冲突。
--   - 跨进程：process_addr（tostring({}) 表地址，ASLR 下每进程不同）+ sequence 起点偏移
--     提供区分。未播种时 math.random 是确定性序列，rand 分量不提供跨进程熵，
--     但其他熵源已将冲突概率压到极低。
--   - 这是有意设计：事务 ID 仅用于单次请求-响应匹配（uint32），不是全局唯一 ID。
--     极小概率冲突在实际 RPC 场景中可接受——YAR 是同步请求-响应模型，不靠 ID 匹配响应。
--
-- 与 PHP Yar / yar-c 对比：
--   - PHP Yar：request->id = (long)php_mt_rand()，单个随机数，PHP 运行时自动播种。
--   - yar-c：request->id = 1000（硬编码 dummy 值，未实现 ID 生成）。
--   - lua-yar（本库）：多熵源混合 + 进程内单调递增计数器，比两者都更健壮。
--
-- 生产环境追求更高随机性：调用 Yar.seed(fn) 播种，或 Yar.set_id_generator(fn) 注入
-- 基于 ngx.worker.pid 的生成器。详见 docs/design-rationale.md §6。
-- ════════════════════════════════════════════════════════════════════════════
-- rand 用 math.random() 无参版本（返回 [0,1) 浮点），跨平台一致性优于 math.random(0,0xFFFF)：
--   后者在 RAND_MAX=32767 平台会塌缩到 [0,32767]（上半区永远空）；无参版本为间隔分布，覆盖更分散。
local function default_gen_id()
    sequence = sequence + 1
    local time_now = os.time()
    local addr = process_addr
    local rand = math.floor(math.random() * RAND_SCALE) * UINT16_MOD
              + math.floor(math.random() * RAND_SCALE)
    local id = ((time_now % TIME_HASH_MOD) * TIME_HASH_MULT
              + (addr % UINT16_MOD) * ADDR_HASH_MULT
              + sequence
              + rand) % UINT32_MOD
    return id
end

-- 可注入的 ID 生成器，默认指向 default_gen_id
local id_generator = default_gen_id

--- Set the transaction ID generator (process-wide)
--- 注入后，库不再调用默认实现，彻底隔离宿主的 math.randomseed 状态。
--- 契约：注入者负责返回 [0, 0xFFFFFFFF] 范围数值，库不做范围校验（性能优先，
---       越界值由 Header.pack_u32 静默截断，可能产生 ID 不匹配，由注入者自负）。
--- OpenResty 多 worker 场景建议注入基于 ngx.worker.pid + ngx.time 的生成器。
---@param fn function|nil generator returning a uint32-range number; nil restores default
function _M.set_id_generator(fn)
    if fn ~= nil and type(fn) ~= "function" then
        error("set_id_generator: expected function or nil, got " .. type(fn), 2)
    end
    id_generator = fn or default_gen_id
end

--- Global seed function (process-wide, convenience API)
--- 业务层提供播种函数 fn，库调用 fn() 执行播种。
--- 这只是便利封装——等价于业务层直接调用 fn()。库永远不自动播种，仅在显式调用时执行。
--- OpenResty 中 math.randomseed 是进程级（per-worker VM），在 init_by_lua 阶段播种一次
--- 即对该 worker 的所有协程生效（协程共享同一 Lua VM 的全局随机状态）。
---@param fn function Seeding function (e.g., function() math.randomseed(os.time()) end)
function _M.seed(fn)
    if type(fn) ~= "function" then
        error("seed: expected function, got " .. type(fn), 2)
    end
    fn()
end

--- Generate transaction ID (uint32 range)
--- 默认实现不调用 math.randomseed，避免污染宿主全局随机状态。
--- 极小概率冲突是有意设计（见 default_gen_id 注释），生产环境可调用 Yar.seed(fn) 播种。
---@return number
function _M.gen_id()
    return id_generator()
end

--- Construct a request
---@param t table {method=, params=, provider=, token=, id=}
---@return Request
function _M.new(t)
    t = t or {}
    setmetatable(t, _M)
    t.id       = t.id or _M.gen_id()
    t.method   = t.method or ""
    t.params   = t.params or {}
    t.provider = t.provider or ""
    t.token    = t.token or ""
    return t
end

--- Pack into request body table {i, m, p}
---@return table
function _M:pack_body()
    return {
        i = self.id,
        m = self.method,
        p = self.params,
    }
end

return _M
