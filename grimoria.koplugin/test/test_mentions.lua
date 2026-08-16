--[[
Chapter appearances: the counting, the boundary, and the reading position.

Three things this has to get right, and each of them is invisible when wrong:

  * COUNTING A PERSON, NOT A STRING. "Ellery Queen said. Ellery nodded." is two
    mentions of one man, not three -- "Ellery" is inside "Ellery Queen". Naive
    per-spelling counting inflates every character whose full name is used, and
    inflates them by different amounts, so the bar chart is wrong in a way that
    still looks like a bar chart.

  * THE BOUNDARY. The scan must stop at the reader's position. "Appears 40
    times in chapter 50" says the character is alive in chapter 50, which on a
    mystery is the answer to the book. There must be no count past the limit --
    not hidden, not present.

  * THE READING POSITION. Building the chapter list moves the document. A
    plugin that leaves the reader on page one after drawing a chart has done
    something far worse than not drawing it.

Runs with no book and no key: the document is a stub, so a fresh clone can run
this one.

  usage: lua test_mentions.lua <plugin_dir>
]]

local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("util", { fixUtf8 = function(s) return s end })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

-- ------------------------------------------------------------- the stubs ----

local CHAPTERS = {
    { title = "One",   body = "Ellery Queen said nothing. Ellery nodded once." },
    { title = "Two",   body = "Mai walked. A maiden passed. Van arrived; Văn is a subject." },
    { title = "Three", body = "Ellery Queen. ELLERY QUEEN. ellery queen." },
    { title = "Four",  body = "Mai and Ellery, together at last." },
    { title = "Five",  body = "Bao appears only here, in the ending." },
}

local doc = {
    file = "/books/test.epub",
    info = { has_pages = false },
    _position = "SAVED",
    _moved_to = nil,
}
function doc:getXPointer() return self._position end
function doc:gotoXPointer(xp) self._moved_to = xp end
function doc:getTextFromXPointers(a, _b) return CHAPTERS[tonumber(a)].body end

local list_calls = 0
local FakeBookText = {}
function FakeBookText:getChapterList()
    -- Standing in for the real one, which MOVES THE DOCUMENT to find the
    -- book's bounds. That is the whole reason the scan has to restore.
    list_calls = list_calls + 1
    doc._position = "MOVED-BY-CHAPTER-LIST"
    local out = {}
    for i, ch in ipairs(CHAPTERS) do
        out[i] = { title = ch.title, xp_start = tostring(i), xp_end = tostring(i) }
    end
    return out
end
stub("lib/booktext", FakeBookText)

local Mentions = require("lib/mentions")
local ui = { document = doc }

-- ------------------------------------------------------------ the counting --

print("=== one person, however many names ===")
do
    local text = CHAPTERS[1].body:lower()
    check(Mentions:countUnion(text, { "Ellery Queen" }) == 1, "the full name once")
    check(Mentions:countUnion(text, { "Ellery" }) == 2, "the short name twice")
    --[[
    The point of the whole function: counting both spellings separately gives
    3, because the "Ellery" inside "Ellery Queen" is matched a second time.
    Merging the spans first gives 2 -- the number of places in the sentence
    where this man is named, which is what a reader is asking.
    ]]
    check(Mentions:countUnion(text, { "Ellery Queen", "Ellery" }) == 2,
          "both together are still 2, not 3 (got " ..
          Mentions:countUnion(text, { "Ellery Queen", "Ellery" }) .. ")")
    check(Mentions:countUnion(text, { "Ellery", "Ellery Queen" }) == 2,
          "and the order the spellings are listed in makes no difference")
end

print("\n=== matching rules ===")
do
    local text = CHAPTERS[2].body:lower()
    check(Mentions:countUnion(text, { "Mai" }) == 1,
          "a name inside a longer word does not count (\"maiden\")")
    --[[
    Not diacritic-folded, and this is the case that decided it. In Vietnamese
    "Văn" (literature) and "Van" (a name) are different words; a folding
    matcher counted every literature student as an appearance of Van, and
    lib/spoilerguard.lua carries the full account.
    ]]
    check(Mentions:countUnion(text, { "Van" }) == 1,
          "\"Văn\" is not an appearance of \"Van\" (got " ..
          Mentions:countUnion(text, { "Van" }) .. ")")
    check(Mentions:countUnion(CHAPTERS[3].body:lower(), { "ellery queen" }) == 3,
          "case is ignored")
    check(Mentions:countUnion(text, { "Ma" }) == 0,
          "a spelling under three characters is refused, not matched everywhere")
end

-- --------------------------------------------------------- the whole scan --

print("\n=== the scan stops where the reader is ===")
do
    local chars = {
        { name = "Ellery Queen", aliases = { "Ellery" } },
        { name = "Mai" },
        { name = "Bao" },
    }

    local seen = {}
    local rows = Mentions:scan(ui, chars, 3, function(done, total)
        seen[#seen + 1] = done .. "/" .. total
        return true
    end)

    check(rows ~= nil and #rows == 3,
          "3 chapters scanned when the reader has finished 3 (got " ..
          tostring(rows and #rows) .. ")")
    check(table.concat(seen, " ") == "1/3 2/3 3/3", "progress is reported per chapter")

    check(rows[1].counts[1] == 2, "chapter 1: Ellery Queen counted as one person, twice")
    check(rows[3].counts[1] == 3, "chapter 3: three mentions")
    check(rows[2].counts[2] == 1, "chapter 2: Mai once")

    --[[
    Bao appears ONLY in chapter 5. If any count for him existed anywhere in
    this result, the reader could tell there is a chapter 5 he is in -- which is
    exactly the fact this feature refuses to compute.
    ]]
    local bao = 0
    for _, row in ipairs(rows) do bao = bao + (row.counts[3] or 0) end
    check(bao == 0, "a character who only appears past the boundary has no counts at all")
    check(rows[3] ~= nil and rows[4] == nil, "and there is no row for chapter 4 or 5")
end

print("\n=== the reader's position survives ===")
do
    doc._position = "WHERE-THE-READER-WAS"
    doc._moved_to = nil
    Mentions:scan(ui, { { name = "Mai" } }, 5, nil)
    check(list_calls > 0, "the chapter list was built (which is what moves the document)")
    check(doc._moved_to == "WHERE-THE-READER-WAS",
          "the position is restored afterwards (got " .. tostring(doc._moved_to) .. ")")
end

print("\n=== a scan can be called off ===")
do
    local rows, err = Mentions:scan(ui, { { name = "Mai" } }, 5, function(done)
        return done < 2        -- the reader dismissed the message
    end)
    check(rows == nil and err == "cancelled",
          "dismissing the progress message aborts rather than finishing quietly")
end

print("\n=== nothing to scan is not a failure ===")
do
    local rows = Mentions:scan(ui, { { name = "Mai" } }, 0, nil)
    check(type(rows) == "table" and #rows == 0,
          "a reader who has finished nothing gets an empty scan, not an error")
end

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
