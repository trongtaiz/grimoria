--[[
Native full-screen Grimoria dashboard.

The HTML prototype settled the information hierarchy; this is the KOReader
implementation. It deliberately uses Menu's own paginator so the page controls
remain anchored to the bottom edge on every screen size and font setting.
]]
local GrimoriaPlugin = {}

local PROVIDER_LABELS = {
    openrouter = "OpenRouter",
    custom = "Custom endpoint",
    gemini = "Google Gemini",
    chatgpt = "ChatGPT",
}

local function providerSummary(self)
    local llm = self:getLLM()
    local id = self.ai_provider or llm.default_provider or "openrouter"
    local cfg = llm.providers[id] or {}
    local label = PROVIDER_LABELS[id] or cfg.name or id
    if cfg.model and cfg.model ~= "" then
        return label .. " · " .. cfg.model
    end
    return label
end

local function providerLabel(self)
    local summary = providerSummary(self)
    return summary:match("^(.-) · ") or summary
end

local function hasUpdateBackup(self)
    local lfs = require("libs/libkoreader-lfs")
    local dir = self:updaterPluginDir()
    return dir ~= nil and lfs.attributes(dir .. "/.update-backup", "mode") == "directory"
end

function GrimoriaPlugin:showGrimoriaDashboard(mode)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local TitleBar = require("ui/widget/titlebar")
    local UIManager = require("ui/uimanager")

    self:applyChapterFilter()
    mode = mode == "full" and "full" or mode == "compact" and "compact"
        or self.grimoria_dashboard_mode or "compact"
    self.grimoria_dashboard_mode = mode

    local counts = self:getMenuCounts()
    local quotes_available = self.book_data ~= nil and #(self.book_data.quotes or {}) == 0
    local revert_available = hasUpdateBackup(self)
    local menu

    local function closeThen(callback)
        return function()
            UIManager:close(menu)
            callback()
        end
    end

    local function toggleAndRefresh(callback)
        return function()
            callback()
            menu:updateItems()
        end
    end

    local items = {
        {
            text = self.loc:t("menu_characters"),
            mandatory = counts.characters > 0 and tostring(counts.characters) or nil,
            bold = true,
            callback = closeThen(function() self:showCharacters() end),
        },
        {
            text = self.loc:t("menu_ai_settings"),
            mandatory_func = function() return providerLabel(self) end,
            bold = true,
            callback = closeThen(function() self:showAISettings() end),
        },
        {
            text = self.loc:t("menu_chapter_characters"),
            callback = closeThen(function() self:showChapterCharacters() end),
        },
        {
            text = self.loc:t("menu_timeline"),
            mandatory = counts.timeline > 0 and tostring(counts.timeline) or nil,
            callback = closeThen(function() self:showTimeline() end),
        },
        {
            text = self.loc:t("menu_appearances"),
            callback = closeThen(function() self:showAppearancesPicker() end),
        },
        {
            text = self.loc:t("menu_character_notes"),
            callback = closeThen(function() self:showCharacterNotes() end),
        },
        {
            text = self.loc:t("menu_summary"),
            callback = closeThen(function() self:showSummary() end),
        },
        {
            text = self.loc:t("menu_locations"),
            mandatory = counts.locations > 0 and tostring(counts.locations) or nil,
            callback = closeThen(function() self:showLocations() end),
        },
        {
            text = self.loc:t("menu_themes"),
            mandatory = counts.themes > 0 and tostring(counts.themes) or nil,
            callback = closeThen(function() self:showThemes() end),
        },
        {
            text = self.loc:t("menu_historical_figures"),
            mandatory = counts.historical_figures > 0 and tostring(counts.historical_figures) or nil,
            callback = closeThen(function() self:showHistoricalFigures() end),
        },
        {
            text = self.loc:t("menu_author_info"),
            callback = closeThen(function() self:showAuthorInfo() end),
        },
        {
            text = "Re-analyse this book",
            callback = closeThen(function() self:fetchFromAI() end),
        },
        {
            text = "Analysis versions",
            callback = closeThen(function() self:showVersionPicker() end),
        },
        {
            text = self.loc:t("menu_fetch_ai"),
            callback = closeThen(function() self:fetchFromAI() end),
        },
        {
            text = self.loc:t("menu_fetch_range"),
            callback = closeThen(function() self:fetchChapterRange() end),
        },
        {
            text = "Extract quotes (AI)",
            dim = not quotes_available,
            select_enabled_func = function() return quotes_available end,
            callback = closeThen(function() self:fetchQuotesOnly() end),
        },
        {
            text = "Spoiler filter",
            mandatory_func = function() return self:isWholeBookView() and "OFF" or "ON" end,
            callback = toggleAndRefresh(function() self:toggleWholeBookView() end),
        },
        {
            text = self.loc:t("menu_grimoria_mode"),
            mandatory_func = function() return self.grimoria_mode_enabled and "ON" or "OFF" end,
            callback = toggleAndRefresh(function() self:toggleGrimoriaMode() end),
        },
        {
            text = self.loc:t("menu_language"),
            callback = closeThen(function() self:showLanguageSelection() end),
        },
        {
            text = self.loc:t("menu_check_updates"),
            callback = closeThen(function() self:checkForUpdates() end),
        },
        {
            text = self.loc:t("menu_revert_update"),
            dim = not revert_available,
            select_enabled_func = function() return revert_available end,
            callback = closeThen(function() self:revertLastUpdate() end),
        },
        {
            text = self.loc:t("menu_about"),
            callback = closeThen(function() self:showAbout() end),
        },
        {
            text = self.loc:t("menu_clear_cache"),
            callback = closeThen(function() self:clearCache() end),
        },
    }

    if mode == "compact" then
        items = { items[1], items[12], items[13], items[2], items[17], items[20] }
    end

    local target_mode = mode == "compact" and "Full" or "Compact"
    local title_bar = TitleBar:new{
        width = Screen:getWidth(),
        fullscreen = true,
        title = self.loc:t("menu_grimoria") .. " · " .. (mode == "compact" and "Compact" or "Full"),
        subtitle = providerSummary(self) .. " · top-right: " .. target_mode,
        with_bottom_line = true,
        left_icon = "chevron.left",
        left_icon_tap_callback = function() UIManager:close(menu) end,
        right_icon = "appbar.menu",
        right_icon_tap_callback = function()
            UIManager:close(menu)
            self:showGrimoriaDashboard(mode == "compact" and "full" or "compact")
        end,
    }
    menu = Menu:new{
        custom_title_bar = title_bar,
        item_table = items,
        items_per_page = mode == "compact" and 4 or 6,
        single_line = true,
        is_enable_shortcut = false,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    self.grimoria_dashboard = menu
    UIManager:show(menu)
end

return GrimoriaPlugin
