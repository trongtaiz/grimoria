-- LLM - Google Gemini & ChatGPT for Grimoria
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")

local LLM = {}

-- AI Provider settings (default values)
LLM.providers = {
    gemini = {
        name = "Google Gemini",
        enabled = true,
        api_key = nil,
        model = "gemini-3.5-flash", -- Default model (2.5-* is retired: 404 for new keys)
    },
    chatgpt = {
        name = "ChatGPT",
        enabled = true,
        api_key = nil,
        endpoint = "https://api.openai.com/v1/chat/completions",
        model = "gpt-4o-mini", -- Default: the cost/performance compromise
        max_output_tokens = 16384,   -- gpt-4o-mini's actual ceiling
    },
    --[[
    OpenRouter: one key, every model, and the model is chosen by its full slug
    ("google/gemini-3.7-flash", "anthropic/claude-sonnet-5", ...). Its own
    provider entry rather than a preset of "custom" so that a proxy and
    OpenRouter can both be configured and switched between, exactly as chatgpt
    and custom already are.

    Streaming is on for the same reason as the custom provider: a whole-book
    analysis takes minutes, and OpenRouter's edge drops a request whose
    upstream has produced nothing for long enough. Bytes trickling out keep it
    open. It also means the Kindle never sits on a silent socket for 15
    minutes, which is what the wifi watchdog kills.
    ]]
    openrouter = {
        name = "OpenRouter",
        enabled = true,
        api_key = nil,
        endpoint = "https://openrouter.ai/api/v1/chat/completions",
        -- Full slug, including the vendor prefix. Verified present in
        -- OpenRouter's /api/v1/models listing.
        model = "google/gemini-3.7-flash",
        max_output_tokens = 64000,
        stream = true,
        -- Optional but recommended by OpenRouter: identifies the caller on
        -- their dashboards. Neither header affects routing or cost.
        extra_headers = {
            ["HTTP-Referer"] = "https://github.com/koreader/koreader",
            ["X-Title"] = "KOReader Grimoria",
        },
        --[[
        Thinking is ON by default here, and that is the whole point of this
        entry.

        Left unset, google/gemini-3.7-flash answers at whatever thinking level
        Google picks by default, which is a low one -- the reported symptom was
        summaries that read shallow. Building a per-chapter index of a whole
        novel is exactly the kind of long-horizon task the thinking pass is for,
        so it is worth paying for.

        OpenRouter takes this as `reasoning: {effort=...}`, NOT as the top-level
        `reasoning_effort` the custom provider uses -- see buildReasoningBody.
        For a Gemini 3 model it forwards to Google's `thinkingLevel`, so the
        budget is decided by Google per request rather than being carved out of
        max_tokens as a fixed percentage. Reasoning tokens are still billed and
        still counted as completion tokens, which is why callChatGPT steps this
        value down before it touches the answer when a reply hits the ceiling.
        ]]
        reasoning_effort = "high",
        -- Which wire form this endpoint understands: "openrouter" for the
        -- reasoning object, "openai" (the default) for top-level
        -- reasoning_effort. Not inferred from the endpoint, because the LiteLLM
        -- backend behind the custom provider validates its parameters strictly
        -- enough to 400 on a field it doesn't recognise.
        reasoning_style = "openrouter",
        -- Don't stream the thoughts back. They are billed either way, but a
        -- high-effort pass on a novel is tens of thousands of tokens the Kindle
        -- would have to receive, buffer and throw away, over the same wifi link
        -- that already drops whole-book replies.
        reasoning_exclude = true,
    },
    -- Any OpenAI-compatible endpoint: a LiteLLM proxy, OpenRouter, GLM, a
    -- local server. Same wire format as "chatgpt", so it goes through
    -- callChatGPT; only the endpoint/model/key differ. Kept separate from
    -- "chatgpt" so someone can have a real OpenAI key AND a proxy configured
    -- at once and switch between them.
    custom = {
        name = "Custom AI",
        enabled = true,
        api_key = nil,
        -- Placeholder, not a working default: this provider is whatever the
        -- user points it at. Set it in Menu -> Grimoria -> AI Settings -> Custom
        -- AI, in settings/grimoria/custom_endpoint.txt, or in config.lua. A
        -- non-empty string is deliberate -- provider routing selects
        -- callChatGPT on the presence of an endpoint (see selectProvider), and
        -- an unreachable placeholder produces the "check the endpoint URL"
        -- error, which is the message a user who skipped configuration needs.
        endpoint = "https://YOUR-OPENAI-COMPATIBLE-ENDPOINT/v1/chat/completions",
        model = "gpt-4o-mini",
        max_output_tokens = 64000,
        -- MANDATORY for any proxy behind Cloudflare, not an optimisation.
        -- Measured against a LiteLLM proxy during development: the edge cuts
        -- any request whose origin hasn't answered within ~125s with a 524 --
        -- identically at 336k and 604k chars, so it is a fixed edge timeout,
        -- not a size limit. A whole-book analysis takes minutes. Streaming
        -- keeps bytes flowing, so the edge stays out of the way; see
        -- readSSEStream.
        stream = true,
        -- Some proxies sit behind Cloudflare, which 403s ("error code: 1010")
        -- user agents it doesn't recognise -- and KOReader's LuaSocket sends
        -- exactly such a UA. See callChatGPT.
        user_agent = "curl/8.7.1",
        -- Optional: none|minimal|low|medium|high|xhigh, sent as
        -- reasoning_effort. This is the ONLY way to set effort on models like
        -- gpt-5.6-luna and gpt-5.6-terra, which have no "-xhigh" name variant
        -- registered -- those names come back 400 "Invalid model name".
        -- Verified to be honoured rather than ignored: an invalid value is
        -- rejected with 400 by the backend, so a 200 means it took.
        -- Unset by default because gpt-5.5-high already carries its effort in
        -- the model name.
        reasoning_effort = nil,
    },
}

-- Per-provider fields that can be overridden from settings/grimoria/<provider>_<field>.txt.
-- api_key and model are handled everywhere; the rest only make sense on an
-- OpenAI-compatible provider, and are skipped for providers that lack them.
LLM.FILE_FIELDS = { "model", "api_key", "endpoint", "reasoning_effort" }

--[[
Reasoning effort, weakest first.

Ordered rather than a set because callChatGPT walks DOWN it: when a reply is
truncated by the output budget, the cheapest thing to give up is some of the
thinking, since reasoning tokens and answer tokens come out of the same
completion budget. Giving up answer detail comes after that, and dropping book
text comes last.

"none" does NOT mean "no thinking". It means "send no reasoning field", which
leaves the provider's own default -- and measured against
google/gemini-3.7-flash that default is roughly 325 reasoning tokens on a
question small enough to fit in a paragraph. Thinking sits between "minimal"
and "low" when nothing is asked for.

Nor can thinking be turned off on that endpoint at all. `effort: "none"`,
`enabled: false` and `max_tokens: 0` were each measured returning

    400  Reasoning is mandatory for this endpoint and cannot be disabled.

so "none" must never be sent as a value -- only honoured by omitting the field.
"minimal" is the real floor: measured at exactly 0 reasoning tokens, and it is
accepted.

The list must stay complete, not merely cover what the menu offers. An effort
that isn't listed here is dropped from the request with only a log line, so a
value typed into settings/grimoria/<provider>_reasoning_effort.txt or exported in
the environment would leave the menu reading "xhigh" while the wire asks for
nothing -- worse than the old behaviour, where an unknown value reached the
endpoint and came back as a visible 400.
]]
LLM.EFFORT_LADDER = {
    "none", "minimal", "low", "medium", "high", "xhigh", "max",
}

function LLM:isValidEffort(effort)
    for _, e in ipairs(self.EFFORT_LADDER) do
        if e == effort then return true end
    end
    return false
end

--[[
Where to drop to when a reply was truncated by the output budget, or nil once
there is nowhere left to drop to.

Deliberately not one rung at a time. Every step is another whole-book request
against a paid API, and xhigh -> high frees almost nothing, so a rung-by-rung
walk would spend four requests to reach the level that was going to be needed
anyway. Two steps at most: down to a level that leaves the budget clearly free
for the answer, then to the floor.

The floor is "minimal", not "none". Sending nothing leaves the provider's
default thinking in place -- more than "minimal", not less -- so "none" is a
rung to step DOWN from rather than the bottom of the ladder, and stepping from
it to "minimal" is a real reduction rather than a no-op.
]]
function LLM:fallbackEffort(effort)
    if effort == "minimal" then return nil end          -- already at the floor
    if effort == "low" or effort == "none" or effort == nil then return "minimal" end
    if self:isValidEffort(effort) then return "low" end
    return nil
end

--[[
Add whichever reasoning fields this provider's endpoint understands to `body`.

Two incompatible spellings are in play and the difference is not cosmetic:

  openai      top-level  reasoning_effort = "high"
              What the LiteLLM proxy behind the custom provider accepts. It
              validates the value -- an invalid one comes back 400 -- so this
              is also the form that can be proven to have taken effect.

  openrouter  reasoning = { effort = "high", exclude = true }
              OpenRouter's own unified field. `exclude` has no equivalent in
              the OpenAI spelling and is what keeps the thoughts off the wire.

Sending the wrong one is not harmless: a strict endpoint 400s an unknown field
rather than ignoring it, which is why the style is declared per provider rather
than guessed from the URL.

`effort` overrides the provider's configured value and is how the truncation
ladder steps down without writing to the shared provider table -- doing that
would silently change the user's setting for the rest of the session and leave
the menu showing the degraded value.
]]
function LLM:buildReasoningBody(body, config, effort)
    effort = effort or config.reasoning_effort
    if not effort or effort == "" then return body end       -- not configured
    if not self:isValidEffort(effort) then
        logger.warn("LLM: ignoring unknown reasoning effort:", tostring(effort))
        return body
    end

    if config.reasoning_style == "openrouter" then
        -- "none" is not a value OpenRouter will take -- it answers with 400
        -- "Reasoning is mandatory for this endpoint" -- so here it can only
        -- mean "ask for nothing and accept the provider's default".
        if effort == "none" then return body end
        body.reasoning = { effort = effort }
        if config.reasoning_exclude then body.reasoning.exclude = true end
    else
        -- Passed through as written, "none" included. On the OpenAI wire
        -- format "none" is a real value that genuinely disables thinking on
        -- the newer models, and the LiteLLM backend validates the field --
        -- an invalid value comes back 400 -- so swallowing it here would turn
        -- a deliberate setting into a silent no-op.
        body.reasoning_effort = effort
    end
    return body
end

LLM.model_override = nil

-- Set Gemini model
function LLM:setGeminiModel(model_name)
    if not model_name or #model_name == 0 then return false end
    self.providers.gemini.model = model_name
    self:saveModelToConfig(model_name)
    return true
end

-- Set ChatGPT model
function LLM:setChatGPTModel(model_name)
    if not model_name or #model_name == 0 then return false end
    self.providers.chatgpt.model = model_name
    self:saveModelToConfig(model_name, "chatgpt")
    return true
end

-- Set default provider
-- Validated against the provider table rather than a hardcoded pair, so
-- adding a provider above is all it takes to make it selectable.
function LLM:setDefaultProvider(provider_name)
    if not provider_name or not self.providers[provider_name] then
        return false
    end
    self.default_provider = provider_name
    self:saveProviderToConfig(provider_name)
    logger.info("LLM: Default provider changed to:", provider_name)
    return true
end

-- Save model preference to config file
function LLM:saveModelToConfig(model_name, provider)
    provider = provider or "gemini"
    local DataStorage = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()
    local grimoria_dir = settings_dir .. "/grimoria"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(grimoria_dir)
    
    local model_file = grimoria_dir .. "/" .. provider .. "_model.txt"
    local file = io.open(model_file, "w")
    if file then
        file:write(model_name)
        file:close()
        return true
    end
    return false
end

-- Set and persist the model of any provider. The per-provider setters above
-- predate this and stay for their existing callers.
function LLM:setProviderModel(provider, model_name)
    if not model_name or #model_name == 0 then return false end
    local cfg = self.providers[provider]
    if not cfg then return false end
    cfg.model = model_name
    self:saveModelToConfig(model_name, provider)
    return true
end

-- Persist an arbitrary field of a provider (endpoint, reasoning_effort, ...)
-- to settings/grimoria/<provider>_<field>.txt, where loadModelFromFile picks it up.
function LLM:saveProviderField(provider, field, value)
    local cfg = self.providers[provider]
    if not cfg then return false end

    local DataStorage = require("datastorage")
    local grimoria_dir = DataStorage:getSettingsDir() .. "/grimoria"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(grimoria_dir)

    local f = io.open(grimoria_dir .. "/" .. provider .. "_" .. field .. ".txt", "w")
    if not f then
        logger.warn("LLM: could not save", provider, field)
        return false
    end
    f:write(value)
    f:close()
    cfg[field] = value
    return true
end


-- Save provider preference to config file
function LLM:saveProviderToConfig(provider_name)
    local DataStorage = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()
    local grimoria_dir = settings_dir .. "/grimoria"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(grimoria_dir)
    
    local provider_file = grimoria_dir .. "/default_provider.txt"
    local file = io.open(provider_file, "w")
    if file then
        file:write(provider_name)
        file:close()
        logger.info("LLM: Saved default provider:", provider_name)
        return true
    end
    logger.warn("LLM: Failed to save provider preference")
    return false
end

-- Initialize LLM
function LLM:init()
    self:loadConfig()
    self:loadModelFromFile()
    self:loadLanguage()
    self:loadEnvOverrides()   -- last, so the environment wins over every file
    logger.info("LLM: Initialized with Gemini model:", self.providers.gemini.model)
    logger.info("LLM: ChatGPT model:", self.providers.chatgpt.model)
end

--[[
Environment overrides, applied after every file-based source so they win.

    export GEMINI_API_KEY=...
    export OPENAI_API_KEY=...
    export GRIMORIA_GEMINI_MODEL=gemini-3.5-flash   (optional)

On a Kindle put the export lines near the top of koreader/koreader.sh, before
it launches reader.lua. Keeping the key out of the plugin directory means a
plugin update or a re-copy of the folder can't clobber or leak it.
]]
function LLM:loadEnvOverrides()
    local function env(name)
        local ok, v = pcall(os.getenv, name)
        if not ok or not v then return nil end
        v = v:gsub("%s+", "")
        return #v > 0 and v or nil
    end

    local gk = env("GEMINI_API_KEY")
    if gk then
        self.providers.gemini.api_key = gk
        logger.info("LLM: Gemini API key taken from GEMINI_API_KEY")
    end

    local ok = env("OPENAI_API_KEY")
    if ok then
        self.providers.chatgpt.api_key = ok
        logger.info("LLM: ChatGPT API key taken from OPENAI_API_KEY")
    end

    local gm = env("GRIMORIA_GEMINI_MODEL")
    if gm then self.providers.gemini.model = gm end

    -- Custom OpenAI-compatible endpoint. LITELLM_API_KEY is accepted as an
    -- alias because that is what the proxy's own documentation tells people to
    -- export.
    local ck = env("GRIMORIA_CUSTOM_API_KEY") or env("LITELLM_API_KEY")
    if ck then
        self.providers.custom.api_key = ck
        logger.info("LLM: Custom API key taken from the environment")
    end
    local ce = env("GRIMORIA_CUSTOM_ENDPOINT")
    if ce then self.providers.custom.endpoint = ce end
    local cm = env("GRIMORIA_CUSTOM_MODEL")
    if cm then self.providers.custom.model = cm end
    local ce2 = env("GRIMORIA_CUSTOM_EFFORT")
    if ce2 then self.providers.custom.reasoning_effort = ce2 end

    -- OPENROUTER_API_KEY is what OpenRouter's own documentation tells people to
    -- export, so it is accepted alongside the namespaced form.
    local ok2 = env("GRIMORIA_OPENROUTER_API_KEY") or env("OPENROUTER_API_KEY")
    if ok2 then
        self.providers.openrouter.api_key = ok2
        logger.info("LLM: OpenRouter API key taken from the environment")
    end
    local om = env("GRIMORIA_OPENROUTER_MODEL")
    if om then self.providers.openrouter.model = om end
    local oe = env("GRIMORIA_OPENROUTER_EFFORT")
    if oe then self.providers.openrouter.reasoning_effort = oe end
end

-- Load configuration
function LLM:loadConfig()
    local success, config = pcall(require, "config")
    if success and config then
        if config.gemini_api_key then self.providers.gemini.api_key = config.gemini_api_key end
        if config.gemini_model then self.providers.gemini.model = config.gemini_model end
        if config.chatgpt_api_key then self.providers.chatgpt.api_key = config.chatgpt_api_key end
        if config.chatgpt_model then self.providers.chatgpt.model = config.chatgpt_model end
        -- callChatGPT already honours config.endpoint, but nothing ever set it.
        -- Exposing it here makes the "chatgpt" provider work against any
        -- OpenAI-compatible endpoint (GLM, OpenRouter, Groq, a local server).
        if config.chatgpt_endpoint then self.providers.chatgpt.endpoint = config.chatgpt_endpoint end
        if config.openrouter_api_key then self.providers.openrouter.api_key = config.openrouter_api_key end
        if config.openrouter_model then self.providers.openrouter.model = config.openrouter_model end
        if config.openrouter_endpoint then self.providers.openrouter.endpoint = config.openrouter_endpoint end
        if config.openrouter_reasoning_effort then
            self.providers.openrouter.reasoning_effort = config.openrouter_reasoning_effort
        end
        if config.custom_api_key then self.providers.custom.api_key = config.custom_api_key end
        if config.custom_endpoint then self.providers.custom.endpoint = config.custom_endpoint end
        if config.custom_model then self.providers.custom.model = config.custom_model end
        if config.custom_name then self.providers.custom.name = config.custom_name end
        if config.custom_reasoning_effort then
            self.providers.custom.reasoning_effort = config.custom_reasoning_effort
        end
        if config.default_provider then self.default_provider = config.default_provider end
        if config.settings then self.settings = config.settings end
    end
end

--[[
Load per-provider preferences from settings/grimoria/.

    <provider>_model.txt      model name
    <provider>_api_key.txt    API key
    <provider>_endpoint.txt   base URL (OpenAI-compatible providers only)
    <provider>_reasoning_effort.txt   none|minimal|low|medium|high|xhigh
    default_provider.txt      which provider to use

Driven by the provider table instead of one hand-written block per provider,
which is what let "custom" be added without a fourth copy of this code -- and
what stops a saved preference from being silently discarded because a
hardcoded name check didn't know about it.
]]
function LLM:loadModelFromFile()
    local Paths = require("lib/paths")

    -- Reads the current settings directory, then the pre-rename one, so a
    -- reader who already had a key configured does not have to find it again.
    local function readFile(filename)
        return Paths:readSetting(filename)
    end

    for name, cfg in pairs(self.providers) do
        for _, field in ipairs(self.FILE_FIELDS) do
            -- endpoint/reasoning_effort mean nothing for a provider whose URL
            -- is fixed (Gemini), so only read what that provider can use.
            local applies = (field == "model" or field == "api_key")
                or cfg[field] ~= nil or cfg.endpoint ~= nil
            if applies then
                local v = readFile(name .. "_" .. field .. ".txt")
                if v then
                    cfg[field] = v
                    logger.info("LLM: loaded", name, field, "from file")
                end
            end
        end
    end

    local provider = readFile("default_provider.txt")
    if provider and self.providers[provider] then
        self.default_provider = provider
        logger.info("LLM: Loaded default provider from file:", provider)
    end
end


-- Save API Key preference to file
function LLM:saveAPIKeyToFile(provider, api_key)
    local DataStorage = require("datastorage")
    local settings_dir = DataStorage:getSettingsDir()
    local grimoria_dir = settings_dir .. "/grimoria"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(grimoria_dir)
    
    local key_file = grimoria_dir .. "/" .. provider .. "_api_key.txt"
    local file = io.open(key_file, "w")
    if file then
        file:write(api_key)
        file:close()
        logger.info("LLM: Saved", provider, "API key to file")
        return true
    end
    logger.warn("LLM: Failed to save", provider, "API key")
    return false
end

-- Get book data from AI
function LLM:getBookData(title, author, provider_name, context)
    self:loadModelFromFile() -- Refresh model
    local provider = provider_name or "gemini"
    local provider_config = self.providers[provider]
    
    if not provider_config or not provider_config.api_key then
        return nil, "error_no_api_key"
    end
    
    -- Build the prompt with the context
    local prompt = self:createPrompt(title, author, context)
    
    logger.info("LLM: Using provider:", provider, "Model:", provider_config.model)
    if context and context.spoiler_free then
        logger.info("LLM: Spoiler-free mode active, reading:", context.reading_percent, "%")
    end
    
    if provider == "gemini" then
        return self:callGemini(prompt, provider_config)
    elseif provider_config.endpoint then
        -- Everything that isn't Gemini speaks OpenAI chat-completions here --
        -- chatgpt, custom, openrouter. Keyed on the endpoint rather than a list
        -- of names so a new provider needs no change on this line.
        return self:callChatGPT(prompt, provider_config)
    end
    return nil, "error_unknown_provider"
end

-- Check network
function LLM:checkNetworkConnectivity()
    local socket = require("socket")
    local success, err = pcall(function()
        local tcp = socket.tcp()
        tcp:settimeout(3)
        local result = tcp:connect("8.8.8.8", 53)
        tcp:close()
        return result
    end)
    return success
end

-- Load language
function LLM:loadLanguage()
    local Paths = require("lib/paths")
    self.current_language = Paths:readSetting("language.txt") or "en"

    -- The UI language and the language the AI WRITES IN are separate concerns:
    -- someone reading Vietnamese books may still want an English interface,
    -- and the reverse is just as common.
    --
    -- Absent or empty, the AI answers in the BOOK's own language -- not the
    -- interface language, and not English. That is the right default: an index
    -- of a Vietnamese novel reads badly in English, and the names have to match
    -- the page in front of the reader anyway. See createPrompt's OUTPUT
    -- LANGUAGE clause, which is where the behaviour actually lives.
    --
    -- settings/grimoria/output_language.txt overrides it with a plain language
    -- name such as "English"; "auto" means the same as leaving it empty.
    local forced = Paths:readSetting("output_language.txt")
    if forced then self.output_language = forced end

    self:loadPrompts()
end

--[[
Load prompts: start from English, then let a localized file override whichever
keys it happens to define.

Only prompts/en.lua ships. The prompt is instructions addressed to the model,
not text the reader ever sees, and the models handle English instructions at
least as well as translated ones -- while a translated prompt is one more thing
to keep in sync with the JSON schema every time it changes. What the model
WRITES is a separate setting and defaults to the book's own language.

The merge is kept because it costs nothing and a prompts/<lang>.lua dropped in
later starts overriding immediately, key by key.
]]
function LLM:loadPrompts()
    local merged = {}
    local ok_en, en = pcall(require, "prompts/en")
    if ok_en and type(en) == "table" then
        for k, v in pairs(en) do merged[k] = v end
    end
    if self.current_language and self.current_language ~= "en" then
        local ok_l, loc = pcall(require, "prompts/" .. self.current_language)
        if ok_l and type(loc) == "table" then
            for k, v in pairs(loc) do merged[k] = v end
        end
    end
    self.prompts = merged
end

-- Markers around the book text. callGemini's shrink-on-429 logic finds the
-- block by these, so they must stay in sync with the wording in prompts/en.lua.
LLM.TEXT_START = "<<<BOOK_TEXT_START>>>"
LLM.TEXT_END   = "<<<BOOK_TEXT_END>>>"

--[[
Assemble the prompt from the per-feature sections.

context.book_text  chapter-marked text from lib/booktext (may be nil)
context.truncated  true when the tail of the book was dropped
]]
function LLM:createPrompt(title, author, context)
    if not self.prompts then self:loadLanguage() end
    local p = self.prompts
    context = context or {}

    local parts = {
        p.system_instruction,
        string.format('Book: "%s"\nAuthor: %s', title or "Unknown", author or "Unknown"),
        p.grounding,
        p.section_spoilers,
        p.section_language,
        p.section_chapters,
        p.section_characters,
        p.section_merges,
        p.section_locations,
        p.section_themes,
        p.section_historical_figures,
        string.format(p.section_author_bio, author or "Unknown"),
        p.json_schema,
    }

    -- Long books can ask for more per-chapter detail than the reply is allowed
    -- to contain (65,536 output tokens, shared with the thinking pass). Say the
    -- ceiling out loud rather than letting the answer be cut off mid-JSON.
    if context.chapter_count and context.chapter_count > 25 then
        parts[#parts + 1] = string.format(
            "LENGTH BUDGET: this book has %d chapters, which is a lot. Emit at "
            .. "most about %d by_chapter entries IN TOTAL across all characters. "
            .. "Spend them on chapters where something genuinely happens to that "
            .. "character, and keep each to one sentence. Minor characters may "
            .. "have only one or two entries. Chapter summaries stay short (2-3 "
            .. "sentences). A complete, valid JSON object matters more than "
            .. "exhaustive detail -- never run long enough to be cut off.",
            context.chapter_count, context.dev_budget or 700)
    end

    if context.book_text and #context.book_text > 0 then
        local note = ""
        if context.truncated then
            note = "\n(The tail of the book was cut to fit request limits; the "
                .. "text below ends partway through. Analyse only what is here.)"
        end
        parts[#parts + 1] = self.TEXT_START .. note .. "\n"
            .. context.book_text .. "\n" .. self.TEXT_END
    else
        -- Extraction failed. Fall back to the old title-only behaviour but say
        -- so, otherwise the model answers as though it had read the text.
        parts[#parts + 1] =
            "NOTE: no book text could be extracted from the device, so the "
            .. "GROUNDING RULES cannot be applied. Answer from general knowledge "
            .. "of this exact title, and if you do not reliably know it, say so "
            .. "in the summary rather than guessing. Leave 'chapters' empty."
    end

    local prompt = table.concat(parts, "\n\n")

    -- Appended last so it outranks anything above it. Keys stay English because
    -- main.lua indexes the decoded JSON by name -- only the values get translated.
    -- Empty or "auto" means: match whatever language the book itself is in.
    local forced = self.output_language
    if forced and #forced > 0 and forced:lower() ~= "auto" then
        prompt = prompt .. "\n\nOUTPUT LANGUAGE: Write every JSON *value* in "
            .. forced .. "."
    else
        prompt = prompt .. "\n\nOUTPUT LANGUAGE: Write every JSON *value* in the "
            .. "same language as the book text itself (the language you report "
            .. "in book_language)."
    end
    prompt = prompt .. " Keep all JSON keys exactly as given, in English, and "
        .. "keep character and place names in their original spelling."

    return prompt
end

function LLM:getFallbackStrings()
    if not self.prompts then self:loadPrompts() end
    return self.prompts.fallback or {}
end

--[[
Cut the book-text block down by `factor` and hand back the rewritten prompt.

Used when the request is too big for the moment - a 429 (rate limit) or a
MAX_TOKENS reply. Trimming from the FRONT of the block keeps the later
chapters, but we keep the earlier ones instead: a reader partway through only
ever sees early chapters anyway, and the per-chapter filter degrades cleanly
when the tail is missing.
]]
function LLM:shrinkBookTextInPrompt(prompt, factor)
    local s = prompt:find(self.TEXT_START, 1, true)
    local e = prompt:find(self.TEXT_END, 1, true)
    if not s or not e or e <= s then return nil end

    local inner = prompt:sub(s + #self.TEXT_START, e - 1)
    local keep = math.floor(#inner * factor)
    if keep < 5000 then return nil end   -- below this the analysis is worthless

    local shrunk = inner:sub(1, keep)
    shrunk = shrunk:gsub("[\194-\244][\128-\191]*$", "")  -- don't end mid-codepoint

    local block = self.TEXT_START
        .. "\n(Text was shortened further to fit request limits; it ends "
        .. "partway through the book. Analyse only what is here.)\n"
        .. shrunk .. "\n" .. self.TEXT_END

    logger.info("LLM: shrank book text", #inner, "->", #shrunk, "chars")
    return prompt:sub(1, s - 1) .. block .. prompt:sub(e + #self.TEXT_END)
end

-- Call Google Gemini API
-- state = { shrink = <fraction of original text still present> } on retries.
function LLM:callGemini(prompt, config, state)
    logger.info("LLM: Calling Google Gemini API")
    state = state or { shrink = 1.0 }

    if not self:checkNetworkConnectivity() then
        return nil, "error_no_network", "No internet connection"
    end

    local model = config.model or "gemini-3.5-flash"
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. config.api_key
    
    -- Safety filters OFF. Not optional: serious literature trips them
    -- routinely -- murder, suicide and abuse are ordinary subject matter
    -- in a novel, and a blocked response costs the whole book's tokens.
    local safety_settings = {
        { category = "HARM_CATEGORY_HARASSMENT", threshold = "BLOCK_NONE" },
        { category = "HARM_CATEGORY_HATE_SPEECH", threshold = "BLOCK_NONE" },
        { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
        { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" }
    }

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        safetySettings = safety_settings,
        generationConfig = {
            temperature = 0.4,
            topK = 40,
            topP = 0.95,
            -- 8192 was fine before thinking models. On Gemini 3.x the thinking
            -- pass spends this same budget -- measured 6500-7400 tokens on a
            -- 20-character index -- leaving too little for the answer, so the
            -- reply came back finishReason=MAX_TOKENS with truncated JSON.
            -- 65536 is the model's actual outputTokenLimit (per the models
            -- endpoint); per-chapter data for a long book needs the headroom.
            maxOutputTokens = 65536,
            responseMimeType = "application/json" -- JSON Modu
        }
    })
    
    -- A whole book of input takes the model minutes to read, and the Kindle
    -- must upload several hundred KB first. Measured: a 334k-char prompt took
    -- 209s from a fast desktop connection.
    --
    -- NOTE: passing `timeout =` inside the https.request{} table does NOT work
    -- -- LuaSocket ignores unknown fields, so every large request died at the
    -- 60s default (confirmed in crash.log: "API Code: nil" exactly 60s after
    -- "Calling Google Gemini API", twice). The timeout has to be set on the
    -- module, which is what socketutil does properly for both the per-block
    -- and total budgets.
    local req_timeout = 120
    if #prompt > 400000 then req_timeout = 900
    elseif #prompt > 150000 then req_timeout = 600 end

    local socketutil = nil
    pcall(function() socketutil = require("socketutil") end)
    local function setTimeouts()
        if socketutil then
            -- (per-block, total): a stalled socket still fails fast, while the
            -- whole exchange gets the long budget it needs.
            socketutil:set_timeout(60, req_timeout)
        else
            https.TIMEOUT = req_timeout
            http.TIMEOUT = req_timeout
        end
    end
    local function clearTimeouts()
        if socketutil then socketutil:reset_timeout() end
    end

    -- RETRY LOGIC. 503 is Google's own capacity problem and costs no quota, so
    -- it is worth waiting out properly -- the old 2 tries 3s apart gave up
    -- after 16 seconds (crash.log 23:13).
    local max_retries = 3
    for attempt = 1, max_retries + 1 do
        if attempt > 1 then
             local socket = require("socket")
             socket.sleep(15 * (attempt - 1))   -- 15s, 30s, 45s
        end

        local response_body = {}
        setTimeouts()
        local res, code, headers, status = https.request{
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#request_body),
            },
            source = ltn12.source.string(request_body),
            sink = ltn12.sink.table(response_body),
        }
        clearTimeouts()

        local response_text = table.concat(response_body)
        local code_num = tonumber(code)
        
        logger.info("LLM: API Code:", code_num, "Length:", #response_text)

        if code_num == 200 then
            local success, data = pcall(json.decode, response_text)
            if not success then return nil, "error_json_parse" end
            
            -- CRASH PROTECTION: null-check the whole chain before indexing
            if data and data.candidates and data.candidates[1] then
                local candidate = data.candidates[1]
                
                -- Blocked by the safety filter?
                if candidate.finishReason == "SAFETY" then
                     logger.warn("LLM: BLOCKED BY SAFETY FILTER")
                     return nil, "error_safety", "Blocked by Google's safety filter."
                end

                -- Truncated by the output budget: the JSON is cut mid-string, so
                -- parseAIResponse would fail with a json error that points nowhere
                -- near the real cause. Say what actually happened instead.
                if candidate.finishReason == "MAX_TOKENS" then
                    logger.warn("LLM: MAX_TOKENS - response truncated")
                    -- Ask for a shorter ANSWER before cutting the book down:
                    -- trimming the text loses coverage of real chapters, while
                    -- terser entries keep the whole book in view.
                    if not state.brief then
                        logger.info("LLM: retrying with a brevity directive")
                        return self:callGemini(
                            prompt .. "\n\nHARD LIMIT: the previous attempt was cut "
                            .. "off. Be much terser -- at most 250 by_chapter entries "
                            .. "in total, one short clause each, and only the 12 most "
                            .. "important characters. A complete JSON object is the "
                            .. "priority.",
                            config, { shrink = state.shrink, brief = true })
                    end
                    -- Still too long: now shrink the input as a last resort.
                    if state.shrink > 0.35 then
                        local smaller = self:shrinkBookTextInPrompt(prompt, 0.6)
                        if smaller then
                            return self:callGemini(smaller, config,
                                { shrink = state.shrink * 0.6, brief = true })
                        end
                    end
                    return nil, "error_max_tokens",
                        "The book is long enough that the reply keeps hitting the size limit.\n\n" ..
                        "Lower the value in settings/grimoria/max_text_chars.txt\n" ..
                        "(try 500000) and analyse again."
                end

                if candidate.content and candidate.content.parts then
                    -- Thinking models may put a thought part first; take the first
                    -- part that actually carries text rather than assuming [1].
                    for _, part in ipairs(candidate.content.parts) do
                        if part.text and #part.text > 0 then
                            return self:parseAIResponse(part.text)
                        end
                    end
                    logger.warn("LLM: No text in any response part")
                    return nil, "error_api", "The API returned an empty response."
                else
                    logger.warn("LLM: No text in response")
                    return nil, "error_api", "The API returned an empty response."
                end
            else
                return nil, "error_api", "Invalid response format"
            end
        elseif code_num == nil then
            -- No HTTP status at all: the socket died. `code` carries the
            -- LuaSocket reason ("timeout", "closed", "connection refused").
            local why = tostring(code or status or "unknown")
            logger.warn("LLM: no HTTP response:", why)
            if attempt > max_retries then
                if why == "timeout" then
                    return nil, "error_timeout",
                        "No reply from Google within " .. req_timeout .. "s.\n\n" ..
                        "A whole book is a large upload. Try again on stronger wifi, " ..
                        "or lower the size limit in\nsettings/grimoria/max_text_chars.txt"
                end
                return nil, "error_network",
                    "Lost connection to Google (" .. why .. ").\n\n" ..
                    "Check wifi is still on and try again."
            end
        elseif code_num == 503 then
             logger.warn("LLM: 503 Service Unavailable (Retrying...)")
             if attempt > max_retries then
                 return nil, "error_503",
                     "Google's servers are overloaded right now (503).\n\n" ..
                     "This is temporary and costs none of your daily quota. " ..
                     "Wait a few minutes and try again."
             end
        elseif code_num == 404 then
            return nil, "error_404",
                "Model not found (404).\n\n" ..
                "The selected model has been retired. Pick another in\n" ..
                "Menu -> Grimoria -> Gemini model."
        elseif code_num == 400 then
            return nil, "error_400",
                "Google rejected the request (400).\n\n" ..
                "The book may be too large. Lower the limit in\n" ..
                "settings/grimoria/max_text_chars.txt and try again."
        elseif code_num == 403 then
            return nil, "error_403",
                "API key rejected (403).\n\n" ..
                "Check the key in Menu -> Grimoria -> AI Settings."
        elseif code_num == 429 then
            -- Free tier limits by tokens-per-minute, and a whole book is a lot
            -- of tokens. Wait it out first; only shrink the request if waiting
            -- doesn't clear it.
            logger.warn("LLM: 429 rate limited")
            local socket = require("socket")
            if attempt == 1 then
                socket.sleep(20)
            else
                if state.shrink > 0.35 then
                    local smaller = self:shrinkBookTextInPrompt(prompt, 0.5)
                    if smaller then
                        socket.sleep(20)
                        return self:callGemini(smaller, config,
                            { shrink = state.shrink * 0.5 })
                    end
                end
                return nil, "error_429",
                    "Daily quota used up for this model (429).\n\n" ..
                    "The free tier allows 20 analyses per day PER MODEL.\n" ..
                    "Switch model in Menu -> Grimoria -> Gemini model -- each one\n" ..
                    "has its own daily allowance -- or try again tomorrow."
            end
        else
             return nil, "error_" .. tostring(code_num),
                 "Google returned an unexpected error (" .. tostring(code_num) .. ").\n\n" ..
                 "Try again; if it persists, switch model in\nMenu -> Grimoria -> Gemini model."
        end
    end

    return nil, "error_timeout",
        "Gave up after " .. (max_retries + 1) .. " attempts.\n\n" ..
        "Google was unreachable or overloaded. Try again later."
end

--[[
An ltn12 sink that decodes an OpenAI SSE stream as it arrives.

Deliberately incremental rather than "collect everything, parse at the end":
the wire form is ~10x the size of the text it carries (a 60 KB answer arrived
as 650 KB of SSE in testing), and holding that on a Kindle alongside the
prompt and the request body is exactly the memory pressure the book-size
hardening was fighting.

Returns the sink and the accumulator it fills:
  acc.parts   content deltas, table.concat at the end
  acc.finish  finish_reason from whichever chunk carries it
  acc.err     an error object if the endpoint streamed one
  acc.head    first few KB raw, so a non-200 body can still be reported
]]
local function makeSSESink(acc)
    local buf = ""
    return function(chunk, err)
        if chunk == nil or chunk == "" then return 1 end   -- nil = end of stream

        if #acc.head < 4096 then
            acc.head = acc.head .. chunk:sub(1, 4096 - #acc.head)
        end

        buf = buf .. chunk
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1):gsub("\r$", "")
            buf = buf:sub(nl + 1)

            if line:sub(1, 6) == "data: " then
                local payload = line:sub(7)
                if payload ~= "[DONE]" then
                    local ok, obj = pcall(json.decode, payload)
                    if ok and type(obj) == "table" then
                        if obj.error then acc.err = obj.error end
                        local c = obj.choices and obj.choices[1]
                        if c then
                            if c.delta and type(c.delta.content) == "string" then
                                acc.parts[#acc.parts + 1] = c.delta.content
                            end
                            -- Thinking, when the provider streams it back
                            -- despite `exclude`. Counted and dropped rather
                            -- than accumulated: it is not part of the answer,
                            -- and on a high-effort whole-book pass it is tens
                            -- of thousands of tokens this device would be
                            -- holding in memory for nothing. The count is kept
                            -- because "did it think at all?" is otherwise
                            -- unanswerable from the log.
                            if c.delta and type(c.delta.reasoning) == "string" then
                                acc.reasoning_bytes = (acc.reasoning_bytes or 0) + #c.delta.reasoning
                            end
                            if c.finish_reason then acc.finish = c.finish_reason end
                        end
                        if obj.usage then acc.usage = obj.usage end
                    end
                end
            end
        end
        return 1
    end
end

--[[
Call any OpenAI-compatible chat-completions endpoint.

Serves both the "chatgpt" and "custom" providers -- OpenAI, a LiteLLM proxy,
OpenRouter, GLM, a local server -- since they all speak the same wire format
and differ only in endpoint, model and key.

This path had none of the hardening the Gemini path got: an 8192 output cap
that a per-chapter index cannot fit in, no handling for a truncated reply
(it fell through to the JSON parser and surfaced as "error_json_parse",
pointing nowhere near the real cause), a timeout tier that stopped at 600s,
and no User-Agent -- which a Cloudflare-fronted proxy answers with 403.

state = { shrink = <fraction of the original text still present>, brief = ... }
on retries, same contract as callGemini.
]]
function LLM:callChatGPT(prompt, config, state)
    logger.info("LLM: Calling OpenAI-compatible API")
    state = state or { shrink = 1.0 }

    if not self:checkNetworkConnectivity() then
        return nil, "error_no_network", "No internet connection."
    end

    local model = config.model or "gpt-4o-mini"
    local url = config.endpoint or "https://api.openai.com/v1/chat/completions"
    local label = config.name or "the AI service"

    local system_instruction = self.prompts and self.prompts.system_instruction or
        "You are an expert literary critic. Respond ONLY with valid JSON format."

    local streaming = config.stream and true or false

    -- The effort actually used on this attempt. state.effort is set by the
    -- truncation ladder below; config.reasoning_effort is the user's setting
    -- and is never written to from here.
    local effort = state.effort or config.reasoning_effort

    local body = {
        model = model,
        messages = {
            { role = "system", content = system_instruction },
            { role = "user", content = prompt },
        },
        temperature = 0.4,
        -- A whole-book per-chapter index does not fit in 8192, and on a
        -- reasoning model the thinking pass spends this same budget. Providers
        -- differ in what they accept (OpenAI's small models cap far lower than
        -- a proxy fronting a large one), so it comes from the provider entry.
        max_tokens = config.max_output_tokens or 16384,
        top_p = 0.95,
        response_format = { type = "json_object" },
        stream = streaming or nil,
    }
    -- Only sent when configured, and in whichever spelling this endpoint
    -- understands. An endpoint that doesn't know the field ignores it; one
    -- that does will reject a bad value outright, which is what makes it
    -- verifiable rather than merely hoped for.
    self:buildReasoningBody(body, config, effort)

    local request_body = json.encode(body)

    logger.info("LLM: request size:", #request_body, "model:", model,
                "streaming:", tostring(streaming),
                "reasoning:", tostring(effort or "off"))

    local req_timeout = 120
    if #prompt > 400000 then req_timeout = 900
    elseif #prompt > 150000 then req_timeout = 600 end
    -- Streaming trades one long silence for a slow trickle, so the exchange
    -- itself runs longer even though it never stalls. The per-block timeout is
    -- what actually catches a dead connection here.
    if streaming then req_timeout = req_timeout * 2 end

    -- Same trap as callGemini: a `timeout` field inside the request table is
    -- ignored by LuaSocket, so it has to be set on the module first.
    local socketutil = nil
    pcall(function() socketutil = require("socketutil") end)
    -- Per-block budget. 60s is right for a single-shot request, where silence
    -- means a dead socket -- but under streaming a long silence is just the
    -- model thinking before it emits its first token, and killing that would
    -- reproduce the "API Code: nil at exactly the timeout" bug on a path where
    -- the connection is perfectly healthy. req_timeout still bounds the whole
    -- exchange, so a genuinely dead socket cannot hang forever either.
    local block_timeout = streaming and 300 or 60
    local function setTimeouts()
        if socketutil then socketutil:set_timeout(block_timeout, req_timeout)
        else https.TIMEOUT = req_timeout; http.TIMEOUT = req_timeout end
    end
    local function clearTimeouts()
        if socketutil then socketutil:reset_timeout() end
    end

    local max_retries = 3
    for attempt = 1, max_retries + 1 do
        if attempt > 1 then
            local socket = require("socket")
            socket.sleep(10 * (attempt - 1))   -- 10s, 20s, 30s
            logger.info("LLM: retrying request (attempt " .. attempt .. ")")
        end

        local headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. config.api_key,
            ["Content-Length"] = tostring(#request_body),
        }
        -- KOReader's LuaSocket sends a User-Agent that Cloudflare-fronted
        -- proxies reject outright, so a provider may pin one.
        if config.user_agent then headers["User-Agent"] = config.user_agent end
        if streaming then headers["Accept"] = "text/event-stream" end
        -- Provider-specific extras (OpenRouter's HTTP-Referer / X-Title).
        -- Applied last, but never over Authorization or Content-Length.
        for k, v in pairs(config.extra_headers or {}) do
            if k ~= "Authorization" and k ~= "Content-Length" then headers[k] = v end
        end

        local response_body = {}
        local acc = { parts = {}, head = "" }
        setTimeouts()
        local res, code, rheaders, status = https.request{
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(request_body),
            sink = streaming and makeSSESink(acc) or ltn12.sink.table(response_body),
        }
        clearTimeouts()

        local response_text = streaming and acc.head or table.concat(response_body)
        local code_num = tonumber(code)

        logger.info("LLM: API Code:", code_num,
                    streaming and ("stream parts: " .. #acc.parts) or ("Length: " .. #response_text))

        --[[
        Log the token accounting before anything branches on the result, so a
        truncated or empty run reports it too -- those are exactly the runs
        where it explains what happened.

        Two numbers matter. `reasoning` proves the thinking pass ran at all,
        which is otherwise invisible when the thoughts are excluded from the
        stream. And `completion` includes the reasoning tokens, so
        completion >= max_tokens is the signature of a budget spent thinking
        instead of answering -- the case the effort step-down below exists for.
        ]]
        local u = acc.usage
        if u then
            local d = u.completion_tokens_details or {}
            logger.info("LLM: tokens -- prompt:", u.prompt_tokens,
                        "completion:", u.completion_tokens,
                        "reasoning:", d.reasoning_tokens,
                        "budget:", config.max_output_tokens or 16384)
        elseif acc.reasoning_bytes then
            logger.info("LLM: reasoning streamed:", acc.reasoning_bytes, "bytes")
        end

        -- Normalise the streamed result into the same shape the non-streaming
        -- branch below expects, so there is only one place that interprets a
        -- reply. An error streamed mid-flight surfaces here too.
        local choice, incomplete = nil, false
        if code_num == 200 and streaming then
            if acc.err then
                local msg = (type(acc.err) == "table" and acc.err.message) or tostring(acc.err)
                logger.warn("LLM: error inside the stream:", msg)
                return nil, "error_api", msg
            end
            --[[
            A stream that stops without a terminal finish_reason was cut off
            mid-flight -- the likeliest failure when a Kindle holds a
            multi-minute connection over wifi. The JSON it carries is
            truncated, so handing it to the parser would surface as a
            meaningless parse error with no message at all. Retry instead.

            "No content at all" is a DIFFERENT failure and must not be folded
            into this one. With reasoning on and the thoughts excluded from the
            stream, a model that spends its whole completion budget thinking
            sends zero content deltas and then a perfectly well-formed terminal
            chunk. That is a completed request: retrying it four times bills
            four more whole-book passes and reports "the connection dropped"
            about a connection that was never in trouble. It falls through to
            the finish_reason handling below, where the effort step-down can
            actually fix it.
            ]]
            if not acc.finish then
                logger.warn("LLM: stream ended early -- parts:", #acc.parts,
                            "finish:", tostring(acc.finish))
                incomplete = true
            elseif #acc.parts == 0 then
                logger.warn("LLM: stream completed with no content -- finish:",
                            acc.finish)
                choice = {
                    finish_reason = acc.finish,
                    message = { content = "" },
                }
            else
                choice = {
                    finish_reason = acc.finish,
                    message = { content = table.concat(acc.parts) },
                }
            end
            acc.parts = nil   -- the text is in `choice` now; let the pieces go
            collectgarbage("step")
        end

        if code_num == 200 and incomplete then
            if attempt > max_retries then
                return nil, "error_stream_incomplete",
                    "The connection to " .. label .. " dropped partway through\n" ..
                    "the reply, " .. (max_retries + 1) .. " times.\n\n" ..
                    "The answer to a whole book takes several minutes to arrive.\n" ..
                    "Try again on stronger wifi, or lower the size limit in\n" ..
                    "settings/grimoria/max_text_chars.txt"
            end
            -- fall through to the next attempt

        elseif code_num == 200 then
            if not choice then
                local success, data = pcall(json.decode, response_text)
                if not success then
                    logger.warn("LLM: JSON parse error on the envelope")
                    return nil, "error_json_parse"
                end

                if data and data.error then
                    local msg = (type(data.error) == "table" and data.error.message)
                        or tostring(data.error)
                    logger.warn("LLM: API error:", msg)
                    return nil, "error_api", msg
                end
                if not (data and data.choices and data.choices[1]) then
                    return nil, "error_api", "Unrecognised reply format from " .. label .. "."
                end
                choice = data.choices[1]
                -- Non-streaming carries usage in the envelope rather than in a
                -- terminal SSE chunk; the checks below read it either way.
                u = data.usage or u
                if u then
                    local d = u.completion_tokens_details or {}
                    logger.info("LLM: tokens -- prompt:", u.prompt_tokens,
                                "completion:", u.completion_tokens,
                                "reasoning:", d.reasoning_tokens)
                end
            end

            do
                if choice.finish_reason == "content_filter" then
                    logger.warn("LLM: blocked by content filter")
                    return nil, "error_safety",
                        "The content filter at " .. label .. " blocked this book."
                end

                -- Truncated by the output budget. The JSON is cut mid-string,
                -- so parsing it would fail with an error that points nowhere
                -- near the cause. Same ladder as Gemini: ask for a shorter
                -- ANSWER first, because trimming the text loses real chapters
                -- while terser entries keep the whole book in view.
                if choice.finish_reason == "length" then
                    logger.warn("LLM: reply truncated (finish_reason=length)")

                    --[[
                    Thinking and answering are paid for out of the same
                    completion budget, so the first thing to give back is some
                    of the thinking. It costs the answer nothing: every
                    by_chapter entry the model would have written is still
                    written, just with a shorter deliberation behind it.

                    This has to come before the brevity directive, which
                    explicitly trims characters and entries out of the result --
                    the least detailed reply is the one worth reaching for last,
                    especially here, where shallow output is the complaint this
                    whole feature exists to answer.
                    ]]
                    local next_effort = self:fallbackEffort(effort)
                    if next_effort then
                        logger.info("LLM: lowering reasoning effort",
                                    tostring(effort), "->", next_effort, "and retrying")
                        return self:callChatGPT(prompt, config, {
                            shrink = state.shrink,
                            brief = state.brief,
                            effort = next_effort,
                        })
                    end

                    if not state.brief then
                        logger.info("LLM: retrying with a brevity directive")
                        return self:callChatGPT(
                            prompt .. "\n\nHARD LIMIT: the previous attempt was cut "
                            .. "off. Be much terser -- at most 250 by_chapter entries "
                            .. "in total, one short clause each, and only the 12 most "
                            .. "important characters. A complete JSON object is the "
                            .. "priority.",
                            config, { shrink = state.shrink, brief = true,
                                      effort = state.effort })
                    end
                    if state.shrink > 0.35 then
                        local smaller = self:shrinkBookTextInPrompt(prompt, 0.6)
                        if smaller then
                            return self:callChatGPT(smaller, config,
                                { shrink = state.shrink * 0.6, brief = true,
                                  effort = state.effort })
                        end
                    end
                    return nil, "error_max_tokens",
                        "The book is long enough that the reply keeps hitting the size limit.\n\n" ..
                        "Lower the value in settings/grimoria/max_text_chars.txt\n" ..
                        "(try 500000) and analyse again."
                end

                if choice.message and choice.message.content
                    and #choice.message.content > 0 then
                    logger.info("LLM: response received, parsing...")
                    return self:parseAIResponse(choice.message.content)
                end
                --[[
                An empty reply that finished cleanly. Turning reasoning on
                makes this reachable for a new reason: the model can spend its
                entire completion budget thinking and stop with nothing left to
                say it with. The usage block distinguishes the two cases, and
                they need opposite responses, so don't report them alike.
                ]]
                local reasoned = u and u.completion_tokens_details
                    and (u.completion_tokens_details.reasoning_tokens or 0) > 0
                if reasoned or (acc.reasoning_bytes or 0) > 0 then
                    local next_effort = self:fallbackEffort(effort)
                    if next_effort then
                        logger.warn("LLM: budget spent entirely on reasoning; lowering",
                                    tostring(effort), "->", next_effort)
                        return self:callChatGPT(prompt, config, {
                            shrink = state.shrink,
                            brief = state.brief,
                            effort = next_effort,
                        })
                    end
                    return nil, "error_api",
                        label .. " thought about the book but never answered.\n\n" ..
                        "Turn the reasoning effort down in\n" ..
                        "Menu -> Grimoria -> AI Settings, or lower the size limit in\n" ..
                        "settings/grimoria/max_text_chars.txt"
                end
                logger.warn("LLM: no content in response")
                return nil, "error_api", label .. " returned an empty reply."
            end

        elseif code_num == nil then
            -- No HTTP status at all: the socket died. `code` carries the
            -- LuaSocket reason ("timeout", "closed", "connection refused").
            local why = tostring(code or status or "unknown")
            logger.warn("LLM: no HTTP response:", why)
            if attempt > max_retries then
                if why == "timeout" then
                    return nil, "error_timeout",
                        "No reply from " .. label .. " within " .. req_timeout .. "s.\n\n" ..
                        "A whole book is a large upload. Try again on stronger wifi, " ..
                        "or lower the size limit in\nsettings/grimoria/max_text_chars.txt"
                end
                return nil, "error_network",
                    "Lost connection to " .. label .. " (" .. why .. ").\n\n" ..
                    "Check wifi is still on and try again."
            end

        elseif code_num == 401 then
            return nil, "error_401",
                "API key rejected (401) by " .. label .. ".\n\n" ..
                "Check the key in Menu -> Grimoria -> AI Settings."

        elseif code_num == 403 then
            -- Distinct from 401 on purpose: a proxy behind Cloudflare answers
            -- 403 "error code: 1010" to user agents it doesn't recognise, and
            -- that is a completely different fix from a bad key.
            return nil, "error_403",
                "Access refused (403) by " .. label .. ".\n\n" ..
                "Either the key lacks permission, or a firewall in front of the\n" ..
                "endpoint rejected the request. Check the endpoint URL in\n" ..
                "settings/grimoria/custom_endpoint.txt"

        elseif code_num == 404 then
            return nil, "error_404",
                "Model not found (404).\n\n" ..
                "\"" .. model .. "\" is not available at this endpoint.\n" ..
                "Set another in settings/grimoria/custom_model.txt"

        elseif code_num == 400 then
            -- The usual cause with a whole book is exceeding the context
            -- window, which the endpoint reports only at this point.
            local detail = ""
            if response_text:lower():find("context") or response_text:lower():find("token") then
                detail = "\n\nThe book is probably larger than this model's context window."
            end
            return nil, "error_400",
                "Request rejected (400) by " .. label .. "." .. detail .. "\n\n" ..
                "Lower the limit in settings/grimoria/max_text_chars.txt and try again."

        elseif code_num == 429 then
            logger.warn("LLM: 429 rate limited")
            if attempt > max_retries then
                return nil, "error_429",
                    "Rate limited (429) by " .. label .. ".\n\n" ..
                    "Wait a few minutes and try again."
            end

        elseif code_num == 500 or code_num == 502 or code_num == 503 or code_num == 504 then
            logger.warn("LLM: " .. tostring(code_num) .. " server error, retrying")
            if attempt > max_retries then
                return nil, "error_" .. tostring(code_num),
                    label .. " is unavailable right now (" .. tostring(code_num) .. ").\n\n" ..
                    "This is temporary. Wait a few minutes and try again."
            end

        else
            logger.warn("LLM: unexpected error code:", code_num)
            return nil, "error_" .. tostring(code_num),
                label .. " returned an unexpected error (" .. tostring(code_num) .. ")."
        end
    end

    return nil, "error_timeout",
        "Gave up after " .. (max_retries + 1) .. " attempts.\n\n" ..
        label .. " was unreachable or overloaded. Try again later."
end

function LLM:parseAIResponse(text)
    -- Temizlik
    local json_text = text:gsub("```json", ""):gsub("```", ""):gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Parse
    local success, data = pcall(json.decode, json_text)
    
    -- On failure, try to isolate whatever sits between the outermost { }
    if not success then
        local first = json_text:find("{")
        local last_brace = nil
        for i = #json_text, 1, -1 do
            if json_text:sub(i,i) == "}" then last_brace = i; break end
        end
        if first and last_brace then
             json_text = json_text:sub(first, last_brace)
             success, data = pcall(json.decode, json_text)
        end
    end

    if success and data then
        -- Seen in the wild: the model wraps the object in a one-element
        -- array, [{...}]. Unwrap rather than fail the whole fetch.
        if type(data) == "table" and data.book_title == nil
            and type(data[1]) == "table" and data[1].book_title ~= nil then
            data = data[1]
        end
        return self:validateAndCleanData(data)
    end

    -- Observed in the wild: gpt-5.6-luna closed the "themes" array with "]]",
    -- one stray bracket in 33,000 characters, with finish_reason "stop" and
    -- JSON mode on -- so this is not truncation and not something the caller's
    -- length ladder can fix. Returning a bare nil here gave main.lua no error
    -- code and no message, which showed up as an empty failure popup. Say what
    -- happened instead; a re-analyse usually produces a clean reply.
    logger.warn("LLM: model returned malformed JSON,", #json_text, "chars")
    return nil, "error_json_parse",
        "The AI's reply was not valid JSON.\n\n" ..
        "This is usually a one-off glitch in the model's output.\n" ..
        "Try 'Re-analyse this book' -- if it keeps happening, switch\n" ..
        "model in Menu -> Grimoria -> AI Settings -> Custom AI: model."
end

function LLM:validateAndCleanData(data)
    if not data then return nil end
    local strings = self:getFallbackStrings()
    
    local function ensureString(v, d)
        return (type(v) == "string" and #v > 0) and v or d or ""
    end

    -- 1. AUTHOR & BOOK (accept either spelling of the field)
    data.book_title = data.book_title or data.title or strings.unknown_book
    data.author = data.author or data.book_author or strings.unknown_author
    data.author_bio = data.author_bio or data.AuthorBio or data.bio or ""
    data.summary = data.summary or data.book_summary or ""

    data.book_language = ensureString(data.book_language, "")

    -- 2. KARAKTERLER
    -- This rebuilds each character rather than passing it through, so any new
    -- field must be listed here or it is silently dropped -- which is exactly
    -- what would happen to by_chapter, the whole point of the redesign.
    local function toInt(v, d)
        local n = tonumber(v)
        return (n and n > 0) and math.floor(n) or d
    end

    local chars = data.characters or data.Characters or {}
    local valid_chars = {}
    for _, c in ipairs(chars) do
        if type(c) == "table" then
            local by_chapter = {}
            for _, bc in ipairs(c.by_chapter or {}) do
                if type(bc) == "table" and bc.development then
                    table.insert(by_chapter, {
                        chapter = toInt(bc.chapter, 1),
                        development = ensureString(bc.development, ""),
                    })
                end
            end
            table.sort(by_chapter, function(a, b) return a.chapter < b.chapter end)

            local intro = ensureString(c.intro, "")
            table.insert(valid_chars, {
                name = ensureString(c.name or c.Name, strings.unnamed_character),
                role = ensureString(c.role or c.Role, strings.not_specified),
                -- Older caches and the no-text fallback path still use
                -- `description`; keep it populated so the views never go blank.
                description = ensureString(c.description or c.desc, intro ~= "" and intro or strings.no_description),
                intro = intro,
                gender = ensureString(c.gender, ""),
                occupation = ensureString(c.occupation, ""),
                first_chapter = toInt(c.first_chapter, by_chapter[1] and by_chapter[1].chapter or 1),
                by_chapter = by_chapter,
            })
        end
    end
    data.characters = valid_chars

    -- 2a-bis. IDENTITY MERGES -- the spoiler mechanism for hidden identities.
    -- Each entry says "these separately-listed identities are one person, and
    -- the text admits it in chapter N". The display layer fuses the entries
    -- at exactly that chapter; before it, they must look unrelated.
    -- Index the character names so merges can be checked against them. A merge
    -- naming an identity that was never listed (observed in the wild) would
    -- otherwise sit in the data doing nothing, and read as a working reveal.
    local known = {}
    for _, c in ipairs(valid_chars) do known[c.name] = true end

    local merges = {}
    for _, m in ipairs(data.identity_merges or {}) do
        if type(m) == "table" and type(m.names) == "table" and #m.names >= 2 then
            local names = {}
            for _, n in ipairs(m.names) do
                if type(n) == "string" and #n > 0 and known[n] then
                    names[#names + 1] = n
                elseif type(n) == "string" then
                    logger.warn("LLM: merge names unknown character:", n)
                end
            end
            -- Fewer than two resolvable names means there is nothing to fuse.
            if #names >= 2 then
                table.insert(merges, {
                    names = names,
                    chapter = toInt(m.chapter, 1),
                    merged_name = ensureString(m.merged_name, table.concat(names, " / ")),
                    true_role = ensureString(m.true_role, ""),
                    revelation = ensureString(m.revelation, ""),
                })
            end
        end
    end
    data.identity_merges = merges

    -- 2b. CHAPTERS
    local chapters = {}
    for i, ch in ipairs(data.chapters or {}) do
        if type(ch) == "table" then
            local events = {}
            for _, ev in ipairs(ch.events or {}) do
                if type(ev) == "table" and ev.event then
                    table.insert(events, {
                        event = ensureString(ev.event, ""),
                        importance = ensureString(ev.importance, ""),
                    })
                end
            end
            table.insert(chapters, {
                index = toInt(ch.index, i),
                title = ensureString(ch.title, ""),
                summary = ensureString(ch.summary, ""),
                events = events,
            })
        end
    end
    table.sort(chapters, function(a, b) return a.index < b.index end)
    data.chapters = chapters

    -- Locations gain first_chapter so they can be filtered like characters.
    local locs = {}
    for _, l in ipairs(data.locations or {}) do
        if type(l) == "table" then
            table.insert(locs, {
                name = ensureString(l.name, ""),
                description = ensureString(l.description, ""),
                importance = ensureString(l.importance, ""),
                first_chapter = toInt(l.first_chapter, 1),
            })
        end
    end
    data.locations = locs

    -- 3. HISTORICAL FIGURES
    local hists = data.historical_figures or data.historicalFigures or {}
    local valid_hists = {}
    for _, h in ipairs(hists) do
        if type(h) == "table" then
            table.insert(valid_hists, {
                name = ensureString(h.name or h.Name, strings.unnamed_person),
                biography = ensureString(h.biography or h.bio, strings.no_biography),
                role = ensureString(h.role, ""),
                importance_in_book = ensureString(h.importance_in_book or h.importance, "Mentioned in the book"),
                context_in_book = ensureString(h.context_in_book or h.context, "Period reference")
            })
        end
    end
    data.historical_figures = valid_hists

    --[[
    4. THEMES -- now chapter-tagged, because they were the biggest spoiler hole
    in the whole design. Measured on Thap Giac Quan: five of six models named
    the murderer inside a theme string, and one spelled out the hidden-identity
    twist outright, while the display layer passed themes through unfiltered on
    the assumption that they were "book-level and rarely spoil a plot".

    A plain string is what every cache written before this change contains, and
    those were produced with no spoiler rule on this field at all. Such a theme
    is treated as end-of-book: visible only in whole-book view or once the
    reader reaches the last chapter. That hides some harmless themes, which is
    the right way round for a filter whose job is to not spoil the ending.
    ]]
    local last_chapter = #data.chapters > 0
        and data.chapters[#data.chapters].index or 1
    local themes = {}
    for _, t in ipairs(data.themes or {}) do
        if type(t) == "string" and #t > 0 then
            themes[#themes + 1] = { theme = t, first_chapter = last_chapter }
        elseif type(t) == "table" then
            local body = ensureString(t.theme or t.name or t.text, "")
            if #body > 0 then
                themes[#themes + 1] = {
                    theme = body,
                    first_chapter = toInt(t.first_chapter, last_chapter),
                }
            end
        end
    end
    data.themes = themes

    -- The AI no longer returns a flat timeline; it comes from chapters[].events.
    -- Build it here so the existing timeline view keeps working unchanged, and
    -- tag each entry with its chapter so the spoiler filter can cut it.
    if not data.timeline or #data.timeline == 0 then
        local timeline = {}
        for _, ch in ipairs(data.chapters) do
            for _, ev in ipairs(ch.events) do
                table.insert(timeline, {
                    event = ev.event,
                    importance = ev.importance,
                    chapter = ch.title ~= "" and ch.title or tostring(ch.index),
                    chapter_index = ch.index,
                })
            end
        end
        data.timeline = timeline
    end

    -- Whole-book summary, stitched from the chapter summaries. The filtered
    -- view rebuilds a shorter one from chapters <= current.
    if (not data.summary or #data.summary == 0) and #data.chapters > 0 then
        local parts = {}
        for _, ch in ipairs(data.chapters) do
            if ch.summary ~= "" then parts[#parts + 1] = ch.summary end
        end
        data.summary = table.concat(parts, " ")
    end

    return data
end

function LLM:setAPIKey(provider, api_key)
    if self.providers[provider] then
        self.providers[provider].api_key = api_key:gsub("%s+", "")
        self:saveAPIKeyToFile(provider, api_key)
        return true
    end
    return false
end

function LLM:testAPIKey(provider)
    local provider_config = self.providers[provider]
    
    if not provider_config then
        return false, "Unknown provider"
    end
    
    if not provider_config.api_key or #provider_config.api_key == 0 then
        return false, "AI API Key not set"
    end
    
    if not self:checkNetworkConnectivity() then
        return false, "No internet connection!"
    end
    
    logger.info("LLM: Testing", provider, "API key")
    
    -- Must literally ask for JSON: the OpenAI-compatible path sends
    -- response_format=json_object, which is rejected unless the request
    -- mentions JSON.
    local test_prompt = 'Reply with this exact JSON and nothing else: {"book_title":"OK"}'

    local result, error_code, error_msg
    if provider == "gemini" then
        result, error_code, error_msg = self:callGemini(test_prompt, provider_config)
    elseif provider == "chatgpt" or provider == "custom" then
        result, error_code, error_msg = self:callChatGPT(test_prompt, provider_config)
    else
        return false, "Unsupported provider"
    end

    if result then return true, "Success" end
    return false, error_msg or ("Error: " .. (error_code or "Unknown"))
end

return LLM
