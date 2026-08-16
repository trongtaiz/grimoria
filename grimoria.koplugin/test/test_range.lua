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

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
