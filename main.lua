--[[--
转书：把正在读的整本书交给大模型，写成一篇浓缩版，在原书里弹窗看。

整本一次发给模型，流式接收：正文一开始写就能在弹窗里看，关掉弹窗也会在后台写完。
结果存在这本书的 .sdr 目录里，跟着书走。
]]
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Book = require("zs_book")
local Html = require("zs_html")
local LLM = require("zs_llm")
local Prompts = require("zs_prompts")
local Screen = Device.screen

-- DeepSeek's 1M-token context holds about 3 MB of text (at most 0.3 token per byte), answer included.
local MAX_BYTES = 3000000
local POLL_SECONDS = 5

local Zhuanshu = WidgetContainer:extend{
    name = "zhuanshu",
    is_doc_only = true,
}

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text })
end

-- Kindle's own power daemon would otherwise sleep halfway through.
local function keepAwake(on)
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
    end
end

function Zhuanshu:init()
    self.poll_cb = function() self:poll() end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Zhuanshu:onDispatcherRegisterActions()
    Dispatcher:registerAction("zhuanshu_open",
        { category = "none", event = "ZhuanshuOpen", title = "转书：浓缩版", reader = true })
end

function Zhuanshu:addToMainMenu(menu_items)
    menu_items.zhuanshu = {
        text = "转书",
        sorting_hint = "tools",
        sub_item_table = {
            { text = "浓缩版", callback = function() self:onZhuanshuOpen() end },
            {
                text = "重新生成浓缩版",
                enabled_func = function() return not self.job end,
                callback = function() self:generate() end,
            },
            {
                text = "停止生成",
                enabled_func = function() return self.job ~= nil end,
                callback = function() self:stop() end,
            },
        },
    }
end

function Zhuanshu:config()
    local ok, cfg = pcall(dofile, self.path .. "/config.lua")
    if ok and type(cfg) == "table" and (cfg.api_key or "") ~= "" and cfg.base_url and cfg.model then
        return cfg
    end
end

function Zhuanshu:dir()
    return DocSettings:getSidecarDir(self.ui.document.file) .. "/zhuanshu"
end

function Zhuanshu:path()
    return self:dir() .. "/condensed.html"
end

function Zhuanshu:title()
    local props = self.ui.doc_props or {}
    return props.display_title or props.title or "未命名"
end

function Zhuanshu:onZhuanshuOpen()
    if self.job or lfs.attributes(self:path(), "mode") == "file" then return self:show() end
    UIManager:show(ConfirmBox:new{
        text = "这本书还没有浓缩版，现在生成吗？",
        ok_text = "生成",
        ok_callback = function() self:generate() end,
    })
    return true
end

-- What the viewer shows: the text so far while writing, the saved file afterwards.
function Zhuanshu:html()
    local job = self.job
    if not job then return readFile(self:path()) end
    if #job.content == 0 then
        return string.format("<p>%s</p><p>正文开始写后会显示在这里。可以先关掉回去看书，转书会在后台继续。</p>",
            job.thought > 0 and string.format("模型在思考，已想 %d 字…", job.thought) or "模型在读全书…")
    end
    return Html.preview(table.concat(job.content)) .. '<p style="text-align:center">（还在写…）</p>'
end

function Zhuanshu:show()
    self.viewer = TextViewer:new{
        title = "《" .. self:title() .. "》浓缩版",
        text = self:html(),
        text_format = "html",
        file = self:path(), -- figures resolve next to it; also enables page pinning
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() self.viewer = nil end,
    }
    UIManager:show(self.viewer)
    return true
end

-- Redraws the open viewer with the latest text, staying on the same page.
function Zhuanshu:refresh(html)
    local v = self.viewer
    local page = v.scroll_widget.htmlbox_widget.page_number
    v.text = html
    v:init(true)
    UIManager:setDirty(v, "partial")
    v.scroll_widget:scrollToRatio((page - 0.5) / v.scroll_widget.htmlbox_widget.page_count)
end

function Zhuanshu:generate()
    local ok, err = pcall(self.start, self)
    if not ok then notify("转书出错：" .. tostring(err)) end
end

function Zhuanshu:start()
    local cfg = self:config()
    if not cfg then return notify("先在插件目录里把 config.sample.lua 复制成 config.lua，填好 api_key。") end
    if self.ui.document.info.has_pages then return notify("暂不支持 PDF 这类按页排版的文档。") end

    local info = InfoMessage:new{ text = "正在提取全文…" }
    UIManager:show(info)
    UIManager:forceRePaint()
    local text = Book.text(self.ui)
    UIManager:close(info)
    if not text:match("%S") then return notify("没取到正文。") end
    if #text > MAX_BYTES then return notify("这本书太长，超出了模型一次能读的量。") end

    local author = ((self.ui.doc_props or {}).authors or ""):gsub("\n", "、")
    local job, err = LLM.start(cfg, Prompts.WRITE,
        string.format("书名：《%s》\n作者：%s\n\n%s", self:title(), author, text), 0.7)
    if not job then return notify(err) end
    util.makePath(self:dir())
    self.job = job
    keepAwake(true)
    UIManager:scheduleIn(POLL_SECONDS, self.poll_cb)
    self:show()
end

function Zhuanshu:poll()
    if LLM.poll(self.job) then return self:finish() end
    -- Only the last page can change, so leave the reader alone elsewhere.
    local box = self.viewer and self.viewer.scroll_widget.htmlbox_widget
    if box and box.page_number >= box.page_count then
        local html = self:html()
        if html ~= self.viewer.text then self:refresh(html) end
    end
    UIManager:scheduleIn(POLL_SECONDS, self.poll_cb)
end

function Zhuanshu:finish()
    local job = self.job
    self.job = nil
    keepAwake(false)
    if job.error then return notify("转书失败：" .. job.error) end
    local html = table.concat(job.content)
    if job.finish == "length" then
        html = html .. "<p>（模型输出到了上限，正文在这里被截断。可以在 config.lua 调大 max_tokens。）</p>"
    end
    local body, figs = Html.clean(html)
    for i, svg in ipairs(figs) do
        writeFile(string.format("%s/fig%d.svg", self:dir(), i), svg)
    end
    writeFile(self:path(), body)
    if self.viewer then return self:refresh(body) end
    notify("《" .. self:title() .. "》的浓缩版写好了。\n菜单 → 工具 → 转书 → 浓缩版")
end

function Zhuanshu:stop()
    if not self.job then return end
    UIManager:unschedule(self.poll_cb)
    LLM.stop(self.job)
    self.job = nil
    keepAwake(false)
end

function Zhuanshu:onCloseDocument()
    self:stop()
end

return Zhuanshu
