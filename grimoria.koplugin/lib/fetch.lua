--[[
The one network call, and everything that keeps it survivable.

Runs in a forked subprocess so the UI stays live, holds the device awake
so it cannot sleep mid-request, and guards cancellation behind a
confirmation because a whole book is minutes of work and real money.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

-- Get current reading progress (works for EPUB, PDF, MOBI, etc.)
function GrimoriaPlugin:getReadingProgress()
    -- Default values
    local current_page = 0
    local total_pages = 0
    local progress = 0
    
    if not self.ui or not self.ui.document then
        logger.warn("GrimoriaPlugin: No document or UI available")
        return current_page, total_pages, progress
    end
    
    local doc = self.ui.document
    
    -- Get total pages
    local success_pages, pages = pcall(function() return doc:getPageCount() end)
    if success_pages and pages and pages > 0 then
        total_pages = pages
    else
        logger.warn("GrimoriaPlugin: Could not get page count")
        return current_page, total_pages, progress
    end
    
    -- Try multiple methods to get current page
    local methods = {
        -- Method 1: Paging (for PDF, DjVu)
        function()
            if self.ui.paging and type(self.ui.paging.getCurrentPage) == "function" then
                return self.ui.paging:getCurrentPage()
            end
        end,
        -- Method 2: Rolling (for EPUB, MOBI)
        function()
            if self.ui.rolling and type(self.ui.rolling.getCurrentPage) == "function" then
                return self.ui.rolling:getCurrentPage()
            end
        end,
        -- Method 3: Document direct
        function()
            if type(doc.getCurrentPage) == "function" then
                return doc:getCurrentPage()
            end
        end,
        -- Method 4: View state
        function()
            if self.view and self.view.state and self.view.state.page then
                return self.view.state.page
            end
        end,
        -- Method 5: Document settings
        function()
            if self.ui.doc_settings then
                local settings = self.ui.doc_settings
                return settings:readSetting("last_page") or settings:readSetting("page")
            end
        end,
    }
    
    -- Try each method
    for i, method in ipairs(methods) do
        local success_method, page = pcall(method)
        if success_method and page and tonumber(page) then
            current_page = tonumber(page)
            logger.info("GrimoriaPlugin: Got current page using method", i, ":", current_page)
            break
        end
    end
    
    -- If still no page, try one more fallback
    if current_page == 0 and self.ui.document then
        local success_fallback, fallback_page = pcall(function()
            -- Try to get from bookmark or last position
            if self.ui.bookmark and self.ui.bookmark.getCurrentPageNumber then
                return self.ui.bookmark:getCurrentPageNumber()
            end
        end)
        
        if success_fallback and fallback_page then
            current_page = tonumber(fallback_page) or 0
            logger.info("GrimoriaPlugin: Got current page from fallback:", current_page)
        end
    end
    
    -- Calculate progress
    if total_pages > 0 and current_page > 0 then
        progress = math.floor((current_page / total_pages) * 100)
    end
    
    logger.info("GrimoriaPlugin: Reading progress -", current_page, "/", total_pages, "=", progress .. "%")
    
    return current_page, total_pages, progress
end

function GrimoriaPlugin:fetchFromAI()
    logger.info("GrimoriaPlugin: Fetching AI data")
    
    -- 1. NETWORK CHECK
    local NetworkMgr = require("ui/network/manager")
    
    if not NetworkMgr:isOnline() then
        logger.info("GrimoriaPlugin: Network is offline, asking user...")
        
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        
        UIManager:show(ConfirmBox:new{
            text = self.loc:t("network_offline_prompt"),
            ok_text = self.loc:t("turn_on_wifi"),
            cancel_text = self.loc:t("cancel"),
            ok_callback = function()
                logger.info("GrimoriaPlugin: User chose to turn on WiFi")
                
                -- Turn Wi-Fi on
                NetworkMgr:turnOnWifi(function()
                    logger.info("GrimoriaPlugin: WiFi turned on, proceeding with fetch")
                    -- Ask the spoiler-scope question once Wi-Fi is up
                    self:askSpoilerPreference()
                end)
            end,
            cancel_callback = function()
                logger.info("GrimoriaPlugin: User cancelled WiFi activation")
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = self.loc:t("fetch_cancelled"),
                    timeout = 3,
                })
            end,
        })
        return
    end
    
    -- Wi-Fi already on: go straight to the spoiler-scope question
    self:askSpoilerPreference()
end

-- Read the extraction cap from settings/grimoria/max_text_chars.txt, same
-- convention as gemini_model.txt and output_language.txt.
function GrimoriaPlugin:getMaxCharsSetting()
    local BookText = require("lib/booktext")
    local Paths = require("lib/paths")
    return tonumber(Paths:readSetting("max_text_chars.txt")) or BookText.MAX_CHARS_DEFAULT
end

--[[
There is no longer a spoiler-free / full-book choice to make: the whole book
is analysed once, and how much of it gets shown is decided locally from the
reading position. So this is now a single confirmation, whose job is to tell
the user what the request will cost before they spend it.
]]
function GrimoriaPlugin:askSpoilerPreference()
    local ConfirmBox = require("ui/widget/confirmbox")
    local BookText = require("lib/booktext")

    local chapters = BookText:getChapterCount(self.ui)
    local pages = self.ui.document:getPageCount() or 0
    -- Rough guess before extracting: ~1.6 KB of text per page. Measured
    -- Vietnamese runs ~3.3 chars/token, so divide by 3 -- the old /2 overstated
    -- the token count by about 60%.
    local est_k = math.floor(math.min(pages * 1600, self:getMaxCharsSetting()) / 3000)

    -- Anything already stored is mentioned HERE rather than in a second
    -- dialog. continueWithFetch used to raise its own confirm, which meant two
    -- popups stacked on top of each other for the same single decision.
    local note = ""
    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end
    local existing = self.archive:listVersions(self.ui.document.file)
    if #existing > 0 then
        note = "\n\n" .. string.format(self.loc:t("confirm_extra_analysis"), #existing)
    end
    -- The reply budget is 65,536 tokens shared with thinking. A long TOC
    -- asks for one summary per entry; past ~40 that is the thing that
    -- gets truncated, not the book text. The range picker is the way out.
    if chapters > 40 then
        note = note .. "\n\n" .. string.format(self.loc:t("confirm_long_toc"), chapters)
    end

    UIManager:show(ConfirmBox:new{
        text = string.format(self.loc:t("confirm_full_fetch"), chapters, est_k) .. note,
        ok_text = self.loc:t("confirm_analyze"),
        cancel_text = self.loc:t("cancel"),
        ok_callback = function() self:continueWithFetch(100) end,
        cancel_callback = function()
            UIManager:show(InfoMessage:new{
                text = self.loc:t("fetch_cancelled"), timeout = 3,
            })
        end,
    })
end

--[[
Analyse part of a long book.

Why this exists: the reply has a 65,536-token budget shared with the model's
thinking pass, and a very long novel asks for more per-chapter output than fits.
The truncation ladder in lib/llm.lua steps effort down, then asks for brevity,
and when both are exhausted it starts dropping chapters off the END of the book
-- so the analysis silently stops covering the last third. Two requests over two
ranges cost roughly the same money and lose nothing.

The chapters offered come from BookText:getChapterList, never from a fresh
doc:getToc(). On a book whose table of contents exceeds MAX_CHAPTERS the list is
bucketed, and a range picked off the raw TOC would name chapters the analysis
does not number the same way -- the reader would choose "30 to 40" and get some
other ten chapters, with nothing anywhere saying so.
]]
function GrimoriaPlugin:fetchChapterRange()
    local BookText = require("lib/booktext")
    local chapters = BookText:getChapterList(self.ui)

    if not chapters or #chapters < 2 then
        UIManager:show(InfoMessage:new{ text = self.loc:t("range_not_useful"), timeout = 4 })
        return
    end

    self:pickChapter(chapters, 1, self.loc:t("range_pick_first"), function(first)
        -- The second picker starts at the first pick, so an invalid range
        -- cannot be chosen rather than being rejected after the fact.
        self:pickChapter(chapters, first, self.loc:t("range_pick_last"), function(last)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = string.format(self.loc:t("range_confirm"), first, last,
                                     last - first + 1),
                ok_text = self.loc:t("confirm_analyze"),
                cancel_text = self.loc:t("cancel"),
                ok_callback = function()
                    self:continueWithFetch(100, { first = first, last = last })
                end,
                cancel_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self.loc:t("fetch_cancelled"), timeout = 3,
                    })
                end,
            })
        end)
    end)
end

-- One chapter out of the canonical list, from `from` onward.
function GrimoriaPlugin:pickChapter(chapters, from, title, on_pick)
    local menu
    local items = {}
    for i = from, #chapters do
        local label = string.format("%s %d", self.loc:t("chapter"), i)
        local t = chapters[i].title
        if type(t) == "string" and #t > 0 then label = label .. " · " .. t end
        items[#items + 1] = {
            text = label,
            callback = function()
                UIManager:close(menu)
                on_pick(i)
            end,
        }
    end

    menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

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
function GrimoriaPlugin:holdDeviceAwake()
    if self.awake_held then return end
    local Device = require("device")
    local PluginShare = require("pluginshare")

    PluginShare.pause_auto_suspend = true
    if Device:isKindle() then
        PluginShare.keepalive = true
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end
    self.awake_held = true
    logger.info("GrimoriaPlugin: holding the device awake for the fetch")
end

function GrimoriaPlugin:releaseDeviceAwake()
    if not self.awake_held then return end
    local Device = require("device")
    local PluginShare = require("pluginshare")

    PluginShare.pause_auto_suspend = false
    if Device:isKindle() then
        PluginShare.keepalive = false
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    self.awake_held = false
    logger.info("GrimoriaPlugin: released the device sleep hold")
end

-- `range` is { first = , last = } for a section analysis, nil for the whole
-- book. Threaded as a parameter rather than parked on self: a fetch that was
-- cancelled halfway would otherwise leave the range set, and the NEXT run --
-- started from the ordinary menu entry, with a confirmation that said "the
-- whole book" -- would quietly analyse ten chapters.
function GrimoriaPlugin:continueWithFetch(reading_percent, range)
    logger.info("GrimoriaPlugin: Continuing with fetch process (reading_percent:", reading_percent, ")")
    
    -- 1. Start the cache manager (needed for the lookup below)
    if not self.archive then
        local Archive = require("lib/archive")
        self.archive = Archive:new()
    end
    
    local book_path = self.ui.document.file

    -- No cache check here on purpose.
    --
    -- Originally this refused to run whenever a cache existed. That had to go
    -- once a book could hold several analyses, but replacing it with a confirm
    -- put a SECOND dialog on screen right behind askSpoilerPreference's, for
    -- what is one decision. The existing-versions count is part of that single
    -- confirm instead, so by the time we get here the user has already agreed.

    -- 3. Start the AI helper (only reached when there is no cache)
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end
    
    -- Selected provider (default: gemini)
    local selected_provider = self.ai_provider or self.llm.default_provider or "gemini"
    local provider_config = self.llm.providers[selected_provider]
    
    local title = self.ui.document:getProps().title or "Unknown"
    local author = self.ui.document:getProps().authors or ""
    
    -- Model name, per the selected provider
    local current_model = self.loc:t("unknown_model")
    if provider_config and provider_config.model then
        current_model = provider_config.model
    end
    
    -- Provider display name
    local provider_name = provider_config and provider_config.name or "AI"
    
    -- 4. Trapper gives a message that can be updated in place between stages,
    -- and -- via dismissableRunInSubprocess in runFetch -- one the user can
    -- tap to abort while the request itself is in flight.
    local Trapper = require("ui/trapper")
    local InfoMessage = require("ui/widget/infomessage")

    Trapper:wrap(function()
        -- The hold and its release bracket everything, and the body runs under
        -- pcall so an error in the middle cannot leave the device pinned awake
        -- draining its battery. (Yielding across pcall is a LuaJIT extension;
        -- KOReader relies on it in this same Trapper pattern elsewhere.)
        self:holdDeviceAwake()
        local ok, err = pcall(function()
            self:runFetch(book_path, title, author, selected_provider,
                          provider_config, provider_name, current_model, range)
        end)
        self:releaseDeviceAwake()

        if not ok then
            logger.warn("GrimoriaPlugin: fetch failed with an error:", err)
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                text = self.loc:t("error_info") .. "\n\n" .. tostring(err),
            })
        end
    end)
end

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
function GrimoriaPlugin:makeCancelConfirmWidget(text, confirm_text, abort_text, continue_text)
    local TrapWidget = require("ui/widget/trapwidget")
    local ConfirmBox = require("ui/widget/confirmbox")

    local CancelConfirm = TrapWidget:extend{}

    -- Called by TrapWidget for every tap, hold, swipe and key press.
    function CancelConfirm:_dismissAndResend()
        if self.finished or self.confirm_box then return true end

        self.confirm_box = ConfirmBox:new{
            text = confirm_text,
            ok_text = abort_text,
            cancel_text = continue_text,
            ok_callback = function()
                self.confirm_box = nil
                -- The fetch may have finished while this box was up: the
                -- coroutine would already be dead, and resuming it would
                -- raise inside a widget callback.
                if self.finished then return end
                self.dismiss_callback()
            end,
            cancel_callback = function() self.confirm_box = nil end,
            -- Don't let the tap that opened this box count as an answer to it.
            flush_events_on_show = true,
        }
        UIManager:show(self.confirm_box)
        return true
    end

    -- The request came back on its own; stop offering to cancel it.
    function CancelConfirm:finish()
        self.finished = true
        if self.confirm_box then
            UIManager:close(self.confirm_box)
            self.confirm_box = nil
        end
        UIManager:close(self)
    end

    return CancelConfirm:new{ text = text }
end

-- The fetch itself. Split out of continueWithFetch so the sleep-hold above can
-- wrap it in a pcall; runs inside Trapper:wrap, so it may yield.
function GrimoriaPlugin:runFetch(book_path, title, author, selected_provider,
                             provider_config, provider_name, current_model, range)
    local Trapper = require("ui/trapper")
    local InfoMessage = require("ui/widget/infomessage")

    do   -- purely to keep this body at its original indentation
        Trapper:info(self.loc:t("stage_extracting"))

        local BookText = require("lib/booktext")
        local book_text, meta = BookText:extract(self.ui, {
            max_chars = self:getMaxCharsSetting(),
            first_chapter = range and range.first or nil,
            last_chapter = range and range.last or nil,
        })

        if not book_text then
            -- Not fatal: fall back to the old title-only request, but tell the
            -- user, because the answer quality is meaningfully different.
            logger.warn("GrimoriaPlugin: extraction failed:", meta)
            Trapper:info(self.loc:t("extract_failed_warning"))
            meta = nil
        end

        local est_k = book_text and math.floor(BookText:estimateTokens(book_text) / 1000) or 0
        Trapper:info(string.format(self.loc:t("stage_sending"),
            meta and meta.chapters_included or 0, est_k))

        local context = {
            book_text = book_text,
            truncated = meta and meta.truncated or false,
            chapter_count = meta and meta.chapters_included or nil,
            dev_budget = meta and meta.dev_budget or nil,
            -- Taken from the extractor rather than from `range`, because the
            -- extractor is what clamped the request to chapters that exist --
            -- and the prompt must state the range that was actually sent.
            first_chapter = meta and meta.first_chapter or nil,
            last_chapter = meta and meta.last_chapter or nil,
        }

        --[[
        The request itself runs in a sub-process.

        Called directly, https.request blocks the single KOReader thread for
        the entire exchange -- ten to twenty minutes on a whole book. No input
        is read in that time, so the screen looks frozen, nothing can be
        dismissed, and there is no way out but a hard restart. That is the
        "locked while loading" symptom, and no timeout tuning fixes it,
        because the freeze is the blocking call, not the wait.

        dismissableRunInSubprocess forks the call away and yields back to
        UIManager while it runs, so the event loop keeps turning: the message
        below stays live and a tap kills the sub-process. This is the same
        mechanism KOReader's own Wikipedia lookups use for their HTTP.

        The child inherits a copy of the process, and must not touch anything
        the parent has a view of -- no UIManager, no settings writes. It only
        reads config files, does the HTTP, and returns the parsed table; the
        cache write below happens back here in the parent.
        ]]
        Trapper:clear()

        -- Kept to one line on purpose: TrapWidget renders its message with a
        -- single-line TextWidget unless it happens to be wide enough to spill
        -- into a TextBoxWidget, so embedded newlines are not dependable here.
        -- Everything else is said in the confirmation.
        local trap = self:makeCancelConfirmWidget(
            string.format(self.loc:t("stage_waiting_trap"), current_model),
            self.loc:t("fetch_cancel_confirm"),
            self.loc:t("fetch_cancel_yes"),
            self.loc:t("fetch_cancel_no"))
        UIManager:show(trap)
        UIManager:forceRePaint()

        local completed, book_data, error_code, error_msg =
            Trapper:dismissableRunInSubprocess(function()
                return self.llm:getBookData(title, author, selected_provider, context)
            end, trap)

        -- Trapper only closes trap widgets it created itself, and this one was
        -- passed in, so closing it is ours to do -- on every path below.
        trap:finish()

        if not completed then
            logger.info("GrimoriaPlugin: fetch dismissed by the user")
            UIManager:show(InfoMessage:new{
                text = self.loc:t("fetch_cancelled"),
                timeout = 3,
            })
            return
        end

        if not book_data then
            -- lib/llm now returns a written-out explanation as error_msg for
            -- every case it knows; prefer it over the generic strings, and
            -- leave the popup up until dismissed so it can actually be read.
            local error_text = self.loc:t("error_info") .. "\n\n"
            if error_msg and #error_msg > 0 then
                error_text = error_text .. error_msg
            elseif error_code == "error_safety" then
                error_text = error_text .. self.loc:t("error_filtered")
            elseif error_code == "error_503" then
                error_text = error_text .. self.loc:t("error_network_timeout")
            else
                error_text = error_text .. self.loc:t("ai_fetch_failed")
            end
            if error_code then
                error_text = error_text .. "\n\n(" .. tostring(error_code) .. ")"
            end

            logger.warn("GrimoriaPlugin: fetch failed:", error_code, error_msg)
            UIManager:show(InfoMessage:new{
                text = error_text,
                -- no timeout: the user taps to dismiss
            })
            return
        end
    
        -- Record what the analysis was built from, so a later reader can tell
        -- whether the tail of the book is missing from it.
        book_data.analyzed_chapters = meta and meta.chapters_included or nil
        book_data.total_chapters = meta and meta.chapter_count or nil
        book_data.text_truncated = meta and meta.truncated or false
        book_data.grounded = book_text ~= nil

        --[[
        The leak scan, before anything else sees this analysis.

        It runs HERE rather than next to saveCache below, because between the
        two the data is assigned to self.book_data, filtered, and its counts
        logged -- so a guard placed by the cache write would let the first view
        after a fetch render unguarded data.

        In the parent, never in the forked child: the child must not touch
        anything the parent has a view of, and the whole value of this pass is
        the warning line it writes, which needs to land in crash.log where it
        can be read. It is pure table work, so it costs nothing here.
        ]]
        local guard_ok, retagged = pcall(function()
            local SpoilerGuard = require("lib/spoilerguard")
            -- book_text is still in scope here, in the parent. Rule 5 (a
            -- name is earned when the book prints it) needs it; cache load
            -- does not have it and skips that rule on purpose.
            local _, n = SpoilerGuard.scan(book_data, book_text)
            return n
        end)
        if guard_ok then
            logger.info("GrimoriaPlugin: spoiler guard re-tagged", tostring(retagged), "field(s)")
        else
            logger.warn("GrimoriaPlugin: spoiler guard failed:", tostring(retagged))
        end

        -- Save data to plugin state
        self.book_title = book_data.book_title
        self.author = book_data.author
        self.author_bio = book_data.author_bio
        self.author_birth = book_data.author_birth
        self.author_death = book_data.author_death
        self.book_data = book_data
        self:applyChapterFilter()

        logger.info("GrimoriaPlugin: Found", #self.characters, "characters")
        logger.info("GrimoriaPlugin: Found", #self.themes, "themes")
        logger.info("GrimoriaPlugin: Found", #self.locations, "locations")
        logger.info("GrimoriaPlugin: Found", #self.timeline, "timeline events")
        logger.info("GrimoriaPlugin: Found", #self.historical_figures, "historical figures")
        
        -- Save to cache
        logger.info("GrimoriaPlugin: Saving to cache")
        -- Recorded with the analysis so the version picker can tell one run
        -- from another, and so a version stays self-describing even if the
        -- index is lost and rebuilt from the files.
        local cache_saved = self.archive:saveCache(book_path, book_data, {
            provider = selected_provider,
            model = current_model,
            effort = provider_config and provider_config.reasoning_effort or nil,
            scope = (meta and meta.first_chapter)
                and { first = meta.first_chapter, last = meta.last_chapter } or nil,
            chapter_scheme = meta and meta.scheme or nil,
        })
        
        local cache_msg = cache_saved and self.loc:t("cache_saved") or self.loc:t("cache_save_failed")
        
        -- Counts describe the whole analysis, not the chapter-filtered view --
        -- otherwise a reader on chapter 2 is told the AI only found 3 characters.
        local success_message = string.format(
            self.loc:t("ai_fetch_complete"),
            provider_name,                          -- %s: provider name (Google Gemini / ChatGPT)
            book_data.book_title,                   -- %s: book title
            book_data.author,                       -- %s: Yazar
            #(book_data.characters or {}),          -- %d: character count
            #(book_data.locations or {}),           -- %d: location count
            #(book_data.themes or {}),              -- %d: theme count
            #(book_data.timeline or {}),            -- %d: event count
            #(book_data.historical_figures or {}),  -- %d: historical-figure count
            cache_msg                               -- %s: cache message
        )

        success_message = success_message .. "\n\n" .. self:describeScope()

        UIManager:show(InfoMessage:new{
            text = success_message,
            timeout = 10,
        })
    end
end

return GrimoriaPlugin
