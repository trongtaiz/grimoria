-- Native dashboard contract: mode contents, AI priority, and fixed page sizes.
-- usage: lua test_dashboard.lua <plugin_dir>
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(name, value) package.loaded[name] = value end
local shown = {}
local closed = 0
stub("ui/uimanager", {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() closed = closed + 1 end,
})
stub("device", { screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    scaleBySize = function(n) return n end,
} })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/widget/button", { new = function(_, o) return o end })
stub("ui/widget/container/leftcontainer", { new = function(_, o) return o end })
stub("ui/widget/container/rightcontainer", { new = function(_, o) return o end })
stub("ui/widget/titlebar", { new = function(_, o)
    function o:getHeight() return 72 end
    return o
end })
stub("ui/widget/menu", { new = function(_, o)
    function o:updateItems() self.updated = true end
    return o
end })
stub("libs/libkoreader-lfs", { attributes = function() return nil end })

local dashboard = require("lib/ui/dashboard")
local plugin = {
    loc = { t = function(_, key) return key end },
    characters = {}, locations = {}, themes = {}, timeline = {}, historical_figures = {},
    getLLM = function()
        return {
            default_provider = "openrouter",
            providers = { openrouter = { model = "google/gemini-3.7-flash" } },
        }
    end,
    applyChapterFilter = function() end,
    getMenuCounts = function()
        return { characters = 24, locations = 12, themes = 7, timeline = 18, historical_figures = 5 }
    end,
    describeScope = function() return "spoiler-safe" end,
    updaterPluginDir = function() return "/plugin" end,
    isWholeBookView = function() return false end,
}
setmetatable(plugin, { __index = dashboard })

local failures = 0
local function check(condition, message)
    if not condition then failures = failures + 1 end
    print((condition and "  PASS  " or "  FAIL  ") .. message)
end

print("=== compact dashboard ===")
plugin:showGrimoriaDashboard("compact")
local compact = shown[#shown]
check(compact.items_per_page == 4, "four native rows per compact page")
check(compact.is_enable_shortcut == false, "keyboard shortcut boxes stay hidden in the emulator")
check(#compact.item_table == 6, "compact keeps six priority features")
check(compact.item_table[4].text == "menu_ai_settings", "AI service is on compact page one")
check(compact.item_table[4].mandatory_func() == "OpenRouter", "AI row keeps its provider label short")
check(compact.custom_title_bar.title == "menu_grimoria · Compact", "title shows Compact selected")

print("\n=== full dashboard ===")
compact.custom_title_bar.right_icon_tap_callback()
local full = shown[#shown]
check(closed == 1, "mode switch closes the previous dashboard")
check(full.items_per_page == 6, "six native rows per full page")
check(#full.item_table == 23, "full mode preserves all 23 features")
check(full.item_table[2].text == "menu_ai_settings", "AI service is on full page one")
check(full.custom_title_bar.title == "menu_grimoria · Full", "title shows Full selected")

print("\nRESULT: " .. (failures == 0 and "all checks passed" or (failures .. " CHECK(S) FAILED")))
os.exit(failures == 0 and 0 or 1)
