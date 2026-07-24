-- yar/server/constants.lua
-- Server 层共享常量（叶子模块，零依赖，无循环风险）。
-- 参考 lua-resty-http 的 resty.http_const 模式与 transport/constants.lua 一致：
-- 包内共享常量集中到叶子模块，各 server 子模块（dispatcher/tcp/http）按需引用。

local _M = {}

_M.DEFAULT_TIMEOUT      = 5000        -- 服务端默认处理超时（ms）
_M.DEFAULT_MAX_BODY_LEN = 1024 * 1024 -- 服务端默认最大 body 长度（1MB，对齐 nginx client_max_body_size 默认）
_M.MAX_HEADER_COUNT     = 100         -- HTTP 请求头数量上限（防止 header 泛洪攻击，对齐 nginx large_client_header_buffers 默认行为）
_M.MAX_ACCEPT_FAILURES  = 10          -- accept 连续失败上限（防止 accept 异常时无限重试，达到阈值后放弃循环）

return _M
