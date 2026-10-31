-- Streams one OpenAI-compatible chat request through the system curl: the key
-- travels in a private curl config file, never on the command line.
-- curl runs in a subprocess and writes the event stream to a file, which the reader polls.
local DataStorage = require("datastorage")
local JSON = require("json")
local ffiutil = require("ffi/util")
local util = require("util")

local M = {}

local function shell(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function private(path, content)
    local f = assert(io.open(path, "wb"))
    local permission = os.execute("chmod 600 " .. shell(path))
    if permission ~= 0 and permission ~= true then
        f:close()
        error("无法设置请求缓存权限", 0)
    end
    local written = f:write(content)
    local closed = f:close()
    assert(written and closed, "无法写入请求缓存")
end

local function readFrom(path, offset)
    local f = io.open(path, "rb")
    if not f then return "" end
    f:seek("set", offset)
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function cleanup(job)
    for _, path in ipairs{ job.conf, job.body, job.out, job.status } do os.remove(path) end
end

--- Shared transport for streaming chat and ordinary JSON tool APIs.
function M.request(cfg, endpoint, body, timeout)
    local dir = DataStorage:getDataDir() .. "/cache/kentread"
    util.makePath(dir)
    local base = string.format("%s/.%d-%d", dir, os.time(), math.random(1, 1e9))
    local job = {
        conf = base .. ".conf", body = base .. ".body", out = base .. ".out", status = base .. ".status",
        offset = 0, rest = "", content = {}, thinking = {},
    }
    local prepared = pcall(function()
        private(job.conf, 'header = "Content-Type: application/json"\n'
            .. 'header = "Authorization: Bearer ' .. cfg.api_key .. '"\n')
        private(job.body, JSON.encode(body))
    end)
    if not prepared then
        cleanup(job)
        return nil, "无法写入私有请求缓存，请检查权限和设备剩余空间。"
    end
    local url = cfg.base_url:gsub("/+$", "") .. endpoint
    local cmd = "/usr/bin/curl --silent --no-buffer --ipv4 --connect-timeout 15 --max-time "
        .. tostring(timeout or 1800) .. " -K " .. shell(job.conf)
        .. " --data-binary @" .. shell(job.body) .. " -o " .. shell(job.out)
        .. " --write-out '%{http_code}' " .. shell(url) .. " > " .. shell(job.status)
        .. " 2>/dev/null; printf ' %s' \"$?\" >> " .. shell(job.status)
    job.pid = ffiutil.runInSubProcess(function() os.execute(cmd) end)
    if not job.pid then
        cleanup(job)
        return nil, "无法启动后台任务"
    end
    return job
end

--- Starts a streaming chat request. Returns a job for M.poll.
function M.start(cfg, system, user, temperature)
    local body = {
        model = cfg.model,
        temperature = temperature,
        max_tokens = cfg.max_tokens or 8192,
        stream = true,
        messages = { { role = "system", content = system }, { role = "user", content = user } },
    }
    for k, v in pairs(cfg.extra or {}) do body[k] = v end
    return M.request(cfg, "/chat/completions", body)
end

-- One server-sent event line: answer text goes to job.content, thinking to job.thinking.
local function take(job, line)
    local data = line:match("^data:%s*(.-)%s*$")
    if not data or data == "[DONE]" then return end
    local ok, event = pcall(JSON.decode, data)
    local choice = ok and type(event) == "table" and type(event.choices) == "table" and event.choices[1]
    if type(choice) ~= "table" then return end
    local delta = type(choice.delta) == "table" and choice.delta or {}
    if type(delta.content) == "string" then table.insert(job.content, delta.content) end
    if type(delta.reasoning_content) == "string" then table.insert(job.thinking, delta.reasoning_content) end
    if type(choice.finish_reason) == "string" then job.finish = choice.finish_reason end
end

local function httpFailure(job)
    local status, code = readFrom(job.status, 0):match("^(%d%d%d) (%d+)$")
    if not status then return "网络请求失败" end
    if code ~= "0" then return "网络错误（curl " .. code .. "）" end
    if status ~= "200" then
        local ok, payload = pcall(JSON.decode, readFrom(job.out, 0))
        local message = ok and type(payload) == "table" and type(payload.error) == "table" and payload.error.message
        return "HTTP " .. status .. (type(message) == "string" and ("：" .. message:sub(1, 200)) or "")
    end
end

local function failure(job)
    local err = httpFailure(job)
    if err then return err end
    if #job.content == 0 then return "模型返回为空" end
    if not job.finish then return "连接中断，正文没写完" end
end

--- Takes in what has arrived since the last call. Returns true once the request
--- has ended; job.error is then set if it failed.
function M.poll(job)
    local done = ffiutil.isSubProcessDone(job.pid)
    local s = readFrom(job.out, job.offset)
    job.offset = job.offset + #s
    job.rest = job.rest .. s
    local last = 1
    for line, pos in job.rest:gmatch("([^\n]*)\n()") do
        take(job, line)
        last = pos
    end
    job.rest = job.rest:sub(last)
    if not done then return false end
    take(job, job.rest)
    job.error = failure(job)
    cleanup(job)
    return true
end

--- Ordinary JSON responses (Search is not an SSE/chat endpoint).
function M.pollJSON(job)
    if not ffiutil.isSubProcessDone(job.pid) then return false end
    job.error = httpFailure(job)
    if not job.error then
        local f = io.open(job.out, "rb")
        local data = f and f:read(2 * 1024 * 1024 + 1) or ""
        if f then f:close() end
        if #data > 2 * 1024 * 1024 then
            job.error = "接口响应过大"
        else
            local ok, payload = pcall(JSON.decode, data)
            if ok and type(payload) == "table" then job.response = payload
            else job.error = "接口没有返回有效的 JSON" end
        end
    end
    cleanup(job)
    return true
end

--- Kills curl along with the subprocess.
function M.stop(job)
    ffiutil.terminateSubProcess(job.pid)
    ffiutil.isSubProcessDone(job.pid, true)
    cleanup(job)
end

return M
