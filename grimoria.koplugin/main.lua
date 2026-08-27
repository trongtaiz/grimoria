--[[
Grimoria -- plugin entry point.

KOReader loads exactly this file, so it is the one filename the project does
not choose. It stays a shell: the class, the mixin that assembles it from
lib/, initialisation, and the Dispatcher actions that let gestures and the
key map reach the menus. Behaviour belongs in lib/.

The version lives in _meta.lua, which is what KOReader reads; repeating it
here would only give it somewhere to go stale.
]]

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
mixin(GrimoriaPlugin, require("lib/ui/dashboard"), "lib/ui/dashboard")
mixin(GrimoriaPlugin, require("lib/ui/settings"), "lib/ui/settings")
mixin(GrimoriaPlugin, require("lib/ui/versions"), "lib/ui/versions")
mixin(GrimoriaPlugin, require("lib/ui/notes"), "lib/ui/notes")
mixin(GrimoriaPlugin, require("lib/ui/views"), "lib/ui/views")
mixin(GrimoriaPlugin, require("lib/ui/lookup"), "lib/ui/lookup")
mixin(GrimoriaPlugin, require("lib/ui/appearances"), "lib/ui/appearances")
mixin(GrimoriaPlugin, require("lib/updater"), "lib/updater")

function GrimoriaPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    
    -- Load localization module
    local Localization = require("lib/i18n")
    self.loc = Localization
    self.loc:init() -- Load saved language preference
    
    self:onDispatcherRegisterActions()

    -- The entry in KOReader's own highlight menu. Registered here rather than
    -- in onReaderReady because ReaderHighlight is built with the reader view,
    -- and a button added after the first highlight of the session would be
    -- missing exactly when someone first goes looking for it.
    self:registerHighlightLookup()

    -- Reaching this line means the plugin loaded and every module resolved,
    -- which is the only "the update worked" signal available on a device with
    -- no console. Clears the marker the updater left; keeps the backup.
    self:updaterHealthCheck()

    logger.info("GrimoriaPlugin: Initialized with language:", self.loc:getLanguage())
end

function GrimoriaPlugin:onReaderReady()
    -- Second attempt at the highlight-menu entry. init() runs while ReaderUI is
    -- still assembling itself and the order it builds its modules in is not
    -- this plugin's to depend on, so ReaderHighlight may not have existed yet.
    -- The call is a no-op once it has taken.
    self:registerHighlightLookup()

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

return GrimoriaPlugin
