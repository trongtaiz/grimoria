--[[
Where the plugin's files live, and where they used to live.

The plugin was renamed. A reader who already analysed books under the old name
has two kinds of file the new name cannot see on its own:

    <koreader>/settings/xray/*.txt          keys, model, language preferences
    <book>.sdr/xray_cache*.lua              the analyses themselves
    <book>.sdr/xray_versions.lua            which analysis is active
    <book>.sdr/xray_notes.lua               the reader's own notes

Abandoning those is not a cosmetic loss: each analysis cost real money and
several minutes of a device being held awake, and the notes were typed by hand.
So every read tries the current name first and falls back to the old one.

Writes always go to the current name. That makes the migration happen by itself
the first time a value is saved, and means nothing on the reader's disk is ever
renamed, moved or deleted by this plugin -- a migration that half-succeeds and
eats a paid analysis is far worse than two files sitting side by side.

The old name is deliberately a constant rather than something clever: when it
eventually stops being worth carrying, deleting it is one line and the fallback
disappears with it.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Paths = {}

Paths.NAME = "grimoria"
Paths.LEGACY_NAME = "xray"

-- ------------------------------------------------------------- settings ----

-- Where settings are written. Always the current name.
function Paths:settingsDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/" .. self.NAME
end

-- Both directories a setting might be read from, current name first.
function Paths:settingsDirs()
    local DataStorage = require("datastorage")
    local base = DataStorage:getSettingsDir()
    return {
        base .. "/" .. self.NAME,
        base .. "/" .. self.LEGACY_NAME,
    }
end

--[[
Read one settings file. Returns a trimmed, non-empty string, or nil.

Empty is treated as absent throughout the plugin: a file someone blanked to
"unset this" should behave the same as one that was never created, and an
empty api_key must not read as a configured key.
]]
function Paths:readSetting(filename)
    for _, dir in ipairs(self:settingsDirs()) do
        local f = io.open(dir .. "/" .. filename, "r")
        if f then
            local v = f:read("*a")
            f:close()
            v = v and v:match("^%s*(.-)%s*$")
            if v and #v > 0 then
                if dir:match("/" .. self.LEGACY_NAME .. "$") then
                    logger.info("Paths: read", filename, "from the pre-rename settings dir")
                end
                return v
            end
        end
    end
    return nil
end

-- --------------------------------------------------------------- sidecar ----

-- The names one of the plugin's sidecar files may have, current name first.
-- `base` is the part after the prefix, e.g. "notes.lua" or "versions.lua".
function Paths:sidecarNames(base)
    return {
        self.NAME .. "_" .. base,
        self.LEGACY_NAME .. "_" .. base,
    }
end

-- First of those that exists in `dir`, or nil. Callers that write should use
-- sidecarNames()[1] rather than this.
function Paths:findSidecar(dir, base)
    if not dir then return nil end
    for _, name in ipairs(self:sidecarNames(base)) do
        local path = dir .. "/" .. name
        if lfs.attributes(path) then return path end
    end
    return nil
end

--[[
Does this filename look like one of our per-book analyses?

Matches both prefixes, and deliberately not the index: that is
<name>_versions.lua, which does not contain "_cache". Returns the version id
when the name carries one, "legacy" for the pre-versioning single file.
]]
function Paths:matchCacheFile(entry)
    for _, prefix in ipairs({ self.NAME, self.LEGACY_NAME }) do
        if entry:match("^" .. prefix .. "_cache.*%.lua$") then
            return true, entry:match("^" .. prefix .. "_cache_([^%.]+)%.lua$") or "legacy"
        end
    end
    return false, nil
end

return Paths
