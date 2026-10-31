--[[--
改写开头（模型还在思考、正文未开始）时显示的定格动画。
按文风选作者场景（海明威打字、老舍写字、单田芳说书……）。三张预渲染的灰度图（静止/A/B）一次载入，每 0.25 秒只在内存里重画打字稿并贴换动作部件的小块。
]]
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local has_render, RenderImage = pcall(require, "ui/renderimage")

local INTERVAL = 0.25
-- Geometry is in 1024x1536 design units; the 800x1200 art is scaled to art_w and coordinates by art_w / 1024 at runtime.
local CH, SPACE, LEAD, STROKE, HAND_STROKE = 12, 21, 21, 7, 5
local TAIL_CYCLE = { "", "a", "", "b" }
local FILES = { [""] = "", a = "-a", b = "-b" }

-- A segment keeps its own wave (A, P, ph, ph2) so handwriting repaints identically while it grows.
local function seg(a, b)
    return { a, b, A = 3 + 2 * math.random(), P = 18 + 8 * math.random(), ph = 2 * math.pi * math.random(), ph2 = 2 * math.pi * math.random() }
end

local function filled(line)
    local segs, x = {}, 0
    while x < line - 24 do
        local w = CH * math.random(1, 6)
        segs[#segs + 1] = seg(x, math.min(line, x + w))
        x = x + w + SPACE
    end
    return segs
end

-- keep: rows the typewriter page holds; rows: rows of a handwriting page.
local function newTyping(line, keep, rows)
    local lines = { filled(line), filled(line) }
    if not rows then lines[3] = filled(line) end
    return { lines = lines, cur = {}, len = 0, gap = true, fr = 0, line = line, keep = keep, rows = rows }
end

-- One keystroke per frame. Returns true on the frame the carriage snaps back.
local function step(s)
    if s.len >= s.line - CH or (s.gap and s.len > s.line - 48 and math.random() < 0.3) then
        if s.rows then
            s.lines[#s.lines + 1] = s.cur
            if #s.lines >= s.rows then s.lines = {} end
        else
            table.insert(s.lines, 1, s.cur)
            s.lines[s.keep + 1] = nil
        end
        s.cur, s.len, s.gap = {}, 0, true
        return true
    end
    if not s.gap and math.random() < 0.22 then s.len = s.len + SPACE; s.gap = true; return false end
    if s.gap then s.cur[#s.cur + 1] = seg(s.len, s.len + CH) else s.cur[#s.cur][2] = s.len + CH end
    s.len = s.len + CH
    s.gap = false
    return false
end

-- text = typewriter page that scrolls up; hand = wavy handwriting that fills a page, then starts a fresh one.
-- hand: wipe box; x, y origin of row 0; along unit direction of writing; step offset between rows; line row length; rows row count.
-- Part roles: keys swap a/b per keystroke, cycle follows TAIL_CYCLE, ding shows a on the line-feed frame.
local SCENES = {
    concise = {
        file = "writing-hemingway", verb = "在写",
        text = { wipe = { 434, 678, 598, 822 }, x = 437, y = 814, line = 158 },
        parts = {
            { "keys", { 220, 748, 417, 978 } }, { "keys", { 615, 747, 749, 858 } },
            { "cycle", { 100, 979, 250, 1140 } },
        },
    },
    humor = {
        file = "writing-laoshe", verb = "在写",
        hand = { wipe = { 420, 780, 596, 893 }, x = 432, y = 885, along = { 0, -1 }, step = { 21, 0 }, line = 99, rows = 8 },
        parts = { { "keys", { 193, 555, 406, 858 } }, { "cycle", { 682, 694, 846, 895 } } },
    },
    pingshu = {
        file = "writing-shantianfang", verb = "在讲",
        parts = {
            { "keys", { 511, 381, 590, 460 } }, { "cycle", { 29, 75, 490, 863 }, { 490, 734, 503, 766 } },
            { "ding", { 608, 619, 899, 891 } },
        },
    },
    clear = {
        file = "writing-feynman", verb = "在写",
        hand = { wipe = { 376, 769, 659, 892 }, x = 647, y = 882, along = { -1, 0 }, step = { 0, -21 }, line = 259, rows = 5 },
        parts = { { "keys", { 171, 590, 371, 841 } }, { "cycle", { 696, 472, 922, 722 } } },
    },
    story = {
        file = "writing-zweig", verb = "在写",
        hand = { wipe = { 367, 743, 672, 886 }, x = 660, y = 876, along = { -1, 0 }, step = { 0, -21 }, line = 281, rows = 6 },
        parts = { { "keys", { 180, 549, 360, 860 } }, { "cycle", { 762, 199, 871, 382 } } },
    },
    dialogue = {
        file = "writing-plato", verb = "在写",
        hand = { wipe = { 365, 816, 690, 927 }, x = 678, y = 917, along = { -1, 0 }, step = { 0, -21 }, line = 301, rows = 5 },
        parts = { { "keys", { 162, 545, 360, 827 } }, { "cycle", { 649, 51, 1008, 249 } } },
    },
    sharp = {
        file = "writing-wangxiaobo", verb = "在写",
        text = { wipe = { 274, 406, 528, 591 }, x = 282, y = 581, line = 238 },
        parts = { { "keys", { 337, 662, 540, 790 } }, { "cycle", { 71, 1030, 384, 1390 } } },
    },
    vivid = {
        file = "writing-wangzengqi", verb = "在写",
        hand = { wipe = { 375, 780, 706, 923 }, x = 694, y = 913, along = { -1, 0 }, step = { 0, -21 }, line = 307, rows = 6 },
        parts = { { "keys", { 200, 623, 367, 831 } }, { "cycle", { 647, 223, 800, 345 } } },
    },
    wuxia = {
        file = "writing-jinyong", verb = "在写",
        hand = { wipe = { 366, 770, 667, 891 }, x = 655, y = 881, along = { -1, 0 }, step = { 0, -21 }, line = 277, rows = 5 },
        parts = { { "keys", { 190, 584, 358, 831 } }, { "cycle", { 754, 149, 1024, 552 } } },
    },
    kids = {
        file = "writing-zhengyuanjie", verb = "在写",
        hand = { wipe = { 393, 806, 654, 948 }, x = 642, y = 938, along = { -1, 0 }, step = { 0, -21 }, line = 237, rows = 6 },
        parts = { { "keys", { 225, 625, 388, 855 } }, { "cycle", { 69, 48, 375, 423 } } },
    },
}

local Canvas = Widget:extend{}

-- Master box to device pixels, grown by pad for the resampling kernel, clamped to the art.
function Canvas:rect(box, pad)
    local sc = self.sc
    local x0, y0 = math.max(0, math.floor(box[1] * sc) - pad), math.max(0, math.floor(box[2] * sc) - pad)
    local x1, y1 = math.min(self.art_w, math.ceil(box[3] * sc) + pad), math.min(self.art_h, math.ceil(box[4] * sc) + pad)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

function Canvas:init()
    self.scene = SCENES[self.style]
    local text, hand = self.scene.text, self.scene.hand
    self.state = hand and newTyping(hand.line, nil, hand.rows)
        or newTyping(text and text.line or 158, text and math.floor((text.y - text.wipe[2]) / LEAD) or 0)
    text = text or hand
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.caption = TextBoxWidget:new{
        text = self.author .. self.scene.verb .. "…",
        face = Font:getFace("x_smallinfofont"), width = self.width, alignment = "center",
    }
    self.cap_h = self.caption:getSize().h
    local area = math.max(1, self.height - self.cap_h)
    self.art_h = math.max(1, math.min(area, math.floor(self.width * 3 / 2)))
    self.art_w = math.max(1, math.floor(self.art_h * 2 / 3))
    self.art_y = math.floor((area - self.art_h) / 2)
    self.sc = self.art_w / 1024
    self.wipe = text and self:rect(text.wipe, 0)
    self.parts = {}
    local u = self.wipe or { x = self.art_w, y = self.art_h, w = 0, h = 0 }
    local x0, y0, x1, y1 = u.x, u.y, u.x + u.w, u.y + u.h
    for _, part in ipairs(self.scene.parts) do
        for i = 2, #part do
            local r = self:rect(part[i], 3)
            self.parts[#self.parts + 1] = { role = part[1], x = r.x, y = r.y, w = r.w, h = r.h }
            x0, y0, x1, y1 = math.min(x0, r.x), math.min(y0, r.y), math.max(x1, r.x + r.w), math.max(y1, r.y + r.h)
        end
    end
    self.union = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    self.hand = "a"
    self.ms, self.frames = 0, 0
    self.tick_cb = function() self:tick() end
end

function Canvas:getSize() return self.dimen end

function Canvas:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local ax = x + math.floor((self.width - self.art_w) / 2)
    self.art = Geom:new{ x = ax, y = y + self.art_y, w = self.art_w, h = self.art_h }
    if self.frame then bb:blitFrom(self.frame, ax, self.art.y, 0, 0, self.art_w, self.art_h) end
    self.caption:paintTo(bb, x, y + self.height - self.cap_h)
end

function Canvas:load()
    local t = os.clock()
    self.imgs = {}
    for key, suffix in pairs(FILES) do
        local path = string.format("%s/art/%s%s.png", self.dir, self.scene.file, suffix)
        self.imgs[key] = has_render and RenderImage:renderImageFile(path, false, self.art_w, self.art_h)
        if not self.imgs[key] then
            logger.warn("KentRead writing: cannot load", path)
            self:free()
            return false
        end
    end
    self.frame = self.imgs[""]:copy()
    logger.info("KentRead writing: load ms", string.format("%.1f", (os.clock() - t) * 1000))
    return true
end

function Canvas:free()
    for _, img in pairs(self.imgs or {}) do img:free() end
    if self.frame then self.frame:free() end
    self.imgs, self.frame = nil, nil
end

-- src maps role -> image key: "" resting, "a" / "b" the poses.
function Canvas:paint(src)
    local f, sc, w, text, hand = self.frame, self.sc, self.wipe, self.scene.text, self.scene.hand
    if text or hand then f:blitFrom(self.imgs[""], w.x, w.y, w.x, w.y, w.w, w.h) end
    if hand then
        local n = math.max(1, math.floor(HAND_STROKE * sc + 0.5))
        local ax, ay = hand.along[1], hand.along[2]
        local function row(segs, i)
            local ox, oy = hand.x + hand.step[1] * i, hand.y + hand.step[2] * i
            for _, g in ipairs(segs) do
                for t = g[1], g[2] do
                    local d = g.A * (math.sin(2 * math.pi * t / g.P + g.ph) + 0.4 * math.sin(2 * math.pi * t / 7 + g.ph2))
                    local x, y = (ox + ax * t + ay * d) * sc, (oy + ay * t + ax * d) * sc
                    f:paintRect(math.floor(x - n / 2 + 0.5), math.floor(y - n / 2 + 0.5), n, n, Blitbuffer.COLOR_BLACK)
                end
            end
        end
        local s = self.state
        for i, segs in ipairs(s.lines) do row(segs, i - 1) end
        row(s.cur, #s.lines)
    elseif text then
        local h = math.max(1, math.floor(STROKE * sc + 0.5))
        local function row(segs, y)
            local top = math.floor(y * sc - h / 2 + 0.5)
            for _, seg in ipairs(segs) do
                local x0, x1 = math.floor((text.x + seg[1]) * sc), math.ceil((text.x + seg[2]) * sc)
                f:paintRect(x0, top, math.max(1, x1 - x0), h, Blitbuffer.COLOR_BLACK)
            end
        end
        local s = self.state
        row(s.cur, text.y)
        for i, segs in ipairs(s.lines) do row(segs, text.y - LEAD * i) end
    end
    for _, p in ipairs(self.parts) do
        f:blitFrom(self.imgs[src[p.role]], p.x, p.y, p.x, p.y, p.w, p.h)
    end
end

function Canvas:tick()
    -- Hold still under a dialog: a fast refresh there would degrade the dialog.
    if UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget() ~= self.dialog then
        return UIManager:scheduleIn(INTERVAL, self.tick_cb)
    end
    local t, s = os.clock(), self.state
    local before = s.len
    local ding = step(s)
    s.fr = s.fr + 1
    local typed = s.len == before + CH
    if typed then self.hand = self.hand == "a" and "b" or "a" end
    self:paint{ keys = typed and self.hand or "", cycle = TAIL_CYCLE[math.floor(s.fr / 5) % 4 + 1], ding = ding and "a" or "" }
    self.ms, self.frames = self.ms + (os.clock() - t) * 1000, self.frames + 1
    if ding then
        logger.info("KentRead writing: avg frame ms", string.format("%.1f", self.ms / self.frames))
        self.ms, self.frames = 0, 0
    end
    UIManager:scheduleIn(INTERVAL, self.tick_cb)
    if self.art then
        local u = self.union
        local region = Geom:new{ x = self.art.x + u.x, y = self.art.y + u.y, w = u.w, h = u.h }
        -- "ui" (GC16) would clean DU ghosts, but flashes every changed pixel, so stay on "fast".
        UIManager:setDirty(self.dialog, function() return "fast", region end)
    end
end

function Canvas:start()
    if self.running then return end
    if not self.frame then
        if not self:load() then return end
        self:paint{ keys = "", cycle = "", ding = "" }
    end
    self.running = true
    UIManager:scheduleIn(INTERVAL, self.tick_cb)
end

function Canvas:stop()
    UIManager:unschedule(self.tick_cb)
    self.running = false
    self:free()
    self.caption:free()
end

local Writing = { SCENES = SCENES }

function Writing.supports(style) return SCENES[style] ~= nil end

function Writing.available() return has_render and true or false end

function Writing.new(opts) return Canvas:new(opts) end

return Writing
