--[[
The interface language, end to end, against the shipped i18n.lua.

Worth its own suite because the failure it guards is silent. `setLanguage`
refuses any code that `discoverLanguages` did not find, and falls back to
English with nothing but a logger.warn -- so a language whose .po is missing,
misnamed or unparseable shows up as a button that does nothing at all when
tapped. Reading the code cannot tell you the .po actually parses.

  usage: lua test_localization.lua <plugin_dir>
]]
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })

--[[
Pure Lua cannot list a directory, and stubbing lfs with a hardcoded answer
would test the stub rather than the code. The Python runner injects __listdir;
under a plain `lua` binary we fall back to probing every language code this
plugin has ever shipped, which catches both a missing vi.po and an es.po that
came back from the dead.
]]
local EVER_SHIPPED = { "en", "vi", "es", "pt_br", "tr", "de", "fr" }
local function listdir(path)
    if __listdir then return __listdir(path) end
    local found = {}
    for _, code in ipairs(EVER_SHIPPED) do
        local f = io.open(path .. "/" .. code .. ".po", "r")
        if f then f:close(); table.insert(found, code .. ".po") end
    end
    return found
end

stub("libs/libkoreader-lfs", {
    mkdir = function() return true end,
    attributes = function(path)
        -- Only ever asked about the languages directory.
        local probe = io.open(path .. "/en.po", "r")
        if not probe then return nil end
        probe:close()
        return { mode = "directory" }
    end,
    dir = function(path)
        local names, i = listdir(path), 0
        return function() i = i + 1; return names[i] end
    end,
})

-- setLanguage reaches into lib/llm to re-read the prompt language. Stubbed:
-- this suite is about the interface strings.
stub("lib/llm", { loadLanguage = function() end })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

local Loc = require("lib/i18n")
-- The module hardcodes KOReader's runtime path; point it at the real folder.
Loc.plugin_dir = plugin_dir

print("=== discovery ===")
Loc:discoverLanguages()
local found = table.concat(Loc.available_languages, ",")
check(found == "en,vi", "exactly en and vi are discovered (got: " .. found .. ")")
check(Loc:languageExists("en"), "English exists")
check(Loc:languageExists("vi"), "Vietnamese exists")
check(not Loc:languageExists("tr"), "Turkish is gone")
check(not Loc:languageExists("es"), "Spanish is gone")
check(not Loc:languageExists("pt_br"), "Portuguese is gone")

print("\n=== switching to Vietnamese ===")
check(Loc:setLanguage("vi") == true, "setLanguage('vi') is accepted")
check(Loc:getLanguage() == "vi", "the language sticks")
-- A parsed .po, not the raw key and not the English fallback table.
local chars = Loc:t("menu_characters")
check(chars == "Nhân vật", "a menu string is Vietnamese (got: " .. tostring(chars) .. ")")
check(Loc:t("menu_timeline") == "Dòng thời gian", "multi-word strings survive parsing")
check(Loc:t("confirm_analyze") == "Phân tích", "newer keys are translated too")

print("\n=== a rejected language cannot change anything ===")
check(Loc:setLanguage("tr") == false, "setLanguage('tr') is refused")
check(Loc:getLanguage() == "vi", "a refused switch leaves the language alone")

print("\n=== both files carry the same keys ===")
local en = Loc:parsePO(plugin_dir .. "/languages/en.po")
local vi = Loc:parsePO(plugin_dir .. "/languages/vi.po")
check(en ~= nil and vi ~= nil, "both .po files parse")

local missing_vi, missing_en, empty = {}, {}, {}
for k, v in pairs(en) do
    if vi[k] == nil then table.insert(missing_vi, k) end
    if v == "" then table.insert(empty, "en:" .. k) end
end
for k, v in pairs(vi) do
    if en[k] == nil then table.insert(missing_en, k) end
    if v == "" then table.insert(empty, "vi:" .. k) end
end
check(#missing_vi == 0, "every English key exists in Vietnamese (" ..
      (#missing_vi > 0 and table.concat(missing_vi, ", ") or "none missing") .. ")")
check(#missing_en == 0, "every Vietnamese key exists in English (" ..
      (#missing_en > 0 and table.concat(missing_en, ", ") or "none missing") .. ")")
check(#empty == 0, "no key is present but empty -- t() would fall back silently (" ..
      (#empty > 0 and table.concat(empty, ", ") or "none") .. ")")

--[[
The one that bites at runtime rather than in review: t() passes the string
straight to string.format, so if English says "%s selected" and Vietnamese
forgets the %s, the Vietnamese user loses the value -- and if the counts
disagree the format call errors out instead. Same key, same specifiers, both
files.
]]
print("\n=== format specifiers agree ===")
local function specs(s)
    local out = {}
    -- %% is a literal percent and takes no argument.
    for spec in s:gsub("%%%%", ""):gmatch("%%[-0-9.]*([a-zA-Z])") do
        table.insert(out, spec)
    end
    return table.concat(out, "")
end

local mismatched = {}
for k, ev in pairs(en) do
    if vi[k] then
        local a, b = specs(ev), specs(vi[k])
        if a ~= b then
            table.insert(mismatched, k .. " (en:'" .. a .. "' vi:'" .. b .. "')")
        end
    end
end
check(#mismatched == 0, "no key formats differently between languages (" ..
      (#mismatched > 0 and table.concat(mismatched, ", ") or "all agree") .. ")")

--[[
Every key main.lua asks for must resolve somewhere. A key that exists in
neither the .po files nor the fallback table renders as the raw key name --
"menu_characters" on a button -- which is the exact failure a rename of the
key vocabulary produces, and it is invisible until someone opens that menu.
]]
print("\n=== every t() call site resolves ===")
local src = assert(io.open(plugin_dir .. "/main.lua", "r"))
local main_src = src:read("*a")
src:close()

local unresolved, seen = {}, {}
for key in main_src:gmatch('loc:t%("([%w_]+)"') do
    if not seen[key] then
        seen[key] = true
        -- t() falls back to the table inside the module, so ask t() itself:
        -- a key resolving to its own name is the failure.
        if en[key] == nil and Loc:t(key) == key then
            table.insert(unresolved, key)
        end
    end
end
table.sort(unresolved)
local n = 0
for _ in pairs(seen) do n = n + 1 end
check(#unresolved == 0, n .. " keys used by main.lua all resolve (" ..
      (#unresolved > 0 and ("unresolved: " .. table.concat(unresolved, ", ")) or "none dangling") .. ")")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
