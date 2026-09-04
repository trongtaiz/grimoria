--[[
Provider configuration: keys, models, endpoints and reasoning effort.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

function GrimoriaPlugin:selectGeminiModel()
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end

    local current_model = "gemini-3.5-flash"
    if self.llm.providers and self.llm.providers.gemini then
        current_model = self.llm.providers.gemini.model or "gemini-3.5-flash"
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {
        {
            {
                -- The old 2.5 Flash / 2.5 Pro / 3 Pro Preview options all return
                -- 404 "no longer available to new users" -- replaced with models
                -- verified working on a current key.
                text = "Gemini 3.5 Flash" .. (current_model == "gemini-3.5-flash" and " ✓" or ""),
                callback = function()
                    self.llm:setGeminiModel("gemini-3.5-flash")
                    UIManager:close(self.dlg)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{text = self.loc:t("gemini_model_flash_info"), timeout = 2})
                end
            }
        },
        {
            {
                text = "Gemini 3.5 Flash Lite (fastest)" .. (current_model == "gemini-3.5-flash-lite" and " ✓" or ""),
                callback = function()
                    self.llm:setGeminiModel("gemini-3.5-flash-lite")
                    UIManager:close(self.dlg)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{text = self.loc:t("gemini_model_pro_info"), timeout = 2})
                end
            }
        },
        {
            {
                text = "Gemini 3.6 Flash" .. (current_model == "gemini-3.6-flash" and " ✓" or ""),
                callback = function()
                    self.llm:setGeminiModel("gemini-3.6-flash")
                    UIManager:close(self.dlg)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{text = self.loc:t("gemini_model_3_pro_info"), timeout = 2})
                end
            }
        },
    }
    self.dlg = ButtonDialog:new{
        title = self.loc:t("gemini_model_title"),
        buttons = buttons,
    }
    UIManager:show(self.dlg)
end

function GrimoriaPlugin:setGeminiAPIKey()
    local InputDialog = require("ui/widget/inputdialog")
    
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end
    
    local current_key = self.llm.providers.gemini.api_key or ""
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = self.loc:t("gemini_key_title"), 
        input = current_key,
        input_hint = self.loc:t("gemini_key_hint"), 
        description = self.loc:t("gemini_key_desc"), 
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
                        local api_key = input_dialog:getInputText()
                        if api_key and #api_key > 0 then
                            if not self.llm then
                                local LLM = require("lib/llm")
                                self.llm = LLM
                            end
                            
                            self.llm:setAPIKey("gemini", api_key)
                            self.ai_provider = "gemini"
                            
                            UIManager:show(InfoMessage:new{
                                text = self.loc:t("gemini_key_saved"), 
                                timeout = 3,
                            })                            
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimoriaPlugin:setChatGPTAPIKey()
    local InputDialog = require("ui/widget/inputdialog")
    
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end
    
    local current_key = self.llm.providers.chatgpt.api_key or ""
    
    local input_dialog
    input_dialog = InputDialog:new{
        title = self.loc:t("chatgpt_key_title"), 
        input = current_key,
        input_hint = self.loc:t("chatgpt_key_hint"), 
        description = self.loc:t("chatgpt_key_desc"), 
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
                        local api_key = input_dialog:getInputText()
                        if api_key and #api_key > 0 then
                            if not self.llm then
                                local LLM = require("lib/llm")
                                self.llm = LLM
                            end
                            self.llm:setAPIKey("chatgpt", api_key)
                            self.ai_provider = "chatgpt"
                            
                            UIManager:show(InfoMessage:new{
                                text = self.loc:t("chatgpt_key_saved"), 
                                timeout = 3,
                            })
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Make sure the LLM module is loaded, and hand it back.
function GrimoriaPlugin:getLLM()
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end
    return self.llm
end

function GrimoriaPlugin:getProviderModel(provider)
    local cfg = self:getLLM().providers[provider]
    return cfg and cfg.model or nil
end

-- Unset and "none" are the same wire behaviour -- no reasoning field, provider
-- default thinking -- so they read back as one state. Not called "off": the
-- endpoint refuses to switch thinking off at all.
function GrimoriaPlugin:getProviderEffort(provider)
    local cfg = self:getLLM().providers[provider]
    local e = cfg and cfg.reasoning_effort
    if not e or e == "" or e == "none" then return "default" end
    return e
end

--[[
Edit one field of one OpenAI-compatible provider.

One dialog per field rather than a combined one: the endpoint and model are
set once and then never touched, while the key is what people actually come
back to. Each writes through to settings/grimoria/<provider>_<field>.txt so it
survives a plugin re-copy.
]]
function GrimoriaPlugin:setProviderField(provider, field, title, description, on_saved)
    local InputDialog = require("ui/widget/inputdialog")

    local cfg = self:getLLM().providers[provider]
    if not cfg then return end

    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = cfg[field] or "",
        description = description,
        buttons = {
            {
                {
                    text = self.loc:t("cancel"),
                    callback = function() UIManager:close(input_dialog) end,
                },
                {
                    text = self.loc:t("save"),
                    is_enter_default = true,
                    callback = function()
                        local value = input_dialog:getInputText()
                        if value and #value > 0 then
                            value = value:gsub("^%s+", ""):gsub("%s+$", "")
                            if field == "api_key" then
                                self.llm:setAPIKey(provider, value)
                                -- Setting a key is the clearest possible
                                -- signal that this is the provider to use.
                                self.ai_provider = provider
                                self.llm:setDefaultProvider(provider)
                            elseif field == "model" then
                                self.llm:setProviderModel(provider, value)
                            else
                                self.llm:saveProviderField(provider, field, value)
                            end
                            UIManager:show(InfoMessage:new{
                                text = title .. " saved.",
                                timeout = 2,
                            })
                            if on_saved then on_saved(value) end
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Kept as the name the Custom AI menu entries already call.
function GrimoriaPlugin:setCustomField(field, title, description)
    return self:setProviderField("custom", field, title, description)
end

--[[
Pick an OpenRouter model.

A shortlist plus a free-text entry, because OpenRouter carries 400+ models and
new ones appear weekly -- a fixed list would be wrong within a month, and
typing a full slug on an e-ink keyboard is miserable. The shortlist is only
what is worth running a whole book through: long input, cheap enough to redo,
and reliable at emitting JSON.
]]
function GrimoriaPlugin:selectOpenRouterModel(touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local helper = self:getLLM()
    local current = helper.providers.openrouter.model

    local presets = {
        "google/gemini-3.8-flash",
        "google/gemini-3.5-flash",
        "google/gemini-3.5-flash-lite",
        "google/gemini-3.1-pro-preview",
        "anthropic/claude-sonnet-5",
        "anthropic/claude-opus-5",
        "openai/gpt-5.5",
    }

    local dialog
    local function choose(slug)
        helper:setProviderModel("openrouter", slug)
        if dialog then UIManager:close(dialog) end
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(InfoMessage:new{ text = "OpenRouter model: " .. slug, timeout = 2 })
    end

    local buttons = {}
    for _, slug in ipairs(presets) do
        buttons[#buttons + 1] = {{
            text = (slug == current and "✓ " or "") .. slug,
            callback = function() choose(slug) end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = "Enter model slug manually…",
        callback = function()
            if dialog then UIManager:close(dialog) end
            self:setProviderField("openrouter", "model", "OpenRouter model",
                "Full slug from openrouter.ai/models,\nvendor prefix included,\ne.g. google/gemini-3.8-flash",
                function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
        end,
    }}
    buttons[#buttons + 1] = {{
        text = self.loc:t("cancel"),
        callback = function() if dialog then UIManager:close(dialog) end end,
    }}

    dialog = ButtonDialog:new{ title = "OpenRouter model", buttons = buttons }
    UIManager:show(dialog)
end

--[[
How hard the model should think before it answers.

A picker rather than the free-text box the custom provider uses, because here
the value is worth getting right and a typo is expensive: an endpoint that
validates the field rejects the whole request, and one that doesn't silently
ignores it, so a misspelling either wastes a fetch or quietly turns thinking
off while the menu claims it is on.

The wording puts the trade-off on the buttons. Every level above "off" is
billed as output tokens on top of the answer, and the levels share the output
budget with the answer itself -- which is why a whole-book fetch that gets cut
off steps this down before it starts trimming the result.
]]
function GrimoriaPlugin:selectReasoningEffort(provider, touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local helper = self:getLLM()
    local cfg = helper.providers[provider]
    if not cfg then return end

    --[[
    "minimal" rather than "off", because off is not on offer: this endpoint
    answers `effort: "none"`, `enabled: false` and a zero budget alike with
    400 "Reasoning is mandatory for this endpoint and cannot be disabled."
    Measured, "minimal" is the floor -- exactly zero reasoning tokens.

    "none" is the provider's own default, which is NOT the cheapest option:
    it measured well above "minimal". It stays on the list because it is what
    the plugin sent before this setting existed, so it is the way back to the
    old behaviour, but it is labelled for what it is rather than as an off
    switch.
    ]]
    local levels = {
        { "minimal", "minimal - least thinking, cheapest" },
        { "none",    "provider default" },
        { "low",     "low - a little deliberation" },
        { "medium",  "medium" },
        { "high",    "high - recommended for a whole book" },
        { "xhigh",   "xhigh" },
        { "max",     "max - slowest, most expensive" },
    }

    local dialog
    local buttons = {}
    for _, lv in ipairs(levels) do
        local value, caption = lv[1], lv[2]
        buttons[#buttons + 1] = {{
            -- "none" is stored as the literal string, not as an absent value:
            -- an empty setting means "not configured" and would fall back to
            -- the provider default, which is the opposite of turning it off.
            text = ((cfg.reasoning_effort or "none") == value and "✓ " or "") .. caption,
            callback = function()
                helper:saveProviderField(provider, "reasoning_effort", value)
                if dialog then UIManager:close(dialog) end
                if touchmenu_instance then touchmenu_instance:updateItems() end
                UIManager:show(InfoMessage:new{
                    text = cfg.name .. " reasoning: " .. value,
                    timeout = 2,
                })
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = self.loc:t("cancel"),
        callback = function() if dialog then UIManager:close(dialog) end end,
    }}

    dialog = ButtonDialog:new{
        title = (cfg.name or provider) .. " reasoning effort",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function GrimoriaPlugin:selectAIProvider()
    if not self.llm then
        local LLM = require("lib/llm")
        self.llm = LLM
        self.llm:init()
    end
    
    if not self.ai_provider and self.llm.default_provider then
        self.ai_provider = self.llm.default_provider
    end
    
    -- Declared before the callbacks so they can close it.
    local provider_menu

    -- Built from a list rather than a hand-written block per provider: adding
    -- one to lib/llm.lua now only needs a line here, and the "custom"
    -- provider can't be left unselectable.
    local order = {
        { id = "gemini",     label = "Google Gemini" },
        { id = "chatgpt",    label = "ChatGPT" },
        { id = "openrouter", label = "OpenRouter" },
        { id = "custom",     label = nil },   -- takes its name from the config
    }

    local providers = {}

    for _, entry in ipairs(order) do
        local cfg = self.llm.providers[entry.id]
        if cfg then
            local label = entry.label or cfg.name or entry.id
            -- The model matters most where one provider fronts very different
            -- models -- the custom endpoint and OpenRouter both do.
            if (entry.id == "custom" or entry.id == "openrouter") and cfg.model then
                label = label .. " (" .. cfg.model .. ")"
            end
            local key = cfg.api_key
            if key and key ~= "" then
                local active = (self.ai_provider == entry.id)
                    and self.loc:t("yes") or self.loc:t("no")
                table.insert(providers, {
                    text = "✅ " .. label .. " (" .. self.loc:t("provider_active") .. ": " .. active .. ")",
                    callback = function()
                        self.ai_provider = entry.id
                        self.llm:setDefaultProvider(entry.id)
                        UIManager:show(InfoMessage:new{
                            text = self.loc:t("provider_selected", label),
                            timeout = 2,
                        })
                        if provider_menu then UIManager:close(provider_menu) end
                    end,
                })
            else
                table.insert(providers, {
                    text = "❌ " .. label .. " (" .. self.loc:t("provider_no_key") .. ")",
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = self.loc:t("set_key_first"),
                            timeout = 3,
                        })
                    end,
                })
            end
        end
    end

    provider_menu = Menu:new{
        title = self.loc:t("provider_select_title"), 
        item_table = providers,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(provider_menu)
end

return GrimoriaPlugin
