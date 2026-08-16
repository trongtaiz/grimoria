-- Grimoria Plugin for KOReader v2.0.0

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = WidgetContainer:new{
    name = "grimoria",
    is_doc_only = true,
}

--[[
The plugin's behaviour lives in lib/, split by what it is rather than by what
it draws. Each module returns a plain table of methods which are copied onto
the class here, so `self` means the same thing everywhere and a call site does
not care which file its method came from.

A mixin rather than composition (`self.views:show(...)`) on purpose: these are
one object's methods that grew too numerous for one file, not collaborating
objects. Splitting them into real components would mean every one of them
needing a back-reference to the plugin to reach self.book_data, self.loc and
the filtered view -- more machinery, no more clarity.

Load order does not matter; the tables are disjoint, and mixin() says so out
loud rather than letting a silent overwrite decide.
]]
local function mixin(target, source, origin)
    for name, fn in pairs(source) do
        if target[name] ~= nil then
            error("Grimoria: '" .. name .. "' defined twice, second in " .. origin)
        end
        target[name] = fn
    end
end

mixin(GrimoriaPlugin, require("lib/spoilers"), "lib/spoilers")
mixin(GrimoriaPlugin, require("lib/fetch"), "lib/fetch")
mixin(GrimoriaPlugin, require("lib/ui/menu"), "lib/ui/menu")
mixin(GrimoriaPlugin, require("lib/ui/settings"), "lib/ui/settings")
mixin(GrimoriaPlugin, require("lib/ui/versions"), "lib/ui/versions")
mixin(GrimoriaPlugin, require("lib/ui/notes"), "lib/ui/notes")
mixin(GrimoriaPlugin, require("lib/ui/views"), "lib/ui/views")

function GrimoriaPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    
    -- Load localization module
    local Localization = require("lib/i18n")
    self.loc = Localization
    self.loc:init() -- Load saved language preference
    
    self:onDispatcherRegisterActions()
    
    logger.info("GrimoriaPlugin v1.0.0: Initialized with language:", self.loc:getLanguage())
end

function GrimoriaPlugin:onReaderReady()
    -- Auto-load cache when book is opened
    self:autoLoadCache()
end

function GrimoriaPlugin:onDispatcherRegisterActions()
    
    local Dispatcher = require("dispatcher")
    
    -- Grimoria Quick Menu action
    Dispatcher:registerAction("grimoria_quick_menu", {
        category = "none",
        event = "ShowGrimoriaQuickMenu",
        title = self.loc:t("quick_menu_title") or "Grimoria Quick Menu",
        general = true,
        separator = true,
    })
    
    -- Grimoria Characters action
    Dispatcher:registerAction("grimoria_characters", {
        category = "none",
        event = "ShowGrimoriaCharacters",
        title = self.loc:t("menu_characters") or "Characters",
        general = true,
    })
    
    -- Grimoria Chapter Characters action
    Dispatcher:registerAction("grimoria_chapter_characters", {
        category = "none",
        event = "ShowGrimoriaChapterCharacters",
        title = self.loc:t("menu_chapter_characters") or "Chapter Characters",
        general = true,
    })
    
    -- Grimoria Timeline action
    Dispatcher:registerAction("grimoria_timeline", {
        category = "none",
        event = "ShowGrimoriaTimeline",
        title = self.loc:t("menu_timeline") or "Timeline",
        general = true,
    })
    
    -- Grimoria Historical Figures action
    Dispatcher:registerAction("grimoria_historical", {
        category = "none",
        event = "ShowGrimoriaHistorical",
        title = self.loc:t("menu_historical_figures") or "Historical Figures",
        general = true,
    })

    -- Grimoria Themes action
    Dispatcher:registerAction("grimoria_themes", {
        category = "none",
        event = "ShowGrimoriaThemes",
        title = self.loc:t("menu_themes") or "Themes",
        general = true,
    })    
    
    -- Grimoria Locations action
    Dispatcher:registerAction("grimoria_locations", {
        category = "none",
        event = "ShowGrimoriaLocations",
        title = self.loc:t("menu_locations") or "Locations",
        general = true,
    }) 
end

-- Event handlers for Dispatcher actions
function GrimoriaPlugin:onShowGrimoriaQuickMenu()
    self:showQuickGrimoriaMenu()
    return true
end

function GrimoriaPlugin:onShowGrimoriaFullMenu()
    self:showFullGrimoriaMenu()
    return true
end

function GrimoriaPlugin:onShowGrimoriaCharacters()
    self:showCharacters()
    return true
end

function GrimoriaPlugin:onShowGrimoriaChapterCharacters()
    self:showChapterCharacters()
    return true
end

function GrimoriaPlugin:onShowGrimoriaTimeline()
    self:showTimeline()
    return true
end

function GrimoriaPlugin:onShowGrimoriaHistorical()
    self:showHistoricalFigures()
    return true
end

function GrimoriaPlugin:onShowGrimoriaThemes()
    self:showThemes()
    return true
end

function GrimoriaPlugin:onShowGrimoriaLocations()
    self:showLocations()
    return true
end

--[[
Apply the reading-position filter to the analysis.

The AI is asked once, for the whole book, and returns everything tagged by
chapter. Hiding what the reader hasn't reached is then a local operation: no
network, no quota, and it updates by itself as they read on.

self.book_data holds the full analysis; self.characters/timeline/... hold the
filtered view the UI reads. Every view calls this before showing anything.
]]
--[[
Fuse identities that the text has already connected.

Books hide people behind aliases and anonymous scenes, so the analysis lists
one entry per TEXTUAL IDENTITY (the mystery man / Van / Morisu are three
characters). Each identity_merges entry names the chapter where the text
itself makes the connection; from that chapter on, the member entries become
one fused card. Before it, they stay unrelated -- that separation IS the
spoiler protection.

limit == nil means "the whole book": every merge applies.
]]


-- Toggle between "up to where I am" and the complete analysis.



-- Get current reading progress (works for EPUB, PDF, MOBI, etc.)







-- Read the extraction cap from settings/grimoria/max_text_chars.txt, same
-- convention as gemini_model.txt and output_language.txt.

--[[
There is no longer a spoiler-free / full-book choice to make: the whole book
is analysed once, and how much of it gets shown is decided locally from the
reading position. So this is now a single confirmation, whose job is to tell
the user what the request will cost before they spend it.
]]

--[[
Keep the device awake for as long as a fetch is running.

A whole-book analysis runs for minutes -- the worst case seen in practice is
~19 minutes. Left alone the device reaches its sleep timeout partway through,
and with "disable Wi-Fi when sleeping" turned on the socket dies with it: the
request is lost after the tokens have already been spent, and the reader comes
back to a dead connection they can't get out of.

Mirrors what KOReader's own KeepAlive plugin does, per platform:

  Kindle    lipc preventScreenSaver, plus PluginShare.keepalive so AutoSuspend
            stops resetting the system t1 timeout -- resetting it while the
            screensaver is disabled is what AutoSuspend itself warns crashes.
  others    PluginShare.pause_auto_suspend, which AutoSuspend checks before
            calling UIManager:suspend() on every platform.

Counted rather than boolean-flagged is unnecessary here: only one fetch can be
in flight, since the UI that starts it is modal.
]]



--[[
The "analysing…" widget shown while the request is in flight, and the
confirmation that guards cancelling it.

Neither widget Trapper accepts is right on its own:

  InfoMessage puts its text inside a MovableContainer, which swallows taps on
  the message itself. Its tap range is the whole screen, so tapping BESIDE the
  box works while tapping ON it appears to do nothing -- which reads as a
  frozen screen, the exact impression this whole change exists to remove.

  TrapWidget does catch taps anywhere, including on its own message, but
  dismissableRunInSubprocess kills the sub-process the instant one lands. One
  stray tap would then throw away a twenty-minute job with no warning.

So: a TrapWidget with the dismissal intercepted to ask first. Trapper
overwrites dismiss_callback with its own resume function, which is fine --
what this subclass changes is WHEN that callback fires, not what it does.

The ConfirmBox has ok and cancel reversed, the same way Trapper:info does it:
tapping outside a ConfirmBox triggers cancel, so cancel must be the harmless
choice. Throwing the analysis away takes a deliberate tap on the button.
]]

-- The fetch itself. Split out of continueWithFetch so the sleep-hold above can
-- wrap it in a pcall; runs inside Trapper:wrap, so it may yield.




--[[
Re-read whatever analysis is now active and refresh the views.

Deliberately not autoLoadCache: that one announces itself with a counts popup
and flips grimoria_mode on, which is right when a book opens and wrong when the
reader is already standing in the version picker. It also does nothing when no
cache is found, which would leave the deleted analysis still on screen after
removing the last version.
]]

--[[
One line per stored analysis, so two runs are distinguishable at a glance:

    > gpt-5.5-high - 14 Aug 00:52 - 56 ch, 21 chars, 2 merges
      gemini-3.6-flash - 13 Aug 22:51 - 56 ch, 15 chars, 1 merge

Caches written before versioning carry no model, and guessing from the current
settings would be confidently wrong for any analysis made with another model,
so they read "unknown model" until renamed.
]]

-- Switch between stored analyses. Entirely local: no API call, works offline.

-- Rename / delete, reached by holding an entry.








-- Make sure the LLM module is loaded, and hand it back.


-- Unset and "none" are the same wire behaviour -- no reasoning field, provider
-- default thinking -- so they read back as one state. Not called "off": the
-- endpoint refuses to switch thinking off at all.

--[[
Edit one field of one OpenAI-compatible provider.

One dialog per field rather than a combined one: the endpoint and model are
set once and then never touched, while the key is what people actually come
back to. Each writes through to settings/grimoria/<provider>_<field>.txt so it
survives a plugin re-copy.
]]

-- Kept as the name the Custom AI menu entries already call.

--[[
Pick an OpenRouter model.

A shortlist plus a free-text entry, because OpenRouter carries 400+ models and
new ones appear weekly -- a fixed list would be wrong within a month, and
typing a full slug on an e-ink keyboard is miserable. The shortlist is only
what is worth running a whole book through: long input, cheap enough to redo,
and reliable at emitting JSON.
]]

--[[
How hard the model should think before it answers.

A picker rather than the free-text box the custom provider uses, because here
the value is worth getting right and a typo is expensive: an endpoint that
validates the field rejects the whole request, and one that doesn't silently
ignores it, so a misspelling either wastes a fetch or quietly turns thinking
off while the menu claims it is on.

The wording puts the trade-off on the buttons. Every level above "off" is
billed as output tokens on top of the answer, and the levels share the output
budget with the answer itself -- which is why a whole-book fetch that gets cut
off steps this down before it starts trimming the result.
]]




















return GrimoriaPlugin

