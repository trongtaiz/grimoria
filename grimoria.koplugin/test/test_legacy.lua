--[[
Reading what the plugin wrote before it was renamed.

A reader who used the old name has settings and, more importantly, finished
analyses that cost real money and minutes of a device held awake. The rename
made all of it invisible in one commit. lib/paths.lua is what makes it visible
again, and this proves it, because the failure is silent: the plugin comes up
perfectly, simply reporting that this book has never been analysed.

The rules being checked, in one line: reads prefer the current name and fall
back to the old one; writes always use the current name; nothing on disk is
renamed, moved or deleted.

  usage: lua test_legacy.lua <plugin_dir> <fixture_dir>

<fixture_dir> must contain settings/{grimoria,xray}/ and sdr/ -- the runner
creates them, since pure Lua cannot make a directory.
]]
local plugin_dir, fixture = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("datastorage", { getSettingsDir = function() return fixture .. "/settings" end })
-- Real existence check: these tests are about which file gets opened.
stub("libs/libkoreader-lfs", {
    mkdir = function() return true end,
    attributes = function(path)
        local f = io.open(path, "r")
        if not f then return nil end
        f:close()
        return { mode = "file" }
    end,
})
stub("docsettings", { getSidecarDir = function() return fixture .. "/sdr" end })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

local Paths = require("lib/paths")

print("=== settings: current name wins, old name is the fallback ===")
-- gemini_model.txt exists under BOTH names, with different values.
check(Paths:readSetting("gemini_model.txt") == "new-model",
      "a setting present under both names reads the current one (got: " ..
      tostring(Paths:readSetting("gemini_model.txt")) .. ")")
-- openrouter_api_key.txt exists ONLY under the old name.
check(Paths:readSetting("openrouter_api_key.txt") == "sk-or-v1-legacy",
      "a setting only in the pre-rename dir is still found (got: " ..
      tostring(Paths:readSetting("openrouter_api_key.txt")) .. ")")
check(Paths:readSetting("nothing_here.txt") == nil,
      "a setting in neither directory is nil")

--[[
An emptied file means "unset", not "set to empty string". This matters most
for api_key: an empty key that read as a value would make the plugin believe
it is configured and fire a request that can only 401.
]]
check(Paths:readSetting("blank.txt") == nil,
      "a blank file reads as absent, not as an empty value")
check(Paths:readSetting("padded.txt") == "trimmed",
      "surrounding whitespace and newlines are stripped")

print("\n=== settings: writes go to the current name ===")
check(Paths:settingsDir():match("/grimoria$") ~= nil,
      "the write directory is the current name (" .. Paths:settingsDir() .. ")")
check(Paths:settingsDirs()[1]:match("/grimoria$") ~= nil
      and Paths:settingsDirs()[2]:match("/xray$") ~= nil,
      "read order is current name first, old name second")

print("\n=== sidecar: both cache prefixes are recognised ===")
local cases = {
    { "grimoria_cache.lua",                     true,  "legacy" },
    { "xray_cache.lua",                         true,  "legacy" },
    { "grimoria_cache_1786641234_gpt-5.lua",    true,  "1786641234_gpt-5" },
    { "xray_cache_1786641234_gpt-5.lua",        true,  "1786641234_gpt-5" },
    -- The index must NOT be mistaken for an analysis, under either name.
    { "grimoria_versions.lua",                  false, nil },
    { "xray_versions.lua",                      false, nil },
    -- Nor must anything else living in a .sdr sidecar.
    { "metadata.epub.lua",                      false, nil },
    { "grimoria_notes.lua",                     false, nil },
}
for _, c in ipairs(cases) do
    local matched, id = Paths:matchCacheFile(c[1])
    local ok = (matched == c[2]) and (id == c[3])
    check(ok, string.format("%-38s -> %s%s", c[1],
          tostring(matched), id and (", id=" .. id) or ""))
end

print("\n=== sidecar: an old analysis is found, a new one preferred ===")
-- sdr/ has xray_cache.lua only.
local found = Paths:findSidecar(fixture .. "/sdr", "cache.lua")
check(found ~= nil and found:match("xray_cache%.lua$") ~= nil,
      "a pre-rename analysis is found when no current one exists (" ..
      tostring(found and found:match("[^/]+$")) .. ")")
-- sdr/ has BOTH notes files.
local notes = Paths:findSidecar(fixture .. "/sdr", "notes.lua")
check(notes ~= nil and notes:match("grimoria_notes%.lua$") ~= nil,
      "the current name wins when both exist (" ..
      tostring(notes and notes:match("[^/]+$")) .. ")")
check(Paths:findSidecar(fixture .. "/sdr", "absent.lua") == nil,
      "a file under neither name is nil")

print("\n=== notes: read follows the old file, write does not ===")
local Marginalia = require("lib/marginalia")
local read_path = Marginalia:getNotesPath("/some/book.epub")
local write_path = Marginalia:getNotesPath("/some/book.epub", true)
check(read_path:match("grimoria_notes%.lua$") ~= nil,
      "reading prefers the current name when it exists")
check(write_path:match("grimoria_notes%.lua$") ~= nil,
      "writing always uses the current name")
check(Marginalia:getNotesPath(nil) == nil, "no book path is nil, not a crash")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
