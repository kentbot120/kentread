-- One selected passage and the original text around it, for an AI lookup.
local sha256 = require("ffi/sha2").sha256
-- 900 bytes is about 300 Chinese characters or 150 English words per side.
local M = { MAX_CHARS = 1000, CONTEXT_WORDS = 300, CONTEXT_BYTES = 900 }

function M.text(text)
    -- ASCII only: locale-dependent %s can match UTF-8 continuation bytes on some devices.
    text = type(text) == "string" and text:match("^[ \t\r\n\v\f]*(.-)[ \t\r\n\v\f]*$") or ""
    if text == "" then return nil, "请先选中要解释的文字。" end
    if select(2, text:gsub("[^\128-\191]", "")) > M.MAX_CHARS then
        return nil, "选中的文字超过 " .. M.MAX_CHARS .. " 字，请缩短后再试。"
    end
    return text
end

function M.id(text) return "explain/" .. sha256(text) end

local function isContinuation(byte) return byte and byte >= 128 and byte <= 191 end

--- Caps each side on a UTF-8 boundary: before keeps its end, after keeps its start.
function M.context(before, after)
    before, after = before or "", after or ""
    local from = math.max(#before - M.CONTEXT_BYTES + 1, 1)
    while isContinuation(before:byte(from)) do from = from + 1 end
    local to = math.min(#after, M.CONTEXT_BYTES)
    while to > 0 and isContinuation(after:byte(to + 1)) do to = to - 1 end
    return before:sub(from), after:sub(1, to)
end

function M.short(text)
    local count = 0
    for pos in text:gmatch("()[^\128-\191]") do
        count = count + 1
        if count > 16 then return text:sub(1, pos - 1) .. "…" end
    end
    return text
end

function M.message(t)
    local head = "书名：《" .. t.title .. "》\n作者：" .. t.author .. "\n"
        .. ((t.chapter or "") ~= "" and ("所在章节：" .. t.chapter .. "\n") or "") .. "\n"
    if (t.before or "") == "" and (t.after or "") == "" then
        return head .. "（未取到上下文，只有划选的文字。）\n划选的文字：\n" .. t.text
    end
    return head .. "前文：\n……" .. (t.before or "") .. "\n划选的文字：\n" .. t.text
        .. "\n后文：\n" .. (t.after or "") .. "……"
end

return M
