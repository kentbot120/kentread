-- Cleans the model output for the viewer. Inline <svg> is stripped: MuPDF's HTML
-- viewer can't render it reliably and no prompt asks for figures.
local M = {}

local function strip(html)
    html = html:gsub("^%s*```%w*", ""):gsub("```%s*$", "")
    return html:match("<body[^>]*>(.*)</body>") or html
end

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- The model closes each section with <p class="src">原书：3、7</p>; the numbers
-- become links to those chapters. Unknown numbers are dropped, and so is an empty line.
local function links(html, chapters)
    return (html:gsub('<p class="src">(.-)</p>', function(src)
        local out = {}
        for n in src:gmatch("%d+") do
            local chapter = chapters[tonumber(n)]
            if chapter then out[#out + 1] = string.format('<a href="ch:%d">%s</a>', tonumber(n), escape(chapter.title)) end
        end
        return #out > 0 and ("<p>原书：" .. table.concat(out, "　") .. "</p>") or ""
    end))
end

--- Returns the cleaned HTML body.
function M.clean(html, chapters)
    return (links(strip(html), chapters):gsub("<svg.-</svg>", ""))
end

--- The part written so far; a figure still being written is hidden too.
function M.preview(html, chapters)
    html = links(strip(html), chapters):gsub("<svg.-</svg>", "")
    return (html:gsub("<svg.*$", ""))
end

--- The model's thinking as small grey paragraphs; with a limit, only its last chars.
function M.thought(text, limit)
    if limit then
        local i, n = #text, 0
        while i > 0 do
            local b = text:byte(i)
            if b < 128 or b >= 192 then
                n = n + 1
                if n == limit then break end
            end
            i = i - 1
        end
        text = text:sub(math.max(i, 1))
    end
    local paras = {}
    for line in text:gmatch("[^\n]+") do paras[#paras + 1] = "<p>" .. escape(line) .. "</p>" end
    return '<p><b>思考过程</b></p><div style="font-size:85%;color:#555">' .. table.concat(paras) .. "</div><hr/>"
end

return M
