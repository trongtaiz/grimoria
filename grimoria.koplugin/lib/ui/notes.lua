--[[
The reader's own notes on a character, stored per book.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

function GrimoriaPlugin:showCharacterNotes()
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_char_data_fetch"), 
            timeout = 3,
        })
        return
    end
    
    if not self.notes_manager then
        local Marginalia = require("lib/marginalia")
        self.notes_manager = Marginalia:new()
    end
    
    local book_path = self.ui.document.file
    self.marginalia = self.notes_manager:loadNotes(book_path)
    
    local items = {}
    local notes_count = 0
    
    for _, char in ipairs(self.characters) do
        local char_name = char.name or self.loc:t("unknown_character")
        local note = self.notes_manager:getNote(self.marginalia, char.name)
        if note then
            notes_count = notes_count + 1
            
            local note_preview = note.text or ""
            if #note_preview > 50 then
                note_preview = string.sub(note_preview, 1, 50) .. "..."
            end
            
            table.insert(items, {
                text = "📝 " .. char_name .. "\n   " .. note_preview,
                callback = function()
                    self:showCharacterWithNote(char, note)
                end,
            })
        end
    end
    
    if notes_count > 0 then
        table.insert(items, {            
            separator = true,
        })
    end
    
    for _, char in ipairs(self.characters) do
        local char_name = char.name or self.loc:t("unknown_character")
        local note = self.notes_manager:getNote(self.marginalia, char.name)
        if not note then
            table.insert(items, {
                text = "➕ " .. char_name .. " (" .. self.loc:t("add_note") .. ")",
                callback = function()
                    self:addCharacterNote(char)
                end,
            })
        end
    end
    
    local menu = Menu:new{
        title = string.format(self.loc:t("character_notes_title"), notes_count),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(menu)
end

function GrimoriaPlugin:showCharacterWithNote(char, note)
    local InputDialog = require("ui/widget/inputdialog")
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = "📝 " .. char.name,
        input = note.text,
        input_hint = self.loc:t("note_hint"),
        buttons = {
            {
                {
                    text = self.loc:t("cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = self.loc:t("delete"),
                    callback = function()
                        self:deleteCharacterNote(char)
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = self.loc:t("save"),
                    is_enter_default = true,
                    callback = function()
                        local new_note = input_dialog:getInputText()
                        self:updateCharacterNote(char, new_note)
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimoriaPlugin:addCharacterNote(char)
    local InputDialog = require("ui/widget/inputdialog")
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = string.format(self.loc:t("add_note_title"), char.name),
        input = "",
        input_hint = self.loc:t("note_hint"),
        buttons = {
            {
                {
                    text = self.loc:t("cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = self.loc:t("save"),
                    is_enter_default = true,
                    callback = function()
                        local note_text = input_dialog:getInputText()
                        if note_text and #note_text > 0 then
                            self:updateCharacterNote(char, note_text)
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimoriaPlugin:updateCharacterNote(char, note_text)
    if not self.notes_manager then
        return
    end
    
    self.notes_manager:setNote(self.marginalia, char.name, note_text)
    
    local book_path = self.ui.document.file
    self.notes_manager:saveNotes(book_path, self.marginalia)
    
    UIManager:show(InfoMessage:new{
        text = string.format(self.loc:t("note_saved"), char.name),
        timeout = 2,
    })
end

function GrimoriaPlugin:deleteCharacterNote(char)
    if not self.notes_manager then
        return
    end
    
    self.notes_manager:deleteNote(self.marginalia, char.name)
    
    local book_path = self.ui.document.file
    self.notes_manager:saveNotes(book_path, self.marginalia)
    
    UIManager:show(InfoMessage:new{
        text = string.format(self.loc:t("note_deleted"), char.name),
        timeout = 2,
    })
    
    self:showCharacterNotes()
end

return GrimoriaPlugin
