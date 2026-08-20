--[[
The plugin's methods live in eight lib/ modules and are mixed onto the class in
main.lua. That mixin is load-bearing and completely silent when it goes wrong:
a module left out of the list, or a method renamed on one side only, produces a
plugin that loads perfectly and then fails with "attempt to call a nil value"
the moment someone opens that particular menu.

So: load main.lua for real and assert every method the UI dispatches to is
actually present and callable.

  usage: lua test_wiring.lua <plugin_dir>
]]
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end,
                       scheduleIn = function() end, nextTick = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("ui/widget/buttondialog", { new = function(_, o) return o end })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("ui/widget/inputdialog", { new = function(_, o) return o end })
stub("ui/widget/textviewer", { new = function(_, o) return o end })
stub("ui/widget/trapwidget", { new = function(_, o) return o end })
stub("ui/trapper", {})
stub("ui/network/manager", {})
stub("dispatcher", { registerAction = function() end })
stub("docsettings", {})
stub("util", {})
stub("socket", {}); stub("socketutil", {}); stub("pluginshare", {})
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end,
                              attributes = function() return nil end,
                              dir = function() return function() return nil end end })
local WC = {}
function WC:new(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
stub("ui/widget/container/widgetcontainer", WC)

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

print("=== main.lua loads with every lib/ module mixed in ===")
local ok, Plugin = pcall(require, "main")
check(ok, "main.lua loads (" .. (ok and "ok" or tostring(Plugin)) .. ")")
if not ok then
    print("\nRESULT: 1 CHECK(S) FAILED")
    os.exit(1)
end

--[[
Every method the plugin dispatches to, grouped by the module it now lives in.
Written out by hand rather than derived from the source: a list generated from
the same files it is checking would agree with them even when both are wrong.
]]
local EXPECTED = {
    ["main.lua (shell)"] = {
        "init", "onReaderReady", "onDispatcherRegisterActions",
        "onShowGrimoriaQuickMenu", "onShowGrimoriaFullMenu", "onShowGrimoriaCharacters",
        "onShowGrimoriaChapterCharacters", "onShowGrimoriaTimeline",
        "onShowGrimoriaHistorical", "onShowGrimoriaThemes", "onShowGrimoriaLocations",
    },
    ["lib/spoilers"] = { "applyChapterFilter", "toggleWholeBookView",
                         "spoilerIncludesCurrentChapter", "describeScope",
                         "chapterScheme", "exportQuotesSidecar" },
    ["lib/fetch"] = {
        "fetchFromAI", "getMaxCharsSetting", "askSpoilerPreference", "holdDeviceAwake",
        "releaseDeviceAwake", "continueWithFetch", "makeCancelConfirmWidget",
        "runFetch", "getReadingProgress", "fetchChapterRange", "pickChapter",
    },
    ["lib/ui/menu"] = {
        "addToMainMenu", "getMenuCounts", "showQuickGrimoriaMenu", "showFullGrimoriaMenu",
        "onShowGrimoriaMenu", "showLanguageSelection", "showAbout", "toggleGrimoriaMode",
    },
    ["lib/ui/settings"] = {
        "selectGeminiModel", "setGeminiAPIKey", "setChatGPTAPIKey", "getLLM",
        "getProviderModel", "getProviderEffort", "setProviderField", "setCustomField",
        "selectOpenRouterModel", "selectReasoningEffort", "selectAIProvider",
    },
    ["lib/ui/versions"] = {
        "reloadActiveVersion", "describeVersion", "showVersionPicker",
        "showVersionActions", "renameVersionDialog", "clearCache", "autoLoadCache",
    },
    ["lib/ui/notes"] = {
        "showCharacterNotes", "showCharacterWithNote", "addCharacterNote",
        "updateCharacterNote", "deleteCharacterNote",
    },
    ["lib/ui/views"] = {
        "showCharacters", "showCharacterDetails", "showCharacterInfo",
        "showCharacterSearch", "findCharacterByName", "showLocations", "showAuthorInfo",
        "showSummary", "showThemes", "showTimeline", "showHistoricalFigures",
        "showHistoricalFigureDetails", "showChapterCharacters", "showLongText",
    },
    ["lib/ui/lookup"] = {
        "registerHighlightLookup", "matchCharactersInSelection", "lookupInGrimoria",
    },
    ["lib/ui/appearances"] = {
        "appearanceScope", "reportAppearanceProblem", "showChapterAppearances",
        "renderAppearances", "jumpToChapter", "showAppearancesPicker",
    },
    ["lib/updater"] = {
        "checkForUpdates", "checkForUpdatesInner", "updaterRun", "updaterHealthCheck",
        "revertLastUpdate", "updaterRevertNow", "updaterPluginDir", "updaterRepo",
        "updaterLocalVersion", "updaterCompareVersions", "updaterFetchRelease",
        "updaterFetchManifest", "updaterDownload", "updaterVerify", "updaterSwap",
    },
}

local order = {
    "main.lua (shell)", "lib/spoilers", "lib/fetch", "lib/ui/menu",
    "lib/ui/settings", "lib/ui/versions", "lib/ui/notes", "lib/ui/views",
    "lib/ui/lookup", "lib/ui/appearances", "lib/updater",
}

local total = 0
for _, group in ipairs(order) do
    local missing = {}
    for _, name in ipairs(EXPECTED[group]) do
        total = total + 1
        if type(Plugin[name]) ~= "function" then
            table.insert(missing, name)
        end
    end
    check(#missing == 0, group .. ": " .. #EXPECTED[group] .. " methods present" ..
          (#missing > 0 and (" -- MISSING: " .. table.concat(missing, ", ")) or ""))
end

--[[
66 from the split, plus 15 for lib/updater, 2 for the current-chapter rule,
1 for showLongText, 3 for lib/ui/lookup, 6 for lib/ui/appearances, 2 for
the chapter-range fetch, 1 for chapterScheme, and 1 for exportQuotesSidecar
(the AI-quotes feed for the sleep-screen patch).

66, not 67, at the split: main.lua had 67 top-level blocks before it, and
exactly one of them -- fuseCharacters -- is a plain local rather than a method.
If this number ever drops, a method was dropped on the floor by an edit to the
mixin list; if it climbs without this line being updated deliberately, someone
added a method without deciding which module owns it.
]]
print("\n=== the split did not drop anything ===")
check(total == 97, "97 methods accounted for across 11 files (counted " .. total .. ")")

-- fuseCharacters is a file-local in lib/spoilers.lua, deliberately not a method.
check(Plugin.fuseCharacters == nil,
      "fuseCharacters stays private to lib/spoilers.lua")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
