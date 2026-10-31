-- DeepSeek's Search tool returns source documents, not a model-written answer.
local sha256 = require("ffi/sha2").sha256
local M = { ENDPOINT = "/v1/tools/search", COUNT = 5 }

function M.query(text)
    if type(text) ~= "string" then return nil, "请输入搜索词。" end
    text = text:gsub("\194[\133\160]", " "):gsub("\225\154\128", " ")
        :gsub("\226\128[\128-\138\168\169\175]", " "):gsub("\226\129\159", " ")
        :gsub("\227\128\128", " "):gsub("[ \t\r\n\v\f]+", " "):match("^ *(.-) *$")
    if text == "" then return nil, "请输入搜索词。" end
    local i, count = 1, 0
    while i <= #text do
        local b = text:byte(i)
        local size = b < 128 and 1 or (b >= 194 and b <= 223 and 2)
            or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4)
        if not size or b < 32 or b == 127 then return nil, "搜索词包含无效字符。" end
        for j = i + 1, i + size - 1 do
            local c = text:byte(j)
            if not c or c < 128 or c > 191 then return nil, "搜索词不是有效的 UTF-8 文本。" end
        end
        local second = text:byte(i + 1) or 0
        if (b == 224 and second < 160) or (b == 237 and second > 159)
            or (b == 240 and second < 144) or (b == 244 and second > 143) then
            return nil, "搜索词不是有效的 UTF-8 文本。"
        end
        i, count = i + size, count + 1
        if count > 128 then return nil, "DeepSeek 搜索词最多 128 个字符，请精简后重试。" end
    end
    return text
end

function M.id(query) return "search/" .. sha256(query) end

function M.payload(query)
    return { query = query, count = M.COUNT, need_content = false }
end

function M.safeURL(url)
    if type(url) ~= "string" or url:find('[%z\1-\32\127"<>\\]') then return end
    local scheme, authority = url:match("^([%a]+)://([^/?#]+)")
    if not scheme or (scheme:lower() ~= "https" and scheme:lower() ~= "http")
        or authority:find("@", 1, true) then return end
    return url
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function stringField(value)
    return type(value) == "string" and value or ""
end

function M.waiting(query)
    return "<h1>" .. escape(query) .. "</h1><p>正在通过 DeepSeek 联网搜索…</p>"
        .. "<p>可以先关掉弹窗继续阅读，完成后会提示。</p>"
end

function M.render(payload, query)
    if type(payload) ~= "table" or type(payload.results) ~= "table" then
        return nil, "DeepSeek 搜索响应缺少 results 列表。"
    end
    local out = { "<h1>" .. escape(query) .. "</h1>",
        "<p>来源：DeepSeek Search。以下为搜索接口返回的网页摘要，未调用聊天模型生成答案。</p>",
        "<p>搜索时间（设备时间）：" .. os.date("%Y-%m-%d %H:%M") .. "</p>" }
    local count = 0
    for _, item in ipairs(payload.results) do
        if type(item) == "table" then
            count = count + 1
            local title = stringField(item.title)
            if title == "" then title = "未命名网页" end
            local url = M.safeURL(item.url)
            local heading = tostring(count) .. ". " .. escape(title)
            out[#out + 1] = "<h1>" .. (url and ('<a href="' .. escape(url) .. '">' .. heading .. '</a>') or heading) .. "</h1>"
            local site = stringField(item.site_name)
            local date = stringField(item.date):match("^%d%d%d%d%-%d%d%-%d%d") or ""
            if site ~= "" or date ~= "" then
                out[#out + 1] = "<p>" .. escape(site) .. (site ~= "" and date ~= "" and " · " or "") .. date .. "</p>"
            end
            local snippet = stringField(item.snippet)
            if snippet == "" then snippet = stringField(item.summary) end
            if snippet ~= "" then out[#out + 1] = "<p>" .. escape(snippet) .. "</p>" end
            if url then out[#out + 1] = '<p><a href="' .. escape(url) .. '">' .. escape(url) .. '</a></p>' end
            if count >= M.COUNT then break end
        end
    end
    if count == 0 then out[#out + 1] = "<p>没有找到匹配结果。可调整搜索词后重新搜索。</p>" end
    out[#out + 1] = "<p>网页内容可能不准确或已经过时，请核对来源。点击链接可使用 KOReader 的外链菜单打开、复制或显示二维码。</p>"
    return table.concat(out, "\n")
end

return M
