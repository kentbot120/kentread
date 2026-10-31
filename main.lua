--[[--
KentRead：全书介绍、章节改写、划词解释与联网搜索。
流式接收，关闭弹窗后继续生成；按书籍、章节和配方分别保存。
]]
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Book = require("kr_book")
local Config = require("kr_config")
local Explain = require("kr_explain")
local Html = require("kr_html")
local LLM = require("kr_llm")
local Prompts = require("kr_prompts")
local Search = require("kr_search")
local Writing = require("kr_writing")
local Screen = Device.screen

-- This is a local safety ceiling, not a guarantee about any provider's context.
local MAX_BYTES = 3000000
local POLL_SECONDS = 5
local WAITING_THOUGHT_CHARS = 600

local KentRead = WidgetContainer:extend{
    name = "kentread",
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
    assert(f:write(s))
    assert(f:close())
end

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function succeeded(result) return result == 0 or result == true end

-- Kindle's own power daemon would otherwise sleep halfway through.
local function keepAwake(on)
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
    end
end

-- Plugins missing from the order list are appended last; put ours first (same trick as insert_menu.lua).
local function pinToolsMenu()
    local tools = require("ui/elements/reader_menu_order").tools
    if not tools then return end
    for _, id in ipairs(tools) do
        if id == "kentread" then return end
    end
    table.insert(tools, 1, "kentread")
end

function KentRead:init()
    pinToolsMenu()
    self.ratios = {}
    self.poll_cb = function() self:poll() end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local function register()
        self:registerHighlight()
        self:registerDictButtons()
    end
    if self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function() if not self.closed then register() end end)
    else
        register()
    end
end

function KentRead:registerHighlight()
    local highlight = self.ui.highlight
    if not highlight or not highlight.addToHighlightDialog then return end
    highlight:addToHighlightDialog("05_kentread_search", function(this)
        return {
            text = "联网搜索",
            callback = function()
                local selected = this.selected_text and this.selected_text.text or ""
                selected = util.cleanupSelectedText(selected)
                this:onClose()
                self:onKentSearch(selected)
            end,
        }
    end)
    highlight:addToHighlightDialog("06_kentread_explain", function(this)
        return {
            text = "AI 解释",
            callback = function()
                -- Closing the menu clears the selection, so take everything first.
                local selected = util.cleanupSelectedText(this.selected_text and this.selected_text.text or "")
                local before, after
                if this.getSelectedWordContext then before, after = this:getSelectedWordContext(Explain.CONTEXT_WORDS) end
                this:onClose()
                self:onKentExplain(selected, before, after)
            end,
        }
    end)
end

-- Long-pressing a single word opens the dictionary instead of the highlight menu.
-- One conditional row_group keeps both buttons visible whatever the user's button layout is.
function KentRead:registerDictButtons()
    local dictionary = self.ui.dictionary
    if not dictionary or not dictionary.addToDictButtons then return end
    local function visible(popup) return not popup.is_wiki end
    local function pick(popup, with_context)
        local term = util.cleanupSelectedText(popup.word or "")
        local before, after
        local hl = popup.highlight
        -- Closing the popup clears the selection, so take the context first.
        if with_context and hl and hl.selected_text and hl.getSelectedWordContext
            and util.cleanupSelectedText(hl.selected_text.text or "") == term then
            before, after = hl:getSelectedWordContext(Explain.CONTEXT_WORDS)
        end
        popup:onClose()
        return term, before, after
    end
    -- The row is ordered by id; keep search before explain, as in the highlight menu.
    dictionary:addToDictButtons{
        id = "kentread_1_search", text = "联网搜索", conditional = true, row_group = "kentread", show_func = visible,
        callback = function(popup)
            if self.closed then return end
            self:onKentSearch((pick(popup)))
        end,
    }
    dictionary:addToDictButtons{
        id = "kentread_2_explain", text = "AI 解释", conditional = true, row_group = "kentread", show_func = visible,
        callback = function(popup)
            if self.closed then return end
            self:onKentExplain(pick(popup, true))
        end,
    }
end

function KentRead:explainResult(text, before, after)
    local id = Explain.id(text)
    return { id = id, kind = "explain", label = "AI 解释：" .. Explain.short(text),
        text = text, before = before, after = after, prompt = Prompts.EXPLAIN, dir = self:dir() .. "/" .. id }
end

function KentRead:onKentExplain(selected, before, after)
    if self.closed then return end
    local text, err = Explain.text(selected)
    if not text then return notify(err) end
    before, after = Explain.context(before, after)
    return self:openResult(self:explainResult(text, before, after))
end

function KentRead:searchResult(query)
    local id = Search.id(query)
    return { id = id, kind = "search", label = "联网搜索", query = query, dir = self:dir() .. "/" .. id }
end

function KentRead:closeSearchDialog()
    local dialog = self.search_dialog
    self.search_dialog = nil
    if dialog then UIManager:close(dialog) end
end

function KentRead:onKentSearch(selected)
    if self.closed then return end
    self:closeSearchDialog()
    local dialog
    local function submit(cached)
        local query, err = Search.query(dialog:getInputText())
        if not query then return notify(err) end
        local task = self:searchResult(query)
        if cached and not (self.job and self.job.task.id == task.id)
            and lfs.attributes(self:htmlPath(task), "mode") ~= "file" then
            return notify("没有这条搜索词的已保存结果，请点击「联网搜索」。")
        end
        self.last_search_query = query
        self:closeSearchDialog()
        if cached then self:openResult(task) else self:generate(task) end
    end
    dialog = InputDialog:new{
        title = "联网搜索",
        description = "仅发送输入框内的搜索词到官方 DeepSeek Search，不发送整章或全书。最多 128 个字符，联网搜索按官方规则计费。",
        input = selected or self.last_search_query or "",
        input_hint = "搜索词（支持 site:、引号等搜索语法）",
        buttons = { {
            { text = "取消", id = "close", callback = function() self:closeSearchDialog() end },
            { text = "已保存结果", callback = function() submit(true) end },
            { text = "联网搜索", callback = function() submit(false) end },
        } },
    }
    self.search_dialog = dialog
    UIManager:show(dialog)
    if dialog.input == "" then dialog:onShowKeyboard() end
    return true
end

function KentRead:onDispatcherRegisterActions()
    Dispatcher:registerAction("kentread_intro",
        { category = "none", event = "KentReadIntro", title = "KentRead：全书介绍", reader = true })
    Dispatcher:registerAction("kentread_rewrite",
        { category = "none", event = "KentReadRewrite", title = "KentRead：章节改写", reader = true })
end

function KentRead:addToMainMenu(menu_items)
    menu_items.kentread = {
        text = "KentRead",
        sorting_hint = "tools",
        sub_item_table = {
            { text = "全书介绍", callback = function() self:onKentReadIntro() end },
            { text = "章节改写", callback = function() self:onKentReadRewrite() end },
            {
                text = "查看生成进度",
                enabled_func = function() return self.job ~= nil end,
                callback = function() if self.job then self:openResult(self.job.task) end end,
            },
            {
                text = "停止生成",
                enabled_func = function() return self.job ~= nil end,
                callback = function() self:stop(); notify("已停止生成，之前保存的版本不会删除。") end,
            },
            { text = "扫码配置接口 / 密钥", callback = function() self:setup() end },
        },
    }
end

function KentRead:config()
    local cfg = Config.load(self.path)
    local valid = Config.validate(cfg)
    if not valid then return end
    for key, value in pairs(valid) do cfg[key] = value end
    return cfg
end

function KentRead:dir()
    return DocSettings:getSidecarDir(self.ui.document.file) .. "/kentread"
end

function KentRead:introResult()
    return { id = "intro", kind = "intro", label = "全书介绍", prompt = Prompts.INTRO, dir = self:dir() .. "/intro" }
end

function KentRead:rewriteResult(n, style)
    local chapter = self:chapters()[n]
    local id = string.format("chapters/%04d/%s", n, style.id)
    return { id = id, kind = "rewrite", chapter = n, style = style.id, author = style.author,
        label = chapter.title .. " · " .. style.title .. "（" .. style.author .. "）",
        description = style.description, prompt = Prompts.rewrite(style), dir = self:dir() .. "/" .. id }
end

function KentRead:htmlPath(task)
    task = task or self.result
    return task.dir .. "/content.html"
end

function KentRead:thinkingPath(task)
    return (task or self.result).dir .. "/thinking.txt"
end

function KentRead:chapters()
    self.chapter_list = self.chapter_list or Book.chapters(self.ui)
    return self.chapter_list
end

-- Only book-wide and chapter results carry source links.
function KentRead:linkChapters(task)
    return task.kind == "explain" and {} or self:chapters()
end

function KentRead:title()
    local props = self.ui.doc_props or {}
    return props.display_title or props.title or "未命名"
end

function KentRead:supported()
    if self.ui.document.info.has_pages then
        notify("暂不支持 PDF 这类按页排版的文档。")
        return false
    end
    return true
end

function KentRead:onKentReadIntro()
    if self:supported() then return self:openResult(self:introResult()) end
end

function KentRead:onKentReadRewrite()
    if self:supported() then self:chooseStyle(Book.current(self.ui, self:chapters())) end
    return true
end

function KentRead:chooseChapter()
    local current = Book.current(self.ui, self:chapters())
    local items = {}
    for n, chapter in ipairs(self:chapters()) do
        local index = n
        items[#items + 1] = {
            text = chapter.title, mandatory = n == current and "当前" or nil,
            callback = function() self:chooseStyle(index) end,
        }
    end
    local menu
    menu = Menu:new{
        title = "选择章节", item_table = items,
        width = Screen:getWidth(), height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function KentRead:chooseStyle(n)
    local dialog
    local buttons = {}
    for i, style in ipairs(Prompts.STYLES) do
        local recipe = style
        local button = {
            text = style.title .. " · " .. style.author,
            callback = function()
                UIManager:close(dialog)
                self:openResult(self:rewriteResult(n, recipe))
            end,
        }
        if i % 2 == 1 then buttons[#buttons + 1] = { button }
        else table.insert(buttons[#buttons], button) end
    end
    buttons[#buttons + 1] = { { text = "选择其他章节", callback = function()
        UIManager:close(dialog)
        self:chooseChapter()
    end } }
    buttons[#buttons + 1] = { { text = "取消", callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = self:chapters()[n].title .. " · 章节改写", buttons = buttons }
    UIManager:show(dialog)
end

function KentRead:openResult(task)
    if (self.job and self.job.task.id == task.id) or lfs.attributes(self:htmlPath(task), "mode") == "file" then
        self:closeViewer()
        self.result = task
        return self:show()
    end
    self:confirmGenerate(task)
    return true
end

function KentRead:confirmGenerate(task, again)
    if task.kind == "search" then
        return UIManager:show(ConfirmBox:new{
            text = "重新联网搜索「" .. task.query .. "」？\n仅发送此搜索词到官方 DeepSeek Search，按官方规则计费。",
            ok_text = "重新搜索", ok_callback = function() self:generate(task) end,
        })
    end
    if task.kind == "explain" then
        return UIManager:show(ConfirmBox:new{
            text = (again and "重新解释「" or "解释「") .. Explain.short(task.text) .. "」？\n将发送选中文字"
                .. ((task.before ~= "" or task.after ~= "") and "及前后约 300 字原文" or "")
                .. "、书名和章节名到你配置的模型服务，可能产生费用。AI 解释可能不准确，请对照原文。",
            ok_text = again and "重新解释" or "解释", ok_callback = function() self:generate(task) end,
        })
    end
    UIManager:show(ConfirmBox:new{
        text = (task.description and (task.description .. "\n\n") or "")
            .. (again and "重新生成「" or "生成「") .. task.label .. "」？\n"
            .. (task.kind == "rewrite" and "本章正文" or "全书正文")
            .. "将发送到你配置的模型服务，可能产生费用。改写是 AI 辅助读本，不能代替原文核对。",
        ok_text = again and "重新生成" or "生成",
        ok_callback = function() self:generate(task) end,
    })
end

function KentRead:activeJob()
    return self.job and self.result and self.job.task.id == self.result.id and self.job or nil
end

function KentRead:thinking()
    if self.result and self.result.kind == "search" then return "" end
    local job = self:activeJob()
    if job then return table.concat(job.thinking) end
    return readFile(self:thinkingPath()) or ""
end

-- The author's writing animation replaces the thinking excerpt until the body starts.
function KentRead:writingPhase()
    local job = self:activeJob()
    return job and job.task.kind == "rewrite" and #job.content == 0 and not self.expand
        and Writing.supports(job.task.style) and Writing.available()
end

function KentRead:html()
    local job = self:activeJob()
    if self.result and self.result.kind == "search" then
        return job and Search.waiting(self.result.query) or (readFile(self:htmlPath()) or "<p>还没有完成的搜索结果。</p>")
    end
    -- Constant, so poll() does not rebuild the viewer while thinking text grows.
    if self:writingPhase() then return "<p>模型正在写…</p>" end
    local thought = self:thinking()
    local head = (self.expand and thought ~= "") and Html.thought(thought) or ""
    if not job then return head .. (readFile(self:htmlPath()) or "<p>还没有生成完成的版本。</p>") end
    if #job.content == 0 then
        if thought == "" then
            head = job.task.kind == "explain" and "<p>模型正在解释…</p>"
                or "<p>模型正在阅读" .. (job.task.kind == "rewrite" and "本章" or "全书") .. "…</p>"
        elseif head == "" then
            head = Html.thought(thought, WAITING_THOUGHT_CHARS)
        end
        return head .. "<p>正文开始写后会显示在这里。</p>"
    end
    return head .. Html.preview(table.concat(job.content), self:linkChapters(job.task))
        .. '<p style="text-align:center">（还在写…）</p>'
end

function KentRead:syncButton()
    self.think_button.text = self.expand and "收起思考" or "展开思考"
    self.think_button.enabled = self:thinking() ~= ""
    self.regenerate_button.enabled = not self.job
end

function KentRead:hookLinks()
    self.viewer.scroll_widget.htmlbox_widget.html_link_tapped_callback = function(link)
        if self.result.kind == "search" then
            local url = Search.safeURL(link.uri)
            if url then self.ui.link:onGoToExternalLink(url) end
            return
        end
        local n = tostring(link.uri or ""):match("^ch:(%d+)$")
        if n then self:jump(tonumber(n)) end
    end
end

function KentRead:mountWriting()
    if not self:writingPhase() then return self:stopWriting() end
    local task, box = self.result, self.viewer.scroll_widget
    if not (self.writing and self.writing.task == task) then
        self:stopWriting()
        self.writing = Writing.new{ style = task.style, author = task.author, task = task,
            width = box.width, height = box.height, dir = self.path }
    end
    self.writing.dialog = self.viewer
    self.viewer.textw[1] = self.writing
    self.writing:start()
end

function KentRead:stopWriting()
    if not self.writing then return end
    self.writing:stop()
    self.writing = nil
end

function KentRead:show()
    local task = self.result
    self.think_button = { callback = function() self:toggleThinking() end }
    local again = { search = "重新搜索", explain = "重新解释" }
    self.regenerate_button = { text = again[task.kind] or "重新生成",
        callback = function() self:confirmGenerate(task, true) end }
    self:syncButton()
    local buttons = task.kind == "search" and { self.regenerate_button } or { self.think_button, self.regenerate_button }
    if task.chapter then
        buttons[#buttons + 1] = { text = "查看原文", callback = function() self:jump(task.chapter) end }
        buttons[#buttons + 1] = { text = "换个读法", callback = function() self:chooseStyle(task.chapter) end }
    end
    self.viewer = TextViewer:new{
        title = "《" .. self:title() .. "》" .. task.label,
        text = self:html(), text_format = "html", file = self:htmlPath(),
        width = Screen:getWidth(), height = Screen:getHeight(),
        buttons_table = { buttons }, add_default_buttons = true,
        close_callback = function() self:remember(); self:stopWriting(); self.viewer = nil end,
    }
    self:mountWriting()
    self:hookLinks()
    local ratio = self.ratios[task.id]
    if ratio then self.viewer.scroll_widget:scrollToRatio(ratio) end
    UIManager:show(self.viewer)
    return true
end

function KentRead:remember()
    if not self.viewer then return end
    local box = self.viewer.scroll_widget.htmlbox_widget
    self.ratios[self.result.id] = (box.page_number - 0.5) / math.max(box.page_count, 1)
end

function KentRead:closeViewer()
    self:stopWriting()
    if not self.viewer then return end
    self:remember()
    UIManager:close(self.viewer)
    self.viewer = nil
end

function KentRead:refresh(html, ratio)
    local v = self.viewer
    local page = v.scroll_widget.htmlbox_widget.page_number
    v.text = html
    self:syncButton()
    v:init(true)
    self:mountWriting()
    self:hookLinks()
    UIManager:setDirty(v, "partial")
    v.scroll_widget:scrollToRatio(ratio or (page - 0.5) / math.max(v.scroll_widget.htmlbox_widget.page_count, 1))
end

function KentRead:toggleThinking()
    self.expand = not self.expand
    self:refresh(self:html(), 0)
end

function KentRead:jump(n)
    local chapter = self:chapters()[n]
    if not chapter then return end
    self:closeViewer()
    self.ui.link:addCurrentLocationToStack()
    self.ui:handleEvent(Event:new("GotoXPointer", chapter.xpointer))
end

function KentRead:generate(task)
    if self.job then return notify("已有任务正在生成，请先等待完成或停止生成。") end
    -- Only require a network connection, not Internet reachability: local
    -- OpenAI-compatible servers must remain usable too.
    NetworkMgr:runWhenConnected(function()
        if self.closed then return end
        if self.job then return notify("已有任务正在生成，请先等待完成或停止生成。") end
        local ok, err = pcall(self.start, self, task)
        if not ok then notify("KentRead 出错：" .. tostring(err)) end
    end)
end

function KentRead:start(task)
    local searching, explaining = task.kind == "search", task.kind == "explain"
    if not searching and not explaining and not self:supported() then return end
    local cfg, config_err
    if searching then cfg, config_err = Config.search(self.path) else cfg = self:config() end
    if not cfg then
        return UIManager:show(ConfirmBox:new{
            text = config_err or "还没有配置有效的模型接口。用手机扫码填写密钥，无需在阅读器上粘贴。\n也可以通过 USB 编辑插件目录里的 config.lua。",
            ok_text = "扫码配置", ok_callback = function() self:setup() end,
        })
    end
    util.makePath(task.dir)
    local author = ((self.ui.doc_props or {}).authors or ""):gsub("\n", "、")
    local job, err
    if searching then
        local query, query_err = Search.query(task.query)
        if not query then return notify(query_err) end
        job, err = LLM.request(cfg, Search.ENDPOINT, Search.payload(query), 60)
    elseif explaining then
        local toc = self.ui.toc
        job, err = LLM.start(cfg, task.prompt, Explain.message{ title = self:title(), author = author,
            chapter = toc and toc.getTocTitleOfCurrentPage and toc:getTocTitleOfCurrentPage(),
            text = task.text, before = task.before, after = task.after }, 0.3)
    else
        local info = InfoMessage:new{ text = task.kind == "rewrite" and "正在提取本章…" or "正在提取全文…" }
        UIManager:show(info)
        UIManager:forceRePaint()
        local extracted, text = pcall(function()
            if task.kind == "rewrite" then return Book.chapterText(self.ui, self:chapters(), task.chapter) end
            return Book.text(self.ui, self:chapters(), MAX_BYTES)
        end)
        UIManager:close(info)
        if not extracted then error(text, 0) end
        if not text:match("%S") then return notify("没取到正文。") end
        if #text > MAX_BYTES then return notify("正文过长，超过本地安全上限。请尝试较小的目录章节。") end
        local heading = task.chapter and ("\n本次章节：" .. self:chapters()[task.chapter].title) or ""
        job, err = LLM.start(cfg, task.prompt,
            string.format("书名：《%s》\n作者：%s%s\n\n以下为书籍原文资料：\n%s", self:title(), author, heading, text), 0.7)
    end
    if not job then return notify(err) end
    self:closeViewer()
    job.task = task
    self.job, self.result = job, task
    self.ratios[task.id] = nil
    self.expand = false
    keepAwake(true)
    UIManager:scheduleIn(searching and 1 or POLL_SECONDS, self.poll_cb)
    self:show()
end

function KentRead:poll()
    if not self.job then return end
    local poll = self.job.task.kind == "search" and LLM.pollJSON or LLM.poll
    local ok, done = pcall(poll, self.job)
    if not ok then
        self:stop()
        return notify("KentRead 接收失败：" .. tostring(done))
    end
    if done then
        local saved, err = pcall(self.finish, self)
        if not saved then
            if self.viewer then self:refresh(self:html()) end
            notify("保存失败：" .. tostring(err))
        end
        return
    end
    -- Only the last page can change, so leave the reader alone elsewhere.
    local box = self:activeJob() and self.viewer and self.viewer.scroll_widget.htmlbox_widget
    if box and box.page_number >= box.page_count then
        local html = self:html()
        if html ~= self.viewer.text then self:refresh(html) end
    end
    UIManager:scheduleIn(self.job.task.kind == "search" and 1 or POLL_SECONDS, self.poll_cb)
end

function KentRead:finish()
    local job = self.job
    self.job = nil
    keepAwake(false)
    local body
    if job.task.kind == "search" and not job.error then body, job.error = Search.render(job.response, job.task.query) end
    if job.error then
        if self.viewer then self:refresh(self:html()) end
        return notify("KentRead 失败：" .. job.error)
    end
    if job.task.kind ~= "search" then
        local html = table.concat(job.content)
        if job.finish == "length" then
            html = html .. "<p>（输出已到模型上限，正文可能不完整。可在 config.lua 调整 max_tokens 后重新生成。）</p>"
        end
        body = Html.clean(html, self:linkChapters(job.task))
        writeFile(self:thinkingPath(job.task), table.concat(job.thinking))
    end
    -- Keep the previous readable version if the final write or rename fails.
    local path = self:htmlPath(job.task)
    writeFile(path .. ".tmp", body)
    assert(os.rename(path .. ".tmp", path))
    if self.viewer and self.result.id == job.task.id then return self:refresh(self:html()) end
    if self.viewer then self:refresh(self:html()) end
    notify(job.task.kind == "explain"
        and "「" .. job.task.label .. "」写好了。再次划选同样的文字并点「AI 解释」即可打开。"
        or "《" .. self:title() .. "》的「" .. job.task.label .. "」写好了。\n菜单 → 工具 → KentRead")
end

function KentRead:stop()
    if not self.job then return end
    UIManager:unschedule(self.poll_cb)
    LLM.stop(self.job)
    self.job = nil
    keepAwake(false)
    if self.viewer then self:refresh(self:html()) end
end

-- Match KOReader's HTTP inspector firewall rules, but only while pairing.
function KentRead:setupFirewall(port, open)
    if not Device:isKindle() then return true end
    local verb = open and "-I" or "-D"
    local rules = {
        "INPUT -p tcp --dport " .. port .. " -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        "OUTPUT -p tcp --sport " .. port .. " -m conntrack --ctstate ESTABLISHED -j ACCEPT",
    }
    local ok = true
    for _, rule in ipairs(rules) do
        if not succeeded(os.execute("iptables " .. verb .. " " .. rule .. " >/dev/null 2>&1")) then ok = false end
    end
    return ok
end

function KentRead:setup()
    NetworkMgr:runWhenConnected(function()
        if self.closed then return end
        self:stopSetup()
        local Setup = require("kr_setup")
        local server, err = Setup.start{
            path = self.path,
            on_saved = function() self:stopSetup(); notify("配置已保存，可以使用全书介绍、章节改写、AI 解释或联网搜索了。") end,
            on_timeout = function() self:stopSetup(); notify("扫码配置已超时关闭，需要时可重新打开。") end,
        }
        if not server then return notify(err) end
        self.setup_server = server
        if not self:setupFirewall(server.port, true) then
            self:stopSetup()
            return notify("无法临时开放 Kindle 配网端口，请使用 USB 配置。")
        end
        self.setup_queue = UIManager:insertZMQ(server)
        self.setup_timeout_cb = function() self:stopSetup(); notify("扫码配置已超时关闭。") end
        UIManager:scheduleIn(Setup.LIFETIME, self.setup_timeout_cb)
        local dialog = ConfirmBox:new{
            text = "手机与阅读器连接同一 Wi-Fi，扫码填写接口、模型和密钥。\n\n"
                .. server.url .. "\n\n仅在可信网络使用（局域网 HTTP 未加密）。保存后关闭，5 分钟后失效。",
            no_ok_button = true, cancel_text = "关闭配网",
            cancel_callback = function() self:stopSetup(true) end,
        }
        self.setup_dialog = dialog
        local available, QRWidget = pcall(require, "ui/widget/qrwidget")
        if available then
            local size = math.floor(math.min(dialog:getAddedWidgetAvailableWidth(), Screen:getHeight() * 0.26))
            dialog:addWidget(QRWidget:new{ text = server.url, width = size, height = size })
        end
        UIManager:show(dialog)
        if not available then notify("当前 KOReader 缺少二维码组件，请在手机浏览器输入上面的临时地址，或升级 KOReader。") end
    end)
end

function KentRead:stopSetup(dialog_closing)
    if self.setup_timeout_cb then UIManager:unschedule(self.setup_timeout_cb); self.setup_timeout_cb = nil end
    if self.setup_queue then UIManager:removeZMQ(self.setup_queue); self.setup_queue = nil end
    if self.setup_server then
        local server = self.setup_server
        self.setup_server = nil
        server:stop()
        self:setupFirewall(server.port, false)
    end
    local dialog = self.setup_dialog
    self.setup_dialog = nil
    if dialog and not dialog_closing then UIManager:close(dialog) end
end

function KentRead:onSuspend() self:stopSetup() end
function KentRead:onEnterStandby() self:stopSetup() end
function KentRead:onNetworkDisconnected() self:stopSetup() end

function KentRead:onCloseDocument()
    self.closed = true
    self:closeSearchDialog()
    if self.ui.highlight and self.ui.highlight.removeFromHighlightDialog then
        self.ui.highlight:removeFromHighlightDialog("05_kentread_search")
        self.ui.highlight:removeFromHighlightDialog("06_kentread_explain")
    end
    self:stopSetup()
    self:stop()
    self:closeViewer()
end

function KentRead:onCloseWidget() self:onCloseDocument() end
function KentRead:onExit() self:onCloseDocument() end

return KentRead
