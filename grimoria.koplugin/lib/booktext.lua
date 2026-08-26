--[[
BookText - pulls the real text of the open book out of KOReader.

Why this module exists: the plugin used to send only the title and author to
the AI, so every answer came from the model's memory of that title. For books
whose titles the model does not know (translations, light novels) that produced
confident fiction. Everything here exists to put the actual text in front of
the model instead.

Text is emitted with "=== CHAPTER n: title ===" markers so the AI can attribute
what it finds to a chapter, which is what makes the spoiler filter possible
without ever asking the AI a second time.

Two backends:
  EPUB (crengine, info.has_pages == false) - chapter ranges as xpointer pairs
  PDF/DjVu (info.has_pages == true)        - chapter ranges as page numbers

APIs used here are the real ones (getTextFromXPointers, getPageText, getToc).
The old lib/mentions.lua called getFullText/extractText/getTextFromPositions
with integers - none of those exist in KOReader, and every call was wrapped in
pcall, so the failures were silent and the feature never actually worked.
]]

local logger = require("logger")
local util = require("util")

local BookText = {}

--[[
Sizing, measured rather than guessed.

Vietnamese runs ~3.3 characters per token (Thap Giac Quan 334k chars = 100,301
tokens; Dau Voi 605k chars = 184,030). So even a 1,000,000-character book is
only ~310k tokens against a 1,048,576-token INPUT limit -- input is not the
binding constraint.

The OUTPUT limit is: 65,536 tokens, shared with the model's thinking pass
(measured 2.4k-19.6k). Per-chapter data for a very long book overruns that
long before the input does, which is why MAX_CHAPTERS below matters more than
MAX_CHARS.
]]
BookText.MAX_CHARS_DEFAULT = 1000000

-- How chapter boundaries are derived. Stored analyses keep this number because
-- changing a boundary changes every spoiler-filter chapter index after it.
--
-- Scheme 1: consecutive pair-bucketing above MAX_CHAPTERS.
-- Scheme 2: nested depth / DocFragment grouping above MAX_CHAPTERS.
-- Scheme 3 (current): scheme 2 plus recovery of printed subchapters which start
-- a spine file but were omitted from the EPUB navigation document. This is a
-- common Calibre conversion defect: the content has "1", "2", "3" section
-- starts in separate XHTML files while toc.ncx advertises only the parent.
BookText.CHAPTER_SCHEME = 3

-- Above this many TOC entries, consecutive ones are grouped into buckets.
-- Ebook tables of contents are wildly inconsistent -- Dau Voi's 13 printed
-- chapters appear as 63 TOC entries on-device because sub-sections are listed
-- too. Without a ceiling, a long book asks the model for hundreds of
-- per-chapter entries and the reply is truncated.
-- Ceiling on how many TOC entries we send as separate chapters. Above this,
-- consecutive entries are grouped (scheme 1: pairs; schemes 2/3: spine file /
-- TOC depth). 100 keeps a typical novel's subsection TOC intact -- Đầu Voi
-- has 63 entries -- while still capping books that list every scene heading.
-- A long list still shares the 65,536-token reply with thinking, so the fetch
-- confirm warns when the count is high.
BookText.MAX_CHAPTERS = 100

-- Rough ceiling on how many by_chapter entries the model should emit in total,
-- derived from the output budget: 65,536 minus ~20k thinking and ~10k for
-- chapter summaries and the rest, divided by ~45 tokens per entry.
BookText.MAX_DEV_ENTRIES = 700
BookText.MAX_PDF_PAGES = 400

-- ---------------------------------------------------------------- helpers --

local function isPaged(ui)
    return ui.document and ui.document.info and ui.document.info.has_pages
end

-- Measured against the API's own countTokens on two Vietnamese novels: 3.33
-- and 3.29 characters per token. Using 3.0 keeps the figure shown to the user
-- slightly conservative without the 60% overstatement the old /2 produced.
function BookText:estimateTokens(text)
    if not text then return 0 end
    return math.ceil(#text / 3)
end

-- Truncation always cuts on a byte boundary that may sit inside a UTF-8
-- sequence, so drop the orphaned continuation bytes and repair the rest.
local function sanitizeCut(text)
    text = text:gsub("^[\128-\191]+", "")
    return util.fixUtf8(text, "_")
end

-- Flatten one page of PDF text. getPageText returns nested tables
-- (blocks -> lines -> word spans), never a plain string; the old code
-- concatenated the table directly, which is why PDF never worked either.
local function flattenPageText(page_text)
    if type(page_text) == "string" then return page_text end
    if type(page_text) ~= "table" then return "" end
    local words = {}
    for _, block in ipairs(page_text) do
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
    return table.concat(words, " ")
end

-- ------------------------------------------------------- chapter listings --

-- Returns { {title=, xp_start=, xp_end=}, ... } for reflowable documents.
-- The document position is moved to find the start/end bounds, so the caller
-- MUST have saved the reading position first (see extract()).
local function fragmentId(ch)
    local xp = ch.xpointer or ch.xp_start
    if type(xp) ~= "string" then return nil end
    return tonumber(xp:match("DocFragment%[(%d+)%]"))
end

local function trim(s)
    return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
end

local function blockText(markup)
    local text = markup:gsub("<.->", " ")
        :gsub("&nbsp;", " ")
        :gsub("&#160;", " ")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&amp;", "&")
        :gsub("%s+", " ")
    return trim(text)
end

-- First visible paragraph/heading blocks in one CREngine DocFragment.
local function firstBlocks(fragment_html)
    if type(fragment_html) ~= "string" then return {} end
    local blocks = {}
    for pos, inner in fragment_html:gmatch("()<[pP][^>]*>(.-)</[pP]>") do
        local text = blockText(inner)
        if text ~= "" then
            blocks[#blocks + 1] = { pos = pos, kind = "p", text = text }
        end
    end
    for pos, level, inner in fragment_html:gmatch(
            "()<[hH]([1-6])[^>]*>(.-)</[hH]%2>") do
        local text = blockText(inner)
        if text ~= "" then
            blocks[#blocks + 1] = { pos = pos, kind = "h", text = text }
        end
    end
    table.sort(blocks, function(a, b) return a.pos < b.pos end)
    return blocks
end

local function printedSectionNumber(text)
    local n = tonumber(type(text) == "string" and text:match("^(%d+)$") or nil)
    -- Printed novel subchapters are small ordinals. A larger standalone number
    -- at a file boundary is much more likely to be a year or data table.
    return n and n >= 1 and n <= 20 and n or nil
end

local function fragmentSignal(doc, n)
    local xp = string.format("/body/DocFragment[%d]", n)
    local ok_found, found = pcall(function()
        return doc:isXPointerInDocument(xp)
    end)
    if not ok_found or not found then return nil end

    local ok_html, fragment_html = pcall(function()
        return doc:getHTMLFromXPointer(xp)
    end)
    if not ok_html then return false end
    local blocks = firstBlocks(fragment_html)
    local first, second = blocks[1], blocks[2]
    if not first then return false end

    local ok_pos, pos = pcall(function() return doc:getPosFromXPointer(xp) end)
    if not ok_pos or type(pos) ~= "number" then return false end

    local number = printedSectionNumber(first.text)
    if first.kind == "h" then
        local second_number = second and printedSectionNumber(second.text) or nil
        if not second_number then return false end
        return {
            fragment = n, xp = xp, pos = pos, heading = first.text,
            number = second_number,
        }
    end
    if number then
        return { fragment = n, xp = xp, pos = pos, number = number }
    end

    local second_number = second and printedSectionNumber(second.text) or nil
    local has_word = first.text:find("[%w\128-\255]") ~= nil
    if second_number and #first.text <= 160 and has_word then
        return {
            fragment = n, xp = xp, pos = pos, heading = first.text,
            number = second_number,
        }
    end
    return false
end

-- Add only strong spine-file boundaries: headings, or a sequence of at least
-- two small printed ordinals inside one advertised TOC entry. Requiring a
-- sequence prevents a file that happens to open with a standalone number from
-- becoming a chapter by accident.
local function refineEpubEntries(doc, entries)
    if #entries == 0
        or type(doc.isXPointerInDocument) ~= "function"
        or type(doc.getHTMLFromXPointer) ~= "function"
        or type(doc.getPosFromXPointer) ~= "function" then
        return entries, false
    end

    local positions, raw_fragments = {}, {}
    for i, entry in ipairs(entries) do
        local ok, pos = pcall(function()
            return doc:getPosFromXPointer(entry.xpointer)
        end)
        if not ok or type(pos) ~= "number" then return entries, false end
        positions[i] = pos
        raw_fragments[i] = fragmentId(entry)
    end

    local groups = {}
    for i = 1, #entries do groups[i] = {} end
    -- EPUB spine item counts are normally in the tens. The cap protects
    -- malformed DOMs where every arbitrary DocFragment index resolves.
    for n = 1, 2000 do
        local signal = fragmentSignal(doc, n)
        if signal == nil then break end
        if signal then
            local owner
            for i, raw_fragment in ipairs(raw_fragments) do
                if raw_fragment == n then owner = i; break end
            end
            if not owner then
                for i = #entries, 1, -1 do
                    if signal.pos >= positions[i] then owner = i; break end
                end
            end
            if owner then groups[owner][#groups[owner] + 1] = signal end
        end
    end

    local out, changed = {}, false
    for i, entry in ipairs(entries) do
        local signals = groups[i]
        local raw_fragment = raw_fragments[i]
        local anchor
        local numeric_count = 0
        for _, signal in ipairs(signals) do
            if signal.fragment == raw_fragment then anchor = signal end
            if signal.number then numeric_count = numeric_count + 1 end
        end

        local base = entry.title or ("Chapter " .. i)
        local title = base
        if anchor and anchor.number and numeric_count >= 2 then
            title = base .. " · " .. anchor.number
        end
        out[#out + 1] = {
            title = title, xpointer = entry.xpointer, depth = entry.depth,
        }

        for _, signal in ipairs(signals) do
            if signal.fragment ~= raw_fragment then
                local candidate_title
                if signal.heading then
                    base = signal.heading
                    candidate_title = signal.number
                        and (base .. " · " .. signal.number) or base
                elseif signal.number and numeric_count >= 2 then
                    candidate_title = base .. " · " .. signal.number
                end
                if candidate_title then
                    out[#out + 1] = {
                        title = candidate_title, xpointer = signal.xp,
                        depth = entry.depth and (entry.depth + 1) or nil,
                    }
                    changed = true
                end
            end
        end
    end
    return changed and out or entries, changed
end

local function getEpubChapters(doc, scheme)
    local saved = doc:getXPointer()

    doc:gotoPos(0)
    local doc_start = doc:getXPointer()

    local height = doc.info and doc.info.doc_height
    doc:gotoPos(height and height > 0 and height or 2 ^ 30)
    local doc_end = doc:getXPointer()

    doc:gotoXPointer(saved)  -- put the reader back where they were

    local toc = doc:getToc() or {}
    local entries = {}
    for _, e in ipairs(toc) do
        if e.xpointer then
            entries[#entries + 1] = {
                title = e.title, xpointer = e.xpointer, depth = e.depth,
            }
        end
    end

    -- No usable TOC: treat the whole book as a single chapter.
    if #entries == 0 then
        return { { title = "Full text", xp_start = doc_start, xp_end = doc_end } },
            false
    end

    local refined = false
    if scheme >= 3 then entries, refined = refineEpubEntries(doc, entries) end

    local chapters = {}
    for i, e in ipairs(entries) do
        chapters[#chapters + 1] = {
            title    = e.title,
            xp_start = e.xpointer,
            xp_end   = entries[i + 1] and entries[i + 1].xpointer or doc_end,
            depth    = e.depth,
        }
    end

    -- Front matter before the first TOC entry (cover, foreword) is skipped on
    -- purpose: it dilutes the analysis and burns tokens.
    return chapters, refined
end

-- Returns { {title=, page_start=, page_end=}, ... } for paged documents.
local function getPdfChapters(doc)
    local total = doc:getPageCount() or 0
    local toc = doc:getToc() or {}

    local entries = {}
    for _, e in ipairs(toc) do
        if e.page then
            entries[#entries + 1] = { title = e.title, page = e.page, depth = e.depth }
        end
    end

    if #entries == 0 then
        return { { title = "Full text", page_start = 1, page_end = total } }
    end

    local chapters = {}
    for i, e in ipairs(entries) do
        local next_page = entries[i + 1] and (entries[i + 1].page - 1) or total
        if next_page >= e.page then
            chapters[#chapters + 1] = {
                title = e.title, page_start = e.page, page_end = next_page,
                depth = e.depth,
            }
        end
    end
    return chapters
end

local function mergeRange(raw, first_i, last_i, paged)
    local first, last = raw[first_i], raw[last_i]
    local title = first.title or ("Chapter " .. first_i)
    if last ~= first and last.title and last.title ~= first.title then
        title = title .. " – " .. last.title
    end
    if paged then
        return { title = title,
                 page_start = first.page_start, page_end = last.page_end }
    end
    return { title = title, xp_start = first.xp_start, xp_end = last.xp_end }
end

local function pairBucket(raw, paged, max_chapters)
    local per = math.ceil(#raw / max_chapters)
    local out = {}
    for i = 1, #raw, per do
        out[#out + 1] = mergeRange(raw, i, math.min(i + per - 1, #raw), paged)
    end
    return out
end

-- Nested TOC: keep only the shallowest depth that actually has children.
local function groupByDepth(raw, paged)
    local min_d, varied = nil, false
    for _, ch in ipairs(raw) do
        local d = tonumber(ch.depth)
        if d then
            if min_d == nil then
                min_d = d
            elseif d < min_d then
                min_d, varied = d, true
            elseif d > min_d then
                varied = true
            end
        end
    end
    if not varied or min_d == nil then return nil end
    local heads = {}
    for i, ch in ipairs(raw) do
        if (tonumber(ch.depth) or (min_d + 1)) == min_d then
            heads[#heads + 1] = i
        end
    end
    if #heads < 2 or #heads == #raw then return nil end
    local out = {}
    for i, hi in ipairs(heads) do
        local last = heads[i + 1] and (heads[i + 1] - 1) or #raw
        out[#out + 1] = mergeRange(raw, hi, last, paged)
    end
    return out
end


-- Consecutive TOC entries that share a crengine DocFragment (one spine HTML
-- file, in practice one printed chapter on Calibre-split EPUBs).
local function groupByFragment(raw, paged)
    if paged then return nil end
    local any = false
    for _, ch in ipairs(raw) do
        if fragmentId(ch) then any = true; break end
    end
    if not any then return nil end
    local out = {}
    local run_start = 1
    local run_id = fragmentId(raw[1])
    for i = 2, #raw + 1 do
        local id = raw[i] and fragmentId(raw[i])
        if i > #raw or id ~= run_id then
            out[#out + 1] = mergeRange(raw, run_start, i - 1, paged)
            run_start, run_id = i, id
        end
    end
    if #out < 2 or #out == #raw then return nil end
    return out
end

--[[
THE canonical chapter list. Everything -- extraction, the AI's chapter
numbering, and the reading-position filter -- must agree on what "chapter 12"
means, so all of them come through here and nowhere else.

`scheme` selects both EPUB boundary recovery and how a list longer than
MAX_CHAPTERS is reduced. It is a forever-contract: scheme 1 is pair-bucketing;
scheme 2 adds depth/DocFragment grouping; scheme 3 also recovers printed
subchapters omitted from the EPUB navigation file. Passing the wrong scheme
against a stored analysis numbers the book differently from the tags in that
analysis, which can either leak later material or hide material already read.

Books with a complete raw TOC below MAX_CHAPTERS remain unchanged.
]]
function BookText:getChapterList(ui, scheme)
    local doc = ui.document
    local paged = isPaged(ui)
    scheme = tonumber(scheme) or self.CHAPTER_SCHEME
    if scheme ~= 1 and scheme ~= 2 and scheme ~= 3 then
        scheme = self.CHAPTER_SCHEME
    end

    -- Building the EPUB list moves the document to find its bounds, and the
    -- filter asks for this every time a view opens. Cache per book AND scheme
    -- so switching between analyses never reuses another scheme's numbering.
    if self._cache and self._cache.file == doc.file
        and self._cache.scheme == scheme then
        return self._cache.list, self._cache.grouped, self._cache.how
    end

    local raw, refined
    if paged then
        raw = getPdfChapters(doc)
    else
        raw, refined = getEpubChapters(doc, scheme)
    end

    if #raw <= self.MAX_CHAPTERS then
        local how = refined and "fragments" or "none"
        self._cache = { file = doc.file, scheme = scheme,
                        list = raw, grouped = false, how = how }
        return raw, false, how
    end

    local out, how
    if scheme == 1 then
        out, how = pairBucket(raw, paged, self.MAX_CHAPTERS), "pairs"
    else
        out = groupByDepth(raw, paged)
        how = out and "depth" or nil
        if not out then
            out = groupByFragment(raw, paged)
            how = out and "fragments" or nil
        end
        if not out or #out > self.MAX_CHAPTERS then
            out = pairBucket(out or raw, paged, self.MAX_CHAPTERS)
            how = "pairs"
        end
    end

    logger.info("BookText: scheme", scheme, "grouped", #raw, "TOC entries into",
                #out, "via", how)
    self._cache = { file = doc.file, scheme = scheme,
                    list = out, grouped = true, how = how }
    return out, true, how
end

-- ----------------------------------------------------------- current spot --

-- Which chapter is the reader in right now? Drives the spoiler filter, so it
-- runs every time a view opens - it must stay cheap and must not move the
-- document.
function BookText:getCurrentChapterIndex(ui, scheme)
    local ok, idx = pcall(function()
        local doc = ui.document
        -- Same list the analysis was numbered against -- crucially including
        -- any bucketing, or the filter would point at the wrong chapter.
        local chapters = self:getChapterList(ui, scheme)
        if #chapters == 0 then return 1 end

        if isPaged(ui) then
            local page = (ui.paging and ui.paging:getCurrentPage())
                or (ui.getCurrentPage and ui:getCurrentPage()) or 1
            local found = 1
            for i, ch in ipairs(chapters) do
                if ch.page_start and ch.page_start <= page then found = i end
            end
            return found
        end

        -- Reflowable: compare numeric positions, not xpointer strings.
        -- Xpointers are paths like "/body/DocFragment[12]/..." and comparing
        -- them lexically gives the wrong answer (fragment 9 > fragment 12).
        local current_pos = doc:getPosFromXPointer(doc:getXPointer())
        local found = 1
        for i, ch in ipairs(chapters) do
            if ch.xp_start then
                local pos = doc:getPosFromXPointer(ch.xp_start)
                if pos and current_pos and pos <= current_pos then found = i end
            end
        end
        return found
    end)

    if not ok or type(idx) ~= "number" then
        logger.warn("BookText: could not resolve current chapter:", idx)
        return nil
    end
    return idx
end

-- How many chapters this book has, after any grouping.
function BookText:getChapterCount(ui, scheme)
    local ok, n = pcall(function() return #(self:getChapterList(ui, scheme)) end)
    return (ok and n and n > 0) and n or 1
end

-- -------------------------------------------------------------- extractor --

--[[
extract(ui, opts) -> text, meta   |   nil, error_code

opts.max_chars      hard cap on the returned string (default MAX_CHARS_DEFAULT)
opts.first_chapter  first chapter to include (default 1)
opts.last_chapter   last chapter to include (default: all of them)

meta = { chapter_count, chapters_included, truncated, chapter_titles,
         first_chapter, last_chapter }

Truncation drops the END of the range rather than the beginning: early chapters
are what a reader partway through can safely be shown, and the per-chapter
filter means missing late chapters degrades gracefully.

SECTION ANALYSES, AND THE ONE THING THAT MUST NOT CHANGE

A very long book can ask for more per-chapter output than the reply is allowed
to hold, and when the ladder in lib/llm.lua runs out it starts dropping whole
chapters off the end. Analysing a range instead lets a reader spend two smaller
requests and lose nothing.

The chapter numbers stay ABSOLUTE. Asking for chapters 30-40 emits
"=== CHAPTER 30 ===" first, not "=== CHAPTER 1 ===". Renumbering from 1 would
be the obvious implementation and would break everything downstream at once:
the model tags its answer with the numbers it was given, the reading-position
filter compares those tags against getChapterList's numbering, and the two
would be ten apart -- so a reader at chapter 35 would be shown material from
chapter 45. Same rule as everywhere else in this file: getChapterList is the
single source of chapter numbering.
]]
function BookText:extract(ui, opts)
    opts = opts or {}
    local max_chars = opts.max_chars or self.MAX_CHARS_DEFAULT
    local doc = ui and ui.document
    if not doc then return nil, "no_document" end

    local paged = isPaged(ui)
    -- Saved outside the pcall so the reader's position is restored even if
    -- extraction blows up halfway through moving the document around.
    local saved_xp = nil
    if not paged then
        local ok_save, xp = pcall(function() return doc:getXPointer() end)
        if ok_save then saved_xp = xp end
    end

    local ok, text, meta = pcall(function()
        local scheme = tonumber(opts.scheme) or self.CHAPTER_SCHEME
        local chapters, grouped, how = self:getChapterList(ui, scheme)
        local buf, total = {}, 0
        local included, truncated = 0, false
        local titles = {}

        -- Clamped rather than trusted: the picker offers real chapters, but a
        -- setting or a stale range could name one that no longer exists, and
        -- an empty extraction reports as "the book could not be read".
        local from = math.max(1, math.floor(tonumber(opts.first_chapter) or 1))
        local to = math.min(#chapters, math.floor(tonumber(opts.last_chapter) or #chapters))
        if to < from then from, to = 1, #chapters end

        for i = from, to do
            local ch = chapters[i]
            local title = ch.title or ("Chapter " .. i)
            titles[#titles + 1] = title

            local body
            if paged then
                local pages = {}
                local last = math.min(ch.page_end, ch.page_start + self.MAX_PDF_PAGES - 1)
                for p = ch.page_start, last do
                    local ok_p, pt = pcall(function() return doc:getPageText(p) end)
                    if ok_p and pt then pages[#pages + 1] = flattenPageText(pt) end
                end
                body = table.concat(pages, "\n")
            else
                local ok_t, t = pcall(function()
                    return doc:getTextFromXPointers(ch.xp_start, ch.xp_end)
                end)
                body = (ok_t and t) or ""
            end

            if body and #body > 0 then
                local header = string.format("\n=== CHAPTER %d: %s ===\n", i, title)
                if total + #header + #body > max_chars then
                    -- Partially include this chapter, then stop.
                    local room = max_chars - total - #header
                    if room > 2000 then
                        buf[#buf + 1] = header
                        buf[#buf + 1] = sanitizeCut(body:sub(1, room))
                        included = included + 1
                    end
                    truncated = true
                    break
                end
                buf[#buf + 1] = header
                buf[#buf + 1] = body
                total = total + #header + #body
                included = included + 1
            end
        end

        local out = util.fixUtf8(table.concat(buf), "_")
        -- Free the per-chapter pieces before the caller builds the prompt and
        -- json-encodes it; on a long book those are three large strings alive
        -- at once, and a Kindle has little room to spare.
        buf = nil
        collectgarbage("step")
        return out, {
            chapter_count     = #chapters,
            chapters_included = included,
            truncated         = truncated,
            chapter_titles    = titles,
            grouped           = grouped,
            grouped_how       = how,
            scheme            = scheme,
            -- Absolute, and only set when this was a section run: the prompt
            -- has to state the range, and the version picker records it.
            first_chapter     = (from > 1 or to < #chapters) and from or nil,
            last_chapter      = (from > 1 or to < #chapters) and to or nil,
            -- Ceiling on per-chapter entries the model should emit, so the
            -- reply fits the output budget. Scaled by how many chapters there
            -- actually are; small books get no artificial limit.
            dev_budget        = math.min(self.MAX_DEV_ENTRIES, math.max(120, included * 12)),
        }
    end)

    -- Restore unconditionally - a reader whose book jumped to page 1 because
    -- Grimoria ran would rightly never trust this plugin again.
    if saved_xp then pcall(function() doc:gotoXPointer(saved_xp) end) end

    if not ok then
        logger.warn("BookText: extraction failed:", text)
        return nil, "extract_error"
    end
    if not text or #text < 500 then
        logger.warn("BookText: extracted text too short:", text and #text or 0)
        return nil, "extract_empty"
    end

    logger.info("BookText: extracted", #text, "chars from",
                meta.chapters_included, "of", meta.chapter_count, "chapters",
                meta.truncated and "(truncated)" or "")
    return text, meta
end

return BookText
