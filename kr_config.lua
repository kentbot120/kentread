-- Browser setup is stored outside the plugin directory; config.lua is the
-- file-based alternative and holds advanced request parameters.
local DataStorage = require("datastorage")
local JSON = require("json")

local M = {}

local function trim(s)
    -- Lua's locale-dependent %s/%c classes can classify UTF-8 continuation
    -- bytes as whitespace/control characters on some hosts. Match ASCII only.
    return type(s) == "string" and s:match("^[ \t\r\n\v\f]*(.-)[ \t\r\n\v\f]*$") or ""
end

local function validKey(key)
    return key ~= "" and #key <= 4096 and not key:find('[%z\1-\32\127"\\]')
end

local function officialDeepSeek(url)
    url = trim(url):lower():gsub("/+$", "")
    return url == "https://api.deepseek.com" or url == "https://api.deepseek.com/v1"
end

function M.path()
    return DataStorage:getSettingsDir() .. "/kentread.json"
end

function M.load(plugin_path)
    local ok, cfg = pcall(dofile, plugin_path .. "/config.lua")
    if not ok or type(cfg) ~= "table" then
        cfg = dofile(plugin_path .. "/config.sample.lua")
    end
    local f = io.open(M.path(), "rb")
    if f then
        local data = f:read("*a")
        f:close()
        local decoded, saved = pcall(JSON.decode, data)
        if decoded and type(saved) == "table" then
            -- A different provider must not inherit DeepSeek-specific options.
            if type(saved.base_url) == "string"
                and saved.base_url:gsub("/+$", "") ~= (cfg.base_url or ""):gsub("/+$", "") then
                cfg.extra = nil
            end
            for _, key in ipairs{ "base_url", "api_key", "model", "search_api_key" } do
                if type(saved[key]) == "string" then cfg[key] = saved[key] end
            end
        end
    end
    return cfg
end

function M.validate(cfg)
    if type(cfg) ~= "table" then return nil, "配置格式不正确。" end
    local url = trim(cfg.base_url):gsub("/+$", "")
    local key, model = trim(cfg.api_key), trim(cfg.model)
    local authority = url:match("^https?://([^/]+)")
    if not authority or authority:find("[@?#]") or url:find("[%z\1-\32\127?#]") or #url > 2048 then
        return nil, "接口地址须以 https:// 或 http:// 开头，不含用户名、密码、查询参数或空白。"
    end
    if not validKey(key) then
        return nil, "请填写有效的 API 密钥（不能包含空白、引号或反斜杠）。"
    end
    if model == "" or #model > 256 or model:find("[%z\1-\31\127]") then
        return nil, "请填写有效的模型名称。"
    end
    local result = { base_url = url, api_key = key, model = model }
    local search_key = trim(cfg.search_api_key)
    if search_key ~= "" then
        if not validKey(search_key) then return nil, "请填写有效的 DeepSeek 搜索密钥。" end
        result.search_api_key = search_key
    end
    return result
end

-- Never send an arbitrary provider's key to DeepSeek. An explicitly supplied
-- search key wins; otherwise only the official DeepSeek chat key may be reused.
function M.search(plugin_path)
    local cfg = M.load(plugin_path)
    local key = trim(cfg.search_api_key)
    if key == "" and officialDeepSeek(cfg.base_url) then key = trim(cfg.api_key) end
    if not validKey(key) then
        return nil, "DeepSeek 搜索需要 DeepSeek API 密钥。主接口不是官方 DeepSeek 时，请在扫码配置页单独填写「DeepSeek 搜索 API 密钥」。"
    end
    return { base_url = "https://api.deepseek.com", api_key = key }
end

function M.save(plugin_path, fields)
    if type(fields) ~= "table" then return nil, "配置格式不正确。" end
    local old = M.load(plugin_path)
    local input = {
        base_url = fields.base_url,
        model = fields.model,
        api_key = fields.api_key,
        search_api_key = trim(fields.search_api_key) ~= "" and fields.search_api_key or old.search_api_key,
    }
    if trim(input.api_key) == "" then
        if trim(input.base_url):gsub("/+$", "") ~= trim(old.base_url):gsub("/+$", "") then
            return nil, "更换接口地址时，请重新填写密钥，避免把旧密钥发送给其他服务。"
        end
        input.api_key = old.api_key
    end
    local cfg, err = M.validate(input)
    if not cfg then return nil, err end

    -- Open with owner-only permissions before writing any secret. The old file
    -- is replaced only after a complete write, so a failed save leaves it intact.
    local path = M.path()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return nil, "无法写入 KOReader 设置目录。" end
    local result = os.execute("chmod 600 '" .. tmp:gsub("'", "'\\''") .. "'")
    if result ~= 0 and result ~= true then
        f:close()
        os.remove(tmp)
        return nil, "无法设置密钥文件权限。"
    end
    local encoded, data = pcall(JSON.encode, cfg)
    local written = encoded and f:write(data)
    local closed = f:close()
    if not written or not closed then
        os.remove(tmp)
        return nil, "配置写入失败，请检查剩余空间。"
    end
    local renamed = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, "无法保存配置。"
    end
    return true
end

return M
