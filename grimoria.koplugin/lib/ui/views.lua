--[[
The read-only screens. Every one of them renders the FILTERED view
(self.characters and friends), never self.book_data, so nothing here
can leak past the reader's current chapter.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

--[[
The one place unbounded text becomes a page.

Everything read-only and long used to go out through InfoMessage with a
timeout -- the summary got 15 seconds, a character card 10, a historical figure
20 -- and three things are wrong with that, the first of them fatal. The widget
dismisses ITSELF while the reader is still reading, and there is no way to get
the text back except walking the menu again. It also cannot paginate, so
anything past one screenful is silently cut off with no scrollbar to admit it.
And its MovableContainer swallows taps that land on the box, so the obvious
gesture does nothing (the same property that made the in-flight fetch message
read as a frozen screen -- see lib/fetch.lua).

TextViewer is what KOReader itself uses for exactly this, and what showAbout
already used: full screen, tap or swipe to turn the page, a title bar with a
close button, no timeout. Short status messages -- "no data yet", "cache
cleared" -- stay on InfoMessage, which is the thing it is actually good at.

`justified = false` on purpose: these texts are full of short bracketed lines
("[12] ...") and headings, and justification stretches those into gappy
nonsense at e-ink column widths.
]]
function GrimoriaPlugin:showLongText(title, text)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = title,
        text = text,
        justified = false,
    })
end

function GrimoriaPlugin:showCharacters()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_character_data") or "No character data",
            timeout = 3,
        })
        return
    end
    
    local items = {}
    
    -- Add search option
    table.insert(items, {
        text = self.loc:t("search_character") or "🔍 Search Character",
        callback = function()
            self:showCharacterSearch()
        end
    })
    
    -- Add characters
    for i, char in ipairs(self.characters) do
        -- CRITICAL: Ensure char and char.name exist
        if char and type(char) == "table" then
            local name = char.name
            
            -- Ensure name is a string
            if type(name) ~= "string" or name == "" then
                name = self.loc:t("unknown_character") or "Unknown Character"
            end
            
            local text = "│ " .. name
            
            -- Add description if available
            if char.description and type(char.description) == "string" and #char.description > 0 then
                text = text .. "\n   " .. char.description
            elseif char.gender or char.occupation then
                local details = {}
                if char.gender and type(char.gender) == "string" then 
                    table.insert(details, char.gender) 
                end
                if char.occupation and type(char.occupation) == "string" then 
                    table.insert(details, char.occupation) 
                end
                if #details > 0 then
                    text = text .. "\n   " .. table.concat(details, ", ")
                end
            end
            
            -- CRITICAL: Ensure text is not nil
            if text and type(text) == "string" and #text > 0 then
                table.insert(items, {
                    text = text,
                    callback = function()
                        self:showCharacterDetails(char)
                    end,
                    -- Hold for the chapter bar chart. The same gesture the
                    -- version picker uses for its per-item actions, and the
                    -- subtitle below says so -- a hold gesture nobody is told
                    -- about is a feature nobody has.
                    hold_callback = function()
                        self:showChapterAppearances(char)
                    end,
                })
            else
                logger.warn("GrimoriaPlugin: Skipping character with invalid text at index", i)
            end
        else
            logger.warn("GrimoriaPlugin: Skipping invalid character at index", i)
        end
    end
    
    -- Ensure we have items to display
    if #items <= 2 then
        -- Only search and separator
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_character_data") or "No valid character data",
            timeout = 3,
        })
        return
    end
    
    local character_menu = Menu:new{
        title = (self.loc:t("menu_characters") or "Characters") .. " (" .. #self.characters .. ")",
        subtitle = self.loc:t("characters_hint"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- Stock Menu:onMenuHold ignores item.hold_callback.
        onMenuHold = function(_, item)
            if item and item.hold_callback then
                item.hold_callback()
                return true
            end
            return true
        end,
    }
    
    UIManager:show(character_menu)
end

function GrimoriaPlugin:showCharacterDetails(character)
    if not character then
        return
    end
    
    local function safeString(value, default)
        if value == nil then
            return default or self.loc:t("not_specified")
        elseif type(value) == "string" then
            return value
        elseif type(value) == "number" then
            return tostring(value)
        elseif type(value) == "table" then
            -- A table here means the spoiler filter handed over a chapter-
            -- tagged list unresolved, which is a bug in lib/spoilers.lua rather
            -- than something to render. This used to call json.encode, and
            -- `json` is not required in this file and is not a KOReader global
            -- -- so the "safe" branch of a function whose whole job is safety
            -- would have taken the card down with an attempt-to-index-nil.
            logger.warn("GrimoriaPlugin: unresolved table reached a view")
            return default or self.loc:t("not_specified")
        elseif type(value) == "function" then
            return self.loc:t("not_specified")
        else
            return tostring(value)
        end
    end
    
    local name = safeString(character.name, self.loc:t("unnamed_character"))
    local description = safeString(character.description, self.loc:t("no_description"))
    local role = safeString(character.role, self.loc:t("not_specified"))
    local gender = safeString(character.gender, self.loc:t("not_specified"))
    local occupation = safeString(character.occupation, self.loc:t("not_specified"))
    
    local text = string.format([[
%s %s

%s
%s

%s %s
%s %s
%s %s
]], self.loc:t("character_name"), name,
    self.loc:t("description"), description,
    self.loc:t("role"), role,
    self.loc:t("gender"), gender,
    self.loc:t("occupation"), occupation)

    -- The names the reader has met this identity under, and only those:
    -- lib/spoilers.lua has already dropped any alias first used in a chapter
    -- they have not reached.
    if character.aliases and #character.aliases > 0 then
        text = text .. "\n" .. self.loc:t("also_known_as") .. " "
            .. table.concat(character.aliases, ", ") .. "\n"
    end

    self:showLongText(name, text)
end

function GrimoriaPlugin:showLocations()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.locations or #self.locations == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_location_data"),
            timeout = 3,
        })
        return
    end
    
    local items = {}
    for i, loc in ipairs(self.locations) do
        local text = loc.name or "Unknown Location"
        
        if loc.description then
            text = text .. "\n   " .. loc.description
        end
        if loc.importance then
            text = text .. "\n   🎯 " .. loc.importance
        end
        
        table.insert(items, {
            text = text,
            callback = function()
                local detail_text = "📍 " .. (loc.name or "Unknown") .. "\n\n"
                if loc.description then
                    detail_text = detail_text .. loc.description .. "\n\n"
                end
                if loc.importance then
                    detail_text = detail_text .. "🎯 " .. self.loc:t("importance") .. "\n" .. loc.importance
                end
                self:showLongText(loc.name or self.loc:t("menu_locations"), detail_text)
            end,
        })
    end
    
    local location_menu = Menu:new{
        title = self.loc:t("menu_locations") .. " (" .. #self.locations .. ")",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(location_menu)
end

function GrimoriaPlugin:showAuthorInfo()
    if not self.author_info or not self.author_info.description or #self.author_info.description == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_author_data"),
            timeout = 3,
        })
        return
    end
    
    local text = self.author_info.description .. "\n\n"

    if self.author_info.birthDate and #self.author_info.birthDate > 0 then
        text = text .. "📅: " .. self.author_info.birthDate .. "\n"
    end
    if self.author_info.deathDate and #self.author_info.deathDate > 0 then
        text = text .. "💀: " .. self.author_info.deathDate .. "\n"
    end

    self:showLongText("✍️ " .. (self.author_info.name or self.loc:t("menu_author_info")), text)
end

function GrimoriaPlugin:findCharacterByName(word)
    if not self.characters or not word then
        return nil
    end
    
    local word_lower = string.lower(word)
    
    for _, char in ipairs(self.characters) do
        local name_lower = string.lower(char.name or "")
        
        if name_lower == word_lower then
            return char
        end
        
        if string.find(name_lower, word_lower, 1, true) or
           string.find(word_lower, name_lower, 1, true) then
            return char
        end
        
        local first_name = string.match(name_lower, "^(%S+)")
        if first_name and first_name == word_lower then
            return char
        end
    end
    
    return nil
end

function GrimoriaPlugin:showCharacterInfo(char)
    local text = ""

    if char.description then
        text = text .. char.description .. "\n\n"
    end
    
    if char.role then
        text = text .. "🎭 " .. self.loc:t("role") .. ": " .. char.role .. "\n"
    end
    
    if char.gender then
        -- The schema asks for "male"/"female" in English regardless of the
        -- book's language, so those two are translated for display and
        -- anything else is shown exactly as the model wrote it.
        local gender_label = char.gender == "male" and self.loc:t("gender_male")
                          or char.gender == "female" and self.loc:t("gender_female")
                          or char.gender
        text = text .. "👤 " .. self.loc:t("gender") .. ": " .. gender_label .. "\n"
    end
    
    if char.occupation then
        text = text .. "💼 " .. self.loc:t("occupation") .. ": " .. char.occupation .. "\n"
    end

    if char.aliases and #char.aliases > 0 then
        text = text .. "🏷️ " .. self.loc:t("also_known_as") .. " "
            .. table.concat(char.aliases, ", ") .. "\n"
    end

    self:showLongText("👤 " .. (char.name or self.loc:t("unnamed_character")), text)
end

function GrimoriaPlugin:showSummary()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.summary or #self.summary == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_summary_data"),
            timeout = 3,
        })
        return
    end
    
    --[[
    The scope line goes in the body rather than the title bar, and the "(Spoiler-
    free)" footer it replaces is gone.

    That footer was an untranslated English string appended to a Vietnamese
    summary, and it made a promise without saying how far it reached.
    describeScope names the actual boundary ("showing up to chapter 12"), which
    is both the honest version of the same claim and the thing a reader wants
    when they open this after a week away. It sits at the top because on a
    paginated view a footer is on the last page, where nobody looks first.
    ]]
    local body = self:describeScope() .. "\n\n" .. self.summary

    --[[
    The quotes ride along at the bottom of the summary rather than getting a
    menu entry of their own: they are a by-product of the same analysis, and
    the reader's main consumer for them is the sleep screen, not a view. The
    list is self.quotes -- already filtered to finished chapters -- never
    book_data.quotes.
    ]]
    if self.quotes and #self.quotes > 0 then
        local parts = {}
        for _, q in ipairs(self.quotes) do
            local line = "“" .. q.quote .. "”"
            if q.speaker and #q.speaker > 0 then
                line = line .. "\n— " .. q.speaker
            end
            parts[#parts + 1] = line
        end
        body = body .. "\n\n── " .. self.loc:t("quotes_title") .. " ──\n\n"
            .. table.concat(parts, "\n\n")
    end

    self:showLongText("📖 " .. self.loc:t("summary_title"), body)
end

function GrimoriaPlugin:showThemes()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.themes or #self.themes == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_theme_data"),
            timeout = 3,
        })
        return
    end
    
    local text = ""
    for i, theme in ipairs(self.themes) do
        -- Chapter-tagged tables now; plain strings only in pre-filter caches.
        local body = type(theme) == "table" and (theme.theme or "") or tostring(theme)
        -- A blank line between them: themes are whole paragraphs once a model
        -- takes the "grounded in specific evidence" instruction seriously, and
        -- run together they read as one long paragraph with stray digits in it.
        text = text .. i .. ". " .. body .. "\n\n"
    end

    self:showLongText("🎨 " .. self.loc:t("themes_title"), text)
end

function GrimoriaPlugin:showTimeline()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.timeline or #self.timeline == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_timeline_data"),
            timeout = 5,
        })
        return
    end
    
    local items = {}
    for i, event in ipairs(self.timeline) do
        local text = ""
        
        if event.chapter then
            text = text .. "📖 " .. event.chapter .. "\n"
        end
        
        if event.event then
            text = text .. event.event
        end
        
        if event.characters and #event.characters > 0 then
            text = text .. "\n👥 " .. table.concat(event.characters, ", ")
        end
        
        table.insert(items, {
            text = text,
            callback = function()
                -- The event number is the title bar now, so it is not repeated
                -- as the first line of the body.
                local detail_text = ""

                if event.chapter then
                    detail_text = detail_text .. self.loc:t("chapter") .. " " .. event.chapter .. "\n\n"
                end
                
                if event.event then
                    detail_text = detail_text .. event.event .. "\n\n"
                end
                
                if event.characters and #event.characters > 0 then
                    detail_text = detail_text .. self.loc:t("characters_involved") .. "\n"
                    for _, char in ipairs(event.characters) do
                        detail_text = detail_text .. "  • " .. char .. "\n"
                    end
                end
                
                if event.importance then
                    detail_text = detail_text .. "\n" .. self.loc:t("importance") .. "\n" .. event.importance
                end

                self:showLongText(string.format(self.loc:t("timeline_event"), i), detail_text)
            end,
        })
    end
    
    local timeline_menu = Menu:new{
        title = self.loc:t("menu_timeline") .. " (" .. #self.timeline .. " " .. self.loc:t("events") .. ")",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(timeline_menu)
end

function GrimoriaPlugin:showHistoricalFigures()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.historical_figures or #self.historical_figures == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_historical_data"),
            timeout = 5,
        })
        return
    end
    
    local items = {}
    for i, figure in ipairs(self.historical_figures) do
        local text = ""
        
        if figure.name then
            text = text .. "👤 " .. figure.name
        end
        
        if figure.birth_year or figure.death_year then
            text = text .. "\n   "
            if figure.birth_year then
                text = text .. figure.birth_year
            end
            if figure.death_year then
                text = text .. " - " .. figure.death_year
            elseif figure.birth_year then
                text = text .. " - ?"
            end
        end
        
        if figure.role then
            text = text .. "\n   " .. figure.role
        end
        
        table.insert(items, {
            text = text,
            callback = function()
                self:showHistoricalFigureDetails(figure)
            end,
        })
    end
    
    local figures_menu = Menu:new{
        title = self.loc:t("menu_historical_figures") .. " (" .. #self.historical_figures .. ")",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(figures_menu)
end

function GrimoriaPlugin:showHistoricalFigureDetails(figure)
    local text = ""

    if figure.birth_year or figure.death_year then
        text = text .. "📅 "
        if figure.birth_year then
            text = text .. figure.birth_year
        end
        if figure.death_year then
            text = text .. " - " .. figure.death_year
        elseif figure.birth_year then
            text = text .. " - ?"
        end
        text = text .. "\n\n"
    end
    
    if figure.role then
        text = text .. "👔 " .. self.loc:t("role") .. ": " .. figure.role .. "\n\n"
    end
    
    
    if figure.biography then
        text = text .. "📖 " .. self.loc:t("hist_bio") .. ":\n" .. figure.biography .. "\n\n"
    end
    
    if figure.importance_in_book then
        text = text .. "📚 " .. self.loc:t("hist_importance") .. ":\n" .. figure.importance_in_book .. "\n\n"
    end
    
    if figure.context_in_book then
        text = text .. "💡 " .. self.loc:t("hist_context") .. ":\n" .. figure.context_in_book
    end

    self:showLongText("📜 " .. (figure.name or self.loc:t("unnamed_character")), text)
end

function GrimoriaPlugin:showChapterCharacters()
    -- This was the one view that did not refresh first, so it matched the
    -- chapter's text against whatever set of characters the last view left
    -- behind. Harmless when that set was smaller than the current one and a
    -- leak when it was larger -- after a trip through the whole-book toggle it
    -- would happily name a character out of a chapter the reader is in.
    self:applyChapterFilter()
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_char_data_fetch"), 
            timeout = 3,
        })
        return
    end
    
    if not self.mentions then
        local Mentions = require("lib/mentions")
        self.mentions = Mentions:new()
    end
    
    UIManager:show(InfoMessage:new{
        text = self.loc:t("analyzing_chapter"),
        timeout = 1,
    })
    
    local chapter_text, chapter_title =
        self.mentions:getCurrentChapterText(self.ui, self:chapterScheme())
    
    if not chapter_text or #chapter_text == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("chapter_text_error"),
            timeout = 3,
        })
        return
    end
    
    local found_chars = self.mentions:findCharactersInText(chapter_text, self.characters)
    
    if #found_chars == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(self.loc:t("no_characters_in_chapter"), chapter_title or self.loc:t("this_chapter")),
            timeout = 5,
        })
        return
    end
    
    local items = {}
    for _, char_info in ipairs(found_chars) do
        local char = char_info.character
        local count = char_info.count
        
        local gender_icon = ""
        if char.gender == "male" then
            gender_icon = "👨 "
        elseif char.gender == "female" then
            gender_icon = "👩 "
        else
            gender_icon = "👤 "
        end
        
        table.insert(items, {
            text = string.format("%s%s (%dx)", gender_icon, char.name, count),
            callback = function()
                self:showCharacterInfo(char)
            end,
        })
    end
    
    local menu = Menu:new{
        title = string.format("📖 %s\n👥 %d %s", 
                             chapter_title or self.loc:t("this_chapter"), 
                             #found_chars,
                             self.loc:t("chapter_chars_title")), 
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(menu)
    
    logger.info("GrimoriaPlugin: Showed chapter characters -", #found_chars, "found")
end

function GrimoriaPlugin:showCharacterSearch()
    self:applyChapterFilter()  -- refresh for the current chapter
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = self.loc:t("no_character_data"),
            timeout = 3,
        })
        return
    end
    
    local InputDialog = require("ui/widget/inputdialog")
    local plugin = self
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = self.loc:t("search_character_title"),
        input = "",
        input_hint = self.loc:t("search_hint"),
        buttons = {
            {
                {
                    text = self.loc:t("cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = self.loc:t("search_button"),
                    is_enter_default = true,
                    callback = function()
                        local search_text = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        
                        if search_text and #search_text > 0 then
                            local found_char = plugin:findCharacterByName(search_text)
                            if found_char then
                                plugin:showCharacterInfo(found_char)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = string.format(self.loc:t("character_not_found"), search_text),
                                    timeout = 3,
                                })
                            end
                        end
                    end,
                },
            },
        },
    }
    
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return GrimoriaPlugin
