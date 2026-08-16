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

return Mentions
