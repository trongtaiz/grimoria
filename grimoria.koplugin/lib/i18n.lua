-- Localization Manager for Grimoria Plugin (with .po support)

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Localization = {
    current_language = "en",
    translations = {},
    available_languages = {},

    -- Where the .po files live, relative to KOReader's working directory.
    -- A field rather than a local inside each function for two reasons: a
    -- rename of the plugin folder is then a one-line change instead of a
    -- silent breakage of every translation lookup, and the off-device test
    -- can point it at a real path.
    plugin_dir = "plugins/grimoria.koplugin",
}

-- Simple .po file parser
function Localization:parsePO(filepath)
    local translations = {}
    local file = io.open(filepath, "r")
    
    if not file then
        logger.warn("Localization: Cannot open .po file:", filepath)
        return nil
    end
    
    local msgid = nil
    local msgstr = nil
    local in_msgid = false
    local in_msgstr = false
    
    for line in file:lines() do
        -- Skip comments and empty lines
        if line:match("^#") or line:match("^%s*$") then
            goto continue
        end
        
        -- Start of msgid
        if line:match('^msgid%s+"') then
            -- Save previous translation
            if msgid and msgstr then
                translations[msgid] = msgstr
            end
            
            msgid = line:match('^msgid%s+"(.-)"')
            msgstr = nil
            in_msgid = true
            in_msgstr = false
        
        -- Start of msgstr
        elseif line:match('^msgstr%s+"') then
            msgstr = line:match('^msgstr%s+"(.-)"')
            in_msgid = false
            in_msgstr = true
        
        -- Continuation line
        elseif line:match('^"') then
            local continuation = line:match('^"(.-)"')
            if in_msgid and msgid then
                msgid = msgid .. continuation
            elseif in_msgstr and msgstr then
                msgstr = msgstr .. continuation
            end
        end
        
        ::continue::
    end
    
    -- Save last translation
    if msgid and msgstr then
        translations[msgid] = msgstr
    end
    
    file:close()
    
    -- Process escape sequences
    for key, value in pairs(translations) do
        value = value:gsub("\\n", "\n")
        value = value:gsub("\\t", "\t")
        value = value:gsub('\\"', '"')
        value = value:gsub("\\\\", "\\")
        translations[key] = value
    end
    
    return translations
end

-- Initialize localization system
function Localization:init()
    logger.info("Localization: Initializing...")
    
    -- Discover available language files
    self:discoverLanguages()
    
    -- Load saved language preference
    self:loadLanguage()
    
    -- Load translation file
    self:loadTranslations()
    
    logger.info("Localization: Initialized with language:", self.current_language)
end

-- Discover available .po files
function Localization:discoverLanguages()
    local lang_dir = self.plugin_dir .. "/languages"
    
    self.available_languages = {}
    
    local attr = lfs.attributes(lang_dir)
    if not attr or attr.mode ~= "directory" then
        logger.warn("Localization: Languages directory not found:", lang_dir)
        return
    end
    
    for file in lfs.dir(lang_dir) do
        if file:match("%.po$") then
            local lang_code = file:match("^(.+)%.po$")
            if lang_code then
                table.insert(self.available_languages, lang_code)
                logger.info("Localization: Found language:", lang_code)
            end
        end
    end
    
    table.sort(self.available_languages)
    logger.info("Localization: Discovered", #self.available_languages, "languages")
end

-- Load translations from .po file
function Localization:loadTranslations()
    local po_file = self.plugin_dir .. "/languages/" .. self.current_language .. ".po"
    
    logger.info("Localization: Loading translations from:", po_file)
    
    local translations = self:parsePO(po_file)
    
    if translations then
        self.translations = translations
        logger.info("Localization: Loaded", self:tableSize(translations), "translations")
    else
        logger.warn("Localization: Failed to load .po file")
        
        -- Fallback to English
        if self.current_language ~= "en" then
            logger.info("Localization: Falling back to English")
            self.current_language = "en"
            po_file = self.plugin_dir .. "/languages/en.po"
            translations = self:parsePO(po_file)
            if translations then
                self.translations = translations
            else
                self.translations = {}
                logger.error("Localization: Failed to load fallback!")
            end
        end
    end
end

-- Helper: count table size
function Localization:tableSize(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Get translated string with better error handling
function Localization:t(key, ...)
    local translation = self.translations[key]
    
    if not translation or translation == "" then
        logger.warn("Localization: Missing translation key:", key)
        -- Return a user-friendly fallback instead of the key
        -- Keys added for text-grounded, per-chapter Grimoria. They are defined
        -- here rather than in the .po files so they work in every language
        -- immediately; translations can be added to the .po files later and
        -- will take precedence automatically.
        local fallbacks = {
            cache_saved = "💾 Saved!",
            cache_save_failed = "❌ Save failed",
            ai_fetch_complete = "✅ Fetched from %s\n\n📖 %s\n👤 %s\n\n👥 %d | 📍 %d | 🎨 %d | 📅 %d | 📜 %d\n\n%s",
            fetching_ai = "🤖 Fetching from %s...",
            no_api_key = "⚠️ No API key set!",

            confirm_full_fetch = "Analyse the whole book?\n\n📖 %d chapters\n📊 roughly %dk tokens\n⏱️ several minutes -- up to ~20 on a long book\n\nThe device is kept awake while it runs, and you can tap to cancel at any point.\n\nThis runs once. As you read on, the Grimoria reveals itself chapter by chapter with no further requests.",
            confirm_analyze = "Analyse",
            stage_extracting = "📖 Reading the book from the device...",
            stage_sending = "📤 Sending %d chapters (~%dk tokens)...",
            -- Deliberately not a tighter estimate: measured 89s on
            -- gemini-3.6-flash and 371s on gpt-5.5-high for the same kind of
            -- book, so any specific number is wrong for one of them.
            stage_waiting = "🤖 %s is analysing.\nThis takes several minutes.",
            -- Shown on the TrapWidget for the whole request. One line: that
            -- widget draws its text with a single-line TextWidget, so newlines
            -- here are not reliable. Says "tap anywhere" because the screen is
            -- NOT frozen any more, and a reader who sat through the old
            -- blocking build has no reason to believe that on its own.
            stage_waiting_trap = "🤖 %s is analysing — tap anywhere to cancel",
            -- The guard on that tap. A whole book is minutes of work and real
            -- money, so it never goes away on one stray touch.
            fetch_cancel_confirm = "The analysis is still running.\n\nCancel it? Everything done so far is lost, and tokens already used are still charged.",
            fetch_cancel_yes = "Cancel analysis",
            fetch_cancel_no = "Keep waiting",
            extract_failed_warning = "⚠️ Could not read the book's text.\nFalling back to title-only analysis, which is much less reliable.",
            showing_up_to_chapter = "🔒 Showing up to chapter %d (spoiler-safe)",
            showing_whole_book = "🔓 Showing the whole book (spoilers included)",
            menu_update_grimoria = "🔄 Re-analyse this book",
            menu_toggle_scope = "🔒 Spoiler filter on/off",

            -- Stored analyses: several per book, switch between them offline.
            menu_versions = "📚 Analysis versions",
            versions_title = "Analysis versions",
            versions_hint = "Tap to switch - hold to rename or delete",
            no_versions = "No analysis stored for this book yet.",
            version_switched = "Now showing: %s",
            version_rename = "Rename",
            version_rename_desc = "A name you will recognise, e.g. the model that produced it.",
            version_delete = "Delete",
            version_delete_confirm = "Delete this analysis? The others are kept.",
            unknown_model_version = "unknown model",

            -- Provider picker. Were inline "Turkish or English" ternaries
            -- until the language set was cut back to English + Vietnamese.
            provider_active = "Active",
            provider_selected = "%s selected",
            provider_no_key = "No API key",
            yes = "YES",
            no = "NO",
            -- Appended to the single fetch confirm, not shown on its own: a
            -- second dialog for the same decision stacked two popups.
            confirm_extra_analysis =
                "You already have %d stored analysis for this book.\n" ..
                "It is kept - you can switch back afterwards.",
        }
        translation = fallbacks[key] or key
    end
    
    -- Format with arguments
    if select('#', ...) > 0 then
        local success, result = pcall(string.format, translation, ...)
        if success then
            return result
        else
            logger.warn("Localization: Format error for key:", key)
            logger.warn("Localization: Error:", result)
            logger.warn("Localization: Args count:", select('#', ...))
            -- Print arguments for debugging
            for i = 1, select('#', ...) do
                local arg = select(i, ...)
                logger.warn("Localization: Arg", i, "type:", type(arg), "value:", tostring(arg))
            end
            return translation
        end
    end
    
    return translation
end

-- Load/save language preference (same as before)
function Localization:loadLanguage()
    local Paths = require("lib/paths")
    local lang = Paths:readSetting("language.txt")

    if lang then
        if self:languageExists(lang) then
            self.current_language = lang
            logger.info("Localization: Loaded language from file:", lang)
        else
            logger.warn("Localization: Language not found:", lang)
            self.current_language = "en"
        end
    else
        self.current_language = "en"
        logger.info("Localization: No saved language, using default: en")
    end
end

function Localization:languageExists(lang_code)
    for _, code in ipairs(self.available_languages) do
        if code == lang_code then return true end
    end
    return false
end

function Localization:getLanguage()
    return self.current_language
end

function Localization:getLanguageName()
    return self.translations["language_name"] or self.current_language
end

function Localization:setLanguage(lang_code)
    if not self:languageExists(lang_code) then
        logger.warn("Localization: Cannot set non-existent language:", lang_code)
        return false
    end
    
    self.current_language = lang_code
    
    local DataStorage = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()
    local grimoria_dir = settings_dir .. "/grimoria"
    lfs.mkdir(grimoria_dir)
    
    local language_file = grimoria_dir .. "/language.txt"
    local file = io.open(language_file, "w")
    if file then
        file:write(lang_code)
        file:close()
        logger.info("Localization: Language saved:", lang_code)
    end
    
    self:loadTranslations()
    
    local LLM = require("lib/llm")
    if LLM then
        LLM:loadLanguage()
    end
    
    return true
end

-- Reload translations (call this after editing .po files)
function Localization:reload()
    logger.info("Localization: Reloading translations...")
    self:loadTranslations()
    
    -- Clear cached translations in LLM if it exists
    local LLM = require("lib/llm")
    if LLM and LLM.localization then
        LLM.localization = nil
    end
    
    logger.info("Localization: Reload complete")
end

return Localization
