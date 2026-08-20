--[[
"Look up in Grimoria" -- the entry in KOReader's own highlight menu.

The plugin's whole value is knowing who somebody is, and until now reaching
that meant leaving the page: menu, Grimoria, Characters, scroll, tap. By the
time a reader has done that twice they stop doing it, and an index nobody opens
is an index that was not worth paying an API for. Highlighting the name on the
page and asking is the gesture people already use for the dictionary.

It costs nothing and works with the radio off: the analysis is already on the
device, and this is a string comparison against it.

THREE RULES, and each one is load-bearing.

1. FILTER FIRST, ALWAYS. applyChapterFilter() runs before anything is matched,
   so the set searched is the set the reader has earned. Skip it and this
   becomes a spoiler oracle: highlight a name in chapter 3, get the card the
   model wrote for the whole book. It would also be the easiest possible way
   to test whether a character matters later -- ask, and see whether anything
   comes back.

2. NAMES AND ALIASES ONLY, NEVER DESCRIPTIONS. Searching prose sounds more
   helpful and is not: "he" and "the doctor" appear in half the cards, and a
   picker offering nine characters answers nothing. Matching identity strings
   keeps a hit meaningful.

3. WHOLE-WORD, CASE-INSENSITIVE, NOT DIACRITIC-FOLDED. lib/spoilerguard.lua
   carries the long version of why folding is wrong for Vietnamese; the short
   version is that "Văn", "Vấn" and "Van" are three different words. Its
   matcher is reused rather than reimplemented here, because two copies of a
   subtle rule become two different rules.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

--[[
A selection long enough to stop being a name.

Highlighting a paragraph and asking "who is in this" is a different feature
(that is Chapter Appearances), and running the matcher over one would return
most of the cast -- a picker as long as the character list, which is the list
the reader could have opened directly. Past this many bytes the lookup says so
instead of pretending.
]]
GrimoriaPlugin.LOOKUP_MAX_CHARS = 400

--[[
Register the highlight-menu entry.

Called from init(). Guarded twice over: ReaderHighlight does not exist for
every document type KOReader opens, and addToHighlightDialog is the kind of
host API that gets renamed between releases -- neither is a reason for the
whole plugin to fail to load, which is what an unguarded call here would do.

The index string decides where the button sits among KOReader's own; a high
number keeps it below Copy, Highlight and Dictionary, which are what most
highlights are actually for.
]]
function GrimoriaPlugin:registerHighlightLookup()
    if self._highlight_registered then return end
    if not (self.ui and self.ui.highlight and self.ui.highlight.addToHighlightDialog) then
        -- Not a failure, and not final: ReaderUI builds its own modules and its
        -- plugins in an order this plugin does not control, so ReaderHighlight
        -- may simply not exist yet. onReaderReady calls this again, by which
        -- point the reader view is fully built. A document type with no
        -- highlighting at all lands here twice and stays quiet, which is right.
        logger.info("GrimoriaPlugin: no highlight dialog to register with (yet)")
        return
    end

    local ok, err = pcall(function()
        self.ui.highlight:addToHighlightDialog("14_grimoria_lookup", function(this)
            return {
                text = self.loc:t("lookup_in_grimoria"),
                -- Hidden rather than greyed when the book has no analysis:
                -- an entry that is always present and never works reads as a
                -- broken plugin, and every other reader of this book has no
                -- reason to see it at all.
                show_in_highlight_dialog_func = function()
                    return self.book_data ~= nil
                end,
                callback = function()
                    local selected = this.selected_text and this.selected_text.text
                    -- Close the highlight dialog first: it is a modal, and a
                    -- card opened underneath it cannot be read or dismissed.
                    -- Guarded like the registration above, and for the same
                    -- reason: this is a host method name, and an error raised
                    -- inside a widget callback is not caught by anything.
                    pcall(function() this:onClose() end)
                    self:lookupInGrimoria(selected)
                end,
            }
        end)
    end)
    if ok then
        self._highlight_registered = true
    else
        logger.warn("GrimoriaPlugin: could not add the highlight entry:", err)
    end

    -- A long-press on a single word opens the dictionary popup, not the
    -- highlight dialog (KOReader setting "Dictionary on single word
    -- selection", on by default). Without this button, hold-on-name never
    -- reaches Grimoria. addToDictButtons is a newer host API; older
    -- KOReader builds just skip it.
    if self._dict_registered then return end
    if not (self.ui and self.ui.dictionary and self.ui.dictionary.addToDictButtons) then
        return
    end
    local dok, derr = pcall(function()
        self.ui.dictionary:addToDictButtons({
            id = "grimoria_lookup",
            menu_text = self.loc:t("lookup_in_grimoria"),
            text = self.loc:t("lookup_in_grimoria"),
            insert_first = true,
            show_func = function()
                return self.book_data ~= nil
            end,
            callback = function(dict_popup)
                local word = dict_popup
                    and (dict_popup.word or dict_popup.lookupword)
                pcall(function()
                    if dict_popup and dict_popup.onClose then
                        dict_popup:onClose()
                    end
                end)
                self:lookupInGrimoria(word)
            end,
        })
    end)
    if dok then
        self._dict_registered = true
    else
        logger.warn("GrimoriaPlugin: could not add the dictionary button:", derr)
    end
end

--[[
Every filtered character whose name or alias appears in `text`.

Returns the list in analysis order, each entry at most once however many of its
spellings matched.
]]
function GrimoriaPlugin:matchCharactersInSelection(text)
    local SpoilerGuard = require("lib/spoilerguard")
    local hits = {}
    if type(text) ~= "string" or #text == 0 then return hits end

    for _, char in ipairs(self.characters or {}) do
        local names = { char.name }
        for _, a in ipairs(char.aliases or {}) do names[#names + 1] = a end

        for _, n in ipairs(names) do
            if type(n) == "string" and #n > 0 and SpoilerGuard.mentions(text, n) then
                hits[#hits + 1] = char
                break
            end
        end
    end
    return hits
end

--[[
The lookup itself: none, one, or several.

"None" is the common case and is not an error -- the reader highlighted a word
that is not a name, or a character they have not been introduced to yet. The
message says the second thing without confirming it, because "not yet" and "not
a character" have to look identical from here: distinguishing them would tell a
reader on chapter three that the word they highlighted becomes somebody.
]]
function GrimoriaPlugin:lookupInGrimoria(text)
    if not self.book_data then
        UIManager:show(InfoMessage:new{ text = self.loc:t("no_character_data"), timeout = 3 })
        return
    end

    -- Rule 1: the set searched is the set the reader has earned.
    self:applyChapterFilter()

    if type(text) ~= "string" or #text == 0 then
        UIManager:show(InfoMessage:new{ text = self.loc:t("lookup_no_selection"), timeout = 3 })
        return
    end
    if #text > self.LOOKUP_MAX_CHARS then
        UIManager:show(InfoMessage:new{ text = self.loc:t("lookup_too_long"), timeout = 3 })
        return
    end

    local hits = self:matchCharactersInSelection(text)
    logger.info("GrimoriaPlugin: lookup on", #text, "chars matched", #hits, "character(s)")

    if #hits == 0 then
        UIManager:show(InfoMessage:new{ text = self.loc:t("lookup_nothing"), timeout = 3 })
        return
    end
    if #hits == 1 then
        self:showCharacterInfo(hits[1])
        return
    end

    local menu
    local items = {}
    for _, char in ipairs(hits) do
        local label = char.name or self.loc:t("unnamed_character")
        if char.role and #char.role > 0 then label = label .. " — " .. char.role end
        items[#items + 1] = {
            text = label,
            callback = function()
                UIManager:close(menu)
                self:showCharacterInfo(char)
            end,
        }
    end

    menu = Menu:new{
        title = self.loc:t("lookup_several"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

return GrimoriaPlugin
