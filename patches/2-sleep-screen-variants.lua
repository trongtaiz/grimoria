--[[
    2-sleep-screen-variants.lua — KOReader user patch

    Multi-variant sleep screen ("Đầu Voi" proofs, layouts Nº 02/03/05/06/07/08/09/14).
    On each sleep, shows either a random variant from an enabled pool, or one fixed
    variant — configurable in: Settings → Screen → Sleep screen.

    Variants:
      classic       Nº 02 · Classic centered   (cover, title, progress bar)
      receipt       Nº 03 · Book receipt       (receipt card with barcode)
      split         Nº 05 · Split screen       (cover left, info column right)
      quote_hero    Nº 06 · Quote hero         (large quote, small footer)
      dashboard     Nº 07 · Stats dashboard    (progress ring + stat cells)
      clock         Nº 08 · Clock + book       (bedside clock)
      overlay_band  Nº 09 · Cover + info band  (full cover, floating box)
      quote_cover   Nº 14 · Quote on cover     (cover fades to paper, quote on top)

    Quotes are only ever taken from the part of the book ALREADY READ:
      1. AI-curated quotes exported by the Grimoria plugin
         (<sidecar>/grimoria_quotes.lua -- pre-filtered to finished chapters)
      2. random highlight with page <= current page
      3. fallback: random sentence extracted from a random already-read page

    Install: copy to koreader/patches/ and restart KOReader.
    Based on patterns from omer-faruq/koreader-user-patches and
    PedroMachado1/Koreader.patches (2-kobo-style-screensaver.lua).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local datetime = require("datetime")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local util = require("util")

local Screen = Device.screen

local STATISTICS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local SCREENSAVER_TYPE = "sleep_variants"

local SETTINGS = {
    MODE = "sleep_variants_mode",           -- "random" | "fixed"
    FIXED = "sleep_variants_fixed",         -- variant id
    POOL_PREFIX = "sleep_variants_pool_",   -- .. variant id -> boolean
}

local VARIANTS = {
    { id = "classic",      label = "Nº 02 · Classic centered" },
    { id = "receipt",      label = "Nº 03 · Book receipt" },
    { id = "split",        label = "Nº 05 · Split screen" },
    { id = "quote_hero",   label = "Nº 06 · Quote hero" },
    { id = "dashboard",    label = "Nº 07 · Stats dashboard" },
    { id = "clock",        label = "Nº 08 · Clock + book" },
    { id = "overlay_band", label = "Nº 09 · Cover + info band" },
    { id = "quote_cover",  label = "Nº 14 · Quote on cover" },
}

-- If a variant cannot be built (e.g. no quote found), try this one instead.
local FALLBACK = {
    quote_cover = "overlay_band",
    quote_hero = "classic",
}

local DEFAULT_FIXED = "receipt"

-- ============================================================================
-- small helpers
-- ============================================================================

local function getSetting(key, default)
    local value = G_reader_settings:readSetting(key)
    if value == nil then return default end
    return value
end

local function isSettingEnabled(key, default)
    local value = G_reader_settings:readSetting(key)
    if value == nil then return default end
    return value == true
end

local function utf8Len(str)
    if not str or str == "" then return 0 end
    local len = 0
    local i = 1
    while i <= #str do
        local byte = string.byte(str, i)
        if byte >= 0xF0 then i = i + 4
        elseif byte >= 0xE0 then i = i + 3
        elseif byte >= 0xC0 then i = i + 2
        else i = i + 1 end
        len = len + 1
    end
    return len
end

local function utf8Sub(str, max_chars)
    if not str or str == "" or max_chars <= 0 then return "" end
    local len = #str
    local i = 1
    local count = 0
    while i <= len and count < max_chars do
        local byte = string.byte(str, i)
        if byte >= 0xF0 then i = i + 4
        elseif byte >= 0xE0 then i = i + 3
        elseif byte >= 0xC0 then i = i + 2
        else i = i + 1 end
        count = count + 1
    end
    if i <= len then
        return str:sub(1, i - 1) .. " …"
    end
    return str
end

-- "1g 24ph" style durations, as in the HTML proofs
local function fmtDur(secs)
    if not secs or secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then
        return string.format("%dg %dph", h, m)
    elseif h > 0 then
        return string.format("%dg", h)
    elseif m > 0 then
        return string.format("%dph", m)
    end
    return "<1ph"
end

local function hasActiveDocument(ui)
    return ui and ui.document ~= nil
end

-- ============================================================================
-- statistics database
-- ============================================================================

local function queryStatNumber(sql)
    local attrs = lfs.attributes(STATISTICS_DB_PATH, "mode")
    if attrs ~= "file" then return nil end
    local ok_conn, conn = pcall(SQ3.open, STATISTICS_DB_PATH)
    if not ok_conn or not conn then return nil end
    local ok_row, result = pcall(function()
        return conn:rowexec(sql)
    end)
    pcall(function() conn:close() end)
    if not ok_row or result == nil then return nil end
    return tonumber(result)
end

local function getBookTodayDuration(id_book)
    if not id_book then return nil end
    local now_stamp = os.time()
    local now_t = os.date("*t", now_stamp)
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today_time = now_stamp - from_begin_day
    local sql = string.format([[SELECT sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d AND id_book = %d
            GROUP BY page
        );
    ]], start_today_time, id_book)
    local duration = queryStatNumber(sql)
    if not duration or duration <= 0 then return nil end
    return duration
end

local function getBookTotalDuration(id_book)
    if not id_book then return nil end
    local sql = string.format(
        "SELECT sum(duration) FROM page_stat WHERE id_book = %d;", id_book)
    local duration = queryStatNumber(sql)
    if not duration or duration <= 0 then return nil end
    return duration
end

-- ============================================================================
-- data collection
-- ============================================================================

local VN_DAYS = { "CHỦ NHẬT", "THỨ HAI", "THỨ BA", "THỨ TƯ", "THỨ NĂM", "THỨ SÁU", "THỨ BẢY" }

local function collectData(ui)
    local d = {}
    local props = ui.doc_props or {}
    d.title = props.display_title or props.title or "…"
    d.authors = props.authors or ""
    d.authors = tostring(d.authors):gsub("\n.*", "")

    local state = ui.view and ui.view.state
    d.page = (state and state.page) or 1
    local doc_settings_data = (ui.doc_settings and ui.doc_settings.data) or {}
    d.total = doc_settings_data.doc_pages or 1
    if (not d.total or d.total <= 0) and ui.document and ui.document.getPageCount then
        local ok, n = pcall(ui.document.getPageCount, ui.document)
        if ok and n then d.total = n end
    end
    if not d.total or d.total <= 0 then d.total = 1 end
    if d.page < 1 then d.page = 1 end
    if d.page > d.total then d.page = d.total end

    d.pages_left = math.max(d.total - d.page, 0)
    d.percent = d.page / d.total
    d.pct_text = string.format("%d%%", math.floor(d.percent * 100 + 0.5))

    -- chapter
    d.chapter = ""
    d.chapter_done = 1
    d.chapter_total = 1
    d.chapter_left = 0
    if ui.toc then
        pcall(function()
            d.chapter = ui.toc:getTocTitleByPage(d.page) or ""
            d.chapter_total = ui.toc:getChapterPageCount(d.page) or d.total
            d.chapter_left = ui.toc:getChapterPagesLeft(d.page) or 0
            d.chapter_done = (ui.toc:getChapterPagesDone(d.page) or 0) + 1
        end)
    end
    if not d.chapter_total or d.chapter_total <= 0 then d.chapter_total = d.total end
    if d.chapter_done < 1 then d.chapter_done = 1 end
    d.chapter_percent = d.chapter_done / d.chapter_total

    -- statistics
    local statistics = ui.statistics
    local avg_time = statistics and statistics.avg_time
    local id_book = statistics and statistics.id_curr_book
    if statistics and statistics.insertDB then
        pcall(statistics.insertDB, statistics)
    end
    d.today_str = fmtDur(getBookTodayDuration(id_book))
    d.total_str = fmtDur(getBookTotalDuration(id_book))
    if avg_time and avg_time > 0 then
        d.left_str = fmtDur(avg_time * d.pages_left)
        d.chapter_left_str = fmtDur(avg_time * d.chapter_left)
    end

    -- clock + battery
    d.time_str = datetime.secondsToHour(os.time(),
        G_reader_settings:isTrue("twelve_hour_clock")) or ""
    local now_t = os.date("*t")
    d.date_line = string.format("%s · %d THÁNG %d",
        VN_DAYS[now_t.wday] or "", now_t.day, now_t.month)
    d.batt_str = nil
    if Device:hasBattery() then
        pcall(function()
            local power_dev = Device:getPowerDevice()
            local lvl = power_dev:getCapacity() or 0
            local charging = power_dev:isCharging() and "+" or ""
            d.batt_str = string.format("%spin %d%%", charging, lvl)
        end)
    end

    -- cover blitbuffer (caller-owned; scaled copies go to ImageWidgets)
    d.cover_bb = nil
    if ui.bookinfo and ui.bookinfo.getCoverImage then
        local ok, cover = pcall(ui.bookinfo.getCoverImage, ui.bookinfo, ui.document)
        if ok then d.cover_bb = cover end
    end

    return d
end

-- ============================================================================
-- quote from the ALREADY-READ part of the book
-- ============================================================================

--[[
Quotes the Grimoria plugin exported for this book, if it is installed and an
analysis has run. The file contains ONLY quotes from chapters the reader has
finished -- the plugin filters before writing -- so everything here is safe
to show as-is. The sidecar directory comes from DocSettings because KOReader
can be configured to keep sidecars in a central folder rather than next to
the book.
]]
local function loadGrimoriaQuotes(ui)
    local doc = ui.document
    local file = doc and doc.file
    if not file then return {} end
    local ok_dir, dir = pcall(function()
        local DocSettings = require("docsettings")
        return DocSettings:getSidecarDir(file)
    end)
    if not ok_dir or not dir then return {} end

    local out = {}
    for _, name in ipairs({ "grimoria_quotes.lua", "xray_quotes.lua" }) do
        local path = dir .. "/" .. name
        if lfs.attributes(path, "mode") == "file" then
            local ok, payload = pcall(dofile, path)
            if ok and type(payload) == "table" and type(payload.quotes) == "table" then
                for _, q in ipairs(payload.quotes) do
                    if type(q) == "table" and type(q.quote) == "string" and #q.quote > 0 then
                        local chapter = nil
                        if type(q.chapter_title) == "string" and #q.chapter_title > 0 then
                            chapter = q.chapter_title
                        elseif tonumber(q.chapter) then
                            chapter = "Chương " .. math.floor(tonumber(q.chapter))
                        end
                        out[#out + 1] = {
                            text = q.quote,
                            chapter = chapter,
                            speaker = (type(q.speaker) == "string" and #q.speaker > 0)
                                and q.speaker or nil,
                        }
                    end
                end
                if #out > 0 then return out end
            end
        end
    end
    return out
end

local function collectQuote(ui, data)
    local cur_page = data.page or 1

    -- 1) AI-curated quotes exported by Grimoria (already read-part-only)
    local cands = loadGrimoriaQuotes(ui)

    -- 2) user highlights, restricted to pages already reached
    local annotations = ui.annotation and ui.annotation.annotations
    if type(annotations) == "table" then
        for _, a in ipairs(annotations) do
            local text = a.text
            local pageno = tonumber(a.pageno) or tonumber(a.page)
            if a.drawer and text and text ~= "" then
                if pageno == nil or pageno <= cur_page then
                    table.insert(cands, {
                        text = tostring(text),
                        page = pageno,
                        chapter = a.chapter,
                    })
                end
            end
        end
    end
    if #cands > 0 then
        local c = cands[math.random(#cands)]
        c.text = utf8Sub(util.trim(c.text), 220)
        return c
    end

    -- 3) fallback: a random sentence from a random already-read page (CRE docs)
    local doc = ui.document
    if not (doc and doc.getPageXPointer and doc.getTextFromXPointers) then
        return nil
    end
    local max_page = math.max(cur_page - 1, 1)
    for _ = 1, 6 do
        local p = math.random(1, max_page)
        local ok, text = pcall(function()
            local xp0 = doc:getPageXPointer(p)
            local xp1 = doc:getPageXPointer(math.min(p + 1, max_page + 1))
            if not xp0 or not xp1 then return nil end
            return doc:getTextFromXPointers(xp0, xp1)
        end)
        if ok and type(text) == "string" and #text > 40 then
            local sentences = {}
            for s in text:gmatch("[^%.%!%?…]+[%.%!%?…]?") do
                s = util.trim((s:gsub("%s+", " ")))
                local n = utf8Len(s)
                if n >= 40 and n <= 200 then
                    table.insert(sentences, s)
                end
            end
            if #sentences > 0 then
                local chosen = sentences[math.random(#sentences)]
                local chap = nil
                pcall(function()
                    chap = ui.toc and ui.toc:getTocTitleByPage(p) or nil
                end)
                return { text = chosen, page = p, chapter = chap }
            end
        end
    end
    return nil
end

-- ============================================================================
-- custom paint widgets
-- ============================================================================

local DashedLine = Widget:extend{
    width = 100,
    height = 1,
    color = Blitbuffer.COLOR_GRAY_6,
    dash = 6,
    gap = 4,
}

function DashedLine:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function DashedLine:paintTo(bb, x, y)
    local cx = 0
    while cx < self.width do
        local w = math.min(self.dash, self.width - cx)
        bb:paintRect(x + cx, y, w, self.height, self.color)
        cx = cx + self.dash + self.gap
    end
end

local DottedFill = Widget:extend{
    width = 40,
    height = 10,
    color = Blitbuffer.COLOR_GRAY_6,
    dot = 2,
    gap = 4,
}

function DottedFill:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function DottedFill:paintTo(bb, x, y)
    local baseline = y + self.height - self.dot - 1
    local cx = 0
    while cx + self.dot <= self.width do
        bb:paintRect(x + cx, baseline, self.dot, self.dot, self.color)
        cx = cx + self.dot + self.gap
    end
end

local Barcode = Widget:extend{
    width = 100,
    height = 20,
    color = Blitbuffer.COLOR_BLACK,
}

function Barcode:paintTo(bb, x, y)
    local pattern = { 2, 2, 1, 4, 3, 2, 1, 2, 2, 3, 1, 1, 2, 4, 1, 2 }
    local unit = math.max(1, math.floor(self.width / 140))
    local cx = 0
    local i = 1
    local draw = true
    while cx < self.width do
        local w = pattern[(i - 1) % #pattern + 1] * unit
        if cx + w > self.width then w = self.width - cx end
        if draw and w > 0 then
            bb:paintRect(x + cx, y, w, self.height, self.color)
        end
        cx = cx + w
        i = i + 1
        draw = not draw
    end
end

function Barcode:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local RingProgress = Widget:extend{
    size = 150,
    thickness = 8,
    percentage = 0,
    done_color = Blitbuffer.COLOR_BLACK,
    rest_color = Blitbuffer.COLOR_GRAY_C,
}

function RingProgress:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function RingProgress:paintTo(bb, x, y)
    local cx = x + self.size / 2
    local cy = y + self.size / 2
    local r = (self.size - self.thickness) / 2
    local dot = self.thickness
    if r <= 0 then return end
    local step = math.max(1 / r, 0.005)

    local function dotAt(angle, color)
        local dx = math.floor(cx + r * math.cos(angle) - dot / 2 + 0.5)
        local dy = math.floor(cy + r * math.sin(angle) - dot / 2 + 0.5)
        bb:paintRect(dx, dy, dot, dot, color)
    end

    local a = 0
    while a < 2 * math.pi do
        dotAt(a, self.rest_color)
        a = a + step
    end
    -- progress arc, starting at 12 o'clock, clockwise
    local sweep = 2 * math.pi * math.max(math.min(self.percentage or 0, 1), 0)
    a = 0
    while a <= sweep do
        dotAt(a - math.pi / 2, self.done_color)
        a = a + step
    end
end

-- ============================================================================
-- cover helpers
-- ============================================================================

-- scale preserving aspect so the cover FITS inside max_w x max_h
local function scaleCoverFit(cover_bb, max_w, max_h)
    local cw = cover_bb:getWidth()
    local ch = cover_bb:getHeight()
    if cw <= 0 or ch <= 0 then return nil end
    local f = math.min(max_w / cw, max_h / ch)
    local tw = math.max(1, math.floor(cw * f + 0.5))
    local th = math.max(1, math.floor(ch * f + 0.5))
    return RenderImage:scaleBlitBuffer(cover_bb, tw, th, false), tw, th
end

-- scale + center-crop so the cover FILLS w x h (css object-fit: cover)
local function scaleCoverFill(cover_bb, w, h)
    local cw = cover_bb:getWidth()
    local ch = cover_bb:getHeight()
    if cw <= 0 or ch <= 0 then return nil end
    local f = math.max(w / cw, h / ch)
    local tw = math.max(w, math.ceil(cw * f))
    local th = math.max(h, math.ceil(ch * f))
    local scaled = RenderImage:scaleBlitBuffer(cover_bb, tw, th, false)
    local canvas = Blitbuffer.new(w, h, scaled:getType())
    local ox = math.floor((tw - w) / 2)
    local oy = math.floor((th - h) / 2)
    canvas:blitFrom(scaled, 0, 0, ox, oy, w, h)
    pcall(function() scaled:free() end)
    return canvas
end

-- full-bleed cover that fades into paper towards the bottom (variant Nº 14)
local function composeQuoteCover(cover_bb, w, h)
    local base = scaleCoverFill(cover_bb, w, h)
    if not base then return nil end
    local comp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    comp:blitFrom(base, 0, 0, 0, 0, w, h)
    pcall(function() base:free() end)

    local overlay = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    local y0 = math.floor(h * 0.12)
    local y1 = math.floor(h * 0.58)
    local band = 4
    local y = 0
    while y < h do
        local alpha
        if y < y0 then
            alpha = 0
        elseif y >= y1 then
            alpha = 255
        else
            alpha = math.floor(255 * (y - y0) / (y1 - y0) + 0.5)
        end
        if alpha > 0 then
            overlay:paintRect(0, y, w, math.min(band, h - y),
                Blitbuffer.Color8A(0xF5, alpha))
        end
        y = y + band
    end
    comp:alphablitFrom(overlay, 0, 0, 0, 0, w, h)
    pcall(function() overlay:free() end)
    return comp
end

-- ============================================================================
-- layout context + shared building blocks
-- ============================================================================

local SERIF = { "NotoSerif-Regular.ttf", "NotoSans-Regular.ttf", "cfont" }
local SERIF_ITALIC = { "NotoSerif-Italic.ttf", "NotoSans-Italic.ttf", "cfont" }
local SANS = { "NotoSans-Regular.ttf", "cfont" }
local SANS_LIGHT = { "NotoSans-Light.ttf", "NotoSans-Regular.ttf", "cfont" }
local MONO = { "DroidSansMono.ttf", "NotoSansMono-Regular.ttf", "cfont" }

local function getFaceSafe(candidates, size)
    for _, name in ipairs(candidates) do
        local ok, f = pcall(Font.getFace, Font, name, size)
        if ok and f then return f end
    end
    return Font:getFace("cfont", size)
end

local COLOR_INK = Blitbuffer.COLOR_BLACK
local COLOR_SOFT = Blitbuffer.COLOR_GRAY_6
local COLOR_HAIR = Blitbuffer.COLOR_GRAY_C

local function makeCtx(ui, data, quote)
    local screen_size = Screen:getSize()
    local ctx = {
        ui = ui,
        data = data,
        quote = quote,
        w = screen_size.w,
        h = screen_size.h,
    }
    -- proofs were designed on a 330px-wide screen: scale everything from that
    local unit = screen_size.w / 330
    ctx.px = function(mock)
        return math.max(1, math.floor(mock * unit + 0.5))
    end
    -- Font:getFace() multiplies by the DPI factor; undo it so a "mock px"
    -- size comes out at the intended fraction of the screen width
    local dpi_factor = Screen:scaleBySize(10000) / 10000
    ctx.fs = function(mockpx)
        return math.max(8, math.floor(mockpx * unit / dpi_factor + 0.5))
    end
    ctx.face = function(candidates, mockpx)
        return getFaceSafe(candidates, ctx.fs(mockpx))
    end
    return ctx
end

-- absolute placement helper for OverlapGroup children
local function place(x, y, widget)
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = math.max(0, math.floor(y)) },
        HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = math.max(0, math.floor(x)) },
            widget,
        },
    }
end

local function placeCenterX(ctx, y, widget)
    local w = widget:getSize().w
    return place((ctx.w - w) / 2, y, widget)
end

local function text(str, face, color, bold_flag, italic_flag)
    return TextWidget:new{
        text = str or "",
        face = face,
        fgcolor = color or COLOR_INK,
        bold = bold_flag or false,
        italic = italic_flag or false,
        padding = 0,
    }
end

local function progressBar(width, height, percentage, bordered)
    return ProgressWidget:new{
        width = width,
        height = height,
        percentage = math.max(math.min(percentage or 0, 1), 0),
        margin_v = 0,
        margin_h = 0,
        radius = 0,
        bordersize = bordered and 1 or 0,
        bordercolor = COLOR_INK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = COLOR_INK,
    }
end

local function hline(width, height, color)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = height or 1 },
        background = color or COLOR_INK,
    }
end

-- left text ... right text within a fixed width
local function spreadRow(width, left_widget, right_widget)
    local lw = left_widget:getSize().w
    local rw = right_widget:getSize().w
    local span = math.max(0, width - lw - rw)
    return HorizontalGroup:new{
        align = "center",
        left_widget,
        HorizontalSpan:new{ width = span },
        right_widget,
    }
end

-- left text ····· right text (receipt style dot leaders)
local function leaderRow(width, left_widget, right_widget, dot_color)
    local lw = left_widget:getSize().w
    local lh = left_widget:getSize().h
    local rw = right_widget:getSize().w
    local pad = 6
    local fill = math.max(0, width - lw - rw - 2 * pad)
    return HorizontalGroup:new{
        align = "center",
        left_widget,
        HorizontalSpan:new{ width = pad },
        DottedFill:new{ width = fill, height = lh, color = dot_color or COLOR_SOFT },
        HorizontalSpan:new{ width = pad },
        right_widget,
    }
end

local function centerIn(width, widget)
    local w = widget:getSize().w
    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = math.max(0, math.floor((width - w) / 2)) },
        widget,
    }
end

local function borderedCover(cover_widget)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        color = COLOR_INK,
        padding = 0,
        margin = 0,
        radius = 0,
        cover_widget,
    }
end

local function coverFitWidget(ctx, max_w, max_h)
    local d = ctx.data
    if not d.cover_bb then return nil end
    local ok, bb, tw, th = pcall(scaleCoverFit, d.cover_bb, max_w, max_h)
    if not ok or not bb then return nil end
    return ImageWidget:new{ image = bb, width = tw, height = th }, tw, th
end

local function coverFillWidget(ctx, w, h)
    local d = ctx.data
    if not d.cover_bb then return nil end
    local ok, bb = pcall(scaleCoverFill, d.cover_bb, w, h)
    if not ok or not bb then return nil end
    return ImageWidget:new{ image = bb, width = w, height = h }
end

local function clockBattLine(ctx, mockpx, color)
    local d = ctx.data
    local parts = {}
    if d.time_str and d.time_str ~= "" then table.insert(parts, d.time_str) end
    if d.batt_str then table.insert(parts, d.batt_str) end
    if #parts == 0 then return nil end
    return text(table.concat(parts, " · "), ctx.face(SANS, mockpx), color or COLOR_SOFT)
end

local function statsLine(ctx)
    local d = ctx.data
    local parts = {}
    if d.today_str then table.insert(parts, "Hôm nay " .. d.today_str) end
    if d.total_str then table.insert(parts, "Tổng " .. d.total_str) end
    if d.left_str then table.insert(parts, "Còn lại " .. d.left_str) end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

-- ============================================================================
-- variant builders — geometry mirrors the approved HTML proofs
-- ============================================================================

local BUILDERS = {}

-- Nº 02 · classic centered -----------------------------------------------
BUILDERS.classic = function(ctx)
    local d = ctx.data
    local px = ctx.px

    local group = VerticalGroup:new{ align = "center" }
    local cover = coverFitWidget(ctx, px(200), px(232))
    if cover then
        table.insert(group, borderedCover(cover))
        table.insert(group, VerticalSpan:new{ width = px(18) })
    end
    table.insert(group, text(d.title, ctx.face(SERIF, 21)))
    if d.authors ~= "" then
        table.insert(group, VerticalSpan:new{ width = px(5) })
        table.insert(group, text(d.authors, ctx.face(SANS, 11), COLOR_SOFT))
    end
    if d.chapter ~= "" then
        table.insert(group, VerticalSpan:new{ width = px(16) })
        table.insert(group, text(utf8Sub(d.chapter, 44),
            ctx.face(SERIF_ITALIC, 10.5), COLOR_SOFT, false, true))
    end
    table.insert(group, VerticalSpan:new{ width = px(9) })
    table.insert(group, progressBar(px(238), px(6), d.percent, true))
    table.insert(group, VerticalSpan:new{ width = px(8) })
    table.insert(group, text(
        string.format("trang %d / %d · %s", d.page, d.total, d.pct_text),
        ctx.face(SANS, 10.5), COLOR_SOFT))

    local children = {
        dimen = Geom:new{ w = ctx.w, h = ctx.h },
        CenterContainer:new{
            dimen = Geom:new{ w = ctx.w, h = ctx.h },
            group,
        },
    }

    local corner = clockBattLine(ctx, 10)
    if corner then
        table.insert(children,
            place(ctx.w - corner:getSize().w - px(14), px(12), corner))
    end
    local stats = statsLine(ctx)
    if stats then
        local sw = text(stats, ctx.face(SANS, 10), COLOR_SOFT)
        table.insert(children,
            place((ctx.w - sw:getSize().w) / 2,
                ctx.h - sw:getSize().h - px(16), sw))
    end
    return OverlapGroup:new(children)
end

-- Nº 03 · book receipt ----------------------------------------------------
BUILDERS.receipt = function(ctx)
    local d = ctx.data
    local px = ctx.px
    local iw = px(218)   -- inner card width
    local gap = px(7)

    local mono9 = ctx.face(MONO, 9.5)
    local mono8 = ctx.face(MONO, 8.5)
    local sep = function() return DashedLine:new{ width = iw, color = COLOR_SOFT } end

    local g = VerticalGroup:new{ align = "left" }
    local function add(widget, spacing)
        table.insert(g, widget)
        table.insert(g, VerticalSpan:new{ width = spacing or gap })
    end

    add(centerIn(iw, text("BIÊN LAI ĐỌC SÁCH", ctx.face(MONO, 10), COLOR_INK, true)))
    local now_t = os.date("*t")
    add(centerIn(iw, text(string.format("%s · %02d.%02d.%d",
        VN_DAYS[now_t.wday] or "", now_t.day, now_t.month, now_t.year),
        mono8, COLOR_SOFT)))
    add(sep())

    local thumb = coverFitWidget(ctx, px(70), px(84))
    if thumb then
        add(centerIn(iw, borderedCover(thumb)))
    end
    add(centerIn(iw, text(utf8Sub(d.title, 26), ctx.face(MONO, 11), COLOR_INK, true)))
    if d.authors ~= "" then
        add(centerIn(iw, text(utf8Sub(d.authors, 32), mono8, COLOR_SOFT)))
    end
    add(sep())

    add(text("SÁCH", ctx.face(MONO, 8), COLOR_SOFT))
    add(progressBar(iw, px(5), d.percent, true), px(3))
    add(spreadRow(iw,
        text(string.format("%d / %d", d.page, d.total), mono9),
        text(d.pct_text, mono9)))

    if d.chapter ~= "" then
        add(text(utf8Sub("CHƯƠNG · " .. d.chapter, 36), ctx.face(MONO, 8), COLOR_SOFT))
        add(progressBar(iw, px(5), d.chapter_percent, true), px(3))
        add(spreadRow(iw,
            text(d.chapter_left_str and ("còn " .. d.chapter_left_str) or
                string.format("còn %d trang", d.chapter_left), mono9),
            text(string.format("%d%%", math.floor(d.chapter_percent * 100 + 0.5)), mono9)))
    end
    add(sep())

    local had_stats = false
    if d.today_str then
        add(leaderRow(iw, text("Hôm nay", mono9), text(d.today_str, mono9)), px(4))
        had_stats = true
    end
    if d.total_str then
        add(leaderRow(iw, text("Tổng cộng", mono9), text(d.total_str, mono9)), px(4))
        had_stats = true
    end
    if d.left_str then
        add(leaderRow(iw, text("Còn lại", mono9), text(d.left_str, mono9)), px(4))
        had_stats = true
    end
    if had_stats then
        add(sep())
    end

    local footer_left = text(d.time_str or "", mono9)
    local footer_right = text(d.batt_str and d.batt_str:upper() or "", mono9)
    add(spreadRow(iw, footer_left, footer_right))
    add(Barcode:new{ width = iw, height = px(22) }, px(5))
    add(centerIn(iw, text("CẢM ƠN ĐÃ ĐỌC · HẸN GẶP LẠI", ctx.face(MONO, 8), COLOR_SOFT)), 0)

    local card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        color = COLOR_INK,
        radius = 0,
        padding = px(14),
        g,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = ctx.w, h = ctx.h },
        CenterContainer:new{
            dimen = Geom:new{ w = ctx.w, h = ctx.h },
            card,
        },
    }
end

-- Nº 05 · split screen -----------------------------------------------------
BUILDERS.split = function(ctx)
    local d = ctx.data
    local px = ctx.px
    local left_w = px(148)
    local x0 = left_w + px(18)
    local rw = ctx.w - x0 - px(16)

    local children = { dimen = Geom:new{ w = ctx.w, h = ctx.h } }

    local cover = coverFillWidget(ctx, left_w, ctx.h)
    if not cover then
        -- without a cover the split layout loses its point
        error("split: no cover")
    end
    table.insert(children, place(0, 0, cover))
    -- vertical divider between cover and info column
    table.insert(children, place(left_w, 0, hline(1, ctx.h)))

    local col = VerticalGroup:new{ align = "left" }
    local function add(widget, spacing)
        table.insert(col, widget)
        if spacing and spacing > 0 then
            table.insert(col, VerticalSpan:new{ width = spacing })
        end
    end

    add(text("ĐANG ĐỌC", ctx.face(MONO, 8.5), COLOR_SOFT), px(10))
    add(TextBoxWidget:new{
        text = d.title,
        face = ctx.face(SERIF, 22),
        width = rw,
        fgcolor = COLOR_INK,
        alignment = "left",
    }, px(5))
    if d.authors ~= "" then
        add(text(utf8Sub(d.authors, 30), ctx.face(SANS, 10.5), COLOR_SOFT), px(14))
    else
        add(VerticalSpan:new{ width = px(6) }, 0)
    end
    add(hline(px(34), 1), px(12))
    if d.chapter ~= "" then
        add(text(utf8Sub(d.chapter, 26), ctx.face(SERIF_ITALIC, 11), COLOR_SOFT, false, true), px(8))
    end
    add(progressBar(rw, px(6), d.percent, true), px(6))
    add(text(string.format("%d / %d · %s", d.page, d.total, d.pct_text),
        ctx.face(SANS, 10), COLOR_SOFT), px(16))

    local sans10 = ctx.face(SANS, 10)
    local function statRow(label, value)
        if not value then return end
        add(spreadRow(rw, text(label, sans10, COLOR_SOFT), text(value, sans10, COLOR_INK, true)), px(4))
        add(hline(rw, 1, COLOR_HAIR), px(5))
    end
    statRow("Hôm nay", d.today_str)
    statRow("Tổng cộng", d.total_str)
    statRow("Còn lại", d.left_str)

    table.insert(children, place(x0, px(22), col))

    local foot_l = text(d.time_str or "", sans10, COLOR_SOFT)
    local foot_r = text(d.batt_str or "", sans10, COLOR_SOFT)
    local foot = spreadRow(rw, foot_l, foot_r)
    table.insert(children, place(x0, ctx.h - foot:getSize().h - px(14), foot))

    return OverlapGroup:new(children)
end

-- Nº 06 · quote hero -------------------------------------------------------
BUILDERS.quote_hero = function(ctx)
    local d = ctx.data
    local q = ctx.quote
    if not q then error("quote_hero: no quote") end
    local px = ctx.px
    local qw = ctx.w - 2 * px(26)

    local children = { dimen = Geom:new{ w = ctx.w, h = ctx.h } }

    local corner = clockBattLine(ctx, 10)
    if corner then
        table.insert(children,
            place(ctx.w - corner:getSize().w - px(14), px(12), corner))
    end

    table.insert(children, place(px(24), px(30),
        text("“", ctx.face(SERIF, 64), COLOR_HAIR)))

    local quote_box = TextBoxWidget:new{
        text = q.text,
        face = ctx.face(SERIF_ITALIC, 15.5),
        width = qw,
        fgcolor = COLOR_INK,
        alignment = "left",
    }
    table.insert(children, place(px(26), px(96), quote_box))

    local attr_parts = {}
    if q.speaker then table.insert(attr_parts, utf8Sub(q.speaker, 24)) end
    if q.page then table.insert(attr_parts, "trang " .. tostring(q.page)) end
    if q.chapter and q.chapter ~= "" then table.insert(attr_parts, utf8Sub(q.chapter, 30)) end
    if #attr_parts > 0 then
        table.insert(children, place(px(26),
            px(96) + quote_box:getSize().h + px(14),
            text("— " .. table.concat(attr_parts, " · "), ctx.face(SANS, 10.5), COLOR_SOFT)))
    end

    -- footer: rule, thumb, title/author, percent
    local foot_group = HorizontalGroup:new{ align = "center" }
    local thumb = coverFitWidget(ctx, px(34), px(44))
    if thumb then
        table.insert(foot_group, borderedCover(thumb))
        table.insert(foot_group, HorizontalSpan:new{ width = px(10) })
    end
    local ft = VerticalGroup:new{ align = "left" }
    table.insert(ft, text(utf8Sub(d.title, 24), ctx.face(SERIF, 11.5)))
    table.insert(ft, VerticalSpan:new{ width = px(3) })
    table.insert(ft, text(string.format("%s · %d / %d",
        utf8Sub(d.authors ~= "" and d.authors or "…", 20), d.page, d.total),
        ctx.face(SANS, 9.5), COLOR_SOFT))
    table.insert(foot_group, ft)
    local pct = text(d.pct_text, ctx.face(SERIF, 15))
    local span_w = math.max(0, qw - foot_group:getSize().w - pct:getSize().w)
    table.insert(foot_group, HorizontalSpan:new{ width = span_w })
    table.insert(foot_group, pct)

    local foot_h = foot_group:getSize().h
    local foot_y = ctx.h - foot_h - px(18)
    table.insert(children, place(px(26), foot_y - px(12), hline(qw, 1, COLOR_HAIR)))
    table.insert(children, place(px(26), foot_y, foot_group))

    return OverlapGroup:new(children)
end

-- Nº 07 · stats dashboard --------------------------------------------------
BUILDERS.dashboard = function(ctx)
    local d = ctx.data
    local px = ctx.px

    local children = { dimen = Geom:new{ w = ctx.w, h = ctx.h } }

    -- header
    local head = HorizontalGroup:new{ align = "center" }
    local thumb = coverFitWidget(ctx, px(36), px(48))
    if thumb then
        table.insert(head, borderedCover(thumb))
        table.insert(head, HorizontalSpan:new{ width = px(10) })
    end
    local ht = VerticalGroup:new{ align = "left" }
    table.insert(ht, text(utf8Sub(d.title, 22), ctx.face(SERIF, 13)))
    if d.authors ~= "" then
        table.insert(ht, VerticalSpan:new{ width = px(2) })
        table.insert(ht, text(utf8Sub(d.authors, 26), ctx.face(SANS, 9.5), COLOR_SOFT))
    end
    table.insert(head, ht)
    table.insert(children, place(px(22), px(18), head))

    local corner = clockBattLine(ctx, 9.5)
    if corner then
        table.insert(children,
            place(ctx.w - corner:getSize().w - px(14), px(20), corner))
    end

    -- progress ring with centered labels
    local ring_size = px(150)
    local ring_y = px(84)
    local ring = RingProgress:new{
        size = ring_size,
        thickness = px(7),
        percentage = d.percent,
    }
    table.insert(children, place((ctx.w - ring_size) / 2, ring_y, ring))

    local pct = text(d.pct_text, ctx.face(SERIF, 34))
    local pages = text(string.format("%d / %d", d.page, d.total),
        ctx.face(SANS, 9), COLOR_SOFT)
    local cx = ctx.w / 2
    local cy = ring_y + ring_size / 2
    local label_h = pct:getSize().h + px(3) + pages:getSize().h
    table.insert(children,
        place(cx - pct:getSize().w / 2, cy - label_h / 2, pct))
    table.insert(children,
        place(cx - pages:getSize().w / 2,
            cy - label_h / 2 + pct:getSize().h + px(3), pages))

    local y = ring_y + ring_size + px(14)
    if d.chapter ~= "" then
        local chap = text(utf8Sub(d.chapter, 40),
            ctx.face(SERIF_ITALIC, 10.5), COLOR_SOFT, false, true)
        table.insert(children, place((ctx.w - chap:getSize().w) / 2, y, chap))
        y = y + chap:getSize().h + px(14)
    end

    -- 2x2 stat grid
    local cells = {
        { "HÔM NAY", d.today_str },
        { "TỔNG CỘNG", d.total_str },
        { "CÒN LẠI", d.left_str },
        { "TRANG CÒN LẠI", tostring(d.pages_left) },
    }
    local grid_w = ctx.w - 2 * px(22)
    local cell_w = math.floor(grid_w / 2)
    local mono8 = ctx.face(MONO, 8)
    local serif15 = ctx.face(SERIF, 15)

    local function cellWidget(label, value)
        local inner = VerticalGroup:new{ align = "left" }
        table.insert(inner, text(label, mono8, COLOR_SOFT))
        table.insert(inner, VerticalSpan:new{ width = px(4) })
        table.insert(inner, text(value or "—", serif15))
        local pad = px(10)
        local content_w = cell_w - 2 * pad - 2
        local sized = HorizontalGroup:new{
            align = "top",
            inner,
            HorizontalSpan:new{ width = math.max(0, content_w - inner:getSize().w) },
        }
        return FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 1,
            color = COLOR_HAIR,
            radius = 0,
            padding = pad,
            sized,
        }
    end

    local grid = VerticalGroup:new{ align = "left" }
    for row = 0, 1 do
        local hg = HorizontalGroup:new{ align = "top" }
        for colidx = 1, 2 do
            local c = cells[row * 2 + colidx]
            table.insert(hg, cellWidget(c[1], c[2]))
        end
        table.insert(grid, hg)
    end
    table.insert(children, place((ctx.w - grid:getSize().w) / 2, y, grid))

    return OverlapGroup:new(children)
end

-- Nº 08 · clock + book -----------------------------------------------------
BUILDERS.clock = function(ctx)
    local d = ctx.data
    local px = ctx.px

    local children = { dimen = Geom:new{ w = ctx.w, h = ctx.h } }

    if d.batt_str then
        local batt = text(d.batt_str, ctx.face(SANS, 9.5), COLOR_SOFT)
        table.insert(children,
            place(ctx.w - batt:getSize().w - px(14), px(12), batt))
    end

    local time_w = text(d.time_str or "--:--", ctx.face(SANS_LIGHT, 62))
    table.insert(children, placeCenterX(ctx, px(36), time_w))
    local y = px(36) + time_w:getSize().h + px(6)

    local date_w = text(d.date_line, ctx.face(SANS, 10.5), COLOR_SOFT)
    table.insert(children, placeCenterX(ctx, y, date_w))
    y = y + date_w:getSize().h + px(22)

    local cover = coverFitWidget(ctx, px(140), px(168))
    if cover then
        local framed = borderedCover(cover)
        table.insert(children, placeCenterX(ctx, y, framed))
        y = y + framed:getSize().h + px(12)
    end

    local title_w = text(utf8Sub(d.title, 28), ctx.face(SERIF, 13))
    table.insert(children, placeCenterX(ctx, y, title_w))
    y = y + title_w:getSize().h + px(6)

    if d.today_str then
        local st = text("hôm nay " .. d.today_str, ctx.face(SANS, 9.5), COLOR_SOFT)
        table.insert(children, placeCenterX(ctx, y, st))
    end

    local pages_w = text(string.format("%d / %d · %s", d.page, d.total, d.pct_text),
        ctx.face(SANS, 9.5), COLOR_SOFT)
    local bar = progressBar(px(190), px(6), d.percent, true)
    local bar_y = ctx.h - px(24) - pages_w:getSize().h - px(8) - bar:getSize().h
    table.insert(children, placeCenterX(ctx, bar_y, bar))
    table.insert(children, placeCenterX(ctx,
        bar_y + bar:getSize().h + px(8), pages_w))

    return OverlapGroup:new(children)
end

-- Nº 09 · cover + info band ------------------------------------------------
BUILDERS.overlay_band = function(ctx)
    local d = ctx.data
    local px = ctx.px

    local bg = coverFillWidget(ctx, ctx.w, ctx.h)
    if not bg then error("overlay_band: no cover") end

    local pad = px(14)
    local band_w = ctx.w - 2 * px(18)
    local bw = band_w - 2 * pad - 2

    local g = VerticalGroup:new{ align = "left" }
    table.insert(g, text(utf8Sub(d.title, 30), ctx.face(SERIF, 15)))
    if d.chapter ~= "" then
        table.insert(g, VerticalSpan:new{ width = px(3) })
        table.insert(g, text(utf8Sub(d.chapter, 40),
            ctx.face(SERIF_ITALIC, 10), COLOR_SOFT, false, true))
    end
    table.insert(g, VerticalSpan:new{ width = px(9) })
    table.insert(g, progressBar(bw, px(5), d.percent, true))
    table.insert(g, VerticalSpan:new{ width = px(7) })

    local sans9 = ctx.face(SANS, 9.5)
    local left = text(string.format("%s · trang %d / %d", d.pct_text, d.page, d.total),
        sans9, COLOR_SOFT)
    local right = clockBattLine(ctx, 9.5) or text("", sans9, COLOR_SOFT)
    table.insert(g, spreadRow(bw, left, right))

    local band = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        color = COLOR_INK,
        radius = 0,
        padding = pad,
        g,
    }
    local band_h = band:getSize().h

    return OverlapGroup:new{
        dimen = Geom:new{ w = ctx.w, h = ctx.h },
        place(0, 0, bg),
        place(px(18), ctx.h - band_h - px(42), band),
    }
end

-- Nº 14 · quote on cover ---------------------------------------------------
BUILDERS.quote_cover = function(ctx)
    local d = ctx.data
    local q = ctx.quote
    if not q then error("quote_cover: no quote") end
    if not d.cover_bb then error("quote_cover: no cover") end
    local px = ctx.px

    local ok, comp = pcall(composeQuoteCover, d.cover_bb, ctx.w, ctx.h)
    if not ok or not comp then error("quote_cover: compose failed") end
    local bg = ImageWidget:new{ image = comp, width = ctx.w, height = ctx.h }

    local qw = ctx.w - 2 * px(26)
    local g = VerticalGroup:new{ align = "left" }
    table.insert(g, text("“", ctx.face(SERIF, 46), COLOR_SOFT))
    table.insert(g, VerticalSpan:new{ width = px(4) })
    table.insert(g, TextBoxWidget:new{
        text = q.text,
        face = ctx.face(SERIF_ITALIC, 15),
        width = qw,
        fgcolor = COLOR_INK,
        alignment = "left",
    })

    local attr_parts = {}
    if q.speaker then table.insert(attr_parts, utf8Sub(q.speaker, 24)) end
    if q.page then table.insert(attr_parts, "trang " .. tostring(q.page)) end
    if q.chapter and q.chapter ~= "" then table.insert(attr_parts, utf8Sub(q.chapter, 30)) end
    if #attr_parts > 0 then
        table.insert(g, VerticalSpan:new{ width = px(12) })
        table.insert(g, text("— " .. table.concat(attr_parts, " · "),
            ctx.face(SANS, 10), COLOR_SOFT))
    end

    table.insert(g, VerticalSpan:new{ width = px(14) })
    table.insert(g, hline(qw, 1, COLOR_INK))
    table.insert(g, VerticalSpan:new{ width = px(10) })

    local foot_l = text(utf8Sub(d.title, 24) .. " · " .. d.pct_text, ctx.face(SERIF, 12))
    local foot_parts = {}
    if d.left_str then table.insert(foot_parts, "còn " .. d.left_str) end
    if d.time_str and d.time_str ~= "" then table.insert(foot_parts, d.time_str) end
    local foot_r = text(table.concat(foot_parts, " · "), ctx.face(SANS, 10), COLOR_SOFT)
    table.insert(g, spreadRow(qw, foot_l, foot_r))

    local gh = g:getSize().h
    return OverlapGroup:new{
        dimen = Geom:new{ w = ctx.w, h = ctx.h },
        place(0, 0, bg),
        place(px(26), ctx.h - gh - px(18), g),
    }
end

-- ============================================================================
-- variant selection + screensaver hook
-- ============================================================================

local function pickVariantId()
    local mode = getSetting(SETTINGS.MODE, "random")
    if mode == "fixed" then
        return getSetting(SETTINGS.FIXED, DEFAULT_FIXED)
    end
    local pool = {}
    for _, v in ipairs(VARIANTS) do
        if isSettingEnabled(SETTINGS.POOL_PREFIX .. v.id, true) then
            table.insert(pool, v.id)
        end
    end
    if #pool == 0 then return DEFAULT_FIXED end
    return pool[math.random(#pool)]
end

local function buildVariantWidget(id, ctx)
    local builder = BUILDERS[id]
    if builder then
        local ok, widget = pcall(builder, ctx)
        if ok and widget then return widget end
    end
    local fb = FALLBACK[id]
    if fb and BUILDERS[fb] then
        local ok, widget = pcall(BUILDERS[fb], ctx)
        if ok and widget then return widget end
    end
    if id ~= "classic" then
        local ok, widget = pcall(BUILDERS.classic, ctx)
        if ok and widget then return widget end
    end
    return nil
end

local Screensaver = require("ui/screensaver")
local orig_screensaver_show = Screensaver.show

Screensaver.show = function(self)
    if G_reader_settings:readSetting("screensaver_type") ~= SCREENSAVER_TYPE then
        return orig_screensaver_show(self)
    end

    local ui = self.ui or ReaderUI.instance
    if not hasActiveDocument(ui) then
        return orig_screensaver_show(self)
    end

    math.randomseed(os.time())

    if self.screensaver_widget then
        UIManager:close(self.screensaver_widget)
        self.screensaver_widget = nil
    end

    Device.screen_saver_mode = true

    -- force upright before measuring the screen
    local rotation_mode = Screen:getRotationMode()
    Device.orig_rotation_mode = rotation_mode
    if bit.band(rotation_mode, 1) == 1 then
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end

    local widget = nil
    local ok_data, data = pcall(collectData, ui)
    if ok_data and data then
        local quote = nil
        pcall(function() quote = collectQuote(ui, data) end)
        local ctx = makeCtx(ui, data, quote)
        widget = buildVariantWidget(pickVariantId(), ctx)
    end

    if not widget then
        Device.screen_saver_mode = false
        if Device.orig_rotation_mode then
            Screen:setRotationMode(Device.orig_rotation_mode)
            Device.orig_rotation_mode = nil
        end
        return orig_screensaver_show(self)
    end

    self.screensaver_widget = ScreenSaverWidget:new{
        widget = widget,
        background = Blitbuffer.COLOR_WHITE,
        covers_fullscreen = true,
    }
    self.screensaver_widget.modal = true
    self.screensaver_widget.dithered = true
    UIManager:show(self.screensaver_widget, "full")
end

-- ============================================================================
-- settings menu (Settings → Screen → Sleep screen)
-- ============================================================================

local orig_dofile = dofile
_G.dofile = function(filepath)
    local result = orig_dofile(filepath)
    if filepath and filepath:match("screensaver_menu%.lua$") then
        if result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table

            local function isVariantsEnabled()
                return G_reader_settings:readSetting("screensaver_type") == SCREENSAVER_TYPE
            end

            table.insert(wallpaper_submenu, 6, {
                text = "Layout variants (Đầu Voi proofs)",
                checked_func = isVariantsEnabled,
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", SCREENSAVER_TYPE)
                end,
                radio = true,
            })

            -- fixed-layout radio list
            local fixed_items = {}
            for _, v in ipairs(VARIANTS) do
                table.insert(fixed_items, {
                    text = v.label,
                    checked_func = function()
                        return getSetting(SETTINGS.FIXED, DEFAULT_FIXED) == v.id
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SETTINGS.FIXED, v.id)
                        G_reader_settings:saveSetting(SETTINGS.MODE, "fixed")
                    end,
                    radio = true,
                })
            end

            -- random-pool checkbox list
            local pool_items = {}
            for _, v in ipairs(VARIANTS) do
                table.insert(pool_items, {
                    text = v.label,
                    checked_func = function()
                        return isSettingEnabled(SETTINGS.POOL_PREFIX .. v.id, true)
                    end,
                    callback = function()
                        local key = SETTINGS.POOL_PREFIX .. v.id
                        G_reader_settings:saveSetting(key,
                            not isSettingEnabled(key, true))
                    end,
                })
            end

            table.insert(wallpaper_submenu, 7, {
                text = "Layout variants settings",
                enabled_func = isVariantsEnabled,
                sub_item_table = {
                    {
                        text = "Random layout on each sleep",
                        checked_func = function()
                            return getSetting(SETTINGS.MODE, "random") == "random"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(SETTINGS.MODE, "random")
                        end,
                        radio = true,
                    },
                    {
                        text = "Fixed layout",
                        checked_func = function()
                            return getSetting(SETTINGS.MODE, "random") == "fixed"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(SETTINGS.MODE, "fixed")
                        end,
                        radio = true,
                    },
                    {
                        text = "Choose fixed layout",
                        enabled_func = function()
                            return getSetting(SETTINGS.MODE, "random") == "fixed"
                        end,
                        sub_item_table = fixed_items,
                    },
                    {
                        text = "Random pool (layouts to draw from)",
                        enabled_func = function()
                            return getSetting(SETTINGS.MODE, "random") == "random"
                        end,
                        sub_item_table = pool_items,
                    },
                },
            })
        end
    end
    return result
end
