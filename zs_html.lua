-- Cleans the model output for the viewer. Each inline <svg> becomes its own
-- file, so a malformed figure only loses itself, not the text around it.
local M = {}

local function strip(html)
    html = html:gsub("^%s*```%w*", ""):gsub("```%s*$", "")
    return html:match("<body[^>]*>(.*)</body>") or html
end

--- Returns the HTML body and the list of SVG figures it now refers to as fig<i>.svg.
function M.clean(html)
    local figs = {}
    html = strip(html):gsub("<svg.-</svg>", function(svg)
        if not svg:match("^<svg[^>]-xmlns=") then
            svg = svg:gsub("^<svg", '<svg xmlns="http://www.w3.org/2000/svg"', 1)
        end
        figs[#figs + 1] = svg
        return string.format('<p style="text-align:center"><img src="fig%d.svg" style="width:100%%"/></p>', #figs)
    end)
    return html, figs
end

--- The part written so far. Figures stay placeholders until the whole text is done.
function M.preview(html)
    local n = 0
    html = strip(html):gsub("<svg.-</svg>", function()
        n = n + 1
        return string.format('<p style="text-align:center">（图 %d，全文写完后显示）</p>', n)
    end)
    return (html:gsub("<svg.*$", '<p style="text-align:center">（正在画图）</p>'))
end

return M
