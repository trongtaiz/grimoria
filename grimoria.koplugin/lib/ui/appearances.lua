--[[
Chapter Appearances: where in the book a person actually shows up.

This is the one screen built from the BOOK rather than from the analysis. The
model says who somebody is; counting how often their name occurs in each
chapter is arithmetic over the text, so it is exact, free, and works with the
radio off. It answers the question a reader actually has when they come back to
a long novel after a fortnight -- "wait, when was this person last around?" --
which no amount of prose on a card does.

THE SCAN STOPS AT THE READER'S POSITION, AND THAT IS THE WHOLE DESIGN

"Appears 40 times in chapter 50" says the character is alive, present and worth
40 mentions in chapter 50. On a mystery that is the answer to the book. So the
counts past the reader's boundary are not computed and hidden -- they are never
computed. There is nothing in memory, nothing in the cache file and nothing on
the screen to leak. lib/mentions.lua takes the boundary as an argument for
exactly this reason.

The scan is cached in the book's .sdr sidecar, but only for the exact
combination it was made for -- same analysis, same boundary, same cast. See
Archive:loadMentions for why anything less is a bar chart of the wrong person.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

-- Longest bar drawn, in cells. Ten is enough to compare chapters at a glance
-- and short enough that the chapter title still fits beside it on a Kindle.
GrimoriaPlugin.APPEARANCE_BAR_CELLS = 10

--[[
Everything that can be decided without reading the book.

Returns { chars, names, limit, book_path, version_id } or nil plus a reason.
Split out from the scan because the two halves live on opposite sides of a
coroutine boundary -- see showChapterAppearances.
]]
function GrimoriaPlugin:appearanceScope()
    self:applyChapterFilter()

    local limit = self.filter_chapter
    if limit == nil then
        -- Whole-book view. There is no boundary to scan up to, and scanning
        -- the whole book here would build exactly the table this feature
        -- refuses to build. The reader can turn the toggle back off.
        return nil, "whole_book"
    end
    if limit < 1 then return nil, "nothing_yet" end

    local chars = self.characters or {}
    if #chars == 0 then return nil, "no_characters" end

    local names = {}
    for i, c in ipairs(chars) do names[i] = c.name end

    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end
    local book_path = self.ui.document.file
    local _versions, active_id = self.archive:listVersions(book_path)

    return { chars = chars, names = names, limit = limit,
             book_path = book_path, version_id = active_id }
end

function GrimoriaPlugin:reportAppearanceProblem(err)
    local key = ({ whole_book = "scan_needs_chapter_view",
                   nothing_yet = "showing_nothing_yet",
                   no_characters = "no_character_data",
                   cancelled = "scan_cancelled" })[err] or "scan_failed"
    UIManager:show(InfoMessage:new{ text = self.loc:t(key), timeout = 3 })
end

--[[
One character's chapters.

THE SHAPE OF THIS FUNCTION IS DICTATED BY Trapper, and getting it wrong is
silent. `Trapper:wrap` starts a coroutine and returns THE MOMENT that coroutine
yields -- and `Trapper:info` yields on its first call, because yielding back to
UIManager is the entire point of it. So anything written after the wrap runs
before the scan has read a single chapter. An earlier version of this did

    local rows
    Trapper:wrap(function() rows = Mentions:scan(...) end)
    if rows then ... end          -- always nil, every time

which reported "the chapters could not be read" on every run and never wrote
the cache, so the fast path never engaged either. lib/fetch.lua has the correct
shape and no code after its wrap at all: everything that depends on the result
goes INSIDE.

Hence the split. The cached path is fully synchronous and shows the chart
immediately; only a real scan enters a coroutine, and the save and the render
go in there with it.
]]
function GrimoriaPlugin:showChapterAppearances(char)
    if not char or not char.name then return end

    local ctx, err = self:appearanceScope()
    if not ctx then
        self:reportAppearanceProblem(err)
        return
    end

    -- Which column of the scan belongs to this character. By name, because the
    -- card the caller holds came from the same filtered list the scan is
    -- indexed against, and a name is the thing both ends agree on.
    local slot
    for i, c in ipairs(ctx.chars) do
        if c.name == char.name then slot = i break end
    end
    if not slot then
        self:reportAppearanceProblem("scan_failed")
        return
    end

    local cached = self.archive:loadMentions(ctx.book_path, ctx.version_id,
                                             ctx.limit, ctx.names)
    if cached then
        logger.info("GrimoriaPlugin: reusing a stored chapter scan")
        self:renderAppearances(char, slot, cached)
        return
    end

    local Mentions = require("lib/mentions")
    local Trapper = require("ui/trapper")

    Trapper:wrap(function()
        Trapper:info(self.loc:t("scan_starting"))
        local rows, scan_err = Mentions:scan(self.ui, ctx.chars, ctx.limit,
            function(done, total)
                -- Trapper:info returns false when the reader dismissed the
                -- message, which lib/mentions.lua turns into an abort.
                return Trapper:info(string.format(self.loc:t("scan_progress"), done, total))
            end, self:chapterScheme())
        Trapper:clear()

        if not rows then
            self:reportAppearanceProblem(scan_err)
            return
        end

        self.archive:saveMentions(ctx.book_path, {
            version_id = ctx.version_id,
            up_to = ctx.limit,
            names = ctx.names,
            rows = rows,
        })
        self:renderAppearances(char, slot, rows)
    end)
end

--[[
The bar chart itself, from a finished scan.

Chapters where the character is not named at all are left out rather than drawn
as an empty row: on a book with sixty chapters and a character who appears in
eight, the empty rows are the entire screen and the reader has to hunt for the
information.
]]
function GrimoriaPlugin:renderAppearances(char, slot, rows)
    local hits, peak, total = {}, 0, 0
    for _, row in ipairs(rows) do
        local n = row.counts and row.counts[slot]
        if n and n > 0 then
            hits[#hits + 1] = { chapter = row.chapter, title = row.title, count = n }
            if n > peak then peak = n end
            total = total + n
        end
    end

    if #hits == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(self.loc:t("scan_no_appearances"), char.name),
            timeout = 4,
        })
        return
    end

    local items = {}
    for _, h in ipairs(hits) do
        local cells = math.max(1, math.floor(
            h.count / peak * self.APPEARANCE_BAR_CELLS + 0.5))
        local label = string.format("%s %d", self.loc:t("chapter"), h.chapter)
        if type(h.title) == "string" and #h.title > 0 then
            label = label .. " · " .. h.title
        end
        items[#items + 1] = {
            text = string.format("%s  %dx\n   %s",
                                 string.rep("█", cells), h.count, label),
            callback = function()
                self:jumpToChapter(h.chapter)
            end,
        }
    end

    local menu = Menu:new{
        title = char.name,
        subtitle = string.format(self.loc:t("scan_summary"), total, #hits),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

--[[
Go to the start of a chapter.

Wrapped in pcall and reported rather than assumed: the navigation call differs
between KOReader's two document backends and is the sort of host API that gets
renamed, and failing to jump is a disappointment while failing loudly with a
stack trace takes the whole reader down.

The current position is pushed onto KOReader's own location stack first, so the
reader's Back gesture returns them to where they were reading -- a plugin that
moves the book somewhere else and provides no way home is worse than one that
does not move it at all.
]]
function GrimoriaPlugin:jumpToChapter(index)
    local BookText = require("lib/booktext")
    local ok = pcall(function()
        local chapters = BookText:getChapterList(self.ui, self:chapterScheme())
        local ch = chapters[index]
        if not ch then error("no such chapter") end

        if self.ui.link and self.ui.link.addCurrentLocationToStack then
            self.ui.link:addCurrentLocationToStack()
        end

        if ch.page_start and self.ui.paging then
            self.ui.paging:onGotoPage(ch.page_start)
        elseif ch.xp_start and self.ui.rolling then
            self.ui.rolling:onGotoXPointer(ch.xp_start, ch.xp_start)
        else
            error("no way to navigate this document")
        end
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = self.loc:t("scan_no_jump"), timeout = 3 })
    end
end

-- Pick a character, then show their chapters. The entry point from the menu,
-- for readers who do not find the hold gesture on the character list.
function GrimoriaPlugin:showAppearancesPicker()
    self:applyChapterFilter()
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{ text = self.loc:t("no_character_data"), timeout = 3 })
        return
    end

    local menu
    local items = {}
    for _, char in ipairs(self.characters) do
        items[#items + 1] = {
            text = char.name,
            callback = function()
                UIManager:close(menu)
                self:showChapterAppearances(char)
            end,
        }
    end

    menu = Menu:new{
        title = self.loc:t("menu_appearances"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

return GrimoriaPlugin
