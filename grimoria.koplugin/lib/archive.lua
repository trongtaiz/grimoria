--[[
Archive - Grimoria analysis caching, with one stored version per analysis.

A book can hold several analyses at once (different models, different runs) and
the reader picks which one is live. Layout inside the book's .sdr sidecar:

    grimoria_cache.lua                              a pre-versioning cache
    grimoria_cache_1786641234_gpt-5-5-high.lua      one file per analysis
    grimoria_versions.lua                           index: the list + which is active

One file per version rather than one file holding all of them, so saving a new
analysis writes only the new file. Rewriting every stored version on each save
would push a few hundred KB through the Kindle's flash each time, and a failed
write would take the other versions down with it.

Caches written before versioning are adopted IN PLACE, under their existing
name -- not moved, not rewritten, not re-fetched. A migration that renames
files is a migration that can lose them.

The index is a convenience, never the source of truth: if it goes missing or
fails to parse it is rebuilt by scanning the sidecar. Losing it costs the
labels, never the analyses.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DocSettings = require("docsettings")

local Archive = {}

Archive.PAYLOAD_VERSION = "7.0"
Archive.INDEX_FILE = "grimoria_versions.lua"
Archive.LEGACY_FILE = "grimoria_cache.lua"

-- Chapter-appearance counts, which are derived from the book text rather than
-- bought from a model. Its own file and its own version number precisely
-- because it is cheap to rebuild: bumping this throws away a scan, never an
-- analysis, so it can change whenever the shape needs to.
Archive.MENTIONS_FILE = "grimoria_mentions.lua"
Archive.MENTIONS_VERSION = "1"

function Archive:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- ---------------------------------------------------------------- paths ----

function Archive:getSidecarDir(book_path)
    if not book_path then return nil end
    return DocSettings:getSidecarDir(book_path)
end

function Archive:getIndexPath(book_path)
    local dir = self:getSidecarDir(book_path)
    return dir and (dir .. "/" .. self.INDEX_FILE) or nil
end

-- Path of the analysis currently in use. Kept because callers outside this
-- module ask "is there a cache for this book at all?".
function Archive:getCachePath(book_path)
    local dir = self:getSidecarDir(book_path)
    if not dir then return nil end

    local index = self:loadIndex(book_path)
    local active = self:getActiveVersion(index)
    if active then return dir .. "/" .. active.file end

    -- No index and no active version: fall back to a pre-versioning single
    -- cache, under either the current or the pre-rename name.
    local Paths = require("lib/paths")
    return Paths:findSidecar(dir, "cache.lua") or (dir .. "/" .. self.LEGACY_FILE)
end

function Archive:ensureDirectory(path)
    local dir = path:match("(.+)/[^/]+$")
    if not dir then return false end

    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then return true end

    logger.info("Archive: Creating directory:", dir)
    local success, err = lfs.mkdir(dir)
    if not success then
        logger.warn("Archive: Failed to create directory:", err or "unknown error")
        return false
    end
    return true
end

-- ------------------------------------------------------------- payloads ----

-- Read one analysis file. Returns nil for anything that isn't a readable
-- payload of the current version.
function Archive:readPayload(path)
    if not lfs.attributes(path) then return nil end

    local ok, data = pcall(function() return dofile(path) end)
    if not ok or type(data) ~= "table" then
        logger.warn("Archive: could not read", path, "-", tostring(data))
        return nil
    end
    if data.cache_version ~= self.PAYLOAD_VERSION then
        logger.warn("Archive: ignoring", path, "- version",
                    tostring(data.cache_version))
        return nil
    end
    return data
end

-- The few numbers that let a reader tell two analyses apart in a list.
function Archive:summarise(data)
    local function count(t) return type(t) == "table" and #t or 0 end
    local meta = type(data.analysis_meta) == "table" and data.analysis_meta or {}
    return {
        created_at = tonumber(data.cached_at) or 0,
        chapters   = count(data.chapters),
        characters = count(data.characters),
        merges     = count(data.identity_merges),
        provider   = meta.provider,
        model      = meta.model,
        effort     = meta.effort,
        -- { first = , last = } when this analysis covered only part of the
        -- book. Nil for the ordinary whole-book run, which is what every
        -- analysis written before section analyses existed is.
        scope      = meta.scope,
    }
end

-- ---------------------------------------------------------------- index ----

function Archive:saveIndex(book_path, index)
    local path = self:getIndexPath(book_path)
    if not path or not self:ensureDirectory(path) then return false end

    local ok, err = pcall(function()
        local f = assert(io.open(path, "w"))
        f:write("-- Grimoria analysis version index\n")
        f:write("-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        f:write("return " .. self:serialize(index))
        f:close()
    end)
    if not ok then
        logger.warn("Archive: could not write index:", tostring(err))
        return false
    end
    return true
end

--[[
Rebuild the index from what is actually on disk.

Runs when there is no index or it won't parse, and is what adopts a
pre-versioning cache: grimoria_cache.lua matches the same pattern as the versioned
files, so it is picked up with no special case. Reading every payload is
expensive, which is exactly why the result is written back as an index.
]]
function Archive:rebuildIndex(book_path)
    local dir = self:getSidecarDir(book_path)
    local index = { index_version = "1.0", active = nil, versions = {} }
    if not dir or not lfs.attributes(dir) then return index end

    local Paths = require("lib/paths")
    local names = {}
    local ok = pcall(function()
        for entry in lfs.dir(dir) do
            -- The index itself does not match: it is <name>_versions.lua, and
            -- carries no "_cache". Matches the pre-rename prefix too, so a
            -- reader's existing paid analyses are adopted rather than orphaned.
            if (Paths:matchCacheFile(entry)) then
                names[#names + 1] = entry
            end
        end
    end)
    if not ok then
        logger.warn("Archive: could not scan", dir)
        return index
    end

    table.sort(names)
    for _, name in ipairs(names) do
        local data = self:readPayload(dir .. "/" .. name)
        if data then
            local s = self:summarise(data)
            local _, id = Paths:matchCacheFile(name)
            s.id = id or "legacy"
            s.file = name
            s.label = type(data.analysis_meta) == "table"
                and data.analysis_meta.label or nil
            index.versions[#index.versions + 1] = s
        end
    end

    -- Newest becomes active, matching what a reader last generated.
    local newest
    for _, v in ipairs(index.versions) do
        if not newest or v.created_at > newest.created_at then newest = v end
    end
    index.active = newest and newest.id or nil

    if #index.versions > 0 then
        logger.info("Archive: rebuilt index with", #index.versions, "version(s)")
        self:saveIndex(book_path, index)
    end
    return index
end

-- Load the index, rebuilding it if it is absent, unparseable, or has drifted
-- from the files actually present.
function Archive:loadIndex(book_path)
    local path = self:getIndexPath(book_path)
    if not path then return { index_version = "1.0", versions = {} } end

    --[[
    The pre-rename index is read too, when no current one exists. Not strictly
    necessary -- rebuildIndex would reconstruct an equivalent index by scanning,
    and labels survive because they live inside each payload -- but the one
    thing a rescan cannot recover is which analysis the reader had made active.
    It guesses "newest", which is wrong for anyone who deliberately switched
    back to an older one.
    ]]
    local Paths = require("lib/paths")
    local candidates = { path }
    local dir_for_legacy = self:getSidecarDir(book_path)
    if dir_for_legacy then
        candidates[#candidates + 1] =
            dir_for_legacy .. "/" .. Paths:sidecarNames("versions.lua")[2]
    end

    local index
    for _, candidate in ipairs(candidates) do
        if lfs.attributes(candidate) then
            local ok, data = pcall(function() return dofile(candidate) end)
            if ok and type(data) == "table" and type(data.versions) == "table" then
                index = data
                if candidate ~= path then
                    logger.info("Archive: adopted the pre-rename index")
                end
                break
            else
                logger.warn("Archive: index unreadable, rebuilding:", candidate)
            end
        end
    end
    if not index then return self:rebuildIndex(book_path) end

    -- Drop entries whose file has gone; if that empties the list, rescan in
    -- case files arrived that the index never knew about.
    local dir = self:getSidecarDir(book_path)
    local kept = {}
    for _, v in ipairs(index.versions) do
        if v.file and lfs.attributes(dir .. "/" .. v.file) then
            kept[#kept + 1] = v
        else
            logger.info("Archive: dropping missing version", tostring(v.file))
        end
    end
    if #kept ~= #index.versions then
        index.versions = kept
        if #kept == 0 then return self:rebuildIndex(book_path) end
        self:saveIndex(book_path, index)
    end
    return index
end

-- ------------------------------------------------- chapter appearances ----

function Archive:getMentionsPath(book_path)
    local dir = self:getSidecarDir(book_path)
    return dir and (dir .. "/" .. self.MENTIONS_FILE) or nil
end

--[[
Store one scan.

`names` is stored beside the rows and is the whole reason this is safe to
reuse: the counts are indexed by the character's position in the FILTERED list,
and that list grows as the reader meets more people. Reusing a scan against a
different list would attribute one person's mentions to another -- silently,
and in a way that looks like a plausible bar chart. So the names are compared
element by element on load, and anything that does not match is rescanned.

`up_to` is compared the same way, and exactly rather than "at least": a scan
made at chapter 20 has no counts for chapters 21..40, but it also has no counts
for characters the reader had not met at chapter 20, so it cannot be extended
by scanning only the new chapters. Rescanning the whole thing is the honest
answer and the only correct one.
]]
function Archive:saveMentions(book_path, payload)
    local path = self:getMentionsPath(book_path)
    if not path or not self:ensureDirectory(path) then return false end

    payload.mentions_version = self.MENTIONS_VERSION
    payload.scanned_at = os.time()

    local ok, err = pcall(function()
        local f = assert(io.open(path, "w"))
        f:write("-- Grimoria chapter appearances (derived from the book text;\n")
        f:write("-- safe to delete, it is rebuilt by scanning again)\n\n")
        f:write("return " .. self:serialize(payload))
        f:close()
    end)
    if not ok then
        logger.warn("Archive: could not write mentions:", tostring(err))
        return false
    end
    return true
end

-- The stored scan, if it is still the right one for this analysis, this
-- reading position and this cast. nil means "scan again".
function Archive:loadMentions(book_path, version_id, up_to, names)
    local path = self:getMentionsPath(book_path)
    if not path or not lfs.attributes(path) then return nil end

    local ok, data = pcall(function() return dofile(path) end)
    if not ok or type(data) ~= "table" then
        logger.warn("Archive: could not read mentions:", tostring(data))
        return nil
    end
    if data.mentions_version ~= self.MENTIONS_VERSION then return nil end
    if data.version_id ~= version_id then return nil end
    if data.up_to ~= up_to then return nil end

    local stored = data.names or {}
    if #stored ~= #names then return nil end
    for i = 1, #names do
        if stored[i] ~= names[i] then return nil end
    end

    return data.rows
end

function Archive:getActiveVersion(index)
    if not index or #index.versions == 0 then return nil end
    for _, v in ipairs(index.versions) do
        if v.id == index.active then return v end
    end
    -- Active id points at nothing (deleted out from under us): fall back to
    -- the newest rather than reporting no cache at all.
    local newest
    for _, v in ipairs(index.versions) do
        if not newest or v.created_at > newest.created_at then newest = v end
    end
    return newest
end

-- Every stored analysis, newest first, for the picker.
function Archive:listVersions(book_path)
    local index = self:loadIndex(book_path)
    local out, order = {}, {}
    for i, v in ipairs(index.versions) do
        out[#out + 1] = v
        order[v] = i          -- the index stores versions in the order saved
    end
    table.sort(out, function(a, b)
        local ta, tb = a.created_at or 0, b.created_at or 0
        if ta ~= tb then return ta > tb end
        -- Same second: the one saved later is the newer one. table.sort is not
        -- stable, so without this the picker could reorder itself between
        -- openings for no visible reason.
        return order[a] > order[b]
    end)
    return out, index.active
end

-- ----------------------------------------------------------- save / load ----

-- "gpt-5.5-high" -> "gpt-5-5-high": filename-safe, still readable in a
-- directory listing, which matters when debugging on a device.
local function slug(s)
    if type(s) ~= "string" or #s == 0 then return "analysis" end
    s = s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if #s == 0 then return "analysis" end
    return s:sub(1, 32)
end

--[[
Store a new analysis as its own version and make it active.

meta = { provider = , model = , effort = , label = , scope = }  (all optional)

`scope` is { first = , last = } for a section analysis -- a run over part of a
long book rather than all of it. It changes nothing about how the analysis is
read or filtered; it exists so the version picker can say which part, because
two runs of the same model over different halves of a book are otherwise
indistinguishable in that list.

The model is written into the payload rather than only into the index, so a
version is self-describing even if the index is lost and rebuilt.
]]
function Archive:saveCache(book_path, data, meta)
    if not book_path or not data then
        logger.warn("Archive: Cannot save cache - invalid parameters")
        return false
    end
    local dir = self:getSidecarDir(book_path)
    if not dir then
        logger.warn("Archive: Cannot determine cache path")
        return false
    end

    meta = meta or {}
    data.cached_at = os.time()
    data.cache_version = self.PAYLOAD_VERSION
    data.analysis_meta = {
        provider = meta.provider,
        model = meta.model,
        effort = meta.effort,
        label = meta.label,
        scope = meta.scope,
        created_at = data.cached_at,
    }

    -- Two analyses finishing in the same second would otherwise collide.
    local base = tostring(data.cached_at) .. "_" .. slug(meta.model)
    local id, file = base, "grimoria_cache_" .. base .. ".lua"
    local n = 1
    while lfs.attributes(dir .. "/" .. file) do
        n = n + 1
        id = base .. "-" .. n
        file = "grimoria_cache_" .. id .. ".lua"
    end

    local full = dir .. "/" .. file
    if not self:ensureDirectory(full) then
        logger.warn("Archive: Cannot create cache directory")
        return false
    end

    local ok, err = pcall(function()
        local f = assert(io.open(full, "w"))
        local body = self:serialize(data)
        assert(body, "serialisation failed")
        f:write("-- Grimoria Cache v" .. self.PAYLOAD_VERSION .. "\n")
        f:write("-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        f:write("return " .. body)
        f:close()
    end)
    if not ok then
        logger.warn("Archive: Failed to save cache:", tostring(err))
        os.remove(full)   -- never leave a half-written version behind
        return false
    end

    local index = self:loadIndex(book_path)
    local entry = self:summarise(data)
    entry.id, entry.file, entry.label = id, file, meta.label
    index.versions[#index.versions + 1] = entry
    index.active = id
    self:saveIndex(book_path, index)

    logger.info("Archive: saved version", id, "->", full)
    return true
end

-- The analysis currently selected for this book.
function Archive:loadCache(book_path)
    if not book_path then return nil end
    local dir = self:getSidecarDir(book_path)
    if not dir then return nil end

    local index = self:loadIndex(book_path)
    local active = self:getActiveVersion(index)
    if not active then
        logger.info("Archive: No cache file found")
        return nil
    end

    local data = self:readPayload(dir .. "/" .. active.file)
    if not data then return nil end

    logger.info("Archive: loaded version", tostring(active.id),
                "model", tostring(active.model or "unknown"))
    return self:normalise(data)
end

--[[
Put a loaded analysis through the same validation a fresh reply gets.

This used to happen only on the way IN -- validateAndCleanData ran on the
model's reply, and everything read back off disk went straight to the display
layer exactly as it had been written. That was survivable while the two ends
agreed, and stopped being survivable the moment the spoiler rules changed:
an analysis stored last month was produced under the old rules, still opens
every day, and was reaching the filter with none of the guarantees the filter
assumes. Concretely, a pre-versioning cache has no `intro` and no `by_chapter`,
so the per-chapter rebuild produced nothing and the whole-book `description`
written before any spoiler rule existed went on screen.

Running it here means every rule -- present and future -- applies to analyses
that predate it, without rewriting a single file on the reader's disk and
without bumping PAYLOAD_VERSION, which would throw away every paid analysis on
every device. That is why validateAndCleanData has to stay idempotent: a value
now passes through it many times over its life rather than exactly once.

Failure is not fatal: a normaliser that errors must not make a stored analysis
unopenable, so the raw payload is returned and the display layer's own
fail-closed defaults take over.
]]
function Archive:normalise(data)
    local ok, LLM = pcall(require, "lib/llm")
    if not ok or type(LLM) ~= "table" or type(LLM.validateAndCleanData) ~= "function" then
        return data
    end
    local ok2, cleaned = pcall(function() return LLM:validateAndCleanData(data) end)
    if not ok2 or type(cleaned) ~= "table" then
        logger.warn("Archive: could not normalise the stored analysis:", tostring(cleaned))
        return data
    end

    -- The leak scan runs here as well as at save time, so an analysis stored
    -- before the guard existed gets it too -- without rewriting the file.
    local ok3, guarded = pcall(function()
        local SpoilerGuard = require("lib/spoilerguard")
        return (SpoilerGuard.scan(cleaned))
    end)
    if ok3 and type(guarded) == "table" then return guarded end
    logger.warn("Archive: spoiler guard did not run on the stored analysis")
    return cleaned
end

-- ------------------------------------------------------------ management ----

function Archive:setActiveVersion(book_path, id)
    local index = self:loadIndex(book_path)
    for _, v in ipairs(index.versions) do
        if v.id == id then
            index.active = id
            return self:saveIndex(book_path, index)
        end
    end
    logger.warn("Archive: no such version:", tostring(id))
    return false
end

function Archive:renameVersion(book_path, id, label)
    local index = self:loadIndex(book_path)
    for _, v in ipairs(index.versions) do
        if v.id == id then
            v.label = (type(label) == "string" and #label > 0) and label or nil
            return self:saveIndex(book_path, index)
        end
    end
    return false
end

-- Remove one analysis. If it was the active one, the next most recent takes
-- over, so the reader is never left with a book that has versions but none
-- selected.
function Archive:deleteVersion(book_path, id)
    local dir = self:getSidecarDir(book_path)
    local index = self:loadIndex(book_path)

    local kept, removed = {}, nil
    for _, v in ipairs(index.versions) do
        if v.id == id then removed = v else kept[#kept + 1] = v end
    end
    if not removed then return false end

    os.remove(dir .. "/" .. removed.file)
    index.versions = kept

    if index.active == id then
        local newest
        for _, v in ipairs(kept) do
            if not newest or v.created_at > newest.created_at then newest = v end
        end
        index.active = newest and newest.id or nil
    end

    if #kept == 0 then
        os.remove(self:getIndexPath(book_path))
        logger.info("Archive: removed last version for this book")
        return true
    end
    self:saveIndex(book_path, index)
    logger.info("Archive: deleted version", tostring(id))
    return true
end

-- Every version for this book, plus the index.
function Archive:clearCache(book_path)
    local dir = self:getSidecarDir(book_path)
    if not dir then return false end

    local index = self:loadIndex(book_path)
    local removed = 0
    for _, v in ipairs(index.versions) do
        if os.remove(dir .. "/" .. v.file) then removed = removed + 1 end
    end
    os.remove(self:getIndexPath(book_path))

    -- A legacy file that never made it into the index would otherwise survive
    -- a "clear everything" and reappear on the next rebuild.
    if lfs.attributes(dir .. "/" .. self.LEGACY_FILE) then
        if os.remove(dir .. "/" .. self.LEGACY_FILE) then removed = removed + 1 end
    end

    logger.info("Archive: cleared", removed, "version(s)")
    return removed > 0
end

-- ------------------------------------------------------------ serialise ----

function Archive:serialize(obj, indent, seen)
    indent = indent or ""
    seen = seen or {}

    local t = type(obj)
    if t == "table" then
        if seen[obj] then
            return "{--[[circular reference]]}"
        end
        seen[obj] = true

        local s = "{\n"
        for k, v in pairs(obj) do
            if type(v) ~= "function" and type(v) ~= "userdata" and type(v) ~= "thread" then
                s = s .. indent .. "  "
                if type(k) == "string" then
                    if k:match("^[%a_][%w_]*$") then
                        s = s .. k .. " = "
                    else
                        s = s .. "[" .. string.format("%q", k) .. "] = "
                    end
                else
                    s = s .. "[" .. tostring(k) .. "] = "
                end
                s = s .. self:serialize(v, indent .. "  ", seen) .. ",\n"
            end
        end
        s = s .. indent .. "}"
        return s
    elseif t == "string" then
        return string.format("%q", obj)
    elseif t == "number" or t == "boolean" then
        return tostring(obj)
    else
        return "nil"
    end
end

return Archive
