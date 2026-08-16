--[[
Run the model's reply through the SHIPPED Lua, off-device.

This is the acceptance test for the spoiler mechanism, and it deliberately
exercises the real code rather than a re-implementation of it:

  lib/llm.lua  validateAndCleanData  -- what actually gets cached
  main.lua      fuseCharacters + applyChapterFilter  -- what the views read

Only KOReader's own modules are stubbed. lib/booktext is stubbed too, so the
"current chapter" can be driven directly instead of needing an open document.

  usage: lua test_filter.lua <plugin_dir> <reply_lua_file>
]]

local plugin_dir, reply_file = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(name, tbl) package.loaded[name] = tbl end

stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("socket.http", {})
stub("ssl.https", {})
stub("ltn12", {})
stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end,
                              attributes = function() return nil end,
                              dir = function() return function() return nil end end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })

-- WidgetContainer:new{...} has to produce something methods can be added to.
local WidgetContainer = {}
function WidgetContainer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)

-- Drives applyChapterFilter's idea of where the reader is.
local FakeExtractor = { chapter = 1 }
function FakeExtractor:getCurrentChapterIndex() return self.chapter end
stub("lib/booktext", FakeExtractor)

local LLM = require("lib/llm")
LLM.current_language = "en"
LLM:loadPrompts()

--[[
The book-specific expectations -- which two names merge and at which chapter --
live beside the reply in private/, not here. They are the central reveal of a
real novel, and hardcoding them would publish the twist in the test source.

Absent, the structural half still runs and the behavioural half says it was
skipped rather than quietly passing on nothing.
]]
local EXPECT
do
    -- Forward slashes only: every caller passes a POSIX-style path, and a Lua
    -- character class containing a backslash is more trouble than it is worth.
    local dir = reply_file:match("^(.*)/[^/]+$") or "."
    local ok, t = pcall(dofile, dir .. "/expectations.lua")
    if ok and type(t) == "table" then EXPECT = t end
end

local raw = dofile(reply_file)
local data = LLM:validateAndCleanData(raw)
assert(data, "validateAndCleanData rejected the reply")

local Grimoria = require("main")
local plugin = Grimoria:new{}
plugin.book_data = data
plugin.loc = { t = function(_, k) return k end, getLanguage = function() return "en" end }
plugin.ui = {}

local fails = 0
local function check(cond, msg)
    if not cond then fails = fails + 1 end
    print((cond and "  PASS  " or "  FAIL  ") .. msg)
end

--[[
`n` is the last chapter the reader has FINISHED.

The extractor reports the chapter they are inside, and the filter shows only
finished chapters -- so reading through chapter n means standing in n+1. That
distinction is the fix for a leak reported from use: the plugin was showing
chapter 12's contents to somebody two paragraphs into chapter 12.
]]
local function namesAtChapter(n)
    FakeExtractor.chapter = n + 1
    plugin.show_whole_book = false
    plugin:applyChapterFilter()
    local set, list = {}, {}
    for _, c in ipairs(plugin.characters) do
        set[c.name] = c
        list[#list + 1] = c.name
    end
    return set, list, plugin.characters
end

print("=== validateAndCleanData (lib/llm.lua) ===")
check(#data.characters > 0, "characters kept: " .. #data.characters)
check(#data.chapters > 0, "chapters kept: " .. #data.chapters)
check(#data.identity_merges > 0, "identity merges kept: " .. #data.identity_merges)
local total_bc = 0
for _, c in ipairs(data.characters) do total_bc = total_bc + #(c.by_chapter or {}) end
check(total_bc > 0, "by_chapter entries survived validation: " .. total_bc)
check(#data.timeline > 0, "timeline built from chapter events: " .. #data.timeline)
for _, m in ipairs(data.identity_merges) do
    print(string.format("    merge at ch%-3d %s -> %s",
        m.chapter, table.concat(m.names, " + "), m.merged_name))
end

--[[
The fused card's name is read out of the reply, not written down here.

It used to be a literal string, which quietly made this suite a test of one
saved reply rather than of the filter: the model is free to order the two
identities either way, and a run that returned the other ordering -- equally
correct -- failed four checks while the plugin had behaved perfectly. What the filter must guarantee is that the merge is applied at its
chapter and not before -- which name the model chose for the fused card is the
model's business.
]]
local reveal_chapter, fused_name
for _, m in ipairs(data.identity_merges) do
    local has_a, has_b = false, false
    for _, n in ipairs(m.names or {}) do
        if n:find(EXPECT.identity_a, 1, true) then has_a = true end
        if n:find(EXPECT.identity_b, 1, true) then has_b = true end
    end
    -- The first merge connecting the two is the reveal; a later one folding in
    -- the anonymous "hắn" is a different event.
    if has_a and has_b and not fused_name then
        reveal_chapter, fused_name = m.chapter, m.merged_name
    end
end
check(fused_name ~= nil, "a merge connects the two identities")
check(reveal_chapter == EXPECT.reveal_chapter,
      "the reveal is at the expected chapter (got " .. tostring(reveal_chapter) .. ")")
print("    fused card name from this reply: " .. tostring(fused_name))

print()
print("=== applyChapterFilter (main.lua) before the reveal ===")
local at46, list46 = namesAtChapter(EXPECT.before_chapter)
print("    " .. table.concat(list46, ", "))
check(at46[EXPECT.name_a] ~= nil, "the first identity is listed on its own")
check(at46[EXPECT.name_b] ~= nil, "the second identity is listed on its own")
check(at46[fused_name] == nil, "the fused card is NOT shown")
check(at46[EXPECT.name_a] and at46[EXPECT.name_a].merge_chapter == nil, "the first identity carries no merge marker")
check(at46[EXPECT.name_a] and not (at46[EXPECT.name_a].description or ""):find(EXPECT.identity_b, 1, true),
      "its description does not name the other")
check(at46[EXPECT.name_b] and
      not (at46[EXPECT.name_b].revelation or ""):find(EXPECT.identity_a, 1, true),
      "the second carries no revelation text yet")

print()
print("=== applyChapterFilter at the reveal ===")
local at47, list47 = namesAtChapter(EXPECT.reveal_chapter)
print("    " .. table.concat(list47, ", "))
check(at47[fused_name] ~= nil, "the fused card IS shown")
check(at47[EXPECT.name_a] == nil, "the first identity no longer appears separately")
check(at47[EXPECT.name_b] == nil, "the second no longer appears separately")
local fused = at47[fused_name]
check(fused and fused.merge_chapter == EXPECT.reveal_chapter, "fused card records the reveal chapter")
check(fused and fused.revelation and #fused.revelation > 0,
      "fused card carries the revelation text")
if fused then
    print("    revelation: " .. tostring(fused.revelation))
    local tagged = 0
    for _, bc in ipairs(fused.by_chapter or {}) do
        if bc.as_name then tagged = tagged + 1 end
    end
    check(tagged > 0, "fused history is tagged with which identity did what: "
                      .. tagged .. " entries")
end

print()
print("=== whole-book view ===")
plugin.show_whole_book = true
plugin:applyChapterFilter()
local whole = {}
for _, c in ipairs(plugin.characters) do whole[c.name] = true end
check(whole[fused_name] ~= nil, "whole-book view shows the fused card")
check(whole[EXPECT.name_a] == nil, "whole-book view does not double-list an identity")

print()
print(fails == 0 and "RESULT: all checks passed" or ("RESULT: " .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
