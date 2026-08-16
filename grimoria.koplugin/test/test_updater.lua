--[[
The self-updater, proven against the failure that actually matters.

An update that goes wrong does not produce a stack trace a reader can send
back. It produces a Kindle whose plugin no longer loads, with the paid
analyses still on it and no console to find out why. So the property under
test here is not "the happy path works" -- it is:

    AT NO POINT IS ANY FILE MISSING, AND ANY FAILURE LEAVES THE OLD
    VERSION COMPLETE.

That cannot be tested against a real filesystem, because the interesting case
is a rename failing halfway through and real renames do not fail on demand. So
this runs the updater against an in-memory filesystem it cannot tell from the
real one, and injects the failure exactly where it hurts.

  usage: lua test_updater.lua <plugin_dir>
]]
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

-- ------------------------------------------------------ in-memory files ----

local FS = { files = {}, dirs = {}, fail_rename_after = nil, renames = 0 }

local function norm(p)
    p = tostring(p):gsub("\\", "/")
    while p:find("//") do p = p:gsub("//", "/") end
    return p
end

function FS:reset()
    self.files, self.dirs = {}, {}
    self.fail_rename_after, self.renames = nil, 0
end

function FS:write(path, body)
    path = norm(path)
    self.files[path] = body
    local parent = path:match("^(.*)/[^/]*$")
    while parent and #parent > 0 do
        self.dirs[parent] = true
        parent = parent:match("^(.*)/[^/]*$")
    end
end

--[[
Every path under `root`. `installed_only` skips the updater's own workspace,
which is what "the version that is installed" means -- a snapshot that counted
the staging folder would report a successful cleanup as a lost file.
]]
function FS:under(root, installed_only)
    root = norm(root) .. "/"
    local out = {}
    for p in pairs(self.files) do
        if p:sub(1, #root) == root then
            local rel = p:sub(#root + 1)
            if not (installed_only and rel:match("^%.update%-")) then
                out[#out + 1] = rel
            end
        end
    end
    table.sort(out)
    return out
end

local lfs_stub = {
    mkdir = function(p) FS.dirs[norm(p)] = true return true end,
    rmdir = function(p) FS.dirs[norm(p)] = nil return true end,
    attributes = function(p, what)
        p = norm(p)
        local mode, size
        if FS.files[p] then mode, size = "file", #FS.files[p]
        elseif FS.dirs[p] then mode, size = "directory", 0
        else return nil end
        if what == "mode" then return mode end
        if what == "size" then return size end
        return { mode = mode, size = size }
    end,
    dir = function(p)
        p = norm(p)
        local seen, kids = {}, { ".", ".." }
        local prefix = p .. "/"
        local function note(child)
            local head = child:match("^([^/]+)")
            if head and not seen[head] then
                seen[head] = true
                kids[#kids + 1] = head
            end
        end
        for f in pairs(FS.files) do
            if f:sub(1, #prefix) == prefix then note(f:sub(#prefix + 1)) end
        end
        for d in pairs(FS.dirs) do
            if d:sub(1, #prefix) == prefix then note(d:sub(#prefix + 1)) end
        end
        local i = 0
        return function() i = i + 1 return kids[i] end
    end,
}

local real_io_open, real_rename, real_remove = io.open, os.rename, os.remove

local function install_fs_stubs()
    io.open = function(path, mode)
        path = norm(path)
        mode = mode or "r"
        if mode:find("r") then
            local body = FS.files[path]
            if not body then return nil, "no such file" end
            return {
                read = function(_, fmt)
                    if fmt == "*a" or fmt == "a" or fmt == nil then return body end
                    return body
                end,
                close = function() return true end,
            }
        end
        local buf = {}
        return {
            write = function(_, s) buf[#buf + 1] = s return true end,
            close = function() FS:write(path, table.concat(buf)) return true end,
        }
    end

    os.rename = function(a, b)
        a, b = norm(a), norm(b)
        FS.renames = FS.renames + 1
        -- fail_rename_at fails exactly one rename, which is the realistic
        -- shape of the problem: one path that cannot be written, not a
        -- filesystem that has stopped working entirely. (The genuinely
        -- unrecoverable case -- every rename failing, disk full or mounted
        -- read-only -- is what fail_rename_after models, and there the
        -- updater's job is to report where the files are, not to recover.)
        if FS.fail_rename_at and FS.renames == FS.fail_rename_at then
            return nil, "injected failure"
        end
        if FS.fail_rename_after and FS.renames > FS.fail_rename_after then
            return nil, "injected failure"
        end
        if not FS.files[a] then return nil, "no such file" end
        FS.files[b] = FS.files[a]
        FS.files[a] = nil
        local parent = b:match("^(.*)/[^/]*$")
        if parent then FS.dirs[parent] = true end
        return true
    end

    os.remove = function(p)
        p = norm(p)
        FS.files[p] = nil
        FS.dirs[p] = nil
        return true
    end
end

local function restore_fs_stubs()
    io.open, os.rename, os.remove = real_io_open, real_rename, real_remove
end

-- ---------------------------------------------------------------- stubs ----

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("ui/uimanager", { show = function() end, close = function() end,
                       forceRePaint = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("libs/libkoreader-lfs", lfs_stub)
stub("ltn12", {})
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end })
stub("ssl.https", {})
stub("socket.http", {})
stub("lib/paths", { readSetting = function() return nil end })

-- A JSON stub is enough here: the updater only round-trips its own state file,
-- and the manifest bodies are handed to it already decoded in these tests.
stub("json", {
    encode = function(t)
        local bits = {}
        for k, v in pairs(t) do
            bits[#bits + 1] = string.format("%q:%s", k,
                type(v) == "string" and string.format("%q", v) or tostring(v))
        end
        return "{" .. table.concat(bits, ",") .. "}"
    end,
    decode = function(s)
        local out = {}
        for k, v in s:gmatch('"([^"]+)":"([^"]*)"') do out[k] = v end
        for k, v in s:gmatch('"([^"]+)":(%d+)') do out[k] = tonumber(v) end
        return out
    end,
})

install_fs_stubs()
local Updater = require("lib/updater")
local plugin = setmetatable({ path = "/plug/grimoria.koplugin",
                              loc = { t = function(_, k) return k end } },
                            { __index = Updater })

-- ------------------------------------------------------------- fixtures ----

local PLUG = "/plug/grimoria.koplugin"

-- Version 1.0.0 as installed, including a file the next release drops and a
-- test/ directory no release ever ships.
local function makeInstall()
    FS:reset()
    FS:write(PLUG .. "/main.lua",            "OLD main")
    FS:write(PLUG .. "/_meta.lua",           'return { version = "1.0.0" }')
    FS:write(PLUG .. "/config.lua",          "return {}")
    FS:write(PLUG .. "/lib/spoilers.lua",    "OLD spoilers")
    FS:write(PLUG .. "/lib/ui/views.lua",    "OLD views")
    FS:write(PLUG .. "/lib/removed.lua",     "OLD removed")   -- gone in 2.0.0
    FS:write(PLUG .. "/test/test_x.lua",     "harness")       -- never touched
end

-- Version 2.0.0, already downloaded into the staging folder.
local NEW = {
    ["main.lua"]         = "NEW main",
    ["_meta.lua"]        = 'return { version = "2.0.0" }',
    ["config.lua"]       = "return {}",
    ["lib/spoilers.lua"] = "NEW spoilers",
    ["lib/ui/views.lua"] = "NEW views",
    ["lib/updater.lua"]  = "NEW updater",                     -- added in 2.0.0
}

local function makeStaging()
    for rel, body in pairs(NEW) do
        FS:write(PLUG .. "/.update-staging/" .. rel, body)
    end
end

local function manifest()
    local files = {}
    for rel, body in pairs(NEW) do
        files[#files + 1] = { path = rel, size = #body }
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return { contract = 1, version = "2.0.0", files = files }
end

local LATEST = { version = "2.0.0", local_version = "1.0.0", tag = "v2.0.0" }

-- ------------------------------------------------------ version compare ----

print("=== version comparison ===")
local cmp = function(a, b) return plugin:updaterCompareVersions(a, b) end
check(cmp("3.1.0", "3.0.0") > 0, "3.1.0 is newer than 3.0.0")
check(cmp("3.0.0", "3.1.0") < 0, "3.0.0 is older than 3.1.0")
check(cmp("3.1", "3.1.0") == 0, "3.1 and 3.1.0 are the same version")
check(cmp("3.10.0", "3.9.0") > 0, "3.10.0 beats 3.9.0 (numeric, not lexical)")
check(cmp("4.0.0", "3.99.99") > 0, "a major bump wins")
check(cmp("3.0.1", "3.0.1") == 0, "equal versions compare equal")
-- An unparseable version must not read as newer; that direction would install
-- a release over a good one on the strength of a typo.
check(cmp("", "3.0.0") < 0, "an empty version is not newer than anything")

-- --------------------------------------------------- manifest hardening ----

print("\n=== a manifest cannot reach outside the plugin folder ===")
do
    local decoded = {
        contract = 1,
        files = {
            { path = "main.lua", size = 5 },
            { path = "../../../etc/passwd", size = 5 },
            { path = "/etc/shadow", size = 5 },
            { path = "C:/Windows/system32/x.dll", size = 5 },
            { path = "lib/ok.lua", size = 5 },
            "not even a table",
        },
    }
    -- updaterFetchManifest does the sanitising after decoding; drive it
    -- through the same filter by handing it a decoding json stub.
    package.loaded["json"].decode = function() return decoded end
    local saved_get = plugin.updaterFetchManifest
    -- httpGet is a local, so stub the transport it uses instead.
    package.loaded["ssl.https"].request = function(t)
        t.sink("{}")
        return 1, 200, {}
    end
    package.loaded["ltn12"] = { sink = { table = function(tbl)
        return function(chunk) if chunk then tbl[#tbl + 1] = chunk end return 1 end
    end, file = function() return function() return 1 end end } }

    local m = plugin:updaterFetchManifest({ repo = "a/b", tag = "v2", local_version = "1.0.0" })
    check(m ~= nil, "a manifest with bad entries still yields the good ones")
    if m then
        local kept = {}
        for _, f in ipairs(m.files) do kept[f.path] = true end
        check(kept["main.lua"] and kept["lib/ok.lua"], "ordinary paths are kept")
        check(not kept["../../../etc/passwd"], "a ../ escape is rejected")
        check(not kept["/etc/shadow"], "an absolute path is rejected")
        check(not kept["C:/Windows/system32/x.dll"], "a drive-letter path is rejected")
        check(#m.files == 2, "only the two safe entries survive (kept " .. #m.files .. ")")
    end
    plugin.updaterFetchManifest = saved_get
end

-- ---------------------------------------------------------- verification ----

print("\n=== verification refuses a truncated download ===")
do
    makeInstall(); makeStaging()
    local m = manifest()
    local ok = plugin:updaterVerify(m)
    check(ok, "a complete staging folder verifies")

    FS:write(PLUG .. "/.update-staging/main.lua", "trunc")   -- wrong size
    local ok2, err = plugin:updaterVerify(m)
    check(not ok2, "a wrong-sized file fails verification")
    check(tostring(err):find("main.lua", 1, true) ~= nil,
          "the error names the file (" .. tostring(err) .. ")")

    makeStaging()
    FS.files[norm(PLUG .. "/.update-staging/lib/spoilers.lua")] = nil
    local ok3 = plugin:updaterVerify(m)
    check(not ok3, "a missing file fails verification")
end

-- ------------------------------------------------------------ the swap ----

print("\n=== a clean swap ===")
do
    makeInstall(); makeStaging()
    local ok, err = plugin:updaterSwap(LATEST, manifest())
    check(ok, "the swap reports success (" .. tostring(err) .. ")")

    check(FS.files[PLUG .. "/main.lua"] == "NEW main", "main.lua is the new one")
    check(FS.files[PLUG .. "/lib/ui/views.lua"] == "NEW views", "a nested file is the new one")
    check(FS.files[PLUG .. "/lib/updater.lua"] == "NEW updater", "a file added by the release is installed")

    -- The release drops lib/removed.lua. It must be gone from the install and
    -- still present in the backup -- that is what makes a revert complete.
    check(FS.files[PLUG .. "/lib/removed.lua"] == nil, "a file dropped by the release is gone")
    check(FS.files[PLUG .. "/.update-backup/lib/removed.lua"] == "OLD removed",
          "...but kept in the backup")
    check(FS.files[PLUG .. "/.update-backup/main.lua"] == "OLD main", "the old main.lua is in the backup")

    check(FS.files[PLUG .. "/test/test_x.lua"] == "harness", "test/ is left alone")
    check(FS.files[PLUG .. "/.update-backup/test/test_x.lua"] == nil, "test/ is not backed up either")

    check(FS.files[PLUG .. "/.update-state.json"] ~= nil, "the health marker is written")
    check(next(FS:under(PLUG .. "/.update-staging")) == nil, "staging is cleaned up")
end

--[[
The one that matters.

A rename fails partway through installing the staged files -- the moment when
some of the new version is in place and some of the old version is sitting in
the backup. If the updater gets this wrong, the plugin folder is a mixture of
two versions and KOReader cannot load it.
]]
print("\n=== a failure mid-swap leaves the OLD version complete ===")
do
    makeInstall(); makeStaging()
    local before = {}
    for _, rel in ipairs(FS:under(PLUG, true)) do
        before[rel] = FS.files[PLUG .. "/" .. rel]
    end

    -- The old files are moved aside first (6 renames), so failing the 9th
    -- lands squarely in the install phase: some of version 2.0.0 is already
    -- in place and all of version 1.0.0 is sitting in the backup. This is the
    -- exact instant at which a mistake produces an unloadable plugin.
    FS.fail_rename_at = 9
    local ok, err = plugin:updaterSwap(LATEST, manifest())
    FS.fail_rename_at = nil

    check(not ok, "the swap reports failure (" .. tostring(err) .. ")")

    local intact, missing, wrong = true, {}, {}
    for rel, body in pairs(before) do
        local now = FS.files[PLUG .. "/" .. rel]
        if now == nil then
            intact = false
            missing[#missing + 1] = rel
        elseif now ~= body then
            intact = false
            wrong[#wrong + 1] = rel
        end
    end
    check(intact, "every file of version 1.0.0 is back, byte for byte"
          .. (#missing > 0 and ("  MISSING: " .. table.concat(missing, ", ")) or "")
          .. (#wrong > 0 and ("  WRONG: " .. table.concat(wrong, ", ")) or ""))

    -- And nothing from the new version is left lying around in the install.
    local contaminated = {}
    for rel in pairs(NEW) do
        local now = FS.files[PLUG .. "/" .. rel]
        if now and now:find("^NEW") then contaminated[#contaminated + 1] = rel end
    end
    check(#contaminated == 0, "no file from the failed release survives in the install"
          .. (#contaminated > 0 and ("  (" .. table.concat(contaminated, ", ") .. ")") or ""))

    check(FS.files[PLUG .. "/.update-state.json"] == nil,
          "no health marker is written for an update that did not happen")
end

--[[
And the case that cannot be recovered from: the filesystem stops accepting
renames entirely, so the rollback cannot run either. Nothing can put the files
back at that point -- but claiming "rolled back" when the folder is half empty
is the one outcome that turns a bad update into an unexplainable one. The
contract is that the swap says so, and hands back the path everything is
sitting in.
]]
print("\n=== an unrecoverable filesystem is reported, not hidden ===")
do
    makeInstall(); makeStaging()
    FS.fail_rename_after = 8
    local ok, err, stranded = plugin:updaterSwap(LATEST, manifest())
    FS.fail_rename_after = nil

    check(not ok, "the swap reports failure")
    check(stranded ~= nil, "and returns where the files are (" .. tostring(stranded) .. ")")
    check(tostring(stranded):find(".update-backup", 1, true) ~= nil,
          "which is the backup folder")

    -- The point of naming it: everything really is there to copy back.
    local recoverable = true
    for _, rel in ipairs({ "main.lua", "_meta.lua", "lib/spoilers.lua", "lib/ui/views.lua" }) do
        if FS.files[PLUG .. "/.update-backup/" .. rel] == nil
            and FS.files[PLUG .. "/" .. rel] == nil then
            recoverable = false
        end
    end
    check(recoverable, "every file of the old version is recoverable by hand")
end

-- ----------------------------------------------------------- the revert ----

print("\n=== revert puts the previous version back ===")
do
    makeInstall(); makeStaging()
    local before = {}
    for _, rel in ipairs(FS:under(PLUG, true)) do
        before[rel] = FS.files[PLUG .. "/" .. rel]
    end

    check(plugin:updaterSwap(LATEST, manifest()), "updated to 2.0.0 first")
    plugin:updaterRevertNow()

    local restored, bad = true, {}
    for rel, body in pairs(before) do
        if FS.files[PLUG .. "/" .. rel] ~= body then
            restored = false
            bad[#bad + 1] = rel
        end
    end
    check(restored, "version 1.0.0 is back, byte for byte"
          .. (#bad > 0 and ("  (" .. table.concat(bad, ", ") .. ")") or ""))
    check(FS.files[PLUG .. "/lib/updater.lua"] == nil,
          "a file the release ADDED is removed again by the revert")
    check(FS.files[PLUG .. "/.update-state.json"] == nil, "the health marker is cleared")
    check(lfs_stub.attributes(PLUG .. "/.update-backup", "mode") ~= "directory",
          "the backup is consumed by the revert")
end

-- ------------------------------------------------- nothing outside PLUG ----

print("\n=== nothing outside the plugin folder is ever touched ===")
do
    makeInstall(); makeStaging()
    FS:write("/plug/settings/grimoria/openrouter_api_key.txt", "sk-secret")
    FS:write("/books/novel.sdr/grimoria_cache_1.lua", "a paid analysis")
    FS:write("/plug/settings/xray/language.txt", "vi")   -- the pre-rename fallback

    plugin:updaterSwap(LATEST, manifest())
    plugin:updaterRevertNow()

    check(FS.files["/plug/settings/grimoria/openrouter_api_key.txt"] == "sk-secret",
          "settings survive an update and a revert")
    check(FS.files["/books/novel.sdr/grimoria_cache_1.lua"] == "a paid analysis",
          "a stored analysis survives")
    check(FS.files["/plug/settings/xray/language.txt"] == "vi",
          "lib/paths.lua's pre-rename fallback directory is untouched")
end

-- ------------------------------------------------------- health marker ----

print("\n=== the health check clears its marker exactly once ===")
do
    makeInstall()
    FS:write(PLUG .. "/.update-state.json", '{"from":"1.0.0","to":"2.0.0"}')
    plugin:updaterHealthCheck()
    check(FS.files[PLUG .. "/.update-state.json"] == nil, "the marker is cleared on the first start")
    -- A second call with no marker must be a no-op, not an error: this runs on
    -- every single plugin load.
    local ok = pcall(function() plugin:updaterHealthCheck() end)
    check(ok, "a start with no marker is a quiet no-op")
end

-- --------------------------------------------------- repo configuration ----

print("\n=== an unconfigured repository is refused ===")
do
    local cases = {
        { "YOUR-GITHUB-USERNAME/grimoria.koplugin", false, "the shipped placeholder" },
        { "", false, "an empty setting" },
        { "https://github.com/owner/name", false, "a full URL" },
        { "owner", false, "a bare owner with no repository" },
        { "owner/name", true, "a real owner/name" },
        { "some-user/grimoria.koplugin", true, "a fork" },
    }
    for _, c in ipairs(cases) do
        package.loaded["lib/paths"].readSetting = function() return c[1] end
        local got = plugin:updaterRepo()
        check((got ~= nil) == c[2], c[3] .. " -> " .. (got and "accepted" or "refused"))
    end
    package.loaded["lib/paths"].readSetting = function() return nil end
end

restore_fs_stubs()
print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
