--[[
The spoiler filter: what the reader is allowed to see yet.

This is the plugin's whole reason for existing. The AI tags every entry
with a chapter; this decides which of them the reader has earned. One
textual identity is one character entry, and two identities that turn out
to be the same person stay separate until the chapter where the book
itself connects them.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

--[[
Fuse identities that the text has already connected.

Books hide people behind aliases and anonymous scenes, so the analysis lists
one entry per TEXTUAL IDENTITY (the mystery man / Van / Morisu are three
characters). Each identity_merges entry names the chapter where the text
itself makes the connection; from that chapter on, the member entries become
one fused card. Before it, they stay unrelated -- that separation IS the
spoiler protection.

limit == nil means "the whole book": every merge applies.
]]
local function fuseCharacters(data, limit)
    local chars = data.characters or {}
    local applies = {}   -- identity name -> merge entry
    for _, m in ipairs(data.identity_merges or {}) do
        if (not limit) or m.chapter <= limit then
            for _, n in ipairs(m.names) do applies[n] = m end
        end
    end
    if not next(applies) then return chars end

    local emitted, out = {}, {}
    for _, c in ipairs(chars) do
        local m = applies[c.name]
        if not m then
            out[#out + 1] = c
        elseif not emitted[m] then
            emitted[m] = true
            -- Fuse every member of the merge, in list order. The first member
            -- encountered anchors the card's position in the list.
            local fused = {
                name = m.merged_name,
                role = (#m.true_role > 0) and m.true_role or c.role,
                gender = c.gender,
                occupation = c.occupation,
                intro = c.intro,
                first_chapter = c.first_chapter or 1,
                by_chapter = {},
                revelation = m.revelation,
                merge_chapter = m.chapter,
            }
            for _, cc in ipairs(chars) do
                if applies[cc.name] == m then
                    fused.first_chapter = math.min(fused.first_chapter, cc.first_chapter or 1)
                    if (not fused.occupation or #fused.occupation == 0)
                        and cc.occupation and #cc.occupation > 0 then
                        fused.occupation = cc.occupation
                    end
                    for _, bc in ipairs(cc.by_chapter or {}) do
                        fused.by_chapter[#fused.by_chapter + 1] = {
                            chapter = bc.chapter,
                            development = bc.development,
                            as_name = cc.name,   -- which identity did this
                        }
                    end
                end
            end
            table.sort(fused.by_chapter, function(a, b) return a.chapter < b.chapter end)
            out[#out + 1] = fused
        end
    end
    return out
end

function GrimoriaPlugin:applyChapterFilter()
    local data = self.book_data
    if not data then return end

    -- Per-chapter data absent (old cache, or the no-text fallback): show it all.
    local has_chapter_data = data.chapters and #data.chapters > 0
    local limit = nil
    if has_chapter_data and not self.show_whole_book then
        local BookText = require("lib/booktext")
        limit = BookText:getCurrentChapterIndex(self.ui)
    end
    self.filter_chapter = limit

    local fused = fuseCharacters(data, limit)

    if not limit then
        self.characters = fused
        self.locations = data.locations or {}
        self.timeline = data.timeline or {}
        self.summary = data.summary
        self.themes = data.themes or {}
        self.historical_figures = data.historical_figures or {}
        return
    end

    -- Characters: only those introduced by now, and only what they had done by
    -- now. description is rebuilt from intro + the chapters already read.
    local chars = {}
    for _, c in ipairs(fused) do
        if (c.first_chapter or 1) <= limit then
            local bits = {}
            if c.intro and #c.intro > 0 then bits[#bits + 1] = c.intro end
            if c.revelation and #c.revelation > 0 then
                bits[#bits + 1] = string.format("[%d] ⚡ %s", c.merge_chapter, c.revelation)
            end
            for _, bc in ipairs(c.by_chapter or {}) do
                if bc.chapter <= limit and bc.development and #bc.development > 0 then
                    if bc.as_name and c.merge_chapter then
                        -- fused card: say which identity this entry belonged to
                        bits[#bits + 1] = string.format("[%d] (%s) %s",
                            bc.chapter, bc.as_name, bc.development)
                    else
                        bits[#bits + 1] = string.format("[%d] %s", bc.chapter, bc.development)
                    end
                end
            end
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            if #bits > 0 then copy.description = table.concat(bits, "\n\n") end
            chars[#chars + 1] = copy
        end
    end
    self.characters = chars

    local locs = {}
    for _, l in ipairs(data.locations or {}) do
        if (l.first_chapter or 1) <= limit then locs[#locs + 1] = l end
    end
    self.locations = locs

    local tl = {}
    for _, ev in ipairs(data.timeline or {}) do
        if (ev.chapter_index or 1) <= limit then tl[#tl + 1] = ev end
    end
    self.timeline = tl

    local parts = {}
    for _, ch in ipairs(data.chapters) do
        if ch.index <= limit and ch.summary and #ch.summary > 0 then
            parts[#parts + 1] = ch.summary
        end
    end
    self.summary = #parts > 0 and table.concat(parts, "\n\n") or data.summary

    -- Themes used to pass through unfiltered on the assumption that they were
    -- book-level and harmless. They are not: on a mystery, models routinely
    -- name the culprit inside a theme, so a reader four chapters in could open
    -- Themes and have the ending handed to them. They filter like everything
    -- else now. Legacy caches hold plain strings; lib/llm tags those as
    -- end-of-book, so they stay hidden until the reader gets there.
    local th = {}
    for _, t in ipairs(data.themes or {}) do
        if type(t) == "table" then
            if (t.first_chapter or 1) <= limit then th[#th + 1] = t end
        else
            th[#th + 1] = { theme = tostring(t), first_chapter = 1 }
        end
    end
    self.themes = th

    -- Historical figures are real people referenced by the text (authors,
    -- era figures); they carry far less plot than a theme does, and have no
    -- chapter information to filter on, so they still pass through.
    self.historical_figures = data.historical_figures or {}
end

-- Toggle between "up to where I am" and the complete analysis.
function GrimoriaPlugin:toggleWholeBookView()
    self.show_whole_book = not self.show_whole_book
    self:applyChapterFilter()
    UIManager:show(InfoMessage:new{
        text = self.show_whole_book and self.loc:t("showing_whole_book")
            or string.format(self.loc:t("showing_up_to_chapter"), self.filter_chapter or 1),
        timeout = 2,
    })
end

return GrimoriaPlugin
