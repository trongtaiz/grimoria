--[[
The governing rule, asserted directly, at every chapter of the book.

test_filter.lua checks that ONE known reveal is handled correctly. That is
worth having, but it is a test of a case somebody thought of, and every leak
found in this plugin so far was a case nobody thought of: a static `occupation`
showing a job taken in chapter 47, a summary falling back to the whole book,
untagged data defaulting to chapter 1, a merge importing a field from a
character not yet met. Each was invisible to a test that looked at one reveal.

So this suite asserts the property instead:

    AT CHAPTER k, NO VISIBLE FIELD OF ANY KIND MAY CONTAIN THE NAME OF AN
    ENTITY THE READER HAS NOT MET, AND NO VALUE TAGGED LATER THAN k MAY
    APPEAR AT ALL.

It sweeps k from 1 to the last chapter, over every character, location, theme,
timeline entry and historical figure, on whatever reply it is given. A model
that behaves badly cannot make it pass, which is the point -- the design is
that the filter is safe even when the model is not.

  usage: lua test_spoiler.lua <plugin_dir> [reply_lua_file]

Without a reply it runs the synthetic fixtures only, which is what a fresh
clone can do: the real replies are derived from a copyrighted novel and live
in the gitignored private/fixtures/.

WHAT THIS DOES NOT COVER, said out loud rather than implied:

  * A SEMANTIC leak with no name in it -- a chapter summary that foreshadows
    in the abstract, a theme phrased as a hint. Nothing here can detect that;
    it is reduced to prompt wording and the per-chapter binding, not solved.
  * An analysis with NO chapters at all. There is nothing to filter against,
    so everything shows, deliberately. The sweep cannot run on one either.
]]

local plugin_dir, reply_file = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(name, tbl) package.loaded[name] = tbl end

stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end,
                              attributes = function() return nil end,
                              dir = function() return function() return nil end end })
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })

local WidgetContainer = {}
function WidgetContainer:new(o)
    o = o or {}; setmetatable(o, self); self.__index = self; return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)

-- Drives applyChapterFilter's idea of where the reader is. `chapter = false`
-- makes it return nil, which is how a real resolution FAILURE looks.
local FakeExtractor = { chapter = 1 }
function FakeExtractor:getCurrentChapterIndex()
    if self.chapter == false then return nil end
    return self.chapter
end
stub("lib/booktext", FakeExtractor)

local LLM = require("lib/llm")
LLM.current_language = "en"
LLM:loadPrompts()

local Spoilers = require("lib/spoilers")
local plugin = setmetatable({ loc = { t = function(_, k) return k end } },
                            { __index = Spoilers })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

--[[
Put the reader where they have FINISHED chapter n.

The extractor reports the chapter the reader is INSIDE, and the filter shows
only chapters they have finished -- so having read through chapter n means
standing in chapter n+1. Spelling that out here rather than writing `n + 1` at
thirty call sites is what keeps each assertion readable as the claim it makes.
]]
local function readThrough(n) FakeExtractor.chapter = n + 1 end

-- --------------------------------------------------------------- helpers ----

--[[
Case only, deliberately NOT diacritics.

Folding Vietnamese diacritics looks obviously right and is obviously wrong:
"Văn" (literature), "Vấn" (to ask) and "Van" (a name) are three different
words, and folding makes them one. Measured -- a folded matcher reported a leak
against every character introduced as a "sinh viên khoa Văn", a LITERATURE
student, on the strength of a character named Van. lib/spoilerguard.lua
explains this at length and test/validate.py had already recorded it.

Written out here rather than calling the shipped SpoilerGuard.mentions on
purpose: a test that checks the code using the code agrees with it even when
both are wrong, and this suite's whole job is to be an independent opinion.
]]
local function fold(s)
    return tostring(s or ""):lower()
end

--[[
Does `haystack` contain `needle` as a whole word?

Word-boundary matching is what makes this usable rather than a noise
generator. Without it "Van" matches inside "Vantage" and every check fails on
prose that never mentioned the character. The boundary is "not an ASCII letter
or digit".
]]
local function mentions(haystack, needle)
    local h, n = fold(haystack), fold(needle)
    if #n < 2 then return false end          -- one-letter names match everything
    local from = 1
    while true do
        local s, e = h:find(n, from, true)
        if not s then return false end
        local before = s > 1 and h:sub(s - 1, s - 1) or " "
        local after = e < #h and h:sub(e + 1, e + 1) or " "
        if not before:match("[%w]") and not after:match("[%w]") then return true end
        from = s + 1
    end
end

--[[
Every string a view could render for one item -- split by whether it is bound
to a chapter, because the two carry different guarantees and conflating them
produces false alarms that make the whole suite worth ignoring.

  UNBOUND text describes the entity as a whole: an intro, a role, an
  occupation, a theme, a location's description. Nothing about it says which
  part of the book it is true of, so naming an entity the reader has not met
  is a leak, full stop.

  BOUND text describes one chapter, and is only shown once the reader has
  reached that chapter -- a by_chapter entry, a chapter summary, a timeline
  event. It is safe with respect to plain names BY CONSTRUCTION: if chapter 12
  says "they plan to go to Ajimu tomorrow", a reader at chapter 12 has read
  that sentence, and hiding it would be hiding the book from itself. (This is
  not hypothetical -- it is exactly what the first run of this sweep flagged,
  against a location the model tagged with the chapter they ARRIVE rather than
  the chapter it is first named.)

Bound text is still checked against identity merges, because there the secret
is not the name but the CONNECTION: naming Morisu inside Van's chapter-12
entry gives away the ending even though the reader has read chapter 12.
]]
local function visibleStrings(item, kind)
    local unbound, bound = {}, {}
    local function add(into, field, v)
        if type(v) == "string" and #v > 0 then
            into[#into + 1] = { field = kind .. "." .. field, text = v }
        end
    end
    add(unbound, "role", item.role)
    add(unbound, "gender", item.gender)
    add(unbound, "occupation", item.occupation)
    add(unbound, "intro", item.intro)
    add(unbound, "importance", item.importance)
    add(unbound, "theme", item.theme)
    add(unbound, "importance_in_book", item.importance_in_book)
    add(unbound, "context_in_book", item.context_in_book)
    for _, a in ipairs(item.aliases or {}) do add(unbound, "alias", a) end
    -- A location's description has no chapter of its own either.
    if kind == "location" then add(unbound, "description", item.description) end

    if kind ~= "location" then add(bound, "description", item.description) end
    add(bound, "event", item.event)
    add(bound, "revelation", item.revelation)
    return unbound, bound
end

-- ------------------------------------------------------------- the sweep ----

--[[
The whole property, run over one analysis at one chapter.

`unmet` is every name the reader has not earned yet: characters introduced
later, locations and figures tagged later, and -- the case the whole design
exists for -- every member name of an identity merge whose reveal has not
happened. That last one is why a merge is not simply "two names for one
person": before the reveal, printing either name inside the other's card is
the spoiler.
]]
--[[
`k` is the chapter the reader is INSIDE, so what they have finished is
1..k-1 -- which is what the filter uses and therefore what "unmet" is measured
against. Passing k straight through as the content limit would make this suite
agree with a bug it is meant to catch: that the plugin used to show chapter
12's contents to somebody two paragraphs into chapter 12.
]]
local function sweepAt(data, k, label)
    plugin.book_data = data
    plugin.show_whole_book = false
    FakeExtractor.chapter = k
    plugin:applyChapterFilter()
    k = plugin.filter_chapter or 0

    --[[
    Names the reader has not earned.

    `unmet` is entities that do not exist yet as far as the reader knows.

    Identity merges are NOT in it, and that distinction took a run of this
    sweep to get right. The members of a merge are usually all met early --
    Van appears in chapter 1, the anonymous figure in chapter 2 -- so their
    names are not secret at all and flagging every mention of them produced
    hundreds of false alarms. What is secret is the CONNECTION, so the merge
    check is a different shape entirely: a member's own card must not name a
    sibling member before the reveal (`siblings`, below), and the merged
    display name -- which spells the connection out -- must not appear at all.
    ]]
    local unmet = {}
    for _, c in ipairs(data.characters or {}) do
        if (tonumber(c.first_chapter) or 1) > k and type(c.name) == "string" then
            unmet[c.name] = "character introduced at ch " .. tostring(c.first_chapter)
        end
    end
    for _, l in ipairs(data.locations or {}) do
        if (tonumber(l.first_chapter) or 1) > k and type(l.name) == "string" then
            unmet[l.name] = "location from ch " .. tostring(l.first_chapter)
        end
    end

    -- member name -> { sibling names still secret at k }, plus merged names.
    local siblings, merged_names = {}, {}
    for _, m in ipairs(data.identity_merges or {}) do
        if (tonumber(m.chapter) or 1) > k then
            for _, n in ipairs(m.names or {}) do
                siblings[n] = siblings[n] or {}
                for _, other in ipairs(m.names or {}) do
                    if other ~= n then
                        siblings[n][other] = "revealed at ch " .. tostring(m.chapter)
                    end
                end
            end
            if type(m.merged_name) == "string" and #m.merged_name > 0 then
                merged_names[m.merged_name] = "merged name, revealed at ch " .. tostring(m.chapter)
            end
        end
    end

    -- A name the reader HAS met cannot be a leak even if some other entity
    -- shares the string, so met names win over unmet ones.
    for _, c in ipairs(data.characters or {}) do
        if (tonumber(c.first_chapter) or 1) <= k then unmet[c.name] = nil end
    end

    local problems = {}
    local function report(s, item, name, why)
        problems[#problems + 1] = string.format("ch%d %s (%s) mentions %q -- %s",
            k, s.field, tostring(item.name), name, why)
    end

    local function scan(list, kind)
        for _, item in ipairs(list or {}) do
            local unbound, bound = visibleStrings(item, kind)
            local mine = siblings[item.name]

            for _, s in ipairs(unbound) do
                for name, why in pairs(unmet) do
                    -- An entity's own name inside its own card is not a leak;
                    -- it is only visible at all because the filter let it be.
                    if item.name ~= name and mentions(s.text, name) then
                        report(s, item, name, why)
                    end
                end
            end

            -- Both kinds of text, bound or not: this card belongs to one
            -- identity of a person the book has not unmasked yet, so naming
            -- another of that person's identities anywhere on it is the leak
            -- the whole fusing mechanism exists to prevent.
            for _, group in ipairs({ unbound, bound }) do
                for _, s in ipairs(group) do
                    if mine then
                        for other, why in pairs(mine) do
                            if mentions(s.text, other) then report(s, item, other, why) end
                        end
                    end
                    for name, why in pairs(merged_names) do
                        if mentions(s.text, name) then report(s, item, name, why) end
                    end
                end
            end
        end

        -- A card under the merged display name must not exist at all yet:
        -- "Morisu Kyoichi (Van)" IS the reveal, written out.
        for _, item in ipairs(list or {}) do
            for name, why in pairs(merged_names) do
                if item.name == name then
                    problems[#problems + 1] = string.format(
                        "ch%d a %s card is already named %q -- %s", k, kind, name, why)
                end
            end
        end
    end

    scan(plugin.characters, "character")
    scan(plugin.locations, "location")
    scan(plugin.themes, "theme")
    scan(plugin.timeline, "event")
    scan(plugin.historical_figures, "figure")

    -- Structural, no string matching: a card may not advertise a reveal that
    -- has not happened.
    for _, c in ipairs(plugin.characters or {}) do
        if c.merge_chapter and c.merge_chapter > k then
            problems[#problems + 1] = string.format(
                "ch%d %s carries merge_chapter %d", k, tostring(c.name), c.merge_chapter)
        end
        if type(c.revelation) == "string" and #c.revelation > 0 and not c.merge_chapter then
            problems[#problems + 1] = string.format(
                "ch%d %s carries revelation text with no merge", k, tostring(c.name))
        end
    end

    -- The summary is the chapters already read, so only the merged name --
    -- the connection spelled out -- can be a leak in it.
    for name, why in pairs(merged_names) do
        if plugin.summary and mentions(plugin.summary, name) then
            problems[#problems + 1] = string.format("ch%d summary mentions %q -- %s", k, name, why)
        end
    end
    return problems
end

local function sweepAll(data, label)
    local last = 1
    for _, ch in ipairs(data.chapters or {}) do
        last = math.max(last, tonumber(ch.index) or 1)
    end
    -- last + 1 so the final chapter is swept as "finished" too, which is the
    -- position a reader reaches on the last page.
    local all = {}
    for k = 1, last + 1 do
        for _, p in ipairs(sweepAt(data, k, label)) do all[#all + 1] = p end
    end
    -- The raw pass is reported, not asserted: a model writing a leak into its
    -- prose is a fact about the model, and the guard below is the answer to
    -- it. Only the guarded pass has to come back clean.
    if label:find("structure only") then
        print("  ----  " .. label .. ": " .. last .. " chapters swept, "
              .. #all .. " leak(s) written by the model")
    else
        check(#all == 0, label .. ": " .. last .. " chapters swept, " .. #all .. " leak(s)")
    end
    for i = 1, math.min(#all, 8) do print("           " .. all[i]) end
    if #all > 8 then print("           ... and " .. (#all - 8) .. " more") end
    return #all
end

-- --------------------------------------------------- the other direction ----

--[[
DELIVERY: the filter must also SHOW what the reader has earned.

Everything above asserts one half of the property -- that nothing unearned
reaches the screen -- and that half is satisfied perfectly by a filter that
shows nothing at all. An empty field passes every leak check trivially, so the
suite was structurally blind to the failure that actually shipped: `intro` is
a plain string, `resolveTagged` reads a plain string as end-of-book, and every
character's opening sentence was blanked for every reader who had not finished
the book. Measured on the saved reply -- 14 of 14 intros written by the model,
0 of 14 displayed at ANY chapter. Eleven green suites saw none of it.

So this sweep asserts the converse, and it is the assertion that has to exist
for "fails closed" to mean a filter rather than a wall:

  at chapter k, a visible card must carry the text its source supplied for
  chapters the reader has already finished.

Concretely, per visible character card:
  * a met source with a non-empty intro  =>  the card's intro is non-empty
  * n source developments at or before k =>  at least n chapter lines in the
    rebuilt description

Cards whose source cannot be identified are skipped and counted rather than
failed: fusion unions merge groups, so a display name need not appear in any
single merge entry, and a test that guesses wrong there would fail on a
correct filter. The count is printed so the skip can never grow silently into
"nothing was actually checked".
]]
local function sourcesFor(data, card)
    local out = {}
    for _, c in ipairs(data.characters or {}) do
        if c.name == card.name then out[#out + 1] = c end
    end
    if #out > 0 then return out end

    -- A fused card is displayed under merged_name; its members are the names
    -- of whichever merge produced that display name.
    for _, m in ipairs(data.identity_merges or {}) do
        if m.merged_name == card.name then
            for _, n in ipairs(m.names or {}) do
                for _, c in ipairs(data.characters or {}) do
                    if c.name == n then out[#out + 1] = c end
                end
            end
        end
    end
    return out
end

local function deliversAt(data, k)
    plugin.book_data = data
    plugin.show_whole_book = false
    plugin._include_current_chapter = false
    plugin.filter_chapter = nil
    readThrough(k)
    plugin:applyChapterFilter()

    local problems, skipped = {}, 0
    for _, card in ipairs(plugin.characters or {}) do
        local sources = sourcesFor(data, card)
        if #sources == 0 then
            skipped = skipped + 1
        else
            local want_intro, want_devs = false, 0
            for _, c in ipairs(sources) do
                local met = (tonumber(c.first_chapter) or math.huge) <= k
                if met and type(c.intro) == "string" and #c.intro > 0 then
                    want_intro = true
                end
                if met then
                    for _, bc in ipairs(c.by_chapter or {}) do
                        if (tonumber(bc.chapter) or math.huge) <= k
                            and type(bc.development) == "string" and #bc.development > 0 then
                            want_devs = want_devs + 1
                        end
                    end
                end
            end

            if want_intro and #card.intro == 0 then
                problems[#problems + 1] = string.format(
                    "ch%d %s: the analysis has an intro for this character and the card shows none",
                    k, tostring(card.name))
            end

            local shown = 0
            for _ in tostring(card.description):gmatch("%[%d+%]") do shown = shown + 1 end
            if shown < want_devs then
                problems[#problems + 1] = string.format(
                    "ch%d %s: %d development(s) earned by chapter %d, %d on the card",
                    k, tostring(card.name), want_devs, k, shown)
            end
        end
    end
    return problems, skipped
end

local function deliversAll(data, label)
    local last = 1
    for _, ch in ipairs(data.chapters or {}) do
        last = math.max(last, tonumber(ch.index) or 1)
    end
    local all, skipped = {}, 0
    for k = 1, last do
        local p, s = deliversAt(data, k)
        for _, one in ipairs(p) do all[#all + 1] = one end
        skipped = skipped + s
    end
    check(#all == 0, label .. ": " .. last .. " chapters swept, "
          .. #all .. " piece(s) of earned text withheld"
          .. (skipped > 0 and (" [" .. skipped .. " unidentifiable card(s) skipped]") or ""))
    for i = 1, math.min(#all, 8) do print("           " .. all[i]) end
    if #all > 8 then print("           ... and " .. (#all - 8) .. " more") end
    return #all
end

print("\n=== the filter delivers what the reader has earned (synthetic) ===")
do
    --[[
    The shape of the shipped bug, in miniature: a plain-string intro and
    developments spread across a book long enough that the reader is nowhere
    near the end. Before the fix this fails at every chapter from 1 to 19.
    ]]
    local chapters = {}
    for i = 1, 20 do
        chapters[i] = { index = i, title = "Chapter " .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData({
        book_title = "T", author = "A", chapters = chapters,
        characters = {
            { name = "Mai", first_chapter = 1,
              intro = "A first-year student who arrives by ferry.",
              role = { { value = "Protagonist", first_chapter = 1 } },
              by_chapter = {
                  { chapter = 2, development = "Mai explores the lighthouse." },
                  { chapter = 4, development = "Mai argues with the caretaker." },
                  { chapter = 15, development = "Mai finds the letter." },
              } },
            { name = "Bao", first_chapter = 3, intro = "The harbour master.",
              by_chapter = { { chapter = 3, development = "Bao refuses to sail." } } },
        },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    })
    deliversAll(data, "a plain-string intro reaches the card")
end

-- ------------------------------------------- fixture: the reported bug ----

--[[
The bug as it was reported: a character whose occupation changes late in the
book showed the LATER job from the moment they appeared.

Small and synthetic on purpose. A regression test for a specific reported
failure should be readable at a glance, and this one is the difference between
"Student" and "Prison Warden" at chapter 46.
]]
print("=== the reported bug: an occupation from the future ===")
do
    local raw = {
        book_title = "T", author = "A",
        chapters = {},
        characters = {
            {
                name = "Mai", first_chapter = 1,
                intro = "A quiet student at the academy.",
                role = { { value = "Supporting", first_chapter = 1 },
                         { value = "Antagonist", first_chapter = 47 } },
                occupation = { { value = "Student", first_chapter = 1 },
                               { value = "Prison Warden", first_chapter = 47 } },
                gender = { { value = "Female", first_chapter = 1 } },
                by_chapter = { { chapter = 1, development = "Arrives at the academy." } },
            },
        },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    }
    for i = 1, 50 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "S" .. i, events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    plugin.show_whole_book = false

    readThrough(46)
    plugin:applyChapterFilter()
    local at46 = plugin.characters[1]
    check(at46.occupation == "Student", "ch46 shows the occupation held then (got: "
          .. tostring(at46.occupation) .. ")")
    check(at46.role == "Supporting", "ch46 shows the role held then (got: "
          .. tostring(at46.role) .. ")")

    readThrough(47)
    plugin:applyChapterFilter()
    local at47 = plugin.characters[1]
    check(at47.occupation == "Prison Warden", "ch47 shows the new occupation (got: "
          .. tostring(at47.occupation) .. ")")
    check(at47.role == "Antagonist", "ch47 shows the new role")

    -- The views concatenate these directly, so a list reaching them is a
    -- crash on one card and raw JSON printed on another.
    check(type(at46.role) == "string" and type(at46.gender) == "string"
          and type(at46.occupation) == "string",
          "every field the views print is a plain string, not a tagged list")

    plugin.show_whole_book = true
    plugin:applyChapterFilter()
    check(plugin.characters[1].occupation == "Prison Warden",
          "whole-book view resolves to the final value")
    check(type(plugin.characters[1].role) == "string",
          "whole-book view also yields plain strings")
    plugin.show_whole_book = false
end

-- ------------------------------------------------- fixture: fail closed ----

print("\n=== untagged data is end-of-book, not chapter 1 ===")
do
    local raw = {
        book_title = "T", author = "A",
        chapters = {},
        -- Not one first_chapter anywhere: a model that ignored the field.
        characters = { { name = "Ghost", intro = "Someone.", role = "Antagonist",
                         occupation = "Executioner", by_chapter = {} } },
        locations = { { name = "The Vault", description = "Where it ends." } },
        themes = { "Revenge, and who took it" },
        historical_figures = { { name = "Napoleon", biography = "A general.",
                                 context_in_book = "Quoted at the climax." } },
        timeline = { { event = "The last confrontation", importance = "Ends it" } },
        identity_merges = {},
    }
    for i = 1, 20 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    readThrough(1)
    plugin:applyChapterFilter()
    check(#plugin.characters == 0, "an untagged character is hidden at ch1")
    check(#plugin.locations == 0, "an untagged location is hidden at ch1")
    check(#plugin.themes == 0, "a legacy string theme is hidden at ch1")
    check(#plugin.historical_figures == 0, "an untagged historical figure is hidden at ch1")
    check(#plugin.timeline == 0, "an untagged timeline event is hidden at ch1")
    check(plugin.summary == "", "no chapter summary yet means NO summary, not the whole book")

    readThrough(20)
    plugin:applyChapterFilter()
    check(#plugin.characters == 1, "...and shown once the reader reaches the end")
    check(#plugin.themes == 1, "...as is the theme")
    check(#plugin.historical_figures == 1, "...and the figure")
    check(#plugin.timeline == 1, "...and the event")
end

print("\n=== the summary never falls back to the whole book ===")
do
    local raw = { book_title = "T", author = "A", chapters = {},
                  characters = {}, locations = {}, themes = {},
                  historical_figures = {}, identity_merges = {} }
    -- Early chapters have no summary; late ones do, and name the culprit.
    for i = 1, 10 do
        raw.chapters[i] = { index = i, title = "C" .. i,
                            summary = i >= 8 and "Bao is unmasked as the killer." or "",
                            events = {} }
    end
    local data = LLM:validateAndCleanData(raw)
    check(#(data.summary or "") > 0, "the whole-book summary exists in the analysis")

    plugin.book_data = data
    readThrough(3)
    plugin:applyChapterFilter()
    check(plugin.summary == "", "at ch3 the reader gets nothing, not data.summary")
    readThrough(9)
    plugin:applyChapterFilter()
    check(plugin.summary:find("Bao") ~= nil, "at ch9 the summaries read so far are shown")
end

print("\n=== a merge does not import from a member not yet met ===")
do
    local raw = {
        book_title = "T", author = "A", chapters = {},
        characters = {
            { name = "The stranger", first_chapter = 1, intro = "A figure in a coat.",
              occupation = { { value = "Unknown", first_chapter = 1 } }, by_chapter = {} },
            { name = "Bao", first_chapter = 30, intro = "The harbour master.",
              occupation = { { value = "Harbour Master", first_chapter = 30 } }, by_chapter = {} },
        },
        identity_merges = { { names = { "The stranger", "Bao" }, chapter = 5,
                              merged_name = "The stranger (Bao)", true_role = "Antagonist",
                              revelation = "They are the same person." } },
        locations = {}, themes = {}, historical_figures = {},
    }
    for i = 1, 40 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    FakeExtractor.chapter = 10          -- merge has landed, Bao has not appeared
    plugin:applyChapterFilter()
    local card = plugin.characters[1]
    check(card ~= nil, "the fused card exists at ch10")
    if card then
        check(card.occupation ~= "Harbour Master",
              "it does NOT carry the occupation of a member not yet met (got: "
              .. tostring(card.occupation) .. ")")
    end

    readThrough(30)
    plugin:applyChapterFilter()
    check(plugin.characters[1].occupation == "Harbour Master",
          "...and does once that member has appeared")
end

--[[
The chapter being read is not a chapter that has been read.

Reported from use: the reader is two paragraphs into chapter 12, opens a
character, and is told what that character does in chapter 12. The position
KOReader reports is "the chapter you are in", and the filter treated it as
"the chapter you have finished".
]]
print("\n=== the chapter you are reading is not shown ===")
do
    local raw = {
        book_title = "T", author = "A", chapters = {},
        characters = { { name = "Mai", first_chapter = 1, intro = "A student.",
                         by_chapter = {
                             { chapter = 11, development = "Boards the ferry." },
                             { chapter = 12, development = "Is revealed to have lied." },
                         } } },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    }
    for i = 1, 20 do
        raw.chapters[i] = { index = i, title = "C" .. i,
                            summary = "Chapter " .. i .. " summary.", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    plugin._include_current_chapter = nil    -- unset: the safe default
    plugin.show_whole_book = false
    FakeExtractor.chapter = 12
    plugin:applyChapterFilter()

    local card = plugin.characters[1]
    check(not card.description:find("lied", 1, true),
          "mid-chapter-12, chapter 12's development is NOT shown")
    check(card.description:find("ferry", 1, true) ~= nil,
          "...while chapter 11's still is")
    check(not plugin.summary:find("Chapter 12 summary", 1, true),
          "chapter 12's summary is not shown while it is being read")
    check(plugin.summary:find("Chapter 11 summary", 1, true) ~= nil,
          "...and chapter 11's is")

    FakeExtractor.chapter = 13
    plugin:applyChapterFilter()
    check(plugin.characters[1].description:find("lied", 1, true) ~= nil,
          "once the reader moves to chapter 13, chapter 12 appears")

    -- Chapter 1: there is nothing finished yet, and saying so is correct.
    FakeExtractor.chapter = 1
    plugin:applyChapterFilter()
    check(#plugin.characters == 0, "on chapter 1 nothing is shown yet (the honest answer)")
    check(plugin.filter_chapter == 0, "the reported scope is 0 chapters read")

    -- The escape hatch restores the old behaviour for a reader who wants it.
    plugin._include_current_chapter = true
    FakeExtractor.chapter = 12
    plugin:applyChapterFilter()
    check(plugin.characters[1].description:find("lied", 1, true) ~= nil,
          "include_current_chapter.txt brings the current chapter back")
    plugin._include_current_chapter = nil
end

--[[
lib/spoilerguard, on the leak only it can catch.

The structural layers cannot see this one: the entry belongs to chapter 12, the
reader has read chapter 12, so the filter is right to show it -- and it names
the other half of an identity the book does not reveal until chapter 30. The
leak is in the prose, which is the entire reason Layer 3 exists.

Synthetic rather than taken from a saved reply, and that is the point. The real
replies contain no such leak (the one this suite originally reported turned out
to be a diacritic-folding artifact: "nghi vấn", meaning "suspicion", folded to
the character name "Van"). Without this fixture the guard would be shipping
untested, its value assumed from a false positive.
]]
print("\n=== the guard catches a leak the structure cannot ===")
do
    local function build()
        local raw = {
            book_title = "T", author = "A", chapters = {},
            characters = {
                { name = "The stranger", first_chapter = 1, intro = "A figure in a coat.",
                  by_chapter = {
                      { chapter = 12, development = "Meets Bao at the harbour and they argue." },
                  } },
                { name = "Bao", first_chapter = 2, intro = "The harbour master.",
                  by_chapter = { { chapter = 2, development = "Opens the harbour office." } } },
            },
            identity_merges = { { names = { "The stranger", "Bao" }, chapter = 30,
                                  merged_name = "Bao (The stranger)", true_role = "Antagonist",
                                  revelation = "They are the same person." } },
            locations = {}, themes = {}, historical_figures = {},
        }
        for i = 1, 40 do
            raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
        end
        return LLM:validateAndCleanData(raw)
    end

    local before = sweepAt(build(), 14, "raw")
    check(#before > 0, "the sweep sees the leak before the guard runs ("
          .. #before .. " found)")

    local SpoilerGuard = require("lib/spoilerguard")
    local guarded, n = SpoilerGuard.scan(build())
    check(n >= 1, "the guard re-tags at least one field (" .. n .. ")")
    check(#sweepAt(guarded, 14, "guarded") == 0, "and the leak is gone at ch14")

    -- Held back, not deleted: the sentence must reappear at the reveal.
    plugin.book_data = guarded
    readThrough(30)
    plugin:applyChapterFilter()
    local shown = false
    for _, c in ipairs(plugin.characters) do
        if c.description and c.description:find("harbour and they argue", 1, true) then
            shown = true
        end
    end
    check(shown, "the held-back sentence reappears once the reveal has landed")
end

--[[
Aliases, which are a new field and therefore a new way to leak.

An alias has no reveal chapter attached -- it is printed next to the character's
name from its own first_chapter onward -- so the one thing that must never end
up in the list is the true name behind a disguise. The prompt says so at length
and that is not the guarantee: prompt rules have failed twice in this plugin's
history, once when five of six models named the murderer inside a theme.

So the shape is checked structurally, and both directions matter. An alias that
names another identity of the same person must wait for the merge; an ordinary
nickname must NOT be delayed, or the feature is a spoiler filter that deleted
the feature.
]]
print("\n=== an alias cannot smuggle in a hidden identity ===")
do
    local function build()
        local raw = {
            book_title = "T", author = "A", chapters = {},
            characters = {
                { name = "Van", first_chapter = 1, intro = "A student on the island.",
                  -- One legitimate nickname, and one that is the whole twist.
                  aliases = { { alias = "Van-kun", first_chapter = 3 },
                              { alias = "Morisu Kyoichi", first_chapter = 1 } },
                  by_chapter = {} },
                { name = "Morisu Kyoichi", first_chapter = 12,
                  intro = "A man living alone on the mainland.", by_chapter = {} },
            },
            identity_merges = { { names = { "Van", "Morisu Kyoichi" }, chapter = 47,
                                  merged_name = "Van (Morisu Kyoichi)",
                                  true_role = "Antagonist",
                                  revelation = "They are the same person." } },
            locations = {}, themes = {}, historical_figures = {},
        }
        for i = 1, 50 do
            raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
        end
        return LLM:validateAndCleanData(raw)
    end

    local plain = build()
    check(#plain.characters[1].aliases == 2,
          "validateAndCleanData keeps aliases at all (they used to be dropped)")
    check(plain.characters[1].aliases[1].alias ~= nil,
          "and in the {alias=, first_chapter=} shape the filter reads")

    -- Idempotent, because Archive:normalise runs this on every cache load.
    local twice = LLM:validateAndCleanData(plain)
    check(#twice.characters[1].aliases == 2, "a second validation pass does not duplicate them")

    local before = sweepAt(build(), 21, "raw")
    check(#before > 0, "the sweep sees the smuggled name before the guard runs ("
          .. #before .. " found)")

    local SpoilerGuard = require("lib/spoilerguard")
    local guarded = SpoilerGuard.scan(build())
    check(#sweepAt(guarded, 21, "guarded") == 0, "the guard closes it at ch20")

    plugin.book_data = guarded
    readThrough(20)
    plugin:applyChapterFilter()
    local card = plugin.characters[1]
    check(card ~= nil and card.name == "Van", "Van's card is still there at ch20")
    if card then
        local shown = table.concat(card.aliases or {}, ",")
        check(shown:find("Van%-kun") ~= nil,
              "the ordinary nickname is NOT collateral damage (got: " .. shown .. ")")
        check(not shown:find("Morisu", 1, true),
              "the true name is not on the card yet (got: " .. shown .. ")")
    end

    -- Held back, not deleted -- same contract as every other guard action.
    readThrough(47)
    plugin:applyChapterFilter()
    local fused = plugin.characters[1]
    check(fused ~= nil and (fused.merge_chapter ~= nil),
          "at ch47 the cards are fused")
    if fused then
        check(table.concat(fused.aliases or {}, ","):find("Morisu", 1, true) ~= nil,
              "and the name the guard held back is finally shown")
    end
end

--[[
The highlight lookup, which is a question a reader can ask repeatedly.

Every other view shows what the filter produced. This one takes input, and that
makes it the one place where a reader could interrogate the analysis: highlight
a name in chapter three, and if a card comes back, that name matters later. So
what it searches has to be the filtered view and nothing else -- which is a
property worth asserting rather than trusting to the applyChapterFilter() call
at the top of the function staying there.
]]
print("\n=== the highlight lookup answers only about people already met ===")
do
    local Lookup = require("lib/ui/lookup")
    for name, fn in pairs(Lookup) do plugin[name] = fn end

    local raw = {
        book_title = "T", author = "A", chapters = {},
        characters = {
            { name = "Mai", first_chapter = 1, intro = "A student.",
              aliases = { { alias = "Linh", first_chapter = 8 } }, by_chapter = {} },
            { name = "Bao", first_chapter = 30, intro = "The harbour master.",
              by_chapter = {} },
        },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    }
    for i = 1, 40 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    plugin.book_data = LLM:validateAndCleanData(raw)
    plugin.show_whole_book = false

    readThrough(5)
    plugin:applyChapterFilter()
    local hits = plugin:matchCharactersInSelection("Mai turned to Bao and said nothing.")
    check(#hits == 1 and hits[1].name == "Mai",
          "at ch5 a sentence naming both returns only the one already met (" ..
          #hits .. " hit(s))")

    check(#plugin:matchCharactersInSelection("Maiden voyage") == 0,
          "a name inside a longer word is not a match")
    check(#plugin:matchCharactersInSelection("Linh nodded.") == 0,
          "an alias tagged to a later chapter is not searchable yet")

    readThrough(8)
    plugin:applyChapterFilter()
    local by_alias = plugin:matchCharactersInSelection("Linh nodded.")
    check(#by_alias == 1 and by_alias[1].name == "Mai",
          "...and is once the reader has met that spelling")

    readThrough(30)
    plugin:applyChapterFilter()
    check(#plugin:matchCharactersInSelection("Mai turned to Bao and said nothing.") == 2,
          "at ch30 both come back")

    -- One character, several matching spellings, still one result: a picker
    -- offering the same person twice is worse than no picker.
    check(#plugin:matchCharactersInSelection("Mai, who everyone calls Linh") == 1,
          "two spellings of one person are one hit")
end

print("\n=== a failed chapter lookup does not open the whole book ===")
do
    local raw = { book_title = "T", author = "A", chapters = {},
                  characters = { { name = "Late", first_chapter = 40, intro = "x",
                                   by_chapter = {} } },
                  locations = {}, themes = {}, historical_figures = {},
                  identity_merges = {} }
    for i = 1, 40 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    plugin.filter_chapter = nil
    FakeExtractor.chapter = false        -- getCurrentChapterIndex returns nil
    plugin:applyChapterFilter()
    check(#plugin.characters == 0,
          "a resolution failure with no prior position filters at ch1, not whole book")

    readThrough(5)
    plugin:applyChapterFilter()
    FakeExtractor.chapter = false
    plugin:applyChapterFilter()
    check(plugin.filter_chapter == 5, "a later failure falls back to the last known position")
end

print("\n=== a legacy-shaped cache leaks nothing ===")
do
    --[[
    What a pre-versioning grimoria_cache.lua / xray_cache.lua actually holds:
    a whole-book `description` per character, no intro, no by_chapter, no
    first_chapter, and themes as plain strings. Until this change none of it
    was re-validated on load, so the description went straight to the screen.
    ]]
    local raw = {
        book_title = "T", author = "A",
        chapters = {},
        characters = {
            { name = "Mai",
              description = "A student who is revealed in chapter 47 to be the killer, "
                         .. "and who kills Bao at the lighthouse.",
              role = "Antagonist", occupation = "Prison Warden" },
        },
        locations = { { name = "Lighthouse", description = "Where Bao dies." } },
        themes = { "The student was the killer all along" },
        historical_figures = {},
        identity_merges = {},
    }
    for i = 1, 50 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)

    plugin.book_data = data
    readThrough(1)
    plugin:applyChapterFilter()

    check(#plugin.characters == 0, "an untagged legacy character is hidden at ch1")

    -- Force the character visible to prove the description itself is rebuilt
    -- rather than inherited -- the exact path the whole-book description used.
    data.characters[1].first_chapter = 1
    plugin:applyChapterFilter()
    local card = plugin.characters[1]
    check(card ~= nil, "the character is shown once it is tagged as early")
    if card then
        check(not card.description:find("killer", 1, true),
              "its description is REBUILT, never the whole-book one (got: "
              .. tostring(card.description) .. ")")
        check(card.occupation == "", "an untagged occupation is still hidden at ch1")
        check(card.role == "", "an untagged role is still hidden at ch1")
    end
    check(#plugin.themes == 0, "the legacy string theme stays hidden at ch1")
end

print("\n=== an unknown field cannot reach the view ===")
do
    local raw = {
        book_title = "T", author = "A", chapters = {},
        characters = { { name = "Mai", first_chapter = 1, intro = "A student.",
                         by_chapter = {},
                         -- A field a future schema might add, or a model might
                         -- invent. It must not appear on screen by default.
                         secret_fate = "Dies in the last chapter." } },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    }
    for i = 1, 10 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local data = LLM:validateAndCleanData(raw)
    check(data.characters[1].secret_fate == nil,
          "validateAndCleanData drops a field it was not taught")

    -- And again with the field forced past validation, straight into the
    -- filter: the whitelist is the second, independent gate.
    data.characters[1].secret_fate = "Dies in the last chapter."
    plugin.book_data = data
    readThrough(1)
    plugin:applyChapterFilter()
    check(plugin.characters[1].secret_fate == nil,
          "the filter's whitelist drops it too")
end

print("\n=== validation is idempotent (it now runs on every cache load) ===")
do
    local raw = {
        book_title = "T", author = "A", chapters = {},
        characters = { { name = "Mai", first_chapter = 1, intro = "A student.",
                         occupation = "Student", by_chapter = {} } },
        locations = {}, themes = {}, historical_figures = {}, identity_merges = {},
    }
    for i = 1, 10 do
        raw.chapters[i] = { index = i, title = "C" .. i, summary = "", events = {} }
    end
    local once = LLM:validateAndCleanData(raw)
    local first = once.characters[1].occupation
    check(type(first) == "table" and #first == 1, "a string is wrapped once")

    local twice = LLM:validateAndCleanData(once)
    local second = twice.characters[1].occupation
    check(type(second) == "table" and #second == 1,
          "a second pass does not wrap it again (got " ..
          tostring(type(second) == "table" and #second or "?") .. " entries)")
    check(second[1].value == "Student", "and the value survives intact")

    local thrice = LLM:validateAndCleanData(twice)
    check(#thrice.characters[1].occupation == 1, "nor does a third")
end

--[[
Rule 5: a name is earned when the book prints it or an alias.

Synthetic book text only -- no quotations from any novel. The markers are
the same shape lib/booktext.lua emits. scan() without book_text must keep
doing what it did yesterday.
]]
print("\n=== a card cannot appear before the book prints its name or an alias ===")
do
    local SpoilerGuard = require("lib/spoilerguard")
    local book = table.concat({
        "=== CHAPTER 1: One ===\nA student named Mai opens the door.\n",
        "=== CHAPTER 2: Two ===\nThe harbour master waves from the pier.\n",
        "=== CHAPTER 9: Nine ===\nOnly here does the text print Bao Van.\n",
    }, "")

    local function tagged(name, at)
        return LLM:validateAndCleanData({
            book_title = "T", author = "A",
            chapters = {
                { index = 1, title = "One", summary = "", events = {} },
                { index = 2, title = "Two", summary = "", events = {} },
                { index = 9, title = "Nine", summary = "", events = {} },
            },
            characters = { { name = name, first_chapter = at, intro = "Someone.",
                             by_chapter = {} } },
            locations = {}, themes = {}, historical_figures = {},
            identity_merges = {},
        })
    end

    local early = tagged("Bao Van", 2)
    local guarded, n = SpoilerGuard.scan(early, book)
    check(n >= 1, "a name tagged before it is printed is pushed (" .. n .. ")")
    check(guarded.characters[1].first_chapter == 9,
          "Bao Van moves 2 -> 9 (got " .. tostring(guarded.characters[1].first_chapter) .. ")")

    local again, n2 = SpoilerGuard.scan(guarded, book)
    check(n2 == 0 and again.characters[1].first_chapter == 9,
          "a second pass is a no-op")

    local ok = tagged("Mai", 1)
    local g2, n3 = SpoilerGuard.scan(ok, book)
    check(n3 == 0 and g2.characters[1].first_chapter == 1,
          "a name printed in chapter 1 is left alone")

    local ghost = tagged("the figure in the coat", 1)
    local g3, n4 = SpoilerGuard.scan(ghost, book)
    check(n4 == 0 and g3.characters[1].first_chapter == 1,
          "a descriptor that never occurs in the text is NOT buried at end-of-book")

    local no_text = tagged("Bao Van", 2)
    local g4, n5 = SpoilerGuard.scan(no_text)
    check(n5 == 0 and g4.characters[1].first_chapter == 2,
          "without book_text, rule 5 does not run (cache-load shape)")

    -- Given name vs full name is an alias, not a disguise. A card named
    -- with the rare full form must not wait until that string is printed
    -- if the book has already been using the given name.
    local named = LLM:validateAndCleanData({
        book_title = "T", author = "A",
        chapters = {
            { index = 1, title = "One", summary = "", events = {} },
            { index = 2, title = "Two", summary = "", events = {} },
            { index = 9, title = "Nine", summary = "", events = {} },
        },
        characters = {
            { name = "Bao Van", first_chapter = 1, intro = "Someone.",
              aliases = { { alias = "Bao", first_chapter = 1 } },
              by_chapter = {} },
        },
        locations = {}, themes = {}, historical_figures = {},
        identity_merges = {},
    })
    -- Book prints "Bao" in ch1 ("A student named Mai" has no Bao). Give the
    -- extract a given-name hit in chapter 1 and the full name in chapter 9.
    local book_alias = table.concat({
        "=== CHAPTER 1: One ===\nBao opens the door.\n",
        "=== CHAPTER 2: Two ===\nThe harbour master waves from the pier.\n",
        "=== CHAPTER 9: Nine ===\nOnly here does the text print Bao Van.\n",
    }, "")
    local g5, n6 = SpoilerGuard.scan(named, book_alias)
    check(n6 == 0 and g5.characters[1].first_chapter == 1,
          "an earlier alias keeps the card (got ch "
          .. tostring(g5.characters[1].first_chapter) .. ", moved " .. n6 .. ")")

    local no_alias = tagged("Bao Van", 1)
    local g6, n7 = SpoilerGuard.scan(no_alias, book_alias)
    check(n7 >= 1 and g6.characters[1].first_chapter == 9,
          "without that alias the full name still waits for ch9 (got "
          .. tostring(g6.characters[1].first_chapter) .. ")")
end

print("\n=== rule 5 on the reported cache, if the fixture is present ===")
do
    -- plugin_dir is the plugin folder; private/ sits next to it at the repo root.
    local cache_path = plugin_dir .. "/../private/fixtures/"
        .. "grimoria_cache_1786908838_google-gemini-3-7-flash.lua"
    local epub_path = plugin_dir .. "/../private/fixtures/"
        .. "Đầu Voi - Bản dịch mới v2.epub"
    local extract = plugin_dir .. "/test/extract_epub.py"
    local tmp = os.tmpname()
    local have_cache = io.open(cache_path, "r")
    local have_epub = io.open(epub_path, "r")
    if have_cache then have_cache:close() end
    if have_epub then have_epub:close() end
    if not have_cache or not have_epub then
        print("  SKIP  reported cache or epub not in private/fixtures/")
    else
        -- Pair-bucketing (scheme 1) matches this cache's 32 chapters.
        -- This cache was numbered under the old ceiling of 60 (32 pairs).
        local cmd = string.format('python3 %q %q %q --scheme 1 --max-chapters 60',
                                  extract, epub_path, tmp)
        local ok_py = os.execute(cmd)
        local fh = io.open(tmp, "r")
        local book = fh and fh:read("*a") or ""
        if fh then fh:close() end
        os.remove(tmp)
        -- os.execute returns true/256-ish depending on Lua; treat empty extract as skip.
        if type(book) ~= "string" or #book < 1000 then
            print("  SKIP  extract_epub.py did not produce text (got "
                  .. tostring(ok_py) .. ", " .. tostring(book and #book) .. " chars)")
        else
            local chunk = assert(loadfile(cache_path))
            local data = chunk()
            local function fc(name)
                for _, c in ipairs(data.characters or {}) do
                    if c.name == name then return tonumber(c.first_chapter) end
                end
            end
            local haru_before, izumi_before = fc("Kagami Haru"), fc("Izumi Saki")
            local SpoilerGuard = require("lib/spoilerguard")
            SpoilerGuard.scan(data, book)
            local haru, izumi = fc("Kagami Haru"), fc("Izumi Saki")
            check(haru_before == 7 and haru == 9,
                  "Kagami Haru 7 -> 9 (was " .. tostring(haru_before)
                  .. ", now " .. tostring(haru) .. ")")
            check(izumi_before == 2 and izumi == 4,
                  "Izumi Saki 2 -> 4 (was " .. tostring(izumi_before)
                  .. ", now " .. tostring(izumi) .. ")")
            local pushed, untouched, buried = 0, 0, 0
            local last = 1
            for _, ch in ipairs(data.chapters or {}) do
                last = math.max(last, tonumber(ch.index) or 1)
            end
            -- Re-load originals to count.
            local orig = assert(loadfile(cache_path))()
            local orig_at = {}
            for _, c in ipairs(orig.characters or {}) do
                orig_at[c.name] = tonumber(c.first_chapter)
            end
            for _, c in ipairs(data.characters or {}) do
                local a, b = orig_at[c.name], tonumber(c.first_chapter)
                if a and b and b > a then
                    pushed = pushed + 1
                    if b >= last then buried = buried + 1 end
                else
                    untouched = untouched + 1
                end
            end
            check(untouched == 17, "17 of 22 cards untouched (got " .. untouched .. ")")
            check(pushed == 5, "5 cards pushed later (got " .. pushed .. ")")
            check(buried == 0, "nothing pushed to end-of-book (got " .. buried .. ")")
        end
    end
end

-- ---------------------------------------------------------- the real reply --

if reply_file then
    --[[
    The real thing, twice: once as the model wrote it, once after the guard.

    Running the raw pass first is deliberate. If the guard is ever the only
    reason this suite passes, that has to be visible -- "0 leaks" on guarded
    data says nothing about whether the structural layers are doing any work,
    and a guard that silently became the whole defence is exactly the kind of
    drift a test should surface rather than absorb.
    ]]
    local chunk = assert(loadfile(reply_file))

    print("\n=== every chapter of the saved reply, AS THE MODEL WROTE IT ===")
    local raw_leaks = sweepAll(LLM:validateAndCleanData(chunk()), "structure only")

    print("\n=== the same reply, after lib/spoilerguard ===")
    local SpoilerGuard = require("lib/spoilerguard")
    local guarded, retagged = SpoilerGuard.scan(LLM:validateAndCleanData(chunk()))
    print("           guard re-tagged " .. retagged .. " field(s)")
    local kept = sweepAll(guarded, "structure + guard")

    check(kept <= raw_leaks,
          "the guard never makes things worse (" .. raw_leaks .. " -> " .. kept .. ")")

    --[[
    The guard is a net, not a substitute.

    Reported at any size, asserted only at a size that cannot be legitimate.
    A book with several identity merges and prose that names siblings freely
    can legitimately trip the guard many times, so a tight threshold would turn
    a working guard into a red suite on the next book. What must never happen
    is the guard quietly hiding a large share of the analysis -- that is how
    "0 leaks" gets bought by hiding the book, and it is what the 15% is for.
    ]]
    local fields = 0
    for _, c in ipairs(guarded.characters or {}) do
        fields = fields + 3 + #(c.by_chapter or {})
    end
    print(string.format("           guard held back %d of ~%d fields (%.1f%%)",
          retagged, fields, fields > 0 and (retagged / fields * 100) or 0))
    check(retagged <= math.max(8, math.floor(fields * 0.15)),
          "the guard is a net, not a blanket")

    -- And the converse, on the real analysis: every sentence the reader has
    -- earned actually reaches the screen. This is the pass that catches a
    -- filter deleting content, which no leak sweep can see.
    print("\n=== the same reply: does the filter deliver? ===")
    deliversAll(guarded, "the saved reply, after the guard")
else
    print("\n=== every chapter of the saved reply ===")
    print("  SKIP  no reply given -- pass one from private/fixtures/ to run the sweep")
end

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
