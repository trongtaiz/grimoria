--[[
Mentions - which characters actually appear in the chapter being read.

Extraction used to live here and never worked: getReflowableText called
getTextFromPositions with integers (it takes screen coordinates), then fell
back to getFullText and view.document:extractText, neither of which exists in
KOReader at all. Every call sat inside a pcall, so the failures were silent and
the feature just quietly returned nothing.

Extraction now goes through lib/booktext.lua, which uses the real APIs
(getToc, getTextFromXPointers, getPageText). What remains here is the part that
was always fine: matching known character names against a chunk of text.
]]

local logger = require("logger")
local BookText = require("lib/booktext")

local Mentions = {}

function Mentions:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Text of the chapter the reader is currently in, or nil.
function Mentions:getCurrentChapterText(ui)
    if not ui or not ui.document then
        logger.warn("Mentions: No document available")
        return nil
    end

    local doc = ui.document
    local paged = doc.info and doc.info.has_pages
    local index = BookText:getCurrentChapterIndex(ui) or 1

    local ok, text = pcall(function()
        -- Must come from the extractor's canonical list, not a fresh read of
        -- getToc(): on books with a large TOC that list is grouped into
        -- buckets, and getCurrentChapterIndex counts buckets. Indexing raw TOC
        -- entries with a bucket number would silently return another chapter.
        local chapters = BookText:getChapterList(ui)

        if #chapters == 0 then
            if paged then
                local page = (ui.paging and ui.paging:getCurrentPage()) or 1
                return self:getPagesText(doc, math.max(1, page - 2), page)
            end
            return nil
        end

        local ch = chapters[index] or chapters[#chapters]
        if paged then
            return self:getPagesText(doc, ch.page_start, ch.page_end)
        end
        return doc:getTextFromXPointers(ch.xp_start, ch.xp_end)
    end)

    if not ok or not text or #text == 0 then
        logger.warn("Mentions: could not read chapter text:", ok and "empty" or text)
        return nil
    end
    return text
end

-- Concatenate the text of a page range. getPageText returns nested tables of
-- word spans, never a string -- the old code appended the table directly.
function Mentions:getPagesText(doc, first, last)
    local words = {}
    for p = first, math.min(last, first + 100) do
        local ok, pt = pcall(function() return doc:getPageText(p) end)
        if ok and type(pt) == "table" then
            for _, block in ipairs(pt) do
                if type(block) == "table" then
                    if block.word then
                        words[#words + 1] = block.word
                    else
                        for _, span in ipairs(block) do
                            if type(span) == "table" and span.word then
                                words[#words + 1] = span.word
                            end
                        end
                    end
                end
            end
        elseif ok and type(pt) == "string" then
            words[#words + 1] = pt
        end
    end
    return table.concat(words, " ")
end

function Mentions:findCharactersInText(text, characters)
    if not text or not characters then
        return {}
    end

    local found_characters = {}
    local text_lower = string.lower(text)

    for _, char in ipairs(characters) do
        local name = char.name
        if name and #name > 2 then
            -- Check full name
            local name_lower = string.lower(name)
            if string.find(text_lower, name_lower, 1, true) then
                table.insert(found_characters, {
                    character = char,
                    count = self:countMentions(text_lower, name_lower)
                })
            else
                -- Check first name only
                local first_name = string.match(name, "^(%S+)")
                if first_name and #first_name > 2 then
                    local first_name_lower = string.lower(first_name)
                    if string.find(text_lower, first_name_lower, 1, true) then
                        table.insert(found_characters, {
                            character = char,
                            count = self:countMentions(text_lower, first_name_lower)
                        })
                    end
                end
            end
        end
    end

    -- Sort by mention count
    table.sort(found_characters, function(a, b)
        return a.count > b.count
    end)

    logger.info("Mentions: Found", #found_characters, "characters in text")

    return found_characters
end

-- Count how many times a name appears
function Mentions:countMentions(text, name)
    local count = 0
    local pos = 1

    while true do
        local start_pos = string.find(text, name, pos, true)
        if not start_pos then break end
        count = count + 1
        pos = start_pos + 1
    end

    return count
end

-- ------------------------------------------------- chapter appearances ----

--[[
How often one person is named in a chapter, counting a PERSON rather than a
string.

A character has several spellings -- "Ellery Queen", "Ellery", "Mr Queen" --
and counting each separately triple-counts every sentence that uses the full
name, because "Ellery" is inside "Ellery Queen". So the spans every spelling
matches are collected, overlapping ones merged, and what is counted is the
merged spans: one mention is one place in the text where this person is named,
whatever the author called them there.

Matching is whole-word and case-insensitive and NOT diacritic-folded, for the
reasons lib/spoilerguard.lua sets out at length -- "Văn", "Vấn" and "Van" are
three different Vietnamese words and folding makes them one. Spellings shorter
than three characters are skipped: a two-letter name matches somewhere in
almost every paragraph and would report a bar chart of noise.
]]
function Mentions:countUnion(haystack_lower, spellings)
    local spans = {}
    for _, raw in ipairs(spellings) do
        local n = type(raw) == "string" and raw:lower() or ""
        if #n >= 3 then
            local from = 1
            while true do
                local s, e = haystack_lower:find(n, from, true)
                if not s then break end
                local before = s > 1 and haystack_lower:sub(s - 1, s - 1) or " "
                local after = e < #haystack_lower and haystack_lower:sub(e + 1, e + 1) or " "
                if not before:match("%w") and not after:match("%w") then
                    spans[#spans + 1] = { s, e }
                end
                from = s + 1
            end
        end
    end
    if #spans == 0 then return 0 end

    table.sort(spans, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)

    local count, reach = 0, -1
    for _, sp in ipairs(spans) do
        if sp[1] > reach then
            count = count + 1
            reach = sp[2]
        elseif sp[2] > reach then
            reach = sp[2]          -- an overlapping longer spelling, same mention
        end
    end
    return count
end

-- Every spelling of one filtered character: the name on the card plus the
-- aliases the reader has already met. lib/spoilers.lua has dropped any alias
-- first used in a chapter they have not reached, so this list is safe by the
-- time it gets here.
function Mentions:spellingsOf(char)
    local out = { char.name }
    for _, a in ipairs(char.aliases or {}) do
        if type(a) == "string" then out[#out + 1] = a end
    end
    return out
end

--[[
scan(ui, characters, up_to, progress) -> rows | nil, error_code

rows = { { chapter = 3, title = "...", counts = { [char_index] = 7 } }, ... }

UP_TO IS A SPOILER BOUNDARY, NOT AN OPTIMISATION. "Appears 40 times in chapter
50" says the character is alive and present in chapter 50, which is a fact
about the ending that no amount of care in the rest of the plugin would undo.
The counts for chapters past the reader's position are therefore never
computed, not computed and hidden -- there is nothing to leak because there is
nothing there. Callers pass the same limit the filter used.

The reading position is saved and restored around the whole walk. Reading a
chapter's text does not move the document, but building the chapter list does
(see lib/booktext.lua), and a plugin that dumped the reader on page one to
draw a bar chart would deserve to be uninstalled.

`progress(done, total)` is called between chapters so a caller under Trapper
can keep the screen alive and offer a way out; returning false from it aborts.

NOTHING HERE WRAPS THE LOOP IN A PCALL, and that is deliberate rather than an
omission. progress() is a Trapper:info call at the other end, which YIELDS the
coroutine -- and yielding across a pcall boundary is a portability trap this
plugin has no reason to take. Every call that can actually fail (building the
chapter list, reading a chapter's text) carries its own pcall instead, and the
rest of the loop is arithmetic over strings.
]]
function Mentions:scan(ui, characters, up_to, progress)
    if not ui or not ui.document then return nil, "no_document" end
    if type(up_to) ~= "number" or up_to < 1 then return {} end

    local doc = ui.document
    local paged = doc.info and doc.info.has_pages

    local saved_xp
    if not paged then
        local ok_save, xp = pcall(function() return doc:getXPointer() end)
        if ok_save then saved_xp = xp end
    end
    -- Restoring is not optional on any path out of here, including the early
    -- returns below: getChapterList moves the document to find its bounds.
    local function restore()
        if saved_xp then pcall(function() doc:gotoXPointer(saved_xp) end) end
    end

    local spellings = {}
    for i, c in ipairs(characters) do spellings[i] = self:spellingsOf(c) end

    local ok_list, chapters = pcall(function() return BookText:getChapterList(ui) end)
    if not ok_list or type(chapters) ~= "table" then
        logger.warn("Mentions: could not build the chapter list:", chapters)
        restore()
        return nil, "scan_failed"
    end

    local last = math.min(up_to, #chapters)
    local out = {}
    for i = 1, last do
        local ch = chapters[i]
        local body
        if paged then
            local ok_p, t = pcall(function()
                return self:getPagesText(doc, ch.page_start, ch.page_end)
            end)
            body = (ok_p and t) or ""
        else
            local ok_t, t = pcall(function()
                return doc:getTextFromXPointers(ch.xp_start, ch.xp_end)
            end)
            body = (ok_t and t) or ""
        end

        local counts = {}
        if #body > 0 then
            local lower = body:lower()
            for idx, list in ipairs(spellings) do
                local n = self:countUnion(lower, list)
                if n > 0 then counts[idx] = n end
            end
        end
        out[#out + 1] = { chapter = i, title = ch.title, counts = counts }

        -- Freed before the next chapter is read: on a long book these are two
        -- large strings alive at once on a device with very little room.
        body = nil
        collectgarbage("step")

        if progress and progress(i, last) == false then
            restore()
            return nil, "cancelled"
        end
    end

    restore()
    logger.info("Mentions: scanned", #out, "chapter(s) for", #characters, "character(s)")
    return out
end

return Mentions
