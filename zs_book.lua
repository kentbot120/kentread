-- Pulls the whole text of the open book.
local M = {}

-- The page after the last one marks the true end when the engine gives it;
-- otherwise fall back to the start of the last page (losing that page's tail).
local function endXPointer(doc)
    local last = doc:getPageXPointer(doc:getPageCount())
    local ok, after = pcall(function()
        local xp = doc:getPageXPointer(doc:getPageCount() + 1)
        return xp and doc:isXPointerInDocument(xp) and doc:compareXPointers(last, xp) == 1 and xp
    end)
    return ok and after or last
end

--- Whole book as plain text, each TOC section headed by its title.
function M.text(ui)
    local doc = ui.document
    local saved = doc:getXPointer()
    ui.toc:fillToc()
    local marks = { { xp = doc:getPageXPointer(1) } }
    for _, item in ipairs(ui.toc.toc or {}) do
        if item.xpointer and item.xpointer ~= marks[#marks].xp then
            marks[#marks + 1] = { xp = item.xpointer, title = item.title }
        end
    end
    marks[#marks + 1] = { xp = endXPointer(doc) }

    local parts = {}
    for i = 1, #marks - 1 do
        local text = doc:getTextFromXPointers(marks[i].xp, marks[i + 1].xp) or ""
        if text:match("%S") then
            parts[#parts + 1] = (marks[i].title and ("【" .. marks[i].title .. "】\n") or "") .. text
        end
    end
    doc:gotoXPointer(saved)
    return table.concat(parts, "\n")
end

return M
