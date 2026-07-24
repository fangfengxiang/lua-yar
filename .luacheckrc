-- luacheck 配置：Lua 5.1 兼容（项目目标 5.1 / LuaJIT / 5.3+）
-- 运行：luacheck src/yar/ test/ example/

std = "lua51"
max_line_length = 120

-- 忽略 self 和下划线前缀参数的未使用警告
-- luacheck 1.2.0 警告码：W421=变量遮蔽（shadowing），W143=访问全局未定义字段
ignore = { "212/self", "212/_.*", "421", "143/table" }

-- example 文件使用环境特定全局变量（ngx / eco / skynet）
globals = { "ngx", "eco", "skynet" }

-- 变量命名检查：显示所有警告码，便于定位
codes = true

-- 禁止隐式全局变量声明（捕获拼写错误 / 未声明的全局变量）
-- W143 = 访问未定义的全局字段（已在 ignore 中对 table 放宽）
-- 以下确保 new_global / undefined 等命名问题被捕获
no_unused = true

-- 文件级配置：test 文件允许定义局部 test 函数但不要求全部调用
files["test/"] = {
    ignore = { "212/self", "212/_.*", "421", "143/table", "311" },  -- 311 = value assigned but unused
    globals = { "ngx", "jit", "arg" },  -- 跨运行时探测 + resty CLI arg 全局表
}

-- 文件级配置：example 文件允许更多环境全局
files["example/"] = {
    globals = { "ngx", "eco", "skynet", "require" },
}
