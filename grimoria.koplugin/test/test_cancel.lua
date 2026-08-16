--[[
Behaviour of the cancel-confirmation widget, using the shipped main.lua.

What this pins down, all of it reported from a device or found while reading
KOReader's widget source:

  1. a tap ANYWHERE reaches the widget, including on its own message -- the
     reason this is a TrapWidget and not an InfoMessage, whose MovableContainer
     swallows taps that land on the box
  2. that tap opens a confirmation and does NOT kill the request
  3. only an explicit "Cancel analysis" kills it
  4. "Keep waiting" leaves the request running and a later tap still works
  5. a tap while the confirmation is already up does not stack a second one
  6. if the request finishes while the confirmation is up, answering it can no
     longer resume a coroutine that has already ended

  usage: lua test_cancel.lua <plugin_dir>
]]

local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end })
stub("lib/booktext", { getCurrentChapterIndex = function() return 1 end })

local WC = {}
function WC:new(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
stub("ui/widget/container/widgetcontainer", WC)

-- Records what the UI was asked to show and close.
local shown, closed = {}, {}
stub("ui/uimanager", {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) closed[#closed + 1] = w end,
    forceRePaint = function() end,
})

-- Stand-in for TrapWidget: the parts this subclass relies on are :extend,
-- :new, and _dismissAndResend being what every gesture handler funnels into.
local TrapWidget = {}
function TrapWidget:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
TrapWidget.new = TrapWidget.extend
-- The real widget binds tap/hold/swipe/key over the FULL screen, with no
-- movable container to swallow a tap on the message. Modelled here as: any
-- tap position at all reaches _dismissAndResend.
function TrapWidget:tapAt(_x, _y) return self:_dismissAndResend("Gesture", {}) end
stub("ui/widget/trapwidget", TrapWidget)

local ConfirmBox = {}
function ConfirmBox:new(o) o.is_confirm_box = true; return o end
stub("ui/widget/confirmbox", ConfirmBox)

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

local Grimoria = require("main")
local plugin = Grimoria:new{}

local killed = 0
local function newWidget()
    shown, closed = {}, {}
    killed = 0
    local w = plugin:makeCancelConfirmWidget("analysing", "Cancel it?", "Cancel analysis", "Keep waiting")
    -- Trapper overwrites dismiss_callback with its own coroutine resume; this
    -- stands in for that, and counts how often the request would be killed.
    w.dismiss_callback = function() killed = killed + 1 end
    return w
end

print("=== a tap on the message itself is caught ===")
local w = newWidget()
w:tapAt(300, 400)     -- dead centre, on top of where a popup would be
check(#shown == 1 and shown[1].is_confirm_box, "a confirmation is shown")
check(killed == 0, "the request is NOT killed by the tap alone")
check(w.confirm_box ~= nil, "the widget remembers its confirmation")

print("\n=== the confirmation's buttons ===")
check(shown[1].ok_text == "Cancel analysis",
      "the destructive choice is the ok button, needing a deliberate tap")
check(shown[1].cancel_text == "Keep waiting",
      "the safe choice is cancel, which is also what a tap outside triggers")
check(shown[1].flush_events_on_show == true,
      "the opening tap is flushed so it cannot answer the box")

print("\n=== a second tap while the confirmation is up ===")
w:tapAt(10, 10)
check(#shown == 1, "no second confirmation is stacked")

print("\n=== 'Keep waiting' ===")
shown[1].cancel_callback()
check(killed == 0, "the request is still running")
check(w.confirm_box == nil, "the widget forgets the dismissed box")
w:tapAt(300, 400)
check(#shown == 2 and killed == 0, "a later tap asks again rather than killing")

print("\n=== 'Cancel analysis' ===")
shown[2].ok_callback()
check(killed == 1, "the request is killed exactly once")

print("\n=== the request finishes on its own ===")
w = newWidget()
w:finish()
check(#closed == 1 and closed[1] == w, "the widget is closed")
w:tapAt(300, 400)
check(#shown == 0, "a tap after finishing does not offer to cancel")

print("\n=== it finishes while the confirmation is up ===")
w = newWidget()
w:tapAt(300, 400)
local box = shown[1]
w:finish()
check(closed[1] == box, "the stale confirmation is closed too")
box.ok_callback()
check(killed == 0, "answering it cannot resume a coroutine that already ended")

print()
print(fails == 0 and "RESULT: all checks passed" or ("RESULT: " .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
