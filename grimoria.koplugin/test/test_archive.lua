--[[
Regression coverage for analysis-version persistence.

The first save for a book has no index yet. saveCache must create exactly one
index entry for the one payload it writes; rebuilding the missing index after
the payload exists and then appending it again produces two identical picker
rows.

  usage: lua test_archive.lua <plugin_dir>
]]
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local files = {}
local directories = { ["/sidecar"] = true }

local function entriesIn(dir)
    local names = {}
    local prefix = dir .. "/"
    for path in pairs(files) do
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            if not rest:find("/", 1, true) then names[#names + 1] = rest end
        end
    end
    table.sort(names)
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end

package.loaded["logger"] = {
    info = function() end, warn = function() end,
    error = function() end, dbg = function() end,
}
package.loaded["docsettings"] = {
    getSidecarDir = function() return "/sidecar" end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        if directories[path] then return { mode = "directory" } end
        if files[path] then return { mode = "file" } end
        return nil
    end,
    mkdir = function(path)
        directories[path] = true
        return true
    end,
    dir = entriesIn,
}

io.open = function(path, mode)
    if mode == "w" then
        local parts = {}
        return {
            write = function(_, value) parts[#parts + 1] = value end,
            close = function() files[path] = table.concat(parts) end,
        }
    end
    if mode == "r" and files[path] then
        return {
            read = function() return files[path] end,
            close = function() end,
        }
    end
    return nil
end

dofile = function(path)
    local chunk, err = load(files[path] or "")
    if not chunk then error(err) end
    return chunk()
end

os.remove = function(path)
    local existed = files[path] ~= nil
    files[path] = nil
    return existed
end
os.time = function() return 1786641234 end
os.date = function() return "2026-08-13 12:00:34" end

local Archive = require("lib/archive"):new()

local fails = 0
local function check(condition, message)
    if not condition then fails = fails + 1 end
    print((condition and "  PASS  " or "  FAIL  ") .. message)
end

print("=== first analysis creates one version ===")
local saved = Archive:saveCache("/book.epub", {
    chapters = { { index = 1 } },
    characters = { { name = "A" } },
    identity_merges = {},
}, { provider = "openrouter", model = "model/example" })
local versions, active = Archive:listVersions("/book.epub")

check(saved, "the payload and index are saved")
check(#versions == 1,
      "one saved analysis produces one picker entry (got " .. #versions .. ")")
check(versions[1] and versions[1].id == active,
      "the sole version is active")

print("\n=== a pre-rename index still receives the new version ===")
files = {
    ["/sidecar/xray_versions.lua"] = [[return {
        index_version = "1.0",
        active = "legacy",
        versions = {
            { id = "legacy", file = "xray_cache.lua", created_at = 1 },
        },
    }]],
    ["/sidecar/xray_cache.lua"] = [[return {
        cache_version = "7.0",
        cached_at = 1,
        chapters = {}, characters = {}, identity_merges = {},
    }]],
}

local adopted_saved = Archive:saveCache("/book.epub", {
    chapters = { { index = 1 } },
    characters = { { name = "B" } },
    identity_merges = {},
}, { provider = "openrouter", model = "model/example" })
local adopted_versions, adopted_active = Archive:listVersions("/book.epub")

check(adopted_saved, "the new payload is saved beside the pre-rename analysis")
check(#adopted_versions == 2,
      "the adopted index keeps its old row and gains the new one (got "
      .. #adopted_versions .. ")")
check(adopted_active ~= "legacy",
      "the newly saved version becomes active")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
