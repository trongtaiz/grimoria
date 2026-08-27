--[[
Menu construction: the main menu, the quick menu and the full menu.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

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
    
    local counts = self:getMenuCounts()
    local function safe_t(key)
        if self.loc and self.loc.t then
            return self.loc:t(key) or key
        end
        return key
    end
    
    menu_items.grimoria = {
        text = self.loc:t("menu_grimoria"),
        sorting_hint = "tools",
        callback = function()
            self:showQuickGrimoriaMenu()
        end,
        hold_callback = function()
            self:showFullGrimoriaMenu()
        end,
        sub_item_table = {
            {
                text = self.loc:t("menu_characters") .. (counts.characters > 0 and " (" .. counts.characters .. ")" or ""),
                keep_menu_open = true,
                callback = function()
                    self:showCharacters()
                end,
            },
            {
                text = self.loc:t("menu_chapter_characters"),
                keep_menu_open = true,
                callback = function()
                    self:showChapterCharacters()
                end,
            },
            {
                text = self.loc:t("menu_appearances"),
                keep_menu_open = true,
                callback = function()
                    self:showAppearancesPicker()
                end,
            },
            {
                text = self.loc:t("menu_character_notes"),
                keep_menu_open = true,
                callback = function()
                    self:showCharacterNotes()
                end,
            },
            {
                text = self.loc:t("menu_timeline") .. (counts.timeline > 0 and " (" .. counts.timeline .. " " .. self.loc:t("events") .. ")" or ""),
                keep_menu_open = true,
                callback = function()
                    self:showTimeline()
                end,
            },
            { separator = true,},
            {
                text = self.loc:t("menu_historical_figures") .. (counts.historical_figures > 0 and " (" .. counts.historical_figures .. ")" or ""),
                keep_menu_open = true,
                callback = function()
                    self:showHistoricalFigures()
                end,
            },
            {
                text = self.loc:t("menu_locations") .. (counts.locations > 0 and " (" .. counts.locations .. ")" or ""),
                keep_menu_open = true,
                callback = function()
                    self:showLocations()
                end,
            },
            {
                text = self.loc:t("menu_author_info"),
                keep_menu_open = true,
                callback = function()
                    self:showAuthorInfo()
                end,
            },
            {
                text = self.loc:t("menu_summary"),
                keep_menu_open = true,
                callback = function()
                    self:showSummary()
                end,
            },
            {
                text = self.loc:t("menu_themes") .. (counts.themes > 0 and " (" .. counts.themes .. ")" or ""),
                keep_menu_open = true,
                callback = function()
                    self:showThemes()
                end,
            },
            { separator = true },
            {
                text = self.loc:t("menu_fetch_ai"),
                keep_menu_open = true,
                callback = function()
                    self:fetchFromAI()
                end,
            },
            {
                -- Sits directly under the ordinary fetch because it is the
                -- answer to that one failing on a very long book, and a reader
                -- who has just been told the reply was truncated should find
                -- it without going looking.
                text = self.loc:t("menu_fetch_range"),
                keep_menu_open = true,
                callback = function()
                    self:fetchChapterRange()
                end,
            },
            {
                -- Only lights up for an analysis made before the quotes field
                -- existed: one cheap request adds the list without re-buying
                -- the analysis. An analysis that has quotes hides it -- a
                -- re-analyse then keeps the existing list rather than asking
                -- again.
                text = self.loc:t("menu_extract_quotes"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.book_data ~= nil
                        and #(self.book_data.quotes or {}) == 0
                end,
                callback = function()
                    self:fetchQuotesOnly()
                end,
            },
            {
                text = self.loc:t("menu_ai_settings"),
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = self.loc:t("menu_gemini_key"), 
                        keep_menu_open = true,
                        callback = function()
                            self:setGeminiAPIKey()
                        end,
                    },
                    {
                        text = self.loc:t("menu_gemini_model"), 
                        keep_menu_open = true,
                        callback = function()
                            self:selectGeminiModel()
                        end,
                    },
                    { separator = true },
                    {
                        text = self.loc:t("menu_chatgpt_key"), 
                        keep_menu_open = true,
                        callback = function()
                            self:setChatGPTAPIKey()
                        end,
                    },
                    { separator = true },
                    {
                        text = "OpenRouter: API key",
                        keep_menu_open = true,
                        callback = function()
                            self:setProviderField("openrouter", "api_key", "OpenRouter API key",
                                "Your key from openrouter.ai/keys.\nStarts with sk-or-v1-")
                        end,
                    },
                    {
                        -- Shows the current slug in the menu line: on OpenRouter
                        -- the model is the whole decision, and it changes far
                        -- more often than the key does.
                        text_func = function()
                            local m = self:getProviderModel("openrouter")
                            return "OpenRouter: model" .. (m and (" (" .. m .. ")") or "")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:selectOpenRouterModel(touchmenu_instance)
                        end,
                    },
                    {
                        -- Shown on the line rather than hidden behind a tap:
                        -- this is the setting that decides whether the analysis
                        -- reads thought-through or shallow, and it costs money,
                        -- so it should never be a surprise what it is set to.
                        text_func = function()
                            return "OpenRouter: reasoning ("
                                .. self:getProviderEffort("openrouter") .. ")"
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:selectReasoningEffort("openrouter", touchmenu_instance)
                        end,
                    },
                    { separator = true },
                    {
                        text = "Custom AI: API key",
                        keep_menu_open = true,
                        callback = function()
                            self:setCustomField("api_key", "Custom AI API key",
                                "Key for any OpenAI-compatible endpoint\n(LiteLLM proxy, OpenRouter, GLM, local server).")
                        end,
                    },
                    {
                        text = "Custom AI: model",
                        keep_menu_open = true,
                        callback = function()
                            self:setCustomField("model", "Custom AI model",
                                "Model name as the endpoint spells it,\ne.g. gpt-4o-mini")
                        end,
                    },
                    {
                        text = "Custom AI: reasoning effort",
                        keep_menu_open = true,
                        callback = function()
                            self:setCustomField("reasoning_effort", "Reasoning effort",
                                "none / minimal / low / medium / high / xhigh\n\nLeave empty unless the model needs it. Some\nendpoints encode the effort in the model name\ninstead and reject this parameter.")
                        end,
                    },
                    {
                        text = "Custom AI: endpoint",
                        keep_menu_open = true,
                        callback = function()
                            self:setCustomField("endpoint", "Custom AI endpoint",
                                "Full chat-completions URL, ending in\n/v1/chat/completions")
                        end,
                    },
                    { separator = true },
                    {
                        text = self.loc:t("menu_provider_select"),
                        keep_menu_open = true,
                        callback = function()
                            self:selectAIProvider()
                        end,
                    },
                }
            },
            {separator = true,},
            {
                -- The spoiler filter is local, so this costs nothing and works
                -- offline -- it just switches which slice of the cached
                -- analysis the views read from.
                text_func = function()
                    local key = self:isWholeBookView()
                        and "menu_toggle_scope_off" or "menu_toggle_scope_on"
                    return self.loc:t(key)
                end,
                keep_menu_open = true,
                callback = function()
                    self:toggleWholeBookView()
                end,
            },
            {
                text = self.loc:t("menu_update_grimoria"),
                keep_menu_open = true,
                callback = function()
                    -- Deliberately does NOT clear the cache first.
                    --
                    -- It used to, because continueWithFetch refused to run
                    -- while any cache existed, so wiping it was the only way
                    -- to force a refresh. Now that a book can hold several
                    -- analyses that clear would destroy every one of them --
                    -- and because clearCache puts up its own ConfirmBox and
                    -- returns immediately, the fetch raced it: it started even
                    -- when the user cancelled the delete.
                    --
                    -- continueWithFetch now asks for confirmation itself and
                    -- keeps the existing versions alongside the new one.
                    self:fetchFromAI()
                end,
            },
            {
                text = self.loc:t("menu_versions"),
                keep_menu_open = true,
                callback = function()
                    self:showVersionPicker()
                end,
            },
            {
                text = self.loc:t("menu_clear_cache"),
                keep_menu_open = true,
                callback = function()
                    self:clearCache()
                end,
            },
            {
                text = self.loc:t("menu_grimoria_mode") .. " " .. (self.grimoria_mode_enabled and self.loc:t("grimoria_mode_active") or self.loc:t("grimoria_mode_inactive")),
                keep_menu_open = true,
                callback = function()
                    self:toggleGrimoriaMode()
                end,
            },
            {
                text = self.loc:t("menu_language"),
                keep_menu_open = true,
                callback = function()
                    self:showLanguageSelection()
                end,
            },
            { separator = true },
            {
                text = self.loc:t("menu_check_updates"),
                keep_menu_open = true,
                callback = function()
                    self:checkForUpdates()
                end,
            },
            {
                -- Only offered when there is something to go back to. Shown
                -- greyed rather than hidden would be worse: an entry that is
                -- always there and usually refuses reads as broken.
                text = self.loc:t("menu_revert_update"),
                keep_menu_open = true,
                enabled_func = function()
                    local lfs = require("libs/libkoreader-lfs")
                    local dir = self:updaterPluginDir()
                    return dir ~= nil
                        and lfs.attributes(dir .. "/.update-backup", "mode") == "directory"
                end,
                callback = function()
                    self:revertLastUpdate()
                end,
            },
            {
                text = self.loc:t("menu_about"),
                keep_menu_open = true,
                callback = function()
                    self:showAbout()
                end,
            },
        }
    }
    
    logger.info("GrimoriaPlugin: Menu item 'grimoria' added successfully with Gemini Model option")
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
    self:applyChapterFilter()  -- refresh for the current chapter
    local ButtonDialog = require("ui/widget/buttondialog")
    
    local buttons = {
        {
            {
                text = self.loc:t("menu_characters"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:showCharacters()
                end,
            },
        },
        {
            {
                text = self.loc:t("menu_chapter_characters"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:showChapterCharacters()
                end,
            },
        },
        {
            {
                text = self.loc:t("menu_timeline"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:showTimeline()
                end,
            },
        },
        {
            {
                text = self.loc:t("menu_historical_figures"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:showHistoricalFigures()
                end,
            },
        },
        {
            {
                text = self.loc:t("menu_character_notes"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:showCharacterNotes()
                end,
            },
        },
        {
            {
                text = self.loc:t("fetch_data"),
                callback = function()
                    UIManager:close(self.quick_dialog)
                    self:fetchFromAI()
                end,
            },
        },
    }
    
    self.quick_dialog = ButtonDialog:new{
        title = self.loc:t("quick_menu_title"),
        buttons = buttons,
    }
    
    UIManager:show(self.quick_dialog)
end

function GrimoriaPlugin:showFullGrimoriaMenu()
    self:applyChapterFilter()  -- refresh for the current chapter
    local menu_items = {}
    self:addToMainMenu(menu_items)
    
    if menu_items.grimoria and menu_items.grimoria.sub_item_table then
        self.full_menu = Menu:new{
            title = self.loc:t("menu_grimoria"),
            item_table = menu_items.grimoria.sub_item_table,
            is_borderless = true,
            is_popout = false,
            title_bar_fm_style = true,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        }
        UIManager:show(self.full_menu)
    end
end

function GrimoriaPlugin:onShowGrimoriaMenu()
    self:showQuickGrimoriaMenu()
    return true
end

return GrimoriaPlugin
