--[[
Regression coverage for the spoiler-scope control.

The selected scope belongs to one book: whole-book mode must survive a fresh
plugin instance for that book, must not leak into another book, and the menu
must show the selected state before the user taps it.

  usage: lua test_scope.lua <plugin_dir>
]]
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(name, value) package.loaded[name] = value end

stub("logger", { info = function() end, warn = function() end,
                 error = function() end, dbg = function() end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })
local current_chapter = 2
stub("lib/booktext", { getCurrentChapterIndex = function() return current_chapter end })

local Spoilers = require("lib/spoilers")
local Menu = require("lib/ui/menu")

local fails = 0
local function check(condition, message)
    if not condition then fails = fails + 1 end
    print((condition and "  PASS  " or "  FAIL  ") .. message)
end

local function settingsFor(store)
    return {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
    }
end

local function newPlugin(store)
    local plugin = {
        loc = { t = function(_, key) return key end },
        ui = {
            doc_settings = settingsFor(store),
            registerKeyEvents = function() end,
        },
        book_data = {
            book_title = "T",
            chapters = {
                { index = 1, title = "One", summary = "One", events = {} },
                { index = 2, title = "Two", summary = "Two", events = {} },
            },
            characters = {}, locations = {}, themes = {}, timeline = {},
            historical_figures = {}, identity_merges = {}, quotes = {},
        },
    }
    for name, value in pairs(Spoilers) do plugin[name] = value end
    for name, value in pairs(Menu) do plugin[name] = value end
    plugin.getMenuCounts = function()
        return { characters = 0, locations = 0, themes = 0,
                 timeline = 0, historical_figures = 0 }
    end
    return plugin
end

local shown = {}
package.loaded["ui/uimanager"].show = function(_, widget) shown[#shown + 1] = widget end
local Views = require("lib/ui/views")

local function scopeMenuItem(plugin)
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    for _, item in ipairs(menu_items.grimoria.sub_item_table) do
        if item.text == "menu_toggle_scope" then return item end
        if item.text_func then
            local ok, text = pcall(item.text_func)
            if ok and (text == "menu_toggle_scope_on" or text == "menu_toggle_scope_off") then
                return item
            end
        end
    end
end

local function withViews(plugin)
    for name, value in pairs(Views) do plugin[name] = value end
    return plugin
end

print("=== an analysed book on chapter 1 explains the reading boundary ===")
current_chapter = 1
local chapter_one = withViews(newPlugin({}))
shown = {}
chapter_one:showCharacters()
check(#shown == 1 and shown[1].text == "showing_nothing_yet",
      "the empty character view says to finish chapter 1, not to analyse again (got "
      .. tostring(shown[1] and shown[1].text) .. ")")
current_chapter = 2

print("=== spoiler scope persists for the current book ===")
local first_book = {}
local first = newPlugin(first_book)
first:applyChapterFilter()
check(first.filter_chapter == 1, "a book starts spoiler-free")
first:toggleWholeBookView()
check(first_book.grimoria_show_whole_book == true,
      "whole-book mode is saved in the book settings")

local reopened = newPlugin(first_book)
reopened:applyChapterFilter()
check(reopened.filter_chapter == nil,
      "whole-book mode survives a fresh plugin instance")

print("\n=== whole-book mode does not carry into another book ===")
local other = newPlugin({})
other:applyChapterFilter()
check(other.filter_chapter == 1,
      "a different book still defaults to spoiler-free")

print("\n=== the menu shows the current value ===")
local item = scopeMenuItem(reopened)
check(item ~= nil, "the spoiler-scope menu item exists")
check(item and type(item.text_func) == "function",
      "the spoiler-scope menu item has dynamic text")
check(item and item.text_func and item.text_func() == "menu_toggle_scope_off",
      "whole-book mode is shown as spoiler filter off")

reopened:toggleWholeBookView()
check(first_book.grimoria_show_whole_book == false,
      "switching back saves spoiler-free mode")
local reopened_again = newPlugin(first_book)
reopened_again:applyChapterFilter()
check(reopened_again.filter_chapter == 1,
      "spoiler-free mode survives another fresh instance")
local on_item = scopeMenuItem(reopened_again)
check(on_item and on_item.text_func and on_item.text_func() == "menu_toggle_scope_on",
      "spoiler-free mode is shown as spoiler filter on")

print("\n=== toggling refreshes the open menu row ===")
local refreshes = 0
local touchmenu = {
    updateItems = function() refreshes = refreshes + 1 end,
}
on_item.callback(touchmenu)
check(refreshes == 1,
      "the open touch menu refreshes after the spoiler filter changes")
check(on_item.text_func() == "menu_toggle_scope_off",
      "the refreshed row immediately shows spoiler filter off")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
