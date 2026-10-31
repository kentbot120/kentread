local passed = 0
local function check(value, message)
    assert(value, message or "assertion failed")
    passed = passed + 1
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function contains(text, part) check(text:find(part, 1, true), "missing: " .. part) end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return end
    local data = f:read("*a"); f:close(); return data
end
local function write(path, data)
    local f = assert(io.open(path, "wb")); assert(f:write(data)); assert(f:close())
end
local plugin = test_dir .. "/plugin"
package.preload.json = function() return { encode = json_encode, decode = json_decode } end
package.preload.datastorage = function() return {
    getSettingsDir = function() return test_dir .. "/settings" end,
    getDataDir = function() return test_dir end,
} end
package.preload.util = function() return { makePath = mkdir_p, cleanupSelectedText = function(text) return text end } end
package.preload["ffi/sha2"] = function() return { sha256 = sha256_hex } end

-- Book extraction, including nested chapters and exact-position selection.
local Book = require("kr_book")
local doc = { position = "15", info = { has_pages = false }, file = "book.epub" }
function doc:getXPointer() return self.position end
function doc:gotoXPointer(xp) self.position = xp end
function doc:getPageCount() return 4 end
function doc:getPageXPointer(n) return tostring(({ 1, 10, 30, 40, 50 })[n]) end
function doc:isXPointerInDocument(xp) return tonumber(xp) ~= nil end
function doc:compareXPointers(a, b)
    a, b = tonumber(a), tonumber(b)
    if a == b then return 0 end
    return a < b and 1 or -1
end
function doc:getTextFromXPointers(a, b)
    self.position = "40" -- emulate extraction side effects
    return "正文 " .. a .. " 到 " .. b
end
local ui = { document = doc, doc_props = { title = "测试书", authors = "作者" },
    toc = { toc = {
        { title = "第一章", xpointer = "1", depth = 1 },
        { title = "第一节", xpointer = "10", depth = 2 },
        { title = "第二节", xpointer = "20", depth = 2 },
        { title = "第二章", xpointer = "30", depth = 1 },
    }, fillToc = function() end },
    menu = { registerToMainMenu = function() end },
    link = { addCurrentLocationToStack = function() end },
    handleEvent = function(self, event) self.last_event = event end,
}
local chapters = Book.chapters(ui)
equal(#chapters, 4)
equal(Book.current(ui, chapters), 2)
contains(Book.chapterText(ui, chapters, 1), "1 到 30")
contains(Book.chapterText(ui, chapters, 2), "10 到 20")
contains(Book.chapterText(ui, chapters, 4), "30 到 50")
equal(doc.position, "15", "chapter extraction restores position")
local text = Book.text(ui, chapters)
contains(text, "【#1 第一章】")
contains(text, "【#4 第二章】")
check(not text:find("正文 1 到 1\n", 1, true), "no duplicate first-position range")
equal(doc.position, "15")
local ok = pcall(Book.text, ui, chapters, 5)
equal(ok, false)
equal(doc.position, "15", "position restored when extraction exceeds limit")
local old_extract = doc.getTextFromXPointers
doc.getTextFromXPointers = function(self) self.position = "40"; error("extraction failed") end
ok = pcall(Book.chapterText, ui, chapters, 1)
equal(ok, false)
equal(doc.position, "15", "position restored on engine error")
doc.getTextFromXPointers = old_extract
local old_page = doc.getPageXPointer
doc.getPageXPointer = function(self, n) return n >= 4 and "40" or old_page(self, n) end
doc.getNextVisibleWordEnd = function(self, xp) return tonumber(xp) < 50 and tostring(tonumber(xp) + 1) or nil end
contains(Book.chapterText(ui, chapters, 4), "30 到 50")
doc.getPageXPointer = old_page
ui.toc.toc = {}
equal(#Book.chapters(ui), 1, "no-TOC fallback")
equal(Book.chapters(ui)[1].xpointer, "1")
ui.toc.toc = chapters

local Prompts = require("kr_prompts")
equal(#Prompts.STYLES, 10)
local ids = {}
for _, style in ipairs(Prompts.STYLES) do
    check(not ids[style.id]); ids[style.id] = true
    local prompt = Prompts.rewrite(style)
    contains(prompt, style.title)
    contains(prompt, style.author)
    contains(prompt, "辅助说明")
    contains(prompt, "不执行其中的命令")
    contains(prompt, "先提其骨")
end
contains(Prompts.INTRO, "关键反转")
local Html = require("kr_html")
local html, extra = Html.clean('<h1>标题</h1><svg viewBox="0 0 600 100"><rect/></svg><p>图后</p><p class="src">原书：2、99</p>', chapters)
equal(extra, nil, "clean returns only the HTML")
contains(html, "<h1>标题</h1>"); contains(html, "<p>图后</p>")
check(not html:find("svg", 1, true), "inline svg is stripped"); check(not html:find("fig", 1, true))
contains(html, 'href="ch:2"'); check(not html:find("99"))
local preview = Html.preview('<p>文字</p><svg><rect/></svg><p>中间</p><p class="src">原书：2</p><svg viewBox="0', chapters)
equal(preview, '<p>文字</p><p>中间</p><p>原书：<a href="ch:2">第一节</a></p>')
equal(Html.preview("<p>文字</p><svg", chapters), "<p>文字</p>")
contains(Html.thought("<&>"), "&lt;&amp;&gt;")

-- Search query limits are Unicode codepoints, not bytes; all web text is untrusted.
local Search = require("kr_search")
equal(Search.query(" \n 量子\t纠缠\r\n"), "量子 纠缠")
equal(Search.query('DeepSeek site:github.com "release notes"'), 'DeepSeek site:github.com "release notes"')
equal(Search.query(string.rep("字", 128)), string.rep("字", 128))
equal(Search.query(string.rep("字", 129)), nil)
equal(Search.query(string.rep("😀", 128)), string.rep("😀", 128))
for _, bad in ipairs{ "", " \t\n", "　", "\226\128\128", "\226\128\168", "\194\133", "\128", "\192\175", "\237\160\128", "\244\144\128\128", "x\0", "\226\130" } do
    equal(Search.query(bad), nil)
end
for _, bad in ipairs{ "javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.com", "https://example.com/\n", 'https://example.com/"x', "https://example.com/\\x" } do
    equal(Search.safeURL(bad), nil)
end
equal(Search.safeURL("https://example.com/?a=1&b=2"), "https://example.com/?a=1&b=2")
equal(Search.id("词"), Search.id("词")); check(Search.id("词") ~= Search.id("另一词"))
check(Search.id("词"):match("^search/%x+$")); equal(#Search.id("词"), 71)
local rendered = assert(Search.render({ results = {
    { title = "<script>标题</script>", url = "https://example.com/?a=1&b=2", snippet = "<img src=x>", site_name = "站点", date = "2026-10-30T00:00:00Z" },
    { title = "后备", url = "javascript:alert(1)", summary = "后备摘要" },
} }, "<搜索词>"))
contains(rendered, "&lt;搜索词&gt;"); contains(rendered, "&lt;script&gt;")
contains(rendered, "&lt;img src=x&gt;"); check(not rendered:find("<script>", 1, true))
contains(rendered, 'href="https://example.com/?a=1&amp;b=2"')
contains(rendered, "2026-10-30"); contains(rendered, "后备摘要")
check(not rendered:find('href="javascript:', 1, true))
contains(assert(Search.render({ results = {} }, "空结果")), "没有找到匹配结果")
equal(Search.render({}, "缺少字段"), nil)
equal(Search.render(nil, "缺少字段"), nil)
equal(Search.payload("词").need_content, false); equal(Search.payload("词").count, 5)

-- Explain: selection limits are Unicode characters; context is cut on UTF-8 boundaries.
local Explain = require("kr_explain")
equal(Explain.text("  \n\t "), nil); equal(Explain.text(""), nil); equal(Explain.text(nil), nil)
equal(Explain.text("  词语\n"), "词语")
equal(Explain.text(string.rep("字", 1000)), string.rep("字", 1000))
local too_long, too_long_err = Explain.text(string.rep("字", 1001))
equal(too_long, nil); contains(too_long_err, "超过 1000 字")
local function valid_utf8(str)
    local i = 1
    while i <= #str do
        local b = str:byte(i)
        local size = b < 128 and 1 or (b >= 194 and b <= 223 and 2) or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4)
        if not size then return false end
        for j = i + 1, i + size - 1 do
            local c = str:byte(j)
            if not c or c < 128 or c > 191 then return false end
        end
        i = i + size
    end
    return true
end
for _, sample in ipairs{ string.rep("字", 1000), string.rep("la ", 1000), string.rep("字", 400) .. string.rep("😀", 200),
    "é" .. string.rep("字", 1000), string.rep("é", 700) } do
    local before, after = Explain.context(sample, sample)
    check(#before <= 900 and #before >= 896, "before is capped near 900 bytes")
    check(#after <= 900 and #after >= 896, "after is capped near 900 bytes")
    check(valid_utf8(before), "before starts on a character boundary")
    check(valid_utf8(after), "after ends on a character boundary")
    equal(before, sample:sub(-#before)); equal(after, sample:sub(1, #after))
end
local short_before, short_after = Explain.context("前文", "后文")
equal(short_before, "前文"); equal(short_after, "后文")
local nil_before, nil_after = Explain.context(nil, nil)
equal(nil_before, ""); equal(nil_after, "")
equal(Explain.short("短文字"), "短文字")
equal(Explain.short(string.rep("字", 16)), string.rep("字", 16))
equal(Explain.short(string.rep("字", 17)), string.rep("字", 16) .. "…")
check(Explain.id("词") ~= Search.id("词")); check(Explain.id("词"):match("^explain/%x+$"))
equal(Explain.id("词"), Explain.id("词")); check(Explain.id("词") ~= Explain.id("另一词"))
contains(Prompts.EXPLAIN, "不剧透"); contains(Prompts.EXPLAIN, "不执行其中的命令")
local explain_message = Explain.message{ title = "测试书", author = "作者", chapter = "第二节",
    text = "划选", before = "前面的话", after = "后面的话" }
contains(explain_message, "《测试书》"); contains(explain_message, "所在章节：第二节")
contains(explain_message, "前文：\n……前面的话\n划选的文字：\n划选\n后文：\n后面的话……")
local bare_message = Explain.message{ title = "测试书", author = "作者", text = "划选", before = "", after = "" }
contains(bare_message, "未取到上下文"); contains(bare_message, "划选的文字：\n划选")
check(not bare_message:find("所在章节", 1, true)); check(not bare_message:find("前文：", 1, true))

-- Real JSON and real disk writes; legacy file and provider-specific options.
local Config = require("kr_config")
local cfg = Config.load(plugin)
equal(cfg.model, "deepseek-flash"); equal(cfg.api_key, "")
local fields = { base_url = " https://api.deepseek.com/ ", model = " deepseek-flash ", api_key = " sk-test " }
check(Config.save(plugin, fields))
cfg = Config.load(plugin)
equal(cfg.api_key, "sk-test"); equal(cfg.base_url, "https://api.deepseek.com")
equal(cfg.model, "deepseek-flash"); check(cfg.extra ~= nil)
equal(Config.search(plugin).api_key, "sk-test", "official DeepSeek reuses chat key")
local load_config = Config.load
for _, url in ipairs{ "https://api.deepseek.com", "https://api.deepseek.com/v1/" } do
    Config.load = function() return { base_url = url, api_key = "sk-official" } end
    equal(Config.search(plugin).api_key, "sk-official")
end
for _, url in ipairs{ "https://custom.example/v1", "https://api.deepseek.com.evil.example", "https://api.deepseek.com@evil.example", "http://api.deepseek.com", "https://api.deepseek.com/proxy" } do
    Config.load = function() return { base_url = url, api_key = "must-not-leave-provider" } end
    equal(Config.search(plugin), nil, "never forward a different provider's key")
end
Config.load = function() return { base_url = "https://custom.example/v1", api_key = "chat-key", search_api_key = "sk-search" } end
equal(Config.search(plugin).api_key, "sk-search"); equal(Config.search(plugin).base_url, "https://api.deepseek.com")
Config.load = load_config
local original = read(Config.path())
for _, key in ipairs{ "bad\nkey", 'bad"key', "bad\\key", "bad key" } do
    local valid = Config.validate{ base_url = cfg.base_url, model = cfg.model, api_key = key }
    equal(valid, nil)
end
for _, url in ipairs{ "ftp://api.example", "https://user:pass@api.example", "https://api.example?q=1", "https://api.example/\nother" } do
    equal(Config.validate{ base_url = url, model = "model", api_key = "key" }, nil)
end
check(not Config.save(plugin, { base_url = "https://other.example/v1", model = "other", api_key = "" }))
equal(read(Config.path()), original, "invalid save preserves previous settings")
check(Config.save(plugin, { base_url = cfg.base_url, model = "new-model", api_key = "" }))
equal(Config.load(plugin).api_key, "sk-test", "empty key preserves existing key")
check(Config.save(plugin, { base_url = "https://other.example/v1", model = "other", api_key = "sk-other" }))
cfg = Config.load(plugin); equal(cfg.extra, nil); equal(cfg.max_tokens, 65536)
write(Config.path(), "corrupt json")
equal(Config.load(plugin).api_key, "", "corrupt JSON falls back safely")
write(plugin .. "/config.lua", 'return { base_url="https://custom.example/v1", model="custom", api_key="sk-legacy", extra={ custom=true }, max_tokens=12345 }')
cfg = Config.load(plugin); equal(cfg.api_key, "sk-legacy"); check(cfg.extra.custom)
check(Config.save(plugin, { base_url = "https://custom.example/v1/", model = "custom2", api_key = "" }))
cfg = Config.load(plugin); check(cfg.extra.custom); equal(cfg.max_tokens, 12345)
local utf8_config = assert(Config.validate{ base_url = cfg.base_url, model = "含中文的模型名", api_key = "sk-test" })
equal(utf8_config.model, "含中文的模型名", "UTF-8 model names are not ASCII control characters")
local previous = read(Config.path())
local old_execute, old_rename = os.execute, os.rename
os.execute = function() return 1 end
check(not Config.save(plugin, { base_url = cfg.base_url, model = "new", api_key = "sk-new" }))
os.execute = old_execute
equal(read(Config.path()), previous); equal(read(Config.path() .. ".tmp"), nil)
os.rename = function() return nil, "permission denied" end
check(not Config.save(plugin, { base_url = cfg.base_url, model = "new", api_key = "sk-new" }))
os.rename = old_rename
equal(read(Config.path()), previous); equal(read(Config.path() .. ".tmp"), nil)
check(Config.save(plugin, { base_url = cfg.base_url, model = cfg.model, api_key = "", search_api_key = "sk-search-only" }))
equal(Config.load(plugin).search_api_key, "sk-search-only")
equal(Config.search(plugin).api_key, "sk-search-only")
check(Config.save(plugin, { base_url = cfg.base_url, model = cfg.model, api_key = "", search_api_key = "" }))
equal(Config.load(plugin).search_api_key, "sk-search-only", "blank form field preserves search key")

-- Fake sockets exercise HTTP framing and partial I/O without a LAN or device.
local clock, listeners = 1000, {}
local function listener()
    local object = { pending = {} }
    function object:settimeout() end
    function object:getsockname() return "192.168.1.20", 43210 end
    function object:accept() return table.remove(self.pending, 1) end
    function object:close() self.closed = true end
    return object
end
package.preload.socket = function() return {
    gettime = function() return clock end,
    udp = function() return {
        setpeername = function() return true end,
        getsockname = function() return "192.168.1.20", 12345 end,
        close = function() end,
    } end,
    bind = function()
        local object = listener(); listeners[#listeners + 1] = object; return object
    end,
} end
local Setup = require("kr_setup")
local function new_server(options)
    options = options or {}; options.path = plugin
    return assert(Setup.start(options))
end
local function url_encode(value)
    return (value:gsub("[^%w%-._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function form_body(key)
    return "base_url=" .. url_encode("https://custom.example/v1") .. "&model=custom&api_key=" .. url_encode(key or "sk-browser")
end
local function request(server, method, body, extras)
    local headers = method .. " " .. server.route .. " HTTP/1.1\r\nHost: " .. server.authority .. "\r\n"
    if body then headers = headers .. "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: " .. #body .. "\r\n" end
    return headers .. (extras or "") .. "\r\n" .. (body or "")
end
local server = new_server()
check(server.url:match("^http://192%.168%.1%.20:43210/%x+$"))
equal(#server.route, 33, "128-bit random pairing token")
local get = request(server, "GET")
local reply = server:request(get)
contains(reply, "200 OK"); contains(reply, "Cache-Control: no-store")
contains(reply, "<title>KentRead · 接口配置</title>")
contains(reply, "<h1>KentRead · 接口配置</h1>")
contains(reply, "https://custom.example/v1"); contains(reply, "留空保留原密钥")
check(not reply:find("sk-legacy", 1, true), "existing API key not sent to browser")
check(not reply:find("sk-search-only", 1, true), "search key is never returned to browser")
contains(reply, 'name="search_api_key"')
check(not reply:find("{{", 1, true), "all HTML placeholders replaced")
contains(server:request(get:gsub(server.authority, "evil.example", 1)), "403 Forbidden")
contains(server:request("GET /wrong HTTP/1.1\r\nHost: " .. server.authority .. "\r\n\r\n"), "403 Forbidden")
contains(server:request(request(server, "POST", form_body(), "Origin: https://evil.example\r\n")), "403 Forbidden")
contains(server:request(request(server, "DELETE")), "405 Method Not Allowed")
contains(server:request(request(server, "GET", nil, "Host: evil.example\r\n")), "400 Bad Request")
contains(server:request(string.rep("x", 8193)), "431 Request Header Fields Too Large")
local post = request(server, "POST", form_body())
equal(server:request(post:sub(1, #post - 3)), nil, "waits for complete POST body")
equal(server:request(post:sub(1, 20)), nil, "waits for complete headers")
contains(server:request(post .. "extra"), "400 Bad Request")
contains(server:request(post:gsub("Content%-Length: %d+", "Content-Length: 99999")), "413 Content Too Large")
contains(server:request(post:gsub("application/x%-www%-form%-urlencoded", "application/json")), "415 Unsupported Media Type")
contains(server:request(post:gsub("application/x%-www%-form%-urlencoded", "application/x-www-form-urlencodedevil")), "415 Unsupported Media Type")
contains(server:request(request(server, "POST", form_body() .. "&model=duplicate")), "400 Bad Request")
contains(server:request(request(server, "POST", form_body() .. "%ZZ")), "400 Bad Request")
contains(server:request(request(server, "POST", form_body("bad\nkey"))), "400 Bad Request")
check(not server.saved)
local response, saved = server:request(post)
contains(response, "200 OK"); check(saved)
equal(Config.load(plugin).api_key, "sk-browser")
contains(server:request(post), "410 Gone", "single-use setup")
server:stop(); equal(server.listener, nil)

local function client(chunks, send_limit)
    local object = { chunks = chunks, sent = "", send_limit = send_limit or 100000 }
    function object:settimeout() end
    function object:receive()
        local data = table.remove(self.chunks, 1)
        return nil, "timeout", data or ""
    end
    function object:send(data, offset)
        local last = math.min(#data, offset + self.send_limit - 1)
        self.sent = self.sent .. data:sub(offset, last)
        if last < #data then return nil, "timeout", last end
        return last
    end
    function object:close() self.closed = true end
    return object
end
local saved_calls = 0
server = new_server{ on_saved = function() saved_calls = saved_calls + 1 end }
post = request(server, "POST", form_body("sk-partial"))
local connection = client({ post:sub(1, 17), post:sub(18, #post - 2), post:sub(-2) }, 17)
server.listener.pending[1] = connection
server:waitEvent(); equal(saved_calls, 0); check(not server.saved)
server:waitEvent(); equal(saved_calls, 0); check(not server.saved)
server:waitEvent(); equal(saved_calls, 0); check(server.saved)
-- Another client's fast 410 response must not trigger closure before success is sent.
server.listener.pending[1] = client({ request(server, "GET") })
server:waitEvent(); equal(saved_calls, 0)
for _ = 1, 200 do server:waitEvent() end
equal(saved_calls, 1); check(connection.closed); contains(connection.sent, "200 OK")
equal(Config.load(plugin).api_key, "sk-partial")
server:stop()
local timed_out = 0
server = new_server{ on_timeout = function() timed_out = timed_out + 1 end }
local slow = client({ "GET " }); server.listener.pending[1] = slow
server:waitEvent(); clock = clock + 11; server:waitEvent(); check(slow.closed)
clock = clock + Setup.LIFETIME; server:waitEvent()
equal(timed_out, 1); equal(server.listener, nil)
server:waitEvent(); equal(timed_out, 1)

-- Curl transport: SSE framing, thinking, failures, and cleanup on cancel.
local subprocess_done, subprocess_fn, terminated = false, nil, false
package.preload["ffi/util"] = function() return {
    runInSubProcess = function(callback) subprocess_fn = callback; return 123 end,
    isSubProcessDone = function() return subprocess_done end,
    terminateSubProcess = function() terminated = true end,
} end
local Transport = require("kr_llm")
local function transport_job()
    subprocess_done = false
    return assert(Transport.start(Config.load(plugin), "system", "user", 0.7))
end
local job = transport_job()
local cmd
local execute = os.execute
os.execute = function(command) cmd = command; return 0 end
subprocess_fn(); os.execute = execute
check(not cmd:find("sk-partial", 1, true), "key not present on curl command line")
contains(read(job.conf), "Authorization: Bearer sk-partial")
local JSON = require("json")
local payload = JSON.decode(read(job.body))
equal(payload.messages[1].content, "system"); equal(payload.stream, true)
check(not read(job.body):find("sk-search-only", 1, true), "independent search key never sent to chat provider")
local thinking = 'data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}\n'
local content = 'data: {"choices":[{"delta":{"content":"<p>正文</p>"}}]}\n'
write(job.out, thinking .. content:sub(1, 20))
equal(Transport.poll(job), false); equal(table.concat(job.thinking), "思考"); equal(#job.content, 0)
write(job.out, thinking .. content .. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\ndata: [DONE]\n')
write(job.status, "200 0"); subprocess_done = true
check(Transport.poll(job)); equal(job.error, nil); equal(table.concat(job.content), "<p>正文</p>")
equal(read(job.conf), nil); equal(read(job.body), nil); equal(read(job.out), nil)
job = transport_job(); write(job.out, '{"error":{"message":"invalid key"}}'); write(job.status, "401 0")
subprocess_done = true; check(Transport.poll(job)); contains(job.error, "HTTP 401")
job = transport_job(); write(job.out, content); write(job.status, "200 0")
subprocess_done = true; check(Transport.poll(job)); contains(job.error, "连接中断")
job = transport_job(); Transport.stop(job); check(terminated); equal(read(job.conf), nil)
subprocess_done = false
job = assert(Transport.request(Config.search(plugin), Search.ENDPOINT, Search.payload("量子纠缠"), 60))
local search_payload = JSON.decode(read(job.body))
equal(search_payload.query, "量子纠缠"); equal(search_payload.count, 5); equal(search_payload.need_content, false)
equal(search_payload.model, nil); equal(search_payload.messages, nil); equal(search_payload.custom, nil)
contains(read(job.conf), "Bearer sk-search-only")
os.execute = function(command) cmd = command; return 0 end
subprocess_fn(); os.execute = execute
contains(cmd, "https://api.deepseek.com/v1/tools/search"); contains(cmd, "--max-time 60")
check(not cmd:find("sk-search-only", 1, true))
write(job.out, '{"results":'); equal(Transport.pollJSON(job), false)
write(job.out, '{"results":[{"title":"来源","url":"https://example.com","snippet":"摘要"}]}')
write(job.status, "200 0"); subprocess_done = true
check(Transport.pollJSON(job)); equal(job.error, nil); equal(job.response.results[1].title, "来源")
equal(read(job.conf), nil); equal(read(job.out), nil)
for _, status in ipairs{ "402", "429" } do
    job = assert(Transport.request(Config.search(plugin), Search.ENDPOINT, Search.payload("test"), 60))
    write(job.out, '{"error":{"message":"tool error"}}'); write(job.status, status .. " 0")
    check(Transport.pollJSON(job)); contains(job.error, "HTTP " .. status); equal(read(job.conf), nil)
end
job = assert(Transport.request(Config.search(plugin), Search.ENDPOINT, Search.payload("test"), 60))
write(job.out, "not JSON"); write(job.status, "200 0")
check(Transport.pollJSON(job)); contains(job.error, "JSON")
job = assert(Transport.request(Config.search(plugin), Search.ENDPOINT, Search.payload("test"), 60))
write(job.out, string.rep("x", 2 * 1024 * 1024 + 1)); write(job.status, "200 0")
check(Transport.pollJSON(job)); contains(job.error, "过大"); equal(read(job.out), nil)

-- KOReader widgets/services are intentionally small substitutes for controller tests.
local UI = { shown = {}, scheduled = {}, queues = {}, dirty = {}, regions = {} }
function UI:show(widget) self.shown[#self.shown + 1] = widget end
function UI:close(widget) widget.closed = true end
function UI:scheduleIn(_, callback) self.scheduled[callback] = true end
function UI:unschedule(callback) self.scheduled[callback] = nil end
function UI:forceRePaint() end
function UI:setDirty(_, mode)
    local region
    if type(mode) == "function" then mode, region = mode() end
    self.dirty[#self.dirty + 1] = mode
    self.regions[#self.regions + 1] = region
end
function UI:insertZMQ(queue) self.queues[queue] = true; return queue end
function UI:removeZMQ(queue) self.queues[queue] = nil end
local function widget()
    return { new = function(self, opts) return setmetatable(opts, { __index = self }) end }
end
local Confirm = widget()
function Confirm:getAddedWidgetAvailableWidth() return 400 end
function Confirm:addWidget(child) self.child = child end
local Input = widget()
function Input:getInputText() return self.input end
function Input:onShowKeyboard() self.keyboard_shown = true end
ui.highlight = { buttons = {},
    addToHighlightDialog = function(self, id, callback) self.buttons[id] = callback end,
    removeFromHighlightDialog = function(self, id) self.buttons[id] = nil end,
    onClose = function(self) self.selected_text = nil; self.closed = true end,
}
ui.dictionary = { specs = {}, addToDictButtons = function(self, spec) self.specs[spec.id] = spec end }
function ui:registerPostInitCallback(callback) callback() end
function ui.link:onGoToExternalLink(url) self.external_url = url end
local Viewer = widget()
function Viewer:init()
    self.scroll_widget = { htmlbox_widget = { page_number = 1, page_count = 2 }, width = 500, height = 600,
        scrollToRatio = function(self, ratio) self.ratio = ratio end }
    self.textw = { self.scroll_widget }
    self.init_count = (self.init_count or 0) + 1
end
function Viewer:new(opts) setmetatable(opts, { __index = self }); opts:init(); return opts end
local Base = {}
function Base:extend(opts) opts.__index = opts; return opts end
local Widget = {}
function Widget:extend(opts) opts.__index = opts; return setmetatable(opts, { __index = self }) end
function Widget:new(opts) opts = setmetatable(opts, { __index = self }); opts:init(); return opts end
local live, logs = 0, {}
local Render = { nil_mode = false, paths = {} }
-- A fake blitbuffer that counts live buffers and records the calls the tests assert on.
local function fakeBB(calls)
    live = live + 1
    local bb = { calls = calls or {}, owned = true }
    function bb:getWidth() return 1 end
    function bb:getHeight() return 1 end
    function bb:copy() return fakeBB() end
    function bb:free() if self.owned then self.owned = false; live = live - 1 end end
    function bb:paintRect(x, y, w, h, color) self.calls[#self.calls + 1] = { "paint", x, y, w, h, color } end
    function bb:blitFrom(src, dx, dy, ox, oy, w, h) self.calls[#self.calls + 1] = { "blit", src, dx, dy, ox, oy, w, h } end
    return bb
end
function Render:renderImageFile(path, _, w, h)
    self.paths[#self.paths + 1] = path
    if self.nil_mode or (self.fail_on and path:find(self.fail_on, 1, true)) then return end
    local bb = fakeBB(); bb.path, bb.w, bb.h = path, w, h
    return bb
end
local Caption = { new = function(self, opts) return setmetatable(opts, { __index = self }) end }
function Caption:getSize() return { h = 40 } end
function Caption:paintTo() end
function Caption:free() end
local device = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
    isKindle = function() return false end }
local actions = {}
local modules = {
    ["ui/widget/buttondialog"] = widget(), ["ui/widget/confirmbox"] = Confirm,
    ["device"] = device,
    ["dispatcher"] = { registerAction = function(_, id, action) actions[id] = action end },
    ["docsettings"] = { getSidecarDir = function() return test_dir .. "/book.sdr" end },
    ["ui/event"] = { new = function(_, name, value) return { name = name, value = value } end },
    ["ui/widget/infomessage"] = widget(), ["ui/widget/menu"] = widget(), ["ui/widget/inputdialog"] = Input,
    ["ui/network/manager"] = { runWhenConnected = function(_, callback) callback() end },
    ["ui/widget/textviewer"] = Viewer, ["ui/uimanager"] = UI,
    ["ui/widget/container/widgetcontainer"] = Base,
    ["ui/widget/qrwidget"] = widget(),
    ["ui/widget/widget"] = Widget, ["ui/renderimage"] = Render, ["ui/widget/textboxwidget"] = Caption,
    ["ffi/blitbuffer"] = { COLOR_BLACK = "black", COLOR_WHITE = "white" },
    ["ui/geometry"] = { new = function(_, t) return t end }, ["ui/font"] = { getFace = function() return "face" end },
    ["logger"] = { info = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end,
        warn = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end },
    ["ui/elements/reader_menu_order"] = { tools = { "wifi", "network_info" } },
    ["libs/libkoreader-lfs"] = { attributes = function(path) return read(path) and "file" or nil end },
}
for name, value in pairs(modules) do
    local module = value
    package.preload[name] = function() return module end
end
local calls, started = {}, 0
local FakeLLM = {
    request = function(cfg, endpoint, payload, timeout)
        started = started + 1
        calls[#calls + 1] = { cfg = cfg, endpoint = endpoint, payload = payload, timeout = timeout }
        return { content = {}, thinking = {} }
    end,
    pollJSON = function(job) return job.done end,
    start = function(cfg, system, user)
        started = started + 1
        calls[#calls + 1] = { cfg = cfg, system = system, user = user }
        return { content = {}, thinking = {} }
    end,
    poll = function(job) return job.done end,
    stop = function(job) job.stopped = true end,
}
package.loaded.kr_llm = FakeLLM
local Main = require("main")
local instance = setmetatable({ ui = ui, path = plugin }, Main)
instance:init()
check(actions.kentread_intro); check(actions.kentread_rewrite)
equal(actions.kentread_open, nil, "legacy action is no longer registered")
equal(actions.kentread_intro.title, "KentRead：全书介绍")
equal(actions.kentread_rewrite.title, "KentRead：章节改写")
local meta = dofile("_meta.lua")
equal(meta.fullname, "KentRead"); equal(meta.name, "kentread", "internal plugin ID remains compatible")
local menu = {}; instance:addToMainMenu(menu)
equal(menu.kentread.text, "KentRead")
equal(menu.kentread.sub_item_table[1].text, "全书介绍")
equal(menu.kentread.sub_item_table[2].text, "章节改写")
for _, item in ipairs(menu.kentread.sub_item_table) do
    check(item.text ~= "联网搜索", "search and explain are selection-only")
    check(not item.text:find("浓缩", 1, true), "no condensed edition entry")
    check(not item.separator, "no leftover separator")
end
local tools_order = require("ui/elements/reader_menu_order").tools
equal(tools_order[1], "kentread", "KentRead leads the Tools menu"); equal(tools_order[2], "wifi")
instance:onKentReadRewrite()
local choices = UI.shown[#UI.shown]
contains(choices.title, "第一节")
equal(choices.buttons[1][1].text, "更好懂 · 费曼")
choices.buttons[1][1].callback()
local confirm = UI.shown[#UI.shown]
contains(confirm.text, "本章正文"); confirm.ok_callback()
equal(started, 1); equal(instance.job.task.chapter, 2)
contains(calls[1].user, "正文 10 到 20"); check(not calls[1].user:find("正文 20 到 30", 1, true))
contains(calls[1].system, "费曼")
local clear = instance.job.task
local humor = instance:rewriteResult(2, Prompts.STYLES[2])
local other_chapter = instance:rewriteResult(3, Prompts.STYLES[1])
check(instance:htmlPath(clear) ~= instance:htmlPath(humor))
check(instance:htmlPath(clear) ~= instance:htmlPath(other_chapter))
instance:generate(humor); equal(started, 1, "one job at a time")
instance.job.content = { "<h1>改写</h1><p>正文</p>" }
instance.job.thinking = { "想法" }; instance.job.finish = "stop"; instance.job.done = true
instance:poll(); equal(instance.job, nil)
contains(read(instance:htmlPath(clear)), "改写")
equal(read(instance:thinkingPath(clear)), "想法")
check(instance.regenerate_button.enabled)
instance:jump(2); equal(ui.last_event.name, "GotoXPointer"); equal(ui.last_event.value, "10")
local count_before = started
instance:openResult(clear); equal(started, count_before, "cached result avoids new request")
contains(instance.viewer.text, "改写")
instance:generate(humor)
instance.job.content = { "<p>另一种改写</p>" }; instance.job.finish = "stop"
instance:openResult(clear)
contains(instance.viewer.text, "改写"); check(not instance.viewer.text:find("另一种改写", 1, true))
instance:finish()
equal(instance.result.id, clear.id, "background finish keeps selected result")
contains(read(instance:htmlPath(humor)), "另一种改写")
check(instance.regenerate_button.enabled)
local old = read(instance:htmlPath(clear))
instance:generate(clear); instance.job.error = "test failure"; instance:finish()
equal(read(instance:htmlPath(clear)), old, "failed regeneration preserves old version")
contains(instance.viewer.text, "改写")
instance:generate(clear); instance.job.content = { "<p>新版本</p>" }; instance.job.finish = "stop"; instance:finish()
equal(read(instance:thinkingPath(clear)), "", "old thinking does not leak into a new generation")
instance:generate(clear)
local stopped = instance.job; instance:stop(); check(stopped.stopped); equal(instance.job, nil)
contains(instance.viewer.text, "新版本")
local intro = instance:introResult()
instance:generate(intro)
contains(calls[#calls].system, "全书介绍"); contains(calls[#calls].user, "【#4 第二章】")
instance.job.content = { '<p>介绍</p><p class="src">原书：2</p>' }; instance.job.finish = "length"
instance:finish(); contains(read(instance:htmlPath(intro)), 'href="ch:2"')
contains(read(instance:htmlPath(intro)), "正文可能不完整")
-- 换个读法: only chapter rewrites; cached styles open instantly, new ones go through confirm.
local function viewer_button(v, text)
    for _, b in ipairs(v.buttons_table[1]) do if b.text == text then return b end end
end
instance:openResult(intro)
check(not viewer_button(instance.viewer, "换个读法"), "intro has no style switch")
instance:openResult(clear)
local switch = viewer_button(instance.viewer, "换个读法")
check(switch, "rewrite viewer has the style switch")
local first_viewer = instance.viewer
count_before = started
switch.callback()
local style_dialog = UI.shown[#UI.shown]
contains(style_dialog.title, "第一节 · 章节改写")
check(not first_viewer.closed, "viewer stays while the style dialog is open")
style_dialog.buttons[#style_dialog.buttons][1].callback()
check(style_dialog.closed); check(not first_viewer.closed); equal(instance.viewer, first_viewer)
switch.callback(); style_dialog = UI.shown[#UI.shown]
style_dialog.buttons[1][2].callback()
check(first_viewer.closed, "old viewer replaced"); check(instance.viewer ~= first_viewer)
equal(instance.result.id, humor.id); contains(instance.viewer.text, "另一种改写")
equal(started, count_before, "cached style starts no job"); equal(instance.job, nil)
-- While a job runs: cached styles just open, new ones hit the existing refusal.
instance:generate(instance:rewriteResult(2, Prompts.STYLES[3]))
local running_job = instance.job
check(running_job); equal(started, count_before + 1)
viewer_button(instance.viewer, "换个读法").callback()
UI.shown[#UI.shown].buttons[1][1].callback()
equal(instance.result.id, clear.id); equal(instance.job, running_job, "job continues"); equal(started, count_before + 1)
viewer_button(instance.viewer, "换个读法").callback()
UI.shown[#UI.shown].buttons[2][2].callback()
UI.shown[#UI.shown].ok_callback()
contains(UI.shown[#UI.shown].text, "已有任务正在生成"); equal(instance.job, running_job); equal(started, count_before + 1)
instance:stop()
equal(instance.legacyResult, nil); equal(instance.onKentReadOpen, nil); equal(Prompts.WRITE, nil)
doc.info.has_pages = true
count_before = started; instance:onKentReadRewrite(); equal(started, count_before)
contains(UI.shown[#UI.shown].text, "暂不支持 PDF")
doc.info.has_pages = false

-- QR setup lifecycle: saves, expiry, cancellation, suspend, and document close.
instance:setup()
check(instance.setup_server); check(instance.setup_queue)
contains(instance.setup_dialog.child.text, "http://192.168.1.20:43210/")
check(UI.queues[instance.setup_server]); check(UI.scheduled[instance.setup_timeout_cb])
local running = instance.setup_server
instance.setup_dialog.cancel_callback()
equal(instance.setup_server, nil); equal(running.listener, nil); check(not UI.queues[running])
instance:setup(); running = instance.setup_server
running.on_saved(); equal(instance.setup_server, nil); equal(instance.setup_dialog, nil)
instance:setup(); instance.setup_timeout_cb(); equal(instance.setup_server, nil)
instance:setup(); instance:onSuspend(); equal(instance.setup_server, nil)
instance:setup(); instance:onNetworkDisconnected(); equal(instance.setup_server, nil)
instance:setup(); instance:onEnterStandby(); equal(instance.setup_server, nil)
-- Kindle rules are reversed on close, and bind failure never opens the firewall.
local commands = {}
device.isKindle = function() return true end
os.execute = function(command) commands[#commands + 1] = command; return 0 end
instance:setup(); instance:stopSetup()
equal(#commands, 4); contains(commands[1], "iptables -I INPUT"); contains(commands[3], "iptables -D INPUT")
commands = {}
os.execute = function(command) commands[#commands + 1] = command; return 1 end
instance:setup(); equal(instance.setup_server, nil); equal(#commands, 4)
os.execute = execute; device.isKindle = function() return false end
instance:setup(); instance:onCloseDocument()
equal(instance.setup_server, nil); equal(instance.viewer, nil)
instance:setup(); equal(instance.setup_server, nil, "closed document cannot reopen setup asynchronously")
count_before = started
instance:generate(intro); equal(started, count_before, "closed document cannot generate asynchronously")

local second = setmetatable({ ui = ui, path = plugin }, Main)
second:init()
local saved_settings = read(Config.path())
write(Config.path(), '{"api_key":""}')
count_before = started
second:generate(intro); equal(started, count_before)
equal(UI.shown[#UI.shown].ok_text, "扫码配置", "missing key offers QR setup")
write(Config.path(), saved_settings)
local old_text = doc.getTextFromXPointers
doc.getTextFromXPointers = function() error("engine failure") end
second:generate(clear); equal(started, count_before)
contains(UI.shown[#UI.shown].text, "engine failure")
check(UI.shown[#UI.shown - 1].closed, "extraction spinner closes on error")
doc.getTextFromXPointers = old_text
local saved_content = read(second:htmlPath(clear))
second:generate(clear)
second.job.content = { "<p>不能提交的版本</p>" }; second.job.done = true
os.rename = function() return nil, "read-only filesystem" end
second:poll()
os.rename = old_rename
equal(read(second:htmlPath(clear)), saved_content)
equal(second.job, nil); check(second.regenerate_button.enabled)
contains(UI.shown[#UI.shown].text, "保存失败")
second:onCloseDocument()

-- Highlight search captures text before clearing the selection and never extracts a book.
local third = setmetatable({ ui = ui, path = plugin }, Main)
third:init()
check(ui.highlight.buttons["05_kentread_search"])
ui.highlight.selected_text = { text = "量子纠缠" }
local search_button = ui.highlight.buttons["05_kentread_search"](ui.highlight)
equal(search_button.text, "联网搜索")
search_button.callback()
equal(third.search_dialog.input, "量子纠缠"); equal(ui.highlight.selected_text, nil)
local input = third.search_dialog
count_before = started
input.input = string.rep("字", 129); input.buttons[1][3].callback()
equal(started, count_before); equal(third.search_dialog, input); contains(UI.shown[#UI.shown].text, "128")
input.input = "量子纠缠"
local extract_book, extract_chapter = Book.text, Book.chapterText
Book.text = function() error("search must not extract a book") end
Book.chapterText = Book.text
doc.info.has_pages = true -- search works on selected PDF text too
input.buttons[1][3].callback()
equal(started, count_before + 1); equal(third.job.task.kind, "search")
equal(calls[#calls].endpoint, "/v1/tools/search"); equal(calls[#calls].cfg.base_url, "https://api.deepseek.com")
equal(calls[#calls].cfg.api_key, "sk-search-only")
equal(calls[#calls].payload.query, "量子纠缠"); equal(calls[#calls].payload.count, 5)
equal(calls[#calls].payload.model, nil); equal(calls[#calls].payload.messages, nil)
contains(third.viewer.text, "正在通过 DeepSeek 联网搜索")
check(not viewer_button(third.viewer, "换个读法"), "search has no style switch")
equal(third.regenerate_button.text, "重新搜索")
local search_task = third.job.task
third.job.response = { results = { { title = "来源", url = "https://example.com/?x=1&y=2", snippet = "搜索摘要" } } }
third.job.done = true; third:poll()
equal(third.job, nil); contains(read(third:htmlPath(search_task)), "搜索摘要")
third.viewer.scroll_widget.htmlbox_widget.html_link_tapped_callback{ uri = "https://example.com/?x=1&y=2" }
equal(ui.link.external_url, "https://example.com/?x=1&y=2")
third.viewer.scroll_widget.htmlbox_widget.html_link_tapped_callback{ uri = "javascript:alert(1)" }
equal(ui.link.external_url, "https://example.com/?x=1&y=2", "unsafe source link is ignored")
third:onKentSearch("量子纠缠"); count_before = started
third.search_dialog.buttons[1][2].callback()
equal(started, count_before, "saved searches do not call the API")
contains(third.viewer.text, "搜索摘要")
third:onKentSearch("量子纠缠"); third.search_dialog.buttons[1][3].callback()
equal(started, count_before + 1, "explicit web search refreshes cached results")
third.job.error = "HTTP 429"; third.job.done = true; third:poll()
contains(read(third:htmlPath(search_task)), "搜索摘要", "failed search keeps saved results")
third:generate(search_task); local cancelled_search = third.job
third:stop(); check(cancelled_search.stopped); equal(third.job, nil)
third:generate(search_task); third.job.response = { results = {} }; third.job.done = true; third:poll()
contains(third.viewer.text, "没有找到匹配结果")
Book.text, Book.chapterText = extract_book, extract_chapter
doc.info.has_pages = false
-- Non-DeepSeek chat keys cannot accidentally be sent to DeepSeek Search.
saved_settings = read(Config.path())
local without_search_key = JSON.decode(saved_settings); without_search_key.search_api_key = nil
write(Config.path(), JSON.encode(without_search_key))
count_before = started; third:generate(search_task)
equal(started, count_before); equal(UI.shown[#UI.shown].ok_text, "扫码配置")
contains(UI.shown[#UI.shown].text, "单独填写")
write(Config.path(), saved_settings)
third:onKentSearch("退出时清理输入框"); input = third.search_dialog
third:onCloseDocument(); check(input.closed); equal(third.search_dialog, nil)
equal(ui.highlight.buttons["05_kentread_search"], nil, "highlight action removed on close")

-- Highlight explain: context is read before the menu closes; results are cached per book x text.
local fourth = setmetatable({ ui = ui, path = plugin }, Main)
fourth:init()
check(ui.highlight.buttons["05_kentread_search"]); check(ui.highlight.buttons["06_kentread_explain"])
local context_words
ui.toc.getTocTitleOfCurrentPage = function() return "第二节" end
ui.highlight.getSelectedWordContext = function(this, words)
    check(this.selected_text, "context is read while the selection exists")
    context_words = words
    return "划选之前的原文", "划选之后的原文"
end
ui.highlight.selected_text = { text = "  隐喻 " }
local explain_button = ui.highlight.buttons["06_kentread_explain"](ui.highlight)
equal(explain_button.text, "AI 解释")
count_before = started
explain_button.callback()
equal(context_words, 300); equal(ui.highlight.selected_text, nil)
equal(started, count_before, "explain asks before sending")
confirm = UI.shown[#UI.shown]
contains(confirm.text, "解释「隐喻」"); contains(confirm.text, "前后约 300 字原文")
contains(confirm.text, "可能产生费用"); equal(confirm.ok_text, "解释")
confirm.ok_callback()
equal(started, count_before + 1); equal(fourth.job.task.kind, "explain")
equal(calls[#calls].system, Prompts.EXPLAIN)
contains(calls[#calls].user, "书名：《测试书》"); contains(calls[#calls].user, "所在章节：第二节")
contains(calls[#calls].user, "……划选之前的原文\n划选的文字：\n隐喻\n后文：\n划选之后的原文……")
contains(fourth.viewer.text, "模型正在解释")
check(not viewer_button(fourth.viewer, "换个读法"), "explain has no style switch")
equal(fourth.regenerate_button.text, "重新解释")
local explain_task = fourth.job.task
equal(explain_task.dir, test_dir .. "/book.sdr/kentread/" .. Explain.id("隐喻"))
fourth.job.content = { "<p>解释正文</p>" }; fourth.job.thinking = { "推理" }; fourth.job.finish = "stop"; fourth.job.done = true
fourth:poll()
equal(fourth.job, nil)
contains(read(test_dir .. "/book.sdr/kentread/explain/" .. sha256_hex("隐喻") .. "/content.html"), "解释正文")
equal(read(test_dir .. "/book.sdr/kentread/explain/" .. sha256_hex("隐喻") .. "/thinking.txt"), "推理")
-- The same text from another spot opens the saved one; regenerating uses the new spot.
ui.highlight.getSelectedWordContext = function() return "另一处前文", "另一处后文" end
ui.highlight.selected_text = { text = "隐喻" }
count_before = started
ui.highlight.buttons["06_kentread_explain"](ui.highlight).callback()
equal(started, count_before, "cached explanation opens without a new job")
contains(fourth.viewer.text, "解释正文")
equal(fourth.regenerate_button.text, "重新解释"); check(fourth.regenerate_button.enabled)
fourth.regenerate_button.callback()
confirm = UI.shown[#UI.shown]; contains(confirm.text, "重新解释「隐喻」"); equal(confirm.ok_text, "重新解释")
confirm.ok_callback()
equal(started, count_before + 1); contains(calls[#calls].user, "另一处前文")
fourth.job.error = "HTTP 500"; fourth.job.done = true; fourth:poll()
contains(read(fourth:htmlPath(explain_task)), "解释正文", "failed regeneration keeps the saved explanation")
count_before = started
fourth:onKentExplain("  \n "); equal(started, count_before); contains(UI.shown[#UI.shown].text, "请先选中")
fourth:onKentExplain(string.rep("字", 1001)); equal(started, count_before); contains(UI.shown[#UI.shown].text, "超过 1000 字")
-- PDF: no context and no chapter list needed.
doc.info.has_pages = true
local chapters_before = Book.chapters
Book.chapters = function() error("explain must not read chapters") end
ui.highlight.getSelectedWordContext = nil
ui.highlight.selected_text = { text = "PDF 里的词" }
ui.highlight.buttons["06_kentread_explain"](ui.highlight).callback()
confirm = UI.shown[#UI.shown]
check(not confirm.text:find("前后约", 1, true)); contains(confirm.text, "解释「PDF 里的词」")
confirm.ok_callback()
equal(started, count_before + 1); contains(calls[#calls].user, "未取到上下文")
fourth.job.content = { '<p>PDF 解释</p><p class="src">原书：2</p>' }; fourth.job.finish = "stop"; fourth.job.done = true
fourth:poll()
equal(fourth.job, nil); contains(read(fourth:htmlPath(fourth.result)), "PDF 解释")
check(not read(fourth:htmlPath(fourth.result)):find("ch:", 1, true), "explain output has no source links")
Book.chapters = chapters_before; doc.info.has_pages = false
fourth:onCloseDocument()
equal(ui.highlight.buttons["05_kentread_search"], nil); equal(ui.highlight.buttons["06_kentread_explain"], nil)
local shown_before = #UI.shown
fourth:onKentExplain("关书之后"); equal(#UI.shown, shown_before, "closed document ignores explain")

-- Dictionary popup entries (single-word long-press): registered once per instance, one always-visible row.
local tools_count = 0
local function count_tools() tools_count = 0; for _, id in ipairs(tools_order) do if id == "kentread" then tools_count = tools_count + 1 end end end
local fifth = setmetatable({ ui = ui, path = plugin }, Main)
fifth:init(); count_tools()
equal(tools_count, 1, "second instance does not insert the Tools entry twice"); equal(tools_order[1], "kentread")
local dict_search, dict_explain = ui.dictionary.specs.kentread_1_search, ui.dictionary.specs.kentread_2_explain
check(dict_search and dict_explain)
equal(dict_search.text, "联网搜索"); equal(dict_explain.text, "AI 解释")
equal(dict_search.conditional, true); equal(dict_explain.conditional, true)
check(dict_search.row_group); equal(dict_search.row_group, dict_explain.row_group)
check(dict_search.show_func({ is_wiki = false })); check(dict_explain.show_func({}))
check(not dict_search.show_func({ is_wiki = true })); check(not dict_explain.show_func({ is_wiki = true }))
local function popup(word, highlight)
    local p = { word = word, highlight = highlight }
    function p:onClose() self.closed = true; if highlight then highlight.selected_text = nil end end
    return p
end
local function selection(text)
    local hl = { selected_text = { text = text }, getSelectedWordContext = function(this, words)
        check(this.selected_text, "context is read before the popup closes")
        context_words = words
        return "词典前文", "词典后文"
    end }
    return hl
end
-- Explain: same selection keeps its context.
local hl = selection("反讽")
local pop = popup("反讽", hl); context_words = nil; count_before = started
dict_explain.callback(pop)
check(pop.closed); equal(context_words, 300); equal(started, count_before, "explain asks before sending")
confirm = UI.shown[#UI.shown]
contains(confirm.text, "解释「反讽」"); contains(confirm.text, "前后约 300 字原文")
-- Explain: selection no longer matches the word, so no context is sent.
hl = selection("别的词"); pop = popup("反讽", hl); context_words = nil
dict_explain.callback(pop)
check(pop.closed); equal(context_words, nil)
confirm = UI.shown[#UI.shown]; contains(confirm.text, "解释「反讽」"); check(not confirm.text:find("前后约", 1, true))
-- Explain: a lookup without any selection (dictionary opened from the menu).
dict_explain.callback(popup("反讽")); check(not UI.shown[#UI.shown].text:find("前后约", 1, true))
-- Search opens the editable dialog with the word.
pop = popup("量子纠缠", selection("量子纠缠"))
dict_search.callback(pop)
check(pop.closed); equal(fifth.search_dialog.input, "量子纠缠")
-- A closed document ignores late taps.
fifth:onCloseDocument(); shown_before = #UI.shown; pop = popup("反讽")
dict_explain.callback(pop); dict_search.callback(pop)
equal(#UI.shown, shown_before); check(not pop.closed)
-- Older KOReader without the dictionary button extension still starts.
local old_dictionary = ui.dictionary
ui.dictionary = {}
local sixth = setmetatable({ ui = ui, path = plugin }, Main)
check(pcall(sixth.init, sixth)); sixth:onCloseDocument()
ui.dictionary = nil
sixth = setmetatable({ ui = ui, path = plugin }, Main)
check(pcall(sixth.init, sixth)); sixth:onCloseDocument()
ui.dictionary = old_dictionary

-- The writing animation (here Hemingway's) shown while the model is still thinking.
local Writing = require("kr_writing")
local concise = Prompts.STYLES[3]
equal(concise.id, "concise")
local function writer_for(style)
    local w = setmetatable({ ui = ui, path = plugin }, Main)
    w:init()
    local task = w:rewriteResult(2, style)
    w.job = { content = {}, thinking = {}, task = task }
    w.result = task
    w:show()
    w.viewer.scroll_widget.htmlbox_widget.page_count = 1
    return w
end
local w = writer_for(concise)
check(w.writing); equal(w.viewer.textw[1], w.writing); check(UI.scheduled[w.writing.tick_cb]); equal(live, 4)
local inits = w.viewer.init_count
w.job.thinking = { "想", "想法" }; w:poll()
w.job.thinking = { "想", "想法", "更多想法" }; w:poll()
equal(w.viewer.init_count, inits, "growing thinking text does not rebuild the viewer")
local mounted = w.writing
w:refresh(w:html()); equal(w.writing, mounted, "refresh keeps the animation going")
equal(w.viewer.textw[1], mounted); equal(w.viewer.init_count, inits + 1)
-- first body text switches back to the streamed text
w.viewer.scroll_widget.htmlbox_widget.page_count = 1
w.job.content = { "<p>正文</p>" }; w:poll()
equal(w.viewer.textw[1], w.viewer.scroll_widget); equal(w.writing, nil)
check(not UI.scheduled[mounted.tick_cb]); equal(live, 0)
w:closeViewer()
-- closing the viewer stops the animation, via closeViewer and via the close button
w = writer_for(concise); local tick = w.writing.tick_cb
w:closeViewer(); check(not UI.scheduled[tick]); equal(w.writing, nil); equal(live, 0)
w = writer_for(concise); tick = w.writing.tick_cb
w.viewer.close_callback(); check(not UI.scheduled[tick]); equal(w.writing, nil); equal(live, 0)
w = writer_for(concise); tick = w.writing.tick_cb
w:onCloseDocument(); check(not UI.scheduled[tick]); equal(live, 0)
-- expanding the thinking shows it instead; collapsing brings the animation back
w = writer_for(concise); w.job.thinking = { "想法" }
tick = w.writing.tick_cb
w:toggleThinking()
equal(w.viewer.textw[1], w.viewer.scroll_widget); equal(w.writing, nil); check(not UI.scheduled[tick]); equal(live, 0)
contains(w.viewer.text, "想法")
w:toggleThinking()
check(w.writing); equal(w.viewer.textw[1], w.writing); check(UI.scheduled[w.writing.tick_cb]); equal(live, 4)
-- stopping the job ends the phase
w:stop(); equal(w.writing, nil); equal(live, 0)
w:closeViewer()
-- animation logic, for every scene: parts, text, dirty region, refresh modes
local ids = {}
for id in pairs(Writing.SCENES) do ids[#ids + 1] = id end
table.sort(ids)
equal(#ids, #Prompts.STYLES)
for _, st in ipairs(Prompts.STYLES) do
    check(Writing.supports(st.id), st.id .. " has a scene")
    for _, suffix in ipairs({ ".png", "-a.png", "-b.png" }) do
        check(io.open("art/" .. Writing.SCENES[st.id].file .. suffix, "rb"), st.id .. " art " .. suffix)
    end
end
local author = {}
for _, st in ipairs(Prompts.STYLES) do author[st.id] = st.author end
local TAIL = { [0] = "", "a", "", "b" }
-- master boxes { x0, y0, x1, y1 }, x1/y1 exclusive
local function overlap(p, q) return p[1] < q[3] and q[1] < p[3] and p[2] < q[4] and q[2] < p[4] end
-- master box to px like Canvas:rect, from the scene data
local function scaled(box, pad, c)
    local sc = c.art_w / 1024
    local x0, y0 = math.max(0, math.floor(box[1] * sc) - pad), math.max(0, math.floor(box[2] * sc) - pad)
    local x1, y1 = math.min(c.art_w, math.ceil(box[3] * sc) + pad), math.min(c.art_h, math.ceil(box[4] * sc) + pad)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
for _, id in ipairs(ids) do
    local scene = Writing.SCENES[id]
    local canvas = Writing.new{ style = id, author = author[id], width = 500, height = 700, dir = "/plug" }
    equal(canvas.art_h + canvas.cap_h <= 700, true)
    equal(canvas.art_w, math.floor(canvas.art_h * 2 / 3))
    contains(canvas.caption.text, author[id] .. scene.verb)
    canvas.dialog = {}
    local drawn = {}
    Render.paths = {}
    canvas:start(); canvas:start()
    equal(#Render.paths, 3, "images load once per start"); equal(live, 4)
    local paths = table.concat(Render.paths, " ")
    for _, suffix in ipairs({ ".png", "-a.png", "-b.png" }) do contains(paths, "/plug/art/" .. scene.file .. suffix) end
    local base, A, B = canvas.imgs[""], canvas.imgs.a, canvas.imgs.b
    equal(base.w, canvas.art_w); equal(base.h, canvas.art_h)
    local frame = canvas.frame
    check(frame ~= base, "frame is a copy")
    canvas:paintTo({ blitFrom = function(_, src, ...) drawn = { src, ... } end }, 10, 20)
    equal(drawn[1], frame); equal(drawn[2], 10 + math.floor((500 - canvas.art_w) / 2))
    -- part rects grow by 3 px, stay inside the art; the union covers them and the wipe
    local want, want0, roles, n = {}, {}, {}, 0
    for pi, part in ipairs(scene.parts) do
        for i = 2, #part do
            n = n + 1; want[n] = scaled(part[i], 3, canvas); want0[n] = { pi = pi, r = part[i] }
            roles[n] = part[1]
        end
    end
    equal(#canvas.parts, n)
    local u, wipe = canvas.union, canvas.wipe
    local function inside(r, o) return r.x >= o.x and r.y >= o.y and r.x + r.w <= o.x + o.w and r.y + r.h <= o.y + o.h end
    for i, p in ipairs(canvas.parts) do
        equal(p.role, roles[i])
        for _, k in ipairs({ "x", "y", "w", "h" }) do equal(p[k], want[i][k]) end
        check(inside(p, { x = 0, y = 0, w = canvas.art_w, h = canvas.art_h }))
        check(inside(p, u), "union covers every part")
    end
    if scene.text or scene.hand then
        for _, k in ipairs({ "x", "y", "w", "h" }) do equal(wipe[k], scaled((scene.text or scene.hand).wipe, 0, canvas)[k]) end
        check(inside(wipe, u), "union covers the wipe")
    else
        equal(wipe, nil)
    end
    for i = 1, n do
        if wipe then check(not overlap(want0[i].r, (scene.text or scene.hand).wipe), "wipe overlaps no part") end
        for j = i + 1, n do
            if want0[i].pi ~= want0[j].pi then check(not overlap(want0[i].r, want0[j].r), id .. " parts do not overlap " .. i .. j) end
        end
    end
    local keep = scene.text and math.floor((scene.text.y - scene.text.wipe[2]) / 21) or 0
    local dings, last_hand, typed_n, rest_n, bars, max_lines, pages = 0, nil, 0, 0, 0, 0, 0
    UI.dirty, UI.regions, logs = {}, {}, {}
    for _ = 1, scene.hand and 1500 or 600 do
        local before, fr, rows_before = canvas.state.len, canvas.state.fr, #canvas.state.lines
        frame.calls = {}
        canvas:tick()
        local s = canvas.state
        local ding, typed = s.len == 0 and before ~= 0, s.len == before + 12
        dings = dings + (ding and 1 or 0)
        equal(s.fr, fr + 1)
        max_lines = math.max(max_lines, #s.lines)
        if scene.hand then
            check(#s.lines < scene.hand.rows, "page never overfills")
            if #s.lines < rows_before then pages = pages + 1 end
        end
        local blits = {}
        for _, c in ipairs(frame.calls) do
            if c[1] == "blit" then blits[#blits + 1] = c end
            if c[1] == "paint" then
                bars = bars + 1
                check(c[6] == "black" and c[4] >= 1 and c[5] >= 1 and inside({ x = c[2], y = c[3], w = c[4], h = c[5] }, wipe))
            end
        end
        if wipe then
            local c = frame.calls[1]
            equal(c[1], "blit"); equal(c[2], base); equal(c[3], wipe.x); equal(c[4], wipe.y); equal(c[7], wipe.w); equal(c[8], wipe.h)
            table.remove(blits, 1)
        end
        equal(#blits, n)
        local keys_src
        for i, c in ipairs(blits) do
            equal(c[3], canvas.parts[i].x); equal(c[4], canvas.parts[i].y)
            equal(c[7], canvas.parts[i].w); equal(c[8], canvas.parts[i].h)
            if roles[i] == "keys" then
                keys_src = keys_src or c[2]
                equal(c[2], keys_src, "keys parts share one source")
            elseif roles[i] == "cycle" then
                equal(c[2], ({ [0] = base, A, base, B })[math.floor(s.fr / 5) % 4], "cycle follows TAIL_CYCLE")
            else
                equal(c[2], ding and A or base, "ding only on the line feed")
            end
        end
        if keys_src then
            if typed then
                typed_n = typed_n + 1
                check(keys_src == A or keys_src == B)
                check(keys_src ~= last_hand, "hands alternate on keystrokes")
                last_hand = keys_src
            else
                rest_n = rest_n + 1
                equal(keys_src, base, "keys rest on spaces and line feeds")
            end
        end
        local region = UI.regions[#UI.regions]
        equal(region.x, canvas.art.x + u.x); equal(region.y, canvas.art.y + u.y)
        equal(region.w, u.w); equal(region.h, u.h)
        equal(UI.dirty[#UI.dirty], "fast", "never the flashing GC16 refresh")
    end
    check(dings > 5, "line feeds happen"); check(max_lines <= keep or not scene.text)
    if scene.text then check(max_lines >= 3 and bars > 0) elseif scene.hand then check(bars > 0 and pages > 0, "fresh pages happen") else equal(bars, 0) end
    check(typed_n > 0 and rest_n > 0)
    equal(#Render.paths, 3, "no reload while running")
    local avg = 0; for _, entry in ipairs(logs) do if entry:find("avg frame ms", 1, true) then avg = avg + 1 end end
    equal(avg, dings, "average frame time logged once per line feed")
    canvas:stop(); canvas:stop(); equal(canvas.frame, nil); equal(live, 0)
end
-- load failure frees what loaded, logs once and does not run
for _, bad in ipairs({ "writing-hemingway.png", "-a.png", "-b.png" }) do
    Render.fail_on = bad; logs = {}
    local c = Writing.new{ style = "concise", author = "海明威", width = 500, height = 700, dir = "/plug" }
    c:start()
    equal(c.running, nil); equal(c.frame, nil); equal(live, 0); equal(#logs, 1); contains(logs[1], "cannot load")
    check(not UI.scheduled[c.tick_cb]); c:stop()
end
Render.fail_on = nil
equal(Writing.available(), true)
print("PASS: " .. passed .. " Lua assertions (book, prompts, search, explain, config, HTTP, SSE, UI, lifecycle)")
