--[[
Merge the multiturn replies into ONE analysis, through the shipped pipeline.

  usage: lua incremental_merge.lua <plugin_dir> <turns_dir> <out.lua>

Each turn_NN.lua in <turns_dir> is one chapter's reply (converted from JSON by
json_to_lua.py). This folds them, in chapter order, into a single analysis of
the same shape a whole-book reply has, then runs the SHIPPED
validateAndCleanData and SpoilerGuard on the merged whole -- the same two
passes the parent runs before saveCache -- and writes the result as a Lua
literal that test_spoiler.lua and test_filter.lua accept exactly as they
accept a whole-book reply.

This file is the seed of a future lib/incremental.lua: the merge rules here
are the ones the device would need, so they are written against the shipped
data shapes rather than anything harness-specific.

Merge rules, and why each is what it is:

  * chapters: replace-by-index. A turn is the authority on its own chapter;
    a re-run of turn k supersedes the earlier reply for k and nothing else.
  * characters: upsert by EXACT name -- names are identities in this design,
    so "merge similar names" would be fusing identities without a reveal.
    A returning character contributes new by_chapter entries and any newly
    tagged role/gender/occupation/alias values; their first_chapter and intro
    stay from the turn that introduced them (the earliest knowledge, which is
    the only intro that cannot know too much).
  * identity_merges: append, deduplicated on the sorted name set -- the
    chapter recorded is the FIRST turn that made the connection.
  * locations / historical figures: upsert by name, union the tagged lists.
  * themes: append, deduplicated on the theme text.
  * timeline: dropped if any turn emitted one flat -- validateAndCleanData
    rebuilds it from chapters[].events, which is the one source that is
    per-chapter by construction.

Deduplication of tagged values is (value, first_chapter) exact: the same
value re-tagged LATER is kept, because "Student @1" and "Student @9" are two
different claims and resolveTagged needs at most one of them.
]]

local plugin_dir, turns_dir, out_path = ...
if not (plugin_dir and turns_dir and out_path) then
    print("usage: lua incremental_merge.lua <plugin_dir> <turns_dir> <out.lua>")
    os.exit(2)
end
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("socket", {}); stub("socketutil", {})
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })
stub("libs/libkoreader-lfs", { attributes = function() return nil end })

local LLM = require("lib/llm")
LLM.current_language = "en"
LLM:loadPrompts()
local SpoilerGuard = require("lib/spoilerguard")

-- ------------------------------------------------------------- load turns ----

-- Portable directory listing without lfs: turn files are numbered, so probe.
local turns = {}
for k = 1, 200 do
    local path = string.format("%s/turn_%02d.lua", turns_dir, k)
    local fn = loadfile(path)
    if fn then
        local ok, reply = pcall(fn)
        if ok and type(reply) == "table" then
            turns[#turns + 1] = { chapter = k, reply = reply }
        else
            print("WARN: " .. path .. " did not evaluate; skipped")
        end
    end
end
if #turns == 0 then
    print("no turn_NN.lua files in " .. turns_dir)
    os.exit(2)
end
print(#turns .. " turn(s) loaded from " .. turns_dir)

-- ------------------------------------------------------------------ merge ----

local merged = {
    book_title = "", author = "", author_bio = "", book_language = "",
    chapters = {}, characters = {}, identity_merges = {},
    locations = {}, themes = {}, historical_figures = {},
}

local chapter_at = {}     -- index -> position in merged.chapters
local char_at = {}        -- name  -> position in merged.characters
local loc_at, fig_at = {}, {}
local merge_seen, theme_seen = {}, {}

local function taggedKey(item)
    if type(item) == "table" then
        return tostring(item.value) .. "@" .. tostring(item.first_chapter)
    end
    return tostring(item) .. "@?"
end

-- Union src's tagged list into dst's, (value, chapter)-exact.
local function unionTagged(dst, src)
    if type(src) ~= "table" then return dst end
    dst = type(dst) == "table" and dst or {}
    local seen = {}
    for _, item in ipairs(dst) do seen[taggedKey(item)] = true end
    for _, item in ipairs(src) do
        local key = taggedKey(item)
        if not seen[key] then
            seen[key] = true
            dst[#dst + 1] = item
        end
    end
    return dst
end

local function aliasKey(a)
    if type(a) == "table" then return tostring(a.alias) end
    return tostring(a)
end

for _, t in ipairs(turns) do
    local r = t.reply

    -- Book meta: first non-empty answer wins; every turn sees the same book.
    if merged.book_title == "" and type(r.book_title) == "string" then
        merged.book_title = r.book_title
    end
    if merged.author == "" and type(r.author) == "string" then
        merged.author = r.author
    end
    if merged.author_bio == "" and type(r.author_bio) == "string" then
        merged.author_bio = r.author_bio
    end
    if merged.book_language == "" and type(r.book_language) == "string" then
        merged.book_language = r.book_language
    end

    for _, ch in ipairs(r.chapters or {}) do
        local idx = tonumber(ch.index)
        if idx then
            local at = chapter_at[idx]
            if at then
                merged.chapters[at] = ch
            else
                merged.chapters[#merged.chapters + 1] = ch
                chapter_at[idx] = #merged.chapters
            end
        end
    end

    for _, c in ipairs(r.characters or {}) do
        if type(c) == "table" and type(c.name) == "string" and #c.name > 0 then
            local at = char_at[c.name]
            if not at then
                merged.characters[#merged.characters + 1] = c
                char_at[c.name] = #merged.characters
            else
                local dst = merged.characters[at]
                dst.role = unionTagged(dst.role, c.role)
                dst.gender = unionTagged(dst.gender, c.gender)
                dst.occupation = unionTagged(dst.occupation, c.occupation)
                -- intro/first_chapter stay from the introducing turn: that
                -- intro was written knowing the least, which is the only
                -- kind that cannot know too much.
                local seen = {}
                dst.aliases = type(dst.aliases) == "table" and dst.aliases or {}
                for _, a in ipairs(dst.aliases) do seen[aliasKey(a)] = true end
                for _, a in ipairs(c.aliases or {}) do
                    if not seen[aliasKey(a)] then
                        seen[aliasKey(a)] = true
                        dst.aliases[#dst.aliases + 1] = a
                    end
                end
                dst.by_chapter = type(dst.by_chapter) == "table" and dst.by_chapter or {}
                for _, bc in ipairs(c.by_chapter or {}) do
                    dst.by_chapter[#dst.by_chapter + 1] = bc
                end
            end
        end
    end

    for _, m in ipairs(r.identity_merges or {}) do
        if type(m) == "table" and type(m.names) == "table" then
            local names = {}
            for _, n in ipairs(m.names) do names[#names + 1] = tostring(n) end
            table.sort(names)
            local key = table.concat(names, "\0")
            if not merge_seen[key] then
                merge_seen[key] = true
                merged.identity_merges[#merged.identity_merges + 1] = m
            end
        end
    end

    for _, l in ipairs(r.locations or {}) do
        if type(l) == "table" and type(l.name) == "string" and #l.name > 0 then
            local at = loc_at[l.name]
            if not at then
                merged.locations[#merged.locations + 1] = l
                loc_at[l.name] = #merged.locations
            else
                local dst = merged.locations[at]
                dst.description = unionTagged(dst.description, l.description)
                dst.importance = unionTagged(dst.importance, l.importance)
            end
        end
    end

    for _, th in ipairs(r.themes or {}) do
        local body = type(th) == "table" and th.theme or th
        if type(body) == "string" and #body > 0 and not theme_seen[body] then
            theme_seen[body] = true
            merged.themes[#merged.themes + 1] = th
        end
    end

    for _, h in ipairs(r.historical_figures or {}) do
        if type(h) == "table" and type(h.name) == "string" and #h.name > 0 then
            local at = fig_at[h.name]
            if not at then
                merged.historical_figures[#merged.historical_figures + 1] = h
                fig_at[h.name] = #merged.historical_figures
            else
                local dst = merged.historical_figures[at]
                dst.role = unionTagged(dst.role, h.role)
                dst.importance_in_book = unionTagged(dst.importance_in_book, h.importance_in_book)
                dst.context_in_book = unionTagged(dst.context_in_book, h.context_in_book)
            end
        end
    end
end

table.sort(merged.chapters, function(a, b)
    return (tonumber(a.index) or 0) < (tonumber(b.index) or 0)
end)

-- ------------------------------------- the shipped pipeline, then serialise ----

local cleaned = LLM:validateAndCleanData(merged)
local guarded, retagged = SpoilerGuard.scan(cleaned)
print(string.format("merged: %d chapters, %d characters, %d merges, %d locations"
      .. " -- guard re-tagged %d field(s)",
      #guarded.chapters, #guarded.characters, #guarded.identity_merges,
      #guarded.locations, retagged))

local function lit(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return tostring(v) end
    if t == "string" then
        -- %q escapes a newline as backslash-newline, which is valid Lua but
        -- unreadable; rewrite it as \n. gsub returns a second value, and a
        -- bare `return x:gsub(...)` would leak it into the caller's argument
        -- list, so the parentheses are load-bearing.
        return (string.format("%q", v):gsub("\\\n", "\\n"))
    end
    if t == "table" then
        local inner, pad = {}, indent .. "  "
        if #v > 0 then
            for _, item in ipairs(v) do
                inner[#inner + 1] = pad .. lit(item, pad)
            end
        else
            for k2, item in pairs(v) do
                inner[#inner + 1] = string.format("%s[%q] = %s", pad, tostring(k2),
                                                  lit(item, pad))
            end
        end
        if #inner == 0 then return "{}" end
        return "{\n" .. table.concat(inner, ",\n") .. "\n" .. indent .. "}"
    end
    error("cannot serialise a " .. t)
end

local f = assert(io.open(out_path, "w"))
f:write("-- merged multiturn analysis; written by incremental_merge.lua\n")
f:write("return " .. lit(guarded) .. "\n")
f:close()
print("written: " .. out_path)
