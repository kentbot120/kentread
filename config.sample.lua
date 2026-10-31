-- 复制为 config.lua 后填写。任何 OpenAI 兼容接口都可以。
return {
    base_url = "https://api.deepseek.com",
    api_key = "",
    model = "deepseek-flash",
    -- 原样并入请求体。DeepSeek 的思考模式参数，换别家接口时删掉。
    extra = { thinking = { type = "enabled" }, reasoning_effort = "high" },
    -- 输出上限。文档没说思考过程算不算在内，所以给足；deepseek-flash 最多 384K。
    max_tokens = 65536,
}
