--[[
Menu construction: the main menu, the quick menu and the full menu.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

local GrimoriaPlugin = {}

function GrimoriaPlugin:getMenuCounts()
    self:applyChapterFilter()  -- refresh for the current chapter
    return {
        characters = self.characters and #self.characters or 0,
        locations = self.locations and #self.locations or 0,
        themes = self.themes and #self.themes or 0,
        timeline = self.timeline and #self.timeline or 0,
        historical_figures = self.historical_figures and #self.historical_figures or 0,
    }
end

function GrimoriaPlugin:addToMainMenu(menu_items)
    logger.info("GrimoriaPlugin: addToMainMenu called")
    
    self.ui:registerKeyEvents({
        ShowGrimoriaMenu = {
            { "Alt", "X" },
            event = "ShowGrimoriaMenu",
        },
    })
    
    
    menu_items.grimoria = {
        text = self.loc:t("menu_grimoria"),
        sorting_hint = "tools",
        callback = function()
            self:showGrimoriaDashboard("compact")
        end,
        hold_callback = function()
            self:showGrimoriaDashboard("full")
        end,

    }
    
    logger.info("GrimoriaPlugin: Menu item registered with native dashboard")
end

function GrimoriaPlugin:showLanguageSelection()
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    
    local current_lang = "en" -- Default
    if self.loc then
        current_lang = self.loc:getLanguage()
    end
    
    local function changeLang(lang_code, lang_name)
        UIManager:close(self.ldlg)
        
        if self.loc then 
            self.loc:setLanguage(lang_code) 
        end
        
        UIManager:show(InfoMessage:new{
            text = "✅" .. self.loc:t("language_changed") .. "\n\n" .. self.loc:t("please_restart"),
            timeout = 4 
        })
    end
    
    --[[
    Interface languages only. This is NOT the language the AI writes in --
    that follows the book's own language by default, and is overridden per
    device in settings/grimoria/output_language.txt. Someone reading Vietnamese
    books on an English interface is a normal setup, so the two never got
    tied together.

    Each entry needs a matching languages/<code>.po. Anything missing a key
    there falls back to the English string built into i18n.lua,
    so a partial translation degrades one line at a time rather than failing.
    ]]
    local languages = {
        { code = "en", label = "English" },
        { code = "vi", label = "Tiếng Việt" },
    }

    local buttons = {}
    for _, lang in ipairs(languages) do
        table.insert(buttons, {
            {
                text = lang.label .. (current_lang == lang.code and " ✓" or ""),
                callback = function() changeLang(lang.code, lang.label) end
            }
        })
    end

    self.ldlg = ButtonDialog:new{
        title = self.loc and self.loc:t("language_title") or "Select Language",
        buttons = buttons,
    }
    UIManager:show(self.ldlg)
end

function GrimoriaPlugin:showAbout()
    local TextViewer = require("ui/widget/textviewer")
    
    local about_viewer = TextViewer:new{
        title = self.loc:t("about_title"),
        text = self.loc:t("about_text"),
        justified = false,
    }
    
    UIManager:show(about_viewer)
end

function GrimoriaPlugin:toggleGrimoriaMode()
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("grimoria_mode_no_data"),
            timeout = 5,
        })
        return
    end
    
    self.grimoria_mode_enabled = not self.grimoria_mode_enabled
    
    if self.grimoria_mode_enabled then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("grimoria_mode_enabled"),
            timeout = 7,
        })
    else
        UIManager:show(InfoMessage:new{
            text = self.loc:t("grimoria_mode_disabled"),
            timeout = 3,
        })
    end
    
    logger.info("GrimoriaPlugin: reader mode:", self.grimoria_mode_enabled and "enabled" or "disabled")
end

function GrimoriaPlugin:showQuickGrimoriaMenu()
    self:showGrimoriaDashboard("compact")
end

function GrimoriaPlugin:showFullGrimoriaMenu()
    self:showGrimoriaDashboard("full")
end

function GrimoriaPlugin:onShowGrimoriaMenu()
    self:showGrimoriaDashboard("compact")
    return true
end

return GrimoriaPlugin
