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

-- Above this many TOC entries, consecutive ones are grouped into buckets.
-- Ebook tables of contents are wildly inconsistent -- Dau Voi's 13 printed
-- chapters appear as 63 TOC entries on-device because sub-sections are listed
-- too. Without a ceiling, a long book asks the model for hundreds of
-- per-chapter entries and the reply is truncated.
BookText.MAX_CHAPTERS = 60

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
local function getEpubChapters(doc)
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
            entries[#entries + 1] = { title = e.title, xpointer = e.xpointer }
        end
    end

    -- No usable TOC: treat the whole book as a single chapter.
    if #entries == 0 then
        return { { title = "Full text", xp_start = doc_start, xp_end = doc_end } }
    end

    local chapters = {}
    for i, e in ipairs(entries) do
        chapters[#chapters + 1] = {
            title   = e.title,
            xp_start = e.xpointer,
            xp_end   = entries[i + 1] and entries[i + 1].xpointer or doc_end,
        }
    end

    -- Front matter before the first TOC entry (cover, foreword) is skipped on
    -- purpose: it dilutes the analysis and burns tokens.
    return chapters
end

-- Returns { {title=, page_start=, page_end=}, ... } for paged documents.
local function getPdfChapters(doc)
    local total = doc:getPageCount() or 0
    local toc = doc:getToc() or {}

    local entries = {}
    for _, e in ipairs(toc) do
        if e.page then entries[#entries + 1] = { title = e.title, page = e.page } end
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
            }
        end
    end
    return chapters
end

--[[
THE canonical chapter list. Everything -- extraction, the AI's chapter
numbering, and the reading-position filter -- must agree on what "chapter 12"
means, so all of them come through here and nowhere else.

Books whose TOC exceeds MAX_CHAPTERS get consecutive entries grouped into
buckets. The grouping is deterministic (same input, same buckets), which is
what keeps the filter aligned with the analysis.
]]
function BookText:getChapterList(ui)
    local doc = ui.document
    local paged = isPaged(ui)

    -- Building the EPUB list moves the document to find its bounds, and the
    -- filter asks for this every time a view opens. Cache per book so that
    -- happens once, not on every menu tap.
    if self._cache and self._cache.file == doc.file then
        return self._cache.list, self._cache.grouped
    end

    local raw = paged and getPdfChapters(doc) or getEpubChapters(doc)

    if #raw <= self.MAX_CHAPTERS then
        self._cache = { file = doc.file, list = raw, grouped = false }
        return raw, false
    end

    local per = math.ceil(#raw / self.MAX_CHAPTERS)
    local out = {}
    for i = 1, #raw, per do
        local first, last = raw[i], raw[math.min(i + per - 1, #raw)]
        local title = first.title or ("Chapter " .. #out + 1)
        if last ~= first and last.title and last.title ~= first.title then
            title = title .. " – " .. last.title
        end
        if paged then
            out[#out + 1] = { title = title,
                              page_start = first.page_start, page_end = last.page_end }
        else
            out[#out + 1] = { title = title,
                              xp_start = first.xp_start, xp_end = last.xp_end }
        end
    end
    logger.info("BookText: grouped", #raw, "TOC entries into", #out, "chapters")
    self._cache = { file = doc.file, list = out, grouped = true }
    return out, true
end

-- ----------------------------------------------------------- current spot --

-- Which chapter is the reader in right now? Drives the spoiler filter, so it
-- runs every time a view opens - it must stay cheap and must not move the
-- document.
function BookText:getCurrentChapterIndex(ui)
    local ok, idx = pcall(function()
        local doc = ui.document
        -- Same list the analysis was numbered against -- crucially including
        -- any bucketing, or the filter would point at the wrong chapter.
        local chapters = self:getChapterList(ui)
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
function BookText:getChapterCount(ui)
    local ok, n = pcall(function() return #(self:getChapterList(ui)) end)
    return (ok and n and n > 0) and n or 1
end

-- -------------------------------------------------------------- extractor --

--[[
extract(ui, opts) -> text, meta   |   nil, error_code

opts.max_chars  hard cap on the returned string (default MAX_CHARS_DEFAULT)

meta = { chapter_count, chapters_included, truncated, chapter_titles }

Truncation drops the END of the book rather than the beginning: early chapters
are what a reader partway through can safely be shown, and the per-chapter
filter means missing late chapters degrades gracefully.
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
        local chapters, grouped = self:getChapterList(ui)
        local buf, total = {}, 0
        local included, truncated = 0, false
        local titles = {}

        for i, ch in ipairs(chapters) do
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
