-- Pulls the whole text of the open book.
local M = {}

-- Prefer the engine's end bookmark. On versions that clamp the next page to
-- the last page, walk its remaining words instead of dropping that page.
local function endXPointer(doc)
    local last = doc:getPageXPointer(doc:getPageCount())
    local ok, after = pcall(function()
        local xp = doc:getPageXPointer(doc:getPageCount() + 1)
        return xp and doc:isXPointerInDocument(xp) and doc:compareXPointers(last, xp) == 1 and xp
    end)
    if ok and after then return after end
    if doc.getNextVisibleWordEnd then
        for _ = 1, 10000 do
            local next_xp = doc:getNextVisibleWordEnd(last)
            if not next_xp or doc:compareXPointers(last, next_xp) ~= 1 then break end
            last = next_xp
        end
    end
    return last
end

--- TOC entries in book order. Their index is also the generated source-link ID.
function M.chapters(ui)
    ui.toc:fillToc()
    local list = {}
    for _, item in ipairs(ui.toc.toc or {}) do
        if item.xpointer and item.xpointer ~= "" and item.xpointer ~= (list[#list] or {}).xpointer then
            list[#list + 1] = {
                title = item.title or "未命名章节", xpointer = item.xpointer, depth = item.depth or 1,
            }
        end
    end
    if #list == 0 then
        list[1] = { title = "全文（无目录）", xpointer = ui.document:getPageXPointer(1), depth = 1 }
    end
    return list
end

local function preservingPosition(doc, callback)
    local saved = doc:getXPointer()
    local ok, text = pcall(callback)
    doc:gotoXPointer(saved)
    if not ok then error(text, 0) end
    return text
end

--- Whole book as plain text, each section headed by 【#number title】.
function M.text(ui, chapters, max_bytes)
    local doc = ui.document
    return preservingPosition(doc, function()
        local marks = { { xp = doc:getPageXPointer(1) } }
        for i, chapter in ipairs(chapters) do
            local mark = { xp = chapter.xpointer, head = string.format("【#%d %s】\n", i, chapter.title) }
            if mark.xp == marks[#marks].xp then marks[#marks] = mark
            else marks[#marks + 1] = mark end
        end
        marks[#marks + 1] = { xp = endXPointer(doc) }
        local parts, bytes = {}, 0
        for i = 1, #marks - 1 do
            if marks[i].xp ~= marks[i + 1].xp then
                local text = doc:getTextFromXPointers(marks[i].xp, marks[i + 1].xp) or ""
                if text:match("%S") then
                    local part = (marks[i].head or "") .. text
                    bytes = bytes + #part + 1
                    if max_bytes and bytes > max_bytes then error("全书过长，请改用章节改写。", 0) end
                    parts[#parts + 1] = part
                end
            end
        end
        return table.concat(parts, "\n")
    end)
end

--- Current deepest TOC section, using exact positions rather than page numbers.
function M.current(ui, chapters)
    local xp, current = ui.document:getXPointer(), 1
    for i, chapter in ipairs(chapters) do
        local cmp = ui.document:compareXPointers(chapter.xpointer, xp)
        if cmp and cmp >= 0 then current = i else break end
    end
    return current
end

--- A parent chapter includes its child sections, up to the next peer/ancestor.
function M.chapterText(ui, chapters, n)
    local chapter = assert(chapters[n], "章节不存在")
    local doc = ui.document
    return preservingPosition(doc, function()
        local ending
        for i = n + 1, #chapters do
            if chapters[i].depth <= chapter.depth then ending = chapters[i].xpointer; break end
        end
        ending = ending or endXPointer(doc)
        if chapter.xpointer == ending then return "" end
        return doc:getTextFromXPointers(chapter.xpointer, ending) or ""
    end)
end

return M
