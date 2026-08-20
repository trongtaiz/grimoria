--[[
Section analyses: sending part of a long book, without renumbering it.

A very long novel asks for more per-chapter output than the 65,536-token reply
budget holds, and when lib/llm.lua's ladder runs out it starts dropping whole
chapters off the end. Analysing chapters 30-40 as one request and 41-56 as
another costs the same and loses nothing.

The one thing that must not go wrong is the numbering. Renumbering a section to
start at 1 is the obvious implementation, and it breaks the entire plugin
quietly: the model tags its answer with the numbers it was given, the spoiler
filter compares those tags against BookText:getChapterList's numbering, and the
two would be off by however far into the book the range started -- so a reader
at chapter 35 would be shown chapter 45's contents, with nothing anywhere
saying so.

So this suite asserts the numbers, on the real extractor, against a stub
document. No book and no key needed.

  usage: lua test_range.lua <plugin_dir>
]]

local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("util", { fixUtf8 = function(s) return s end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end,
                              attributes = function() return nil end,
                              dir = function() return function() return nil end end })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

-- ------------------------------------------------------------ the stub doc --

local N = 12
local function makeDoc(file)
    local doc = { file = file, info = { has_pages = false, doc_height = 1000 } }
    local toc = {}
    for i = 1, N do toc[i] = { title = "Chapter " .. i, xpointer = "xp" .. i } end

    doc._at = "start"
    function doc:getXPointer() return self._at end
    function doc:gotoXPointer(xp) self._at = xp end
    function doc:gotoPos(p) self._at = "pos" .. tostring(p) end
    function doc:getToc() return toc end
    function doc:getTextFromXPointers(a, _b)
        local n = tonumber((tostring(a):gsub("xp", "")))
        if not n then return "" end
        -- Long enough to clear extract()'s 500-character floor on its own.
        return ("Body of chapter " .. n .. ". "):rep(60)
    end
    return doc
end

local BookText = require("lib/booktext")
local function freshUi(name)
    BookText._cache = nil          -- the per-book chapter-list cache
    return { document = makeDoc(name) }
end

-- ------------------------------------------------------------ the numbering --

print("=== a range keeps the book's own chapter numbers ===")
do
    local ui = freshUi("/books/a.epub")
    local text, meta = BookText:extract(ui, { first_chapter = 5, last_chapter = 8 })

    check(text ~= nil, "the range extracts (" .. tostring(meta) .. ")")
    check(text:find("=== CHAPTER 5:", 1, true) ~= nil,
          "it opens at CHAPTER 5, not CHAPTER 1")
    check(text:find("=== CHAPTER 1:", 1, true) == nil,
          "and there is no CHAPTER 1 marker anywhere in it")
    check(text:find("=== CHAPTER 8:", 1, true) ~= nil, "it reaches CHAPTER 8")
    check(text:find("=== CHAPTER 9:", 1, true) == nil, "and stops there")
    check(text:find("Body of chapter 5.", 1, true) ~= nil,
          "the marker is over the right chapter's text")
    check(text:find("Body of chapter 4.", 1, true) == nil,
          "nothing before the range is included")

    check(meta.first_chapter == 5 and meta.last_chapter == 8,
          "the range is reported back, so the prompt and the version can state it")
    check(meta.chapters_included == 4, "4 chapters included")
    check(meta.chapter_count == N,
          "chapter_count stays the BOOK's total, not the range's (got "
          .. tostring(meta.chapter_count) .. ")")
end

print("\n=== a whole-book run is unchanged ===")
do
    local ui = freshUi("/books/b.epub")
    local text, meta = BookText:extract(ui, {})
    check(text:find("=== CHAPTER 1:", 1, true) ~= nil, "starts at chapter 1")
    check(text:find("=== CHAPTER " .. N .. ":", 1, true) ~= nil, "ends at the last chapter")
    --[[
    nil rather than 1..N, and the distinction is load-bearing: the prompt adds
    a "this is only part of the book" clause when these are set, and putting it
    on a whole-book request would tell the model to leave out chapters that are
    right there in front of it.
    ]]
    check(meta.first_chapter == nil and meta.last_chapter == nil,
          "and reports no range at all")
end

print("\n=== a nonsense range falls back to the whole book ===")
do
    local ui = freshUi("/books/c.epub")
    local _text, meta = BookText:extract(ui, { first_chapter = 9, last_chapter = 3 })
    check(meta.chapters_included == N,
          "last before first is not an empty extraction, which would report as "
          .. "\"the book could not be read\" (got " .. meta.chapters_included .. ")")

    local ui2 = freshUi("/books/d.epub")
    local _t2, meta2 = BookText:extract(ui2, { first_chapter = 3, last_chapter = 999 })
    check(meta2.last_chapter == N, "a range past the end is clamped to the last chapter")
end

print("\n=== the reader's position is restored either way ===")
do
    local ui = freshUi("/books/e.epub")
    ui.document._at = "WHERE-THE-READER-WAS"
    BookText:extract(ui, { first_chapter = 4, last_chapter = 6 })
    check(ui.document._at == "WHERE-THE-READER-WAS",
          "extraction put the document back (got " .. ui.document._at .. ")")
end

-- ------------------------------------------------------------- the prompt --

print("\n=== the prompt tells the model the numbers do not start at 1 ===")
do
    local LLM = require("lib/llm")
    LLM.current_language = "en"
    LLM:loadPrompts()

    local whole = LLM:createPrompt("T", "A", { book_text = "x" })
    check(not whole:find("SECTION ANALYSIS", 1, true),
          "a whole-book prompt carries no section clause")

    local part = LLM:createPrompt("T", "A", {
        book_text = "x", first_chapter = 30, last_chapter = 40,
    })
    check(part:find("SECTION ANALYSIS", 1, true) ~= nil,
          "a range prompt does")
    check(part:find("chapters 30 to 40", 1, true) ~= nil,
          "and names the range")
    check(part:find("start at 30", 1, true) ~= nil,
          "and says the markers start at 30 rather than 1")
end

print("\n=== re-analyse skips quotes already in hand ===")
do
    local LLM = require("lib/llm")
    LLM.current_language = "en"
    LLM:loadPrompts()

    local first = LLM:createPrompt("T", "A", { book_text = "x" })
    check(first:find("QUOTES:", 1, true) ~= nil,
          "a first analysis still asks for quotes")
    check(first:find('"quotes":', 1, true) ~= nil,
          "and the schema still has the quotes key")

    local skip = LLM:createPrompt("T", "A", { book_text = "x", skip_quotes = true })
    check(not skip:find("QUOTES:", 1, true),
          "re-analyse with quotes already in hand does not ask for them")
    check(not skip:find('"quotes":', 1, true),
          "and the schema has no quotes key")
    check(skip:find("identity_merges", 1, true) ~= nil,
          "but the rest of the analysis schema is still there")
    check(skip:find("historical_figures", 1, true) ~= nil,
          "including historical figures")
end

print("\n=== scheme 2 groups by DocFragment; scheme 1 still pairs ===")
do
    -- Above MAX_CHAPTERS (100). 126 pair-buckets to 63; 13 fragments stay 13.
    local NENT, NFRAG = 126, 13
    local function makeFragDoc(file)
        local doc = { file = file, info = { has_pages = false, doc_height = 1000 } }
        local toc, per = {}, math.ceil(NENT / NFRAG)
        for i = 1, NENT do
            local frag = math.ceil(i / per)
            toc[i] = {
                title = "E" .. i,
                xpointer = string.format("/body/DocFragment[%d]/p[%d]", frag, i),
            }
        end
        doc._at = "start"
        function doc:getXPointer() return self._at end
        function doc:gotoXPointer(xp) self._at = xp end
        function doc:gotoPos(p) self._at = "pos" .. tostring(p) end
        function doc:getToc() return toc end
        function doc:getTextFromXPointers(a, _b)
            return ("Body of " .. tostring(a) .. ". "):rep(60)
        end
        return doc
    end

    BookText._cache = nil
    local ui = { document = makeFragDoc("/books/frag.epub") }
    local list1, _, how1 = BookText:getChapterList(ui, 1)
    check(#list1 == 63, "scheme 1 pairs 126 into 63 (got " .. #list1 .. ")")
    check(how1 == "pairs", "scheme 1 how=pairs (got " .. tostring(how1) .. ")")

    local list2, _, how2 = BookText:getChapterList(ui, 2)
    check(#list2 == NFRAG,
          "scheme 2 groups 126 into " .. NFRAG .. " fragments (got " .. #list2 .. ")")
    check(how2 == "fragments", "scheme 2 how=fragments (got " .. tostring(how2) .. ")")

    local text, meta = BookText:extract(ui, { scheme = 2 })
    check(meta.scheme == 2, "extract records scheme 2")
    check(text:find("=== CHAPTER 1:", 1, true) ~= nil
          and text:find("=== CHAPTER 13:", 1, true) ~= nil,
          "scheme 2 extract has CHAPTER 1 and CHAPTER 13")
    check(text:find("=== CHAPTER 14:", 1, true) == nil, "and not CHAPTER 14")
    check(text:find("=== CHAPTER 63:", 1, true) == nil,
          "and does not use scheme-1 numbering")
end

print("\n=== a short TOC is identical under both schemes ===")
do
    local ui = freshUi("/books/short-scheme.epub")
    local a = BookText:getChapterList(ui, 1)
    BookText._cache = nil
    local b = BookText:getChapterList(ui, 2)
    check(#a == N and #b == N, "12 entries, no grouping under either scheme")
end

print("\n=== nested TOC depth groups at the parent ===")
do
    local toc = {}
    local n = 0
    -- 5 parents × 25 children = 130 entries, above MAX_CHAPTERS.
    for p = 1, 5 do
        n = n + 1
        toc[n] = { title = "P" .. p, xpointer = "xp" .. n, depth = 1 }
        for c = 1, 25 do
            n = n + 1
            toc[n] = { title = "P" .. p .. "c" .. c, xpointer = "xp" .. n, depth = 2 }
        end
    end
    local doc = { file = "/books/nested.epub",
                  info = { has_pages = false, doc_height = 1000 }, _at = "start" }
    function doc:getXPointer() return self._at end
    function doc:gotoXPointer(xp) self._at = xp end
    function doc:gotoPos(p) self._at = "pos" .. tostring(p) end
    function doc:getToc() return toc end
    function doc:getTextFromXPointers()
        return ("Nested body. "):rep(60)
    end
    BookText._cache = nil
    local ui = { document = doc }
    local list, _, how = BookText:getChapterList(ui, 2)
    check(#list == 5, "scheme 2 keeps 5 depth-1 chapters (got " .. #list .. ")")
    check(how == "depth", "how=depth (got " .. tostring(how) .. ")")
end

print("\n=== the chapter-list cache is per scheme ===")
do
    BookText._cache = nil
    local ui = { document = (function()
        local toc = {}
        for i = 1, 126 do
            toc[i] = {
                title = "E" .. i,
                xpointer = string.format("/body/DocFragment[%d]/p[%d]",
                                        math.ceil(i / 10), i),
            }
        end
        local doc = { file = "/books/cache-scheme.epub",
                      info = { has_pages = false, doc_height = 1000 }, _at = "start" }
        function doc:getXPointer() return self._at end
        function doc:gotoXPointer(xp) self._at = xp end
        function doc:gotoPos(p) self._at = "pos" .. tostring(p) end
        function doc:getToc() return toc end
        return doc
    end)() }
    local a = BookText:getChapterList(ui, 1)
    local b = BookText:getChapterList(ui, 2)
    check(#a == 63 and #b == 13,
          "same ui, both schemes cached separately (got "
          .. #a .. " and " .. #b .. ")")
end

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
