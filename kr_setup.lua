-- A short-lived, nonblocking LAN setup server. No request/response logging:
-- neither the pairing token nor submitted API keys belong in KOReader logs.
local socket = require("socket")
local Config = require("kr_config")

local M = {}
local Server = {}
Server.__index = Server
local MAX_HEADERS, MAX_BODY, MAX_CLIENTS = 8192, 16384, 4
M.LIFETIME = 300

local function escape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function response(code, body, html)
    local reasons = { [200] = "OK", [400] = "Bad Request", [403] = "Forbidden",
        [405] = "Method Not Allowed", [410] = "Gone", [413] = "Content Too Large",
        [415] = "Unsupported Media Type", [431] = "Request Header Fields Too Large",
        [500] = "Internal Server Error" }
    return "HTTP/1.1 " .. code .. " " .. reasons[code] .. "\r\n"
        .. "Content-Type: " .. (html and "text/html" or "text/plain") .. "; charset=utf-8\r\n"
        .. "Content-Length: " .. #body .. "\r\nConnection: close\r\n"
        .. "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        .. "X-Content-Type-Options: nosniff\r\n"
        .. "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        .. body
end

local function decode(s)
    -- Reject malformed escapes rather than silently saving a damaged key.
    if s:gsub("%%[a-fA-F0-9][a-fA-F0-9]", ""):find("%%") then return end
    return (s:gsub("%+", " "):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function form(body)
    local fields = {}
    for part in (body .. "&"):gmatch("(.-)&") do
        local encoded_key, encoded_value = part:match("^([^=]+)=(.*)$")
        if not encoded_key then return end
        local key, value = decode(encoded_key), decode(encoded_value)
        if not key or not value or fields[key] ~= nil then return end
        if key ~= "base_url" and key ~= "model" and key ~= "api_key" and key ~= "search_api_key" then return end
        fields[key] = value
    end
    return fields
end

local function localAddress()
    local udp = socket.udp()
    if not udp then return end
    -- UDP connect chooses the local IPv4 route without sending a packet.
    local ok = udp:setpeername("192.0.2.1", 9)
    local ip = ok and udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" and not ip:match("^127%.") then return ip end
end

local function token()
    local f = io.open("/dev/urandom", "rb")
    if not f then return end
    local bytes = f:read(16)
    f:close()
    if not bytes or #bytes ~= 16 then return end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.start(options)
    local ip = localAddress()
    if not ip then return nil, "无法获取局域网 IPv4 地址，请先连接 Wi-Fi。" end
    local secret = token()
    if not secret then return nil, "无法创建安全的临时配网地址，请使用 USB 配置。" end
    local f = io.open(options.path .. "/setup.html", "rb")
    if not f then return nil, "配网页面缺失，请重新安装完整插件。" end
    local page = f:read("*a")
    f:close()
    local cfg = Config.load(options.path)
    local values = { base_url = cfg.base_url, model = cfg.model,
        key_hint = (cfg.api_key or "") ~= "" and "已配置，留空保留原密钥" or "粘贴服务商提供的 API 密钥",
        search_key_hint = (cfg.search_api_key or "") ~= "" and "已单独配置，留空保留" or "官方 DeepSeek 主接口可留空复用密钥" }
    page = page:gsub("{{([%w_]+)}}", function(key) return escape(values[key]) end)
    local listener = socket.bind(ip, 0)
    if not listener then return nil, "无法启动配网服务，请检查网络后重试。" end
    listener:settimeout(0)
    local _, port = listener:getsockname()
    local authority = ip .. ":" .. port
    local server = setmetatable({ listener = listener, clients = {}, page = page,
        path = options.path, route = "/" .. secret, authority = authority,
        origin = "http://" .. authority, expires = socket.gettime() + M.LIFETIME,
        on_saved = options.on_saved, on_timeout = options.on_timeout }, Server)
    server.url = server.origin .. server.route
    server.port = tonumber(port)
    return server
end

-- nil means more bytes are needed; a string is a complete HTTP response.
function Server:request(data)
    if self.saved or socket.gettime() >= self.expires then
        return response(410, "此配网页面已失效，请在阅读器上重新打开扫码配置。")
    end
    local boundary = data:find("\r\n\r\n", 1, true)
    if not boundary then
        if #data > MAX_HEADERS then return response(431, "请求头过长。") end
        return
    end
    if boundary > MAX_HEADERS then return response(431, "请求头过长。") end
    local head = data:sub(1, boundary + 1)
    local method, route = head:match("^(%u+) ([^ ]+) HTTP/1%.[01]\r\n")
    if not method then return response(400, "请求格式不正确。") end
    local headers = {}
    for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
        local key = name:lower()
        if headers[key] then return response(400, "请求头重复。") end
        headers[key] = value:match("^(.-)%s*$")
    end
    -- Pin the Host header as well as the secret route to prevent DNS rebinding.
    if route ~= self.route or headers.host ~= self.authority
        or (headers.origin and headers.origin ~= self.origin)
        or headers["sec-fetch-site"] == "cross-site" then
        return response(403, "配网地址无效，请扫描阅读器上显示的二维码。")
    end
    if method == "GET" then return response(200, self.page, true) end
    if method ~= "POST" then return response(405, "请通过配网页面提交配置。") end
    if headers["transfer-encoding"] then return response(400, "不支持分块请求。") end
    local length = headers["content-length"]
    if not length or not length:match("^%d+$") then return response(400, "缺少有效的请求长度。") end
    length = tonumber(length)
    if length > MAX_BODY then return response(413, "配置内容过长。") end
    local content_type = (headers["content-type"] or ""):lower():match("^([^;]+)") or ""
    if content_type:match("^%s*(.-)%s*$") ~= "application/x-www-form-urlencoded" then
        return response(415, "请通过配网页面提交配置。")
    end
    local body_start = boundary + 4
    if #data < body_start + length - 1 then return end
    if #data ~= body_start + length - 1 then return response(400, "请求长度不一致。") end
    local fields = form(data:sub(body_start))
    if not fields then return response(400, "配置格式不正确，请返回重试。") end
    local ok, saved, err = pcall(Config.save, self.path, fields)
    if not ok then return response(500, "保存失败，请检查阅读器的设置目录和剩余空间。") end
    if not saved then return response(400, err) end
    self.saved = true
    return response(200, "配置已保存，可以关闭此页面并返回阅读器生成内容。配网服务已关闭。"), true
end

function Server:stop()
    if self.listener then self.listener:close(); self.listener = nil end
    for client in pairs(self.clients) do client:close() end
    self.clients = {}
end

-- UIManager polls this queue every 50 ms. All network I/O is nonblocking,
-- including partial request bodies and partial response writes.
function Server:waitEvent()
    if not self.listener then return end
    if socket.gettime() >= self.expires then
        self:stop()
        if self.on_timeout then self.on_timeout() end
        return
    end
    local count = 0
    for _ in pairs(self.clients) do count = count + 1 end
    if count < MAX_CLIENTS then
        local client = self.listener:accept()
        if client then
            client:settimeout(0)
            self.clients[client] = { input = "", offset = 1, deadline = socket.gettime() + 10 }
        end
    end
    local saved_response_done = false
    for client, state in pairs(self.clients) do
        local close = socket.gettime() >= state.deadline
        if not close and not state.output then
            local data, err, partial = client:receive(4096)
            state.input = state.input .. (data or partial or "")
            state.output, state.saved = self:request(state.input)
            if err == "closed" and not state.output then close = true end
        end
        if not close and state.output then
            local sent, err, last = client:send(state.output, state.offset)
            state.offset = (sent or last or state.offset - 1) + 1
            close = state.offset > #state.output or (err and err ~= "timeout")
        end
        if close then
            client:close()
            self.clients[client] = nil
            if state.saved then saved_response_done = true end
        end
    end
    if saved_response_done and self.on_saved then
        local callback = self.on_saved
        self.on_saved = nil
        callback()
    end
end

return M
