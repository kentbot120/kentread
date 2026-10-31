-- 可直接使用插件菜单里的扫码配置；也可复制为 config.lua 后通过 USB 填写。
-- 任何 OpenAI 兼容接口都可以。扫码保存后，地址、密钥、模型优先使用扫码配置。
-- max_tokens / extra 仍从此文件（或 config.lua）读取。
return {
    base_url = "https://api.deepseek.com",
    api_key = "",
    model = "deepseek-flash",
    -- 联网搜索固定请求官方 DeepSeek Search。主接口不是官方 DeepSeek 时，需单独填写。
    -- search_api_key = "",
    -- 原样并入请求体。DeepSeek 的思考模式参数，换别家接口时删掉。
    extra = { thinking = { type = "enabled" }, reasoning_effort = "high" },
    -- 输出上限。文档没说思考过程算不算在内，所以给足；deepseek-flash 最多 384K。
    max_tokens = 65536,
}
