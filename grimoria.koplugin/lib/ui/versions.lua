--[[
Stored analyses: several per book, switchable offline.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

function GrimoriaPlugin:autoLoadCache()
    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end

    local book_path = self.ui.document.file
    logger.info("GrimoriaPlugin: Auto-loading cache for:", book_path)
    local cached_data = self.archive:loadCache(book_path)

    if cached_data then
        self.book_data = cached_data
        self:applyChapterFilter()
        if cached_data.author_info then
            self.author_info = cached_data.author_info
        else
            -- Flat shape instead of nested (an author_bio field is present)
            self.author_info = {
                name = cached_data.author,
                description = cached_data.author_bio,
                birthDate = cached_data.author_birth,
                deathDate = cached_data.author_death
            }
        end
        local cache_age = math.floor((os.time() - cached_data.cached_at) / 86400)
        
        logger.info("GrimoriaPlugin: Auto-loaded from cache -", #self.characters, "characters,", 
                    cache_age, "days old")
        
        if #self.characters > 0 then
            self.grimoria_mode_enabled = true
            logger.info("GrimoriaPlugin: reader mode auto-enabled")
        end
        
        local scope = ""
        if self.filter_chapter then
            scope = "\n" .. string.format(self.loc:t("showing_up_to_chapter"), self.filter_chapter)
        end

        UIManager:show(InfoMessage:new{
            text = self.loc:t("grimoria_ready") .. "\n\n" ..
                   "👥 " .. #self.characters .. " " .. self.loc:t("characters_loaded") .. "\n" ..
                   "📍 " .. #self.locations .. " " .. self.loc:t("locations_loaded") .. "\n" ..
                   "🎨 " .. #self.themes .. " " .. self.loc:t("themes_loaded") ..
                   scope,
            timeout = 3,
        })
    else
        logger.info("GrimoriaPlugin: No cache found for auto-load")
    end
end

--[[
Re-read whatever analysis is now active and refresh the views.

Deliberately not autoLoadCache: that one announces itself with a counts popup
and flips grimoria_mode on, which is right when a book opens and wrong when the
reader is already standing in the version picker. It also does nothing when no
cache is found, which would leave the deleted analysis still on screen after
removing the last version.
]]
function GrimoriaPlugin:reloadActiveVersion()
    if not self.ui or not self.ui.document then return false end
    local data = self.archive:loadCache(self.ui.document.file)

    if not data then
        self.book_data = nil
        self.characters, self.locations, self.themes = {}, {}, {}
        self.timeline, self.historical_figures = {}, {}
        self.summary, self.author_info = nil, nil
        return false
    end

    self.book_data = data
    self:applyChapterFilter()
    if data.author_info then
        self.author_info = data.author_info
    else
        self.author_info = {
            name = data.author,
            description = data.author_bio,
        }
    end
    return true
end

--[[
One line per stored analysis, so two runs are distinguishable at a glance:

    > gpt-5.5-high - 14 Aug 00:52 - 56 ch, 21 chars, 2 merges
      gemini-3.6-flash - 13 Aug 22:51 - 56 ch, 15 chars, 1 merge

Caches written before versioning carry no model, and guessing from the current
settings would be confidently wrong for any analysis made with another model,
so they read "unknown model" until renamed.
]]
function GrimoriaPlugin:describeVersion(v, is_active)
    local name = v.label or v.model
    if not name or #name == 0 then name = self.loc:t("unknown_model_version") end
    if v.effort and #v.effort > 0 and not v.label then
        name = name .. " @" .. v.effort
    end

    local when = v.created_at and v.created_at > 0
        and os.date("%d %b %H:%M", v.created_at) or "?"

    local stats = string.format("%d ch, %d chars", v.chapters or 0, v.characters or 0)
    if (v.merges or 0) > 0 then
        stats = stats .. string.format(", %d merges", v.merges)
    end

    -- Literal UTF-8, not a "\u{2713}" escape: that is Lua 5.3 syntax and
    -- KOReader runs LuaJIT, where it fails to parse and takes the whole
    -- plugin down at load time.
    return (is_active and "✓ " or "   ") .. name .. " - " .. when .. " - " .. stats
end

-- Switch between stored analyses. Entirely local: no API call, works offline.
function GrimoriaPlugin:showVersionPicker()
    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end
    if not self.ui or not self.ui.document then return end

    local book_path = self.ui.document.file
    local versions, active_id = self.archive:listVersions(book_path)

    if #versions == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_versions"),
            timeout = 3,
        })
        return
    end

    local menu
    local items = {}
    for _, v in ipairs(versions) do
        local is_active = (v.id == active_id)
        table.insert(items, {
            text = self:describeVersion(v, is_active),
            callback = function()
                if menu then UIManager:close(menu) end
                if is_active then return end
                if self.archive:setActiveVersion(book_path, v.id) then
                    self:reloadActiveVersion()
                    UIManager:show(InfoMessage:new{
                        text = string.format(self.loc:t("version_switched"),
                            v.label or v.model or self.loc:t("unknown_model_version")),
                        timeout = 3,
                    })
                end
            end,
            hold_callback = function()
                if menu then UIManager:close(menu) end
                self:showVersionActions(book_path, v)
            end,
        })
    end

    menu = Menu:new{
        title = self.loc:t("versions_title"),
        subtitle = self.loc:t("versions_hint"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

-- Rename / delete, reached by holding an entry.
function GrimoriaPlugin:showVersionActions(book_path, v)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = self:describeVersion(v, false),
        buttons = {
            {{
                text = self.loc:t("version_rename"),
                callback = function()
                    UIManager:close(dlg)
                    self:renameVersionDialog(book_path, v)
                end,
            }},
            {{
                text = self.loc:t("version_delete"),
                callback = function()
                    UIManager:close(dlg)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = self.loc:t("version_delete_confirm"),
                        ok_text = self.loc:t("version_delete"),
                        cancel_text = self.loc:t("cancel"),
                        ok_callback = function()
                            self.archive:deleteVersion(book_path, v.id)
                            -- The active analysis may have just been removed;
                            -- reload so the views follow whatever took over.
                            self:reloadActiveVersion()
                            self:showVersionPicker()
                        end,
                    })
                end,
            }},
            {{
                text = self.loc:t("cancel"),
                callback = function()
                    UIManager:close(dlg)
                    self:showVersionPicker()
                end,
            }},
        },
    }
    UIManager:show(dlg)
end

function GrimoriaPlugin:renameVersionDialog(book_path, v)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = self.loc:t("version_rename"),
        input = v.label or v.model or "",
        description = self.loc:t("version_rename_desc"),
        buttons = {{
            {
                text = self.loc:t("cancel"),
                callback = function()
                    UIManager:close(dlg)
                    self:showVersionPicker()
                end,
            },
            {
                text = self.loc:t("save"),
                is_enter_default = true,
                callback = function()
                    local label = dlg:getInputText()
                    UIManager:close(dlg)
                    self.archive:renameVersion(book_path, v.id, label)
                    self:showVersionPicker()
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function GrimoriaPlugin:clearCache()
    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end
    
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = self.loc:t("cache_clear_confirm"),
        ok_text = self.loc:t("yes_clear"),
        cancel_text = self.loc:t("cancel"),
        ok_callback = function()
            local book_path = self.ui.document.file
            local success = self.archive:clearCache(book_path)
            
            if success then
                self.book_data = nil
                self.characters = {}
                self.locations = {}
                self.themes = {}
                self.summary = nil
                self.author_info = nil
                self.timeline = {}
                self.historical_figures = {}
                
                UIManager:show(InfoMessage:new{
                    text = self.loc:t("cache_cleared"),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = self.loc:t("cache_not_found"),
                    timeout = 3,
                })
            end
        end,
    })
end

return GrimoriaPlugin
