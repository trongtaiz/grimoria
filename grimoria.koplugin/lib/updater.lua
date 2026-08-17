--[[
Updating the plugin from its own GitHub repository.

The plugin is distributed as a folder you copy onto a device. Without this
module, "there is a new version" means plugging the Kindle in, finding the
plugins directory and copying files by hand -- which most readers will simply
not do, so a fix ships and nobody gets it.

Two properties matter more than any feature here, and everything below is
shaped by them.

  IT MUST NEVER BRICK THE PLUGIN. A failed, interrupted or half-finished
  update has to leave either the old version or the new version completely in
  place, never a mixture. A reader whose plugin stops loading has lost the
  paid analyses they can no longer open, on a device with no console to debug
  it. So: everything is downloaded and verified BEFORE anything is replaced,
  the replaced files are kept, and every entry point runs under pcall.

  IT MUST STILL WORK IN FIVE YEARS. This copy of the updater is the one that
  has to reach whatever the project looks like by then. The wire contract is
  therefore tiny, versioned, and additive-only -- and when even that is not
  enough, the updater replaces ITSELF first (see updater_version below) and
  lets its successor do the real work. That is the escape hatch that keeps
  "future-proof" from being a wish.

THE CONTRACT (contract = 1; these field meanings are frozen forever)

  update/latest.json   on the default branch -- the mutable pointer
    { "contract": 1, "version": "3.1.0", "tag": "v3.1.0",
      "updater_version": 1, "notes": "one or two lines for the user" }

  update/manifest.json AT THE TAG -- the immutable file list
    { "contract": 1, "version": "3.1.0",
      "files": [ { "path": "main.lua", "sha256": "...", "size": 11761 }, ... ] }

Files are fetched one by one from raw.githubusercontent.com at the *tag*, not
the branch, so a push landing mid-download cannot produce a torn install.

Why per-file downloads instead of a release zip: unzipping needs an archive
primitive whose availability varies across KOReader builds and devices, while
per-file HTTPS needs exactly what lib/llm.lua already ships for the AI calls.
The whole plugin is ~300 KB across ~35 files -- seconds on wifi. "Works on
every future KOReader" is worth more here than "one request".

Why a future layout cannot break it: the manifest lists paths relative to the
plugin folder, so a release that renames or adds files is just a different
list. Files that exist now and are absent from the new manifest are moved to
the backup and not restored -- that is how a deletion or a rename arrives.

WHAT IS NEVER TOUCHED

The reader's own data lives outside the plugin folder -- settings in
<koreader>/settings/grimoria/ and analyses in each book's .sdr sidecar -- and
nothing here writes, renames or deletes anything outside <plugin>/. That is
also what keeps lib/paths.lua's pre-rename fallback intact across an update.
test/ is skipped in both directions so a developer checkout keeps its harness.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local json = require("json")

local GrimoriaPlugin = {}

-- The contract this updater speaks. A release whose latest.json carries a
-- higher "contract" is one this code cannot be trusted to read, so it stops
-- and says so rather than guessing at unfamiliar fields.
local CONTRACT = 1

-- Bumped ONLY when the updater itself must change to install a release --
-- a new manifest field it has to honour, a different archive layout, a new
-- verification step. latest.json carries the updater_version a release needs;
-- when that exceeds this one, the updater installs its own replacement first
-- and asks for a restart, and the new updater performs the real update.
local UPDATER_VERSION = 1

local STAGING = ".update-staging"
local BACKUP  = ".update-backup"
local STATE   = ".update-state.json"

-- Never backed up, never replaced, never deleted. test/ is a developer's
-- harness that no release ships; the rest is this module's own workspace.
local SKIP_TOP = { ["test"] = true, [STAGING] = true, [BACKUP] = true }

local RAW_HOST = "https://raw.githubusercontent.com"

-- ------------------------------------------------------------ plumbing ----

--[[
Where this plugin is installed.

KOReader's PluginLoader sets `path` on every plugin it loads, and that is the
answer whenever the plugin is running normally. The debug fallback exists for
the test harness, which requires these modules directly with no loader in
sight: source is ".../grimoria.koplugin/lib/updater.lua", so two directories up
is the plugin folder.
]]
function GrimoriaPlugin:updaterPluginDir()
    if self.path and #self.path > 0 then return self.path end
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*)[/\\]lib[/\\]updater%.lua$")
        if dir then return dir end
    end
    return nil
end

--[[
Which GitHub repository to update from, as "owner/name".

Kept in config.lua rather than hardcoded so a fork updates from itself rather
than from upstream, and overridable from settings/grimoria/update_repo.txt the
same way every other setting is. The shipped value is a placeholder: an
unconfigured install must say so plainly instead of fetching from a repository
somebody else controls.
]]
function GrimoriaPlugin:updaterRepo()
    local Paths = require("lib/paths")
    local repo = Paths:readSetting("update_repo.txt")
    if not repo then
        local ok, config = pcall(dofile, self:updaterPluginDir() .. "/config.lua")
        if ok and type(config) == "table" then repo = config.update_repo end
    end
    if type(repo) ~= "string" then return nil end
    repo = repo:match("^%s*(.-)%s*$")
    -- "owner/name" and nothing else: a placeholder, a full URL or an empty
    -- string all mean "not configured yet".
    if not repo:match("^[%w%-%._]+/[%w%-%._]+$") then return nil end
    if repo:find("YOUR%-") or repo:find("EXAMPLE") then return nil end
    return repo
end

-- The version this install reports, from _meta.lua -- the single local source.
function GrimoriaPlugin:updaterLocalVersion()
    local dir = self:updaterPluginDir()
    if not dir then return "0.0.0" end
    local ok, meta = pcall(dofile, dir .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string" then
        return meta.version
    end
    return "0.0.0"
end

--[[
Compare two dotted version strings. Returns -1, 0 or 1.

Deliberately numeric and forgiving: missing components count as zero, so
"3.1" and "3.1.0" compare equal, and any non-numeric suffix is ignored rather
than making the comparison fail. A version this updater cannot parse must not
be a reason to refuse an update -- it should simply not look newer.
]]
function GrimoriaPlugin:updaterCompareVersions(a, b)
    local function parts(v)
        local out = {}
        for n in tostring(v or ""):gmatch("(%d+)") do out[#out + 1] = tonumber(n) end
        return out
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

local MAX_REDIRECTS = 4
local MAX_ATTEMPTS = 5

--[[
Is this failure worth trying again, or is it the answer?

The distinction is the whole point. A 404 means the file is not there -- or the
repository is private, which raw.githubusercontent.com reports as 404 too -- and
retrying it four times just makes the user wait four times as long for the same
no. A 503 means the host declined to serve this request *right now*.

Transport failures (`res == nil`, so `code` is an error string rather than a
number) are transient by the same reasoning: a dropped connection on Kindle wifi
is the most ordinary thing that can happen to this plugin.
]]
local function isTransient(res, code_num)
    if res == nil then return true end            -- socket-level failure
    if not code_num then return true end
    if code_num == 408 or code_num == 425 or code_num == 429 then return true end
    return code_num >= 500 and code_num < 600
end

-- LuaSocket's sleep, if this build has it. Called only from the download
-- sub-process, never from the UI thread, so blocking here is free.
local function pause(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.sleep then
        pcall(function() socket.sleep(seconds) end)
    end
end

--[[
One HTTPS GET, retried when the failure looks temporary.

Redirects are followed by hand rather than left to LuaSocket. socket.http's
built-in redirect logic re-requests through the *http* module, which cannot do
TLS, so a plain https->https redirect fails with a confusing error. GitHub's
raw host does redirect, so this is not a hypothetical.

THE RETRY IS NOT DEFENSIVE PROGRAMMING; IT IS THE FIX FOR A REPORTED FAILURE.

Installing 3.2.0 died with "HTTP 503". Measured against the live repository
afterwards: a burst of the manifest's 24 files returns a 503 for roughly one
request in a hundred, on no particular file, and the same URL succeeds
immediately afterwards -- raw.githubusercontent.com throttling a rapid series of
requests from one address. With no retry, one such blip anywhere in the run
aborted the whole update, and on a manifest of two dozen files that is not a
rare event: it is most of the reason an update fails at all.

Nothing was lost when it happened -- the download writes only into
.update-staging/ and the swap had not begun -- so the update was safe, merely
useless. Backoff of 1, 2, 4, 8 seconds: long enough for a throttle window to
pass, short enough that five attempts still finish inside the wait a user will
tolerate.

`sink_path` writes straight to a file instead of accumulating in memory; the
manifest fetches want the string, the file downloads want the file. It is
reopened "wb" on every attempt, so a partial body from a failed try is
overwritten rather than appended to -- which matters, because a truncated file
that reached the verify step would fail on a byte count with no hint that a
retry was involved.
]]
local function httpGet(url, sink_path, ua)
    local ltn12 = require("ltn12")
    local socketutil = nil
    pcall(function() socketutil = require("socketutil") end)

    local last_err = "download failed"

    for attempt = 1, MAX_ATTEMPTS do
        if attempt > 1 then
            local wait = 2 ^ (attempt - 2)          -- 1, 2, 4, 8
            logger.warn("Updater:", last_err, "-- retrying in", wait, "s (attempt",
                        attempt, "of", MAX_ATTEMPTS .. ")")
            pause(wait)
        end

        local target = url
        local transient, settled = false, false

        for _ = 1, MAX_REDIRECTS do
            local https = require("ssl.https")
            local http = require("socket.http")
            local mod = target:match("^https:") and https or http

            local body, out_file = {}, nil
            local sink
            if sink_path then
                local f, ferr = io.open(sink_path, "wb")
                if not f then
                    -- A filesystem that will not take the file is not something
                    -- waiting will fix.
                    return nil, "cannot write " .. tostring(sink_path) .. ": " .. tostring(ferr)
                end
                out_file = f
                sink = ltn12.sink.file(f)   -- closes the file itself
            else
                sink = ltn12.sink.table(body)
            end

            -- Same lesson as lib/llm.lua: a `timeout =` field inside the request
            -- table is ignored by LuaSocket. It has to be set on the module.
            if socketutil then socketutil:set_timeout(20, 120) end
            local res, code, headers = mod.request{
                url = target,
                method = "GET",
                headers = { ["User-Agent"] = ua or "grimoria.koplugin" },
                sink = sink,
                redirect = false,
            }
            if socketutil then socketutil:reset_timeout() end

            local code_num = tonumber(code)
            if code_num and code_num >= 300 and code_num < 400 and headers and headers.location then
                if out_file then pcall(function() out_file:close() end) end
                target = headers.location
            elseif res and code_num == 200 then
                return sink_path and true or table.concat(body)
            else
                if out_file then pcall(function() out_file:close() end) end
                last_err = "HTTP " .. tostring(code) .. " for " .. target
                transient = isTransient(res, code_num)
                settled = true
                break
            end
        end

        -- A redirect chain that never lands is a broken URL, not a busy server.
        if not settled then
            return nil, "too many redirects for " .. url
        end
        if not transient then
            return nil, last_err
        end
    end

    return nil, last_err .. " (gave up after " .. MAX_ATTEMPTS .. " attempts)"
end

--[[
mkdir -p, for the nested paths a manifest carries (lib/ui/menu.lua).

The prefix handling is not incidental. A plugin folder is an absolute path on
every real install ("/mnt/us/koreader/plugins/grimoria.koplugin"), and
accumulating the components without keeping the leading separator would build
"mnt/us/..." -- a relative path, created in whatever directory KOReader happens
to have been started from, while the real one is never created at all.
mkdir failing because a directory already exists is not an error here.
]]
local function mkdirp(path)
    local rest = path:gsub("\\", "/")
    local acc = ""
    local drive = rest:match("^(%a:)")     -- Windows, for the off-device tests
    if drive then
        acc = drive
        rest = rest:sub(#drive + 1)
    end
    if rest:sub(1, 1) == "/" then
        acc = acc .. "/"
        rest = rest:sub(2)
    end
    for part in rest:gmatch("[^/]+") do
        acc = (acc == "" or acc:sub(-1) == "/") and (acc .. part) or (acc .. "/" .. part)
        lfs.mkdir(acc)
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function fileSize(path)
    local a = lfs.attributes(path)
    return a and a.size or nil
end

--[[
SHA-256 of a file, or nil when this build cannot compute one.

KOReader bundles ffi/sha2, but the updater must not *depend* on it: this code
has to keep working on whatever KOReader looks like years from now, and a
module that moved is not a reason to refuse an update. When the hash is
unavailable the size check plus a complete download is the floor, and the log
says which check actually ran.
]]
local function sha256File(path)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local ok2, digest = pcall(sha2.sha256, data)
    if not ok2 or type(digest) ~= "string" then return nil end
    return digest:lower()
end

-- Every file currently installed, as paths relative to the plugin folder.
-- Used to decide what to move aside, which is also how a release that drops a
-- file gets that file removed: it goes to the backup and never comes back.
local function listInstalled(dir, rel, out)
    rel, out = rel or "", out or {}
    for entry in lfs.dir(dir .. (rel == "" and "" or "/" .. rel)) do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local this = rel == "" and entry or (rel .. "/" .. entry)
            if not (rel == "" and SKIP_TOP[entry]) then
                local mode = lfs.attributes(dir .. "/" .. this, "mode")
                if mode == "directory" then
                    listInstalled(dir, this, out)
                elseif mode == "file" then
                    out[#out + 1] = this
                end
            end
        end
    end
    return out
end

-- Remove a directory and everything under it. Only ever called on our own
-- staging and backup folders, never on anything a release or a reader owns.
local function rmrf(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        if lfs.attributes(path) then os.remove(path) end
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then rmrf(path .. "/" .. entry) end
    end
    lfs.rmdir(path)
end

-- ---------------------------------------------------------- the update ----

--[[
Fetch latest.json and, if it points at something newer, its manifest.

Runs whole in the caller's process: two small files, and the answer decides
whether there is anything worth showing a dialog about.
]]
function GrimoriaPlugin:updaterFetchRelease()
    local repo = self:updaterRepo()
    if not repo then return nil, self.loc:t("update_no_repo") end

    local ua = "grimoria.koplugin/" .. self:updaterLocalVersion()
    local body, err = httpGet(RAW_HOST .. "/" .. repo .. "/HEAD/update/latest.json", nil, ua)
    if not body then return nil, err end

    local ok, latest = pcall(json.decode, body)
    if not ok or type(latest) ~= "table" then
        return nil, self.loc:t("update_bad_release")
    end
    if type(latest.contract) == "number" and latest.contract > CONTRACT then
        -- A newer wire format than this code knows. Refusing is the safe
        -- reading: the fields it would need are ones it has never seen.
        return nil, self.loc:t("update_contract_too_new")
    end
    if type(latest.version) ~= "string" or type(latest.tag) ~= "string" then
        return nil, self.loc:t("update_bad_release")
    end

    latest.repo = repo
    latest.local_version = self:updaterLocalVersion()
    latest.is_newer = self:updaterCompareVersions(latest.version, latest.local_version) > 0
    -- A release may require a newer updater than the one installed. That is
    -- handled by replacing this file first, not by giving up.
    latest.needs_updater = (tonumber(latest.updater_version) or 0) > UPDATER_VERSION
    return latest
end

function GrimoriaPlugin:updaterFetchManifest(latest)
    local ua = "grimoria.koplugin/" .. latest.local_version
    -- At the tag, not the branch: the manifest and the files it describes must
    -- come from the same immutable commit, or a push landing mid-update would
    -- have us verifying one release's files against another's checksums.
    local url = RAW_HOST .. "/" .. latest.repo .. "/" .. latest.tag .. "/update/manifest.json"

    local body, err = httpGet(url, nil, ua)
    if not body then return nil, err end

    local ok, manifest = pcall(json.decode, body)
    if not ok or type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        return nil, self.loc:t("update_bad_manifest")
    end
    if type(manifest.contract) == "number" and manifest.contract > CONTRACT then
        return nil, self.loc:t("update_contract_too_new")
    end

    -- A manifest that lists no files, or one whose paths try to escape the
    -- plugin folder, is not something to act on.
    local clean = {}
    for _, f in ipairs(manifest.files) do
        if type(f) == "table" and type(f.path) == "string" and #f.path > 0
            and not f.path:find("%.%.") and not f.path:match("^[/\\]")
            and not f.path:match("^%a:") then
            clean[#clean + 1] = {
                path = f.path:gsub("\\", "/"),
                size = tonumber(f.size),
                sha256 = type(f.sha256) == "string" and f.sha256:lower() or nil,
            }
        else
            logger.warn("Updater: manifest entry rejected:", type(f) == "table" and tostring(f.path) or type(f))
        end
    end
    if #clean == 0 then return nil, self.loc:t("update_bad_manifest") end
    manifest.files = clean
    return manifest
end

--[[
Download every file in the manifest into the staging folder.

Called inside Trapper's forked sub-process, for the same reason the AI request
is: a serial download of thirty-odd files over Kindle wifi is tens of seconds
during which a direct call would freeze the UI completely. The child only
writes into <plugin>/.update-staging/ -- disposable by construction, so a
child killed halfway leaves nothing that matters -- and returns a plain table.
Nothing is swapped here; that happens back in the parent.
]]
function GrimoriaPlugin:updaterDownload(latest, manifest, only_path)
    local dir = self:updaterPluginDir()
    local staging = dir .. "/" .. STAGING
    rmrf(staging)
    if not mkdirp(staging) then
        return { ok = false, err = "cannot create " .. staging }
    end

    local ua = "grimoria.koplugin/" .. latest.local_version
    local base = RAW_HOST .. "/" .. latest.repo .. "/" .. latest.tag .. "/grimoria.koplugin/"
    local done = 0

    for _, f in ipairs(manifest.files) do
        if (not only_path) or f.path == only_path then
            local dest = staging .. "/" .. f.path
            local parent = dest:match("^(.*)/[^/]*$")
            if parent and not mkdirp(parent) then
                return { ok = false, err = "cannot create " .. parent }
            end
            local ok, err = httpGet(base .. f.path, dest, ua)
            if not ok then
                return { ok = false, err = err or ("failed: " .. f.path) }
            end
            done = done + 1
        end
    end
    return { ok = true, count = done }
end

--[[
Check the staged copy against the manifest before anything is replaced.

Size always, SHA-256 when this build can compute one. This is the last gate: a
truncated download that got past it would be installed over a working plugin.
]]
function GrimoriaPlugin:updaterVerify(manifest, only_path)
    local staging = self:updaterPluginDir() .. "/" .. STAGING
    local hashed, checked = 0, 0

    for _, f in ipairs(manifest.files) do
        if (not only_path) or f.path == only_path then
            local dest = staging .. "/" .. f.path
            local size = fileSize(dest)
            if not size then
                return false, "missing after download: " .. f.path
            end
            if f.size and size ~= f.size then
                return false, string.format("%s: expected %d bytes, got %d", f.path, f.size, size)
            end
            if f.sha256 then
                local got = sha256File(dest)
                if got then
                    hashed = hashed + 1
                    if got ~= f.sha256 then
                        return false, "checksum mismatch: " .. f.path
                    end
                end
            end
            checked = checked + 1
        end
    end
    logger.info("Updater: verified", checked, "files,", hashed, "with a checksum")
    return true
end

--[[
Replace the installed files with the staged ones.

The order is what makes this survivable. Every file that is currently
installed is MOVED (not copied, not deleted) into the backup folder first, so
at every instant each file exists in exactly one of the two places. Only then
are the staged files renamed into place -- same filesystem, so each rename is
atomic. If anything fails partway, every file already moved is put back and
the update is abandoned with the old version intact.

Files present before and absent from the manifest stay in the backup: that is
how a release that renames or removes a file takes effect, and it is why the
backup is never pruned by this code.
]]
function GrimoriaPlugin:updaterSwap(latest, manifest, only_path)
    local dir = self:updaterPluginDir()
    local staging, backup = dir .. "/" .. STAGING, dir .. "/" .. BACKUP

    rmrf(backup)
    if not mkdirp(backup) then return false, "cannot create " .. backup end

    local moved = {}    -- rel path -> true, everything now living in backup

    --[[
    Put everything back where it was.

    Restoring is renames in the opposite direction, so whatever stopped the
    swap can stop this too -- a full disk or a filesystem that has gone
    read-only does not care which way a file is moving. That case cannot be
    fixed by trying harder, so it is reported instead of hidden: the caller
    gets a message naming the backup folder, because every file is still in it
    and copying them back by hand is then a five-minute job rather than a
    reinstall. Silently returning "rolled back" when it did not would be the
    one genuinely dangerous outcome here.
    ]]
    local function undo(reason)
        local stuck = {}
        for rel in pairs(moved) do
            local from, to = backup .. "/" .. rel, dir .. "/" .. rel
            local parent = to:match("^(.*)/[^/]*$")
            if parent then mkdirp(parent) end
            os.remove(to)                      -- a half-installed new file
            if not os.rename(from, to) then stuck[#stuck + 1] = rel end
        end
        if #stuck > 0 then
            logger.warn("Updater: rollback incomplete --", reason,
                        "-- still in the backup:", table.concat(stuck, ", "))
            return false, reason, backup
        end
        logger.warn("Updater: rolled back --", reason)
        return false, reason
    end

    -- 1. current files out of the way
    local current = only_path and { only_path } or listInstalled(dir)
    for _, rel in ipairs(current) do
        local from, to = dir .. "/" .. rel, backup .. "/" .. rel
        local parent = to:match("^(.*)/[^/]*$")
        if parent and not mkdirp(parent) then return undo("cannot create " .. parent) end
        if lfs.attributes(from) then
            local ok, err = os.rename(from, to)
            if not ok then return undo("cannot move aside " .. rel .. ": " .. tostring(err)) end
            moved[rel] = true
        end
    end

    -- 2. staged files in
    for _, f in ipairs(manifest.files) do
        if (not only_path) or f.path == only_path then
            local from, to = staging .. "/" .. f.path, dir .. "/" .. f.path
            local parent = to:match("^(.*)/[^/]*$")
            if parent and not mkdirp(parent) then return undo("cannot create " .. parent) end
            local ok, err = os.rename(from, to)
            if not ok then return undo("cannot install " .. f.path .. ": " .. tostring(err)) end
        end
    end

    -- 3. a marker the next start looks for
    local state = {
        from = latest.local_version,
        to = latest.version,
        tag = latest.tag,
        time = os.time(),
        partial = only_path or nil,
    }
    local sf = io.open(dir .. "/" .. STATE, "w")
    if sf then
        sf:write(json.encode(state))
        sf:close()
    end

    rmrf(staging)
    logger.info("Updater: installed", latest.version, "over", latest.local_version)
    return true
end

-- ------------------------------------------------------------ the menu ----

local function say(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--[[
"Check for updates".

Every step reports what it found rather than failing silently, because the
alternative -- a menu entry that appears to do nothing -- is indistinguishable
from a broken plugin on a device with no visible log.
]]
function GrimoriaPlugin:checkForUpdates()
    local ok, err = pcall(function() self:checkForUpdatesInner() end)
    if not ok then
        logger.warn("Updater: check failed:", err)
        say(self.loc:t("update_failed") .. "\n\n" .. tostring(err))
    end
end

function GrimoriaPlugin:checkForUpdatesInner()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        UIManager:show(ConfirmBox:new{
            text = self.loc:t("network_offline_prompt"),
            ok_text = self.loc:t("turn_on_wifi"),
            cancel_text = self.loc:t("cancel"),
            ok_callback = function()
                NetworkMgr:turnOnWifi(function() self:checkForUpdates() end)
            end,
        })
        return
    end

    say(self.loc:t("update_checking"), 2)
    UIManager:forceRePaint()

    local latest, err = self:updaterFetchRelease()
    if not latest then
        say(self.loc:t("update_failed") .. "\n\n" .. tostring(err))
        return
    end

    if not latest.is_newer then
        say(string.format(self.loc:t("update_up_to_date"), latest.local_version), 4)
        return
    end

    local manifest, merr = self:updaterFetchManifest(latest)
    if not manifest then
        say(self.loc:t("update_failed") .. "\n\n" .. tostring(merr))
        return
    end

    --[[
    The bridge case: this release needs a newer updater than the one running.

    Rather than refuse, install only the updater file and ask for a restart.
    The successor -- which by definition knows whatever this one does not --
    then performs the real update. This is the mechanism that lets a future
    version change anything at all about how updates work without stranding
    the installs that are out in the world today.
    ]]
    if latest.needs_updater then
        local self_path = "lib/updater.lua"
        local found = false
        for _, f in ipairs(manifest.files) do
            if f.path == self_path then
                found = true
                break
            end
        end
        if not found then
            say(self.loc:t("update_failed") .. "\n\n" .. self.loc:t("update_bad_manifest"))
            return
        end
        UIManager:show(ConfirmBox:new{
            text = string.format(self.loc:t("update_needs_bridge"), latest.version),
            ok_text = self.loc:t("update_install"),
            cancel_text = self.loc:t("cancel"),
            ok_callback = function()
                self:updaterRun(latest, manifest, self_path)
            end,
        })
        return
    end

    local notes = type(latest.notes) == "string" and #latest.notes > 0
        and ("\n\n" .. latest.notes) or ""
    UIManager:show(ConfirmBox:new{
        text = string.format(self.loc:t("update_available"),
            latest.version, latest.local_version, #manifest.files) .. notes,
        ok_text = self.loc:t("update_install"),
        cancel_text = self.loc:t("cancel"),
        ok_callback = function()
            self:updaterRun(latest, manifest, nil)
        end,
    })
end

--[[
Download, verify, swap -- with the download in a sub-process.

Same shape as runFetch, and for the same reason: the download is the only part
that blocks, so it is the only part that is forked away. Verification and the
swap are filesystem work in the parent, which is also where the invariant
about the child not touching parent-visible state keeps them.
]]
function GrimoriaPlugin:updaterRun(latest, manifest, only_path)
    local Trapper = require("ui/trapper")

    Trapper:wrap(function()
        local ok, err = pcall(function()
            local n = only_path and 1 or #manifest.files
            Trapper:clear()
            local trap = self:makeCancelConfirmWidget(
                string.format(self.loc:t("update_downloading"), n),
                self.loc:t("update_cancel_confirm"),
                self.loc:t("fetch_cancel_yes"),
                self.loc:t("fetch_cancel_no"))
            UIManager:show(trap)
            UIManager:forceRePaint()

            local completed, result = Trapper:dismissableRunInSubprocess(function()
                return self:updaterDownload(latest, manifest, only_path)
            end, trap)
            trap:finish()

            if not completed then
                -- Nothing has been replaced yet, so a cancel here costs only
                -- the staging folder.
                rmrf(self:updaterPluginDir() .. "/" .. STAGING)
                say(self.loc:t("update_cancelled"), 3)
                return
            end
            if type(result) ~= "table" or not result.ok then
                rmrf(self:updaterPluginDir() .. "/" .. STAGING)
                say(self.loc:t("update_failed") .. "\n\n"
                    .. tostring(type(result) == "table" and result.err or result))
                return
            end

            local good, verr = self:updaterVerify(manifest, only_path)
            if not good then
                rmrf(self:updaterPluginDir() .. "/" .. STAGING)
                say(self.loc:t("update_failed") .. "\n\n" .. tostring(verr))
                return
            end

            local swapped, serr, stranded = self:updaterSwap(latest, manifest, only_path)
            if not swapped then
                if stranded then
                    -- The rollback could not finish either. Every file is
                    -- still in the backup folder, so name it: that is the
                    -- difference between a manual copy and a reinstall.
                    say(string.format(self.loc:t("update_rollback_failed"), stranded))
                else
                    say(self.loc:t("update_rolled_back") .. "\n\n" .. tostring(serr))
                end
                return
            end

            say(string.format(
                only_path and self.loc:t("update_bridge_done") or self.loc:t("update_installed"),
                latest.version))
        end)

        if not ok then
            logger.warn("Updater: run failed:", err)
            say(self.loc:t("update_failed") .. "\n\n" .. tostring(err))
        end
    end)
end

--[[
Put the previous version back.

The mirror image of the swap, and available at any time rather than only after
a failure: the update that installs cleanly and then misbehaves is the one a
reader actually needs an escape from. Everything currently installed is moved
into staging first, so a revert that fails halfway can itself be undone.
]]
function GrimoriaPlugin:revertLastUpdate()
    local ok, err = pcall(function()
        local dir = self:updaterPluginDir()
        local backup = dir .. "/" .. BACKUP
        if lfs.attributes(backup, "mode") ~= "directory" then
            say(self.loc:t("update_no_backup"), 4)
            return
        end

        UIManager:show(ConfirmBox:new{
            text = self.loc:t("update_revert_confirm"),
            ok_text = self.loc:t("update_revert"),
            cancel_text = self.loc:t("cancel"),
            ok_callback = function()
                local ok2, err2 = pcall(function() self:updaterRevertNow() end)
                if not ok2 then
                    logger.warn("Updater: revert failed:", err2)
                    say(self.loc:t("update_failed") .. "\n\n" .. tostring(err2))
                end
            end,
        })
    end)
    if not ok then
        logger.warn("Updater: revert check failed:", err)
        say(self.loc:t("update_failed") .. "\n\n" .. tostring(err))
    end
end

function GrimoriaPlugin:updaterRevertNow()
    local dir = self:updaterPluginDir()
    local backup, staging = dir .. "/" .. BACKUP, dir .. "/" .. STAGING

    rmrf(staging)
    mkdirp(staging)

    -- Current install out of the way, into staging.
    for _, rel in ipairs(listInstalled(dir)) do
        local to = staging .. "/" .. rel
        local parent = to:match("^(.*)/[^/]*$")
        if parent then mkdirp(parent) end
        os.rename(dir .. "/" .. rel, to)
    end

    -- Backup back in.
    local restored = 0
    for _, rel in ipairs(listInstalled(backup)) do
        local to = dir .. "/" .. rel
        local parent = to:match("^(.*)/[^/]*$")
        if parent then mkdirp(parent) end
        local ok = os.rename(backup .. "/" .. rel, to)
        if ok then restored = restored + 1 end
    end

    rmrf(backup)
    rmrf(staging)
    os.remove(dir .. "/" .. STATE)
    logger.info("Updater: reverted,", restored, "files restored")

    say(string.format(self.loc:t("update_reverted"), self:updaterLocalVersion()))
end

--[[
Called once from init(): did the last update survive its first start?

Reaching this line means the plugin loaded, its modules resolved and its
methods mixed in -- which is the only definition of "healthy" available
without a test suite on the device. The marker is cleared so the message is
shown once, and the backup is deliberately KEPT: it costs a few hundred
kilobytes and it is the whole of the revert path.
]]
function GrimoriaPlugin:updaterHealthCheck()
    local ok = pcall(function()
        local dir = self:updaterPluginDir()
        if not dir then return end
        local path = dir .. "/" .. STATE
        local f = io.open(path, "r")
        if not f then return end
        local body = f:read("*a")
        f:close()
        os.remove(path)

        local decoded = select(2, pcall(json.decode, body))
        if type(decoded) == "table" and decoded.to then
            logger.info("Updater: first start after updating",
                        tostring(decoded.from), "->", tostring(decoded.to), "-- healthy")
        else
            logger.info("Updater: first start after an update -- healthy")
        end
    end)
    if not ok then logger.warn("Updater: health check failed") end
end

return GrimoriaPlugin
