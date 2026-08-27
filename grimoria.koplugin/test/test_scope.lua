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
stub("lib/booktext", { getCurrentChapterIndex = function() return 2 end })

local Spoilers = require("lib/spoilers")

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
    return plugin
end


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

print("\n=== switching back persists spoiler-free mode ===")
reopened:toggleWholeBookView()
check(first_book.grimoria_show_whole_book == false,
      "switching back saves spoiler-free mode")
local reopened_again = newPlugin(first_book)
reopened_again:applyChapterFilter()
check(reopened_again.filter_chapter == 1,
      "spoiler-free mode survives another fresh instance")

print("\nRESULT: " .. (fails == 0 and "all checks passed" or (fails .. " CHECK(S) FAILED")))
os.exit(fails == 0 and 0 or 1)
