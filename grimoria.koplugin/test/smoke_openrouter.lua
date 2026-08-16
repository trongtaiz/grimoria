-- Smoke test for the OpenRouter wiring, using the shipped modules.
local plugin_dir = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(n, t) package.loaded[n] = t end
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("socket.http", {}); stub("ssl.https", {}); stub("ltn12", {}); stub("json", {})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", { show = function() end, close = function() end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/menu", { new = function(_, o) return o end })
stub("device", { screen = { getWidth = function() return 600 end,
                            getHeight = function() return 800 end } })
local WC = {}
function WC:new(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
stub("ui/widget/container/widgetcontainer", WC)
-- DataStorage is only reached by the save/load paths, which this test avoids.
stub("datastorage", { getSettingsDir = function() return "/nonexistent" end })
stub("libs/libkoreader-lfs", { mkdir = function() return true end })

local fails = 0
local function check(c, m)
    if not c then fails = fails + 1 end
    print((c and "  PASS  " or "  FAIL  ") .. m)
end

local LLM = require("lib/llm")
local or_cfg = LLM.providers.openrouter

print("=== provider table ===")
check(or_cfg ~= nil, "openrouter provider exists")
check(or_cfg.endpoint == "https://openrouter.ai/api/v1/chat/completions",
      "endpoint: " .. tostring(or_cfg.endpoint))
check(or_cfg.model == "google/gemini-3.7-flash", "default model: " .. tostring(or_cfg.model))
check(or_cfg.stream == true, "streaming is on")
check(or_cfg.max_output_tokens == 64000, "output budget: " .. tostring(or_cfg.max_output_tokens))
check(type(or_cfg.extra_headers) == "table" and or_cfg.extra_headers["X-Title"] ~= nil,
      "OpenRouter attribution headers present")

print("\n=== routing ===")
-- getBookData sends anything with an endpoint through callChatGPT. Prove it by
-- watching which of the two call sites fires.
local called
LLM.callGemini = function() called = "gemini"; return {} end
LLM.callChatGPT = function(_, _, cfg) called = "chatgpt:" .. cfg.endpoint; return {} end
LLM.current_language = "en"
LLM:loadPrompts()
LLM.loadModelFromFile = function() end   -- no settings dir in this test

-- Both need a key present, or getBookData bails before it ever routes.
or_cfg.api_key = "sk-or-v1-test"
LLM.providers.gemini.api_key = "test"

called = nil
LLM:getBookData("T", "A", "openrouter", {})
check(called == "chatgpt:" .. or_cfg.endpoint, "openrouter -> callChatGPT (" .. tostring(called) .. ")")

called = nil
LLM:getBookData("T", "A", "gemini", {})
check(called == "gemini", "gemini -> callGemini (" .. tostring(called) .. ")")

-- The custom provider ships a placeholder endpoint rather than a real one, on
-- purpose: config.lua and this table both travel with a copy of the plugin, so
-- neither may name anyone's actual proxy. It has to stay a NON-EMPTY string
-- even so -- routing selects callChatGPT on the presence of an endpoint, so
-- nil-ing it out would silently drop the custom provider off that path.
local cu_cfg = LLM.providers.custom
check(type(cu_cfg.endpoint) == "string" and #cu_cfg.endpoint > 0,
      "custom endpoint is a non-empty placeholder: " .. tostring(cu_cfg.endpoint))
-- The placeholder must stay obviously a placeholder. Asserting the shape
-- rather than blocklisting a hostname: naming the private host this once
-- defended against would put it back in the repository, which is the thing
-- the check exists to prevent.
check(cu_cfg.endpoint:upper() == cu_cfg.endpoint:gsub("[a-z:/%.%-]", ""):upper()
      or cu_cfg.endpoint:find("YOUR", 1, true) ~= nil,
      "custom endpoint is a self-evident placeholder, not someone's real host")
cu_cfg.api_key = "sk-test"
called = nil
LLM:getBookData("T", "A", "custom", {})
check(called == "chatgpt:" .. cu_cfg.endpoint, "custom -> callChatGPT (" .. tostring(called) .. ")")

called = nil
local _, err = LLM:getBookData("T", "A", "nosuch", {})
check(called == nil and err == "error_no_api_key",
      "an unknown provider is still rejected (" .. tostring(err) .. ")")

print("\n=== helpers ===")
check(type(LLM.setProviderModel) == "function", "setProviderModel exists")
check(type(LLM.saveProviderField) == "function", "saveProviderField exists")
check(LLM.saveCustomField == nil,
      "saveCustomField is gone -- saveProviderField replaced it")

--[[
The reasoning wire format, which is the one thing here that cannot be checked
by reading the code: the two providers need DIFFERENT spellings and sending the
wrong one is a 400, not a silently ignored field.

Everything asserted below was measured against the live endpoint first:
  effort "none" / enabled:false / max_tokens:0  ->  400, reasoning is mandatory
  omitting the field                            ->  ~325 reasoning tokens
  effort "minimal"                              ->  0 reasoning tokens
]]
print("\n=== reasoning body ===")
local cus_cfg = LLM.providers.custom

check(or_cfg.reasoning_effort == "high",
      "openrouter defaults to high (" .. tostring(or_cfg.reasoning_effort) .. ")")
check(or_cfg.reasoning_style == "openrouter", "openrouter uses the reasoning object")
check(cus_cfg.reasoning_style ~= "openrouter", "custom keeps top-level reasoning_effort")

local b = LLM:buildReasoningBody({}, or_cfg)
check(type(b.reasoning) == "table" and b.reasoning.effort == "high",
      "openrouter -> reasoning.effort = high")
check(b.reasoning and b.reasoning.exclude == true,
      "openrouter -> reasoning.exclude = true (thoughts stay off the wire)")
check(b.reasoning_effort == nil, "openrouter does NOT also send top-level reasoning_effort")

b = LLM:buildReasoningBody({}, cus_cfg, "xhigh")
check(b.reasoning_effort == "xhigh", "custom -> top-level reasoning_effort = xhigh")
check(b.reasoning == nil, "custom does NOT send the reasoning object")

b = LLM:buildReasoningBody({}, or_cfg, "none")
check(b.reasoning == nil and b.reasoning_effort == nil,
      "'none' emits no reasoning field at all -- sending it is a 400")

b = LLM:buildReasoningBody({}, cus_cfg, "none")
check(b.reasoning_effort == "none",
      "'none' IS passed through on the OpenAI spelling, where it really disables")

b = LLM:buildReasoningBody({}, or_cfg, "banana")
check(b.reasoning == nil and b.reasoning_effort == nil, "an unknown effort is dropped, not sent")

-- Every documented level must be in the ladder. One that is missing is
-- silently dropped from the request while the menu still displays it, which is
-- a worse failure than the 400 an unknown value used to produce.
for _, e in ipairs({ "minimal", "low", "medium", "high", "xhigh", "max" }) do
    local bb = LLM:buildReasoningBody({}, or_cfg, e)
    check(bb.reasoning and bb.reasoning.effort == e, "effort '" .. e .. "' reaches the wire")
end
check(LLM:fallbackEffort("max") == "low", "step-down: max -> low")

check(LLM:fallbackEffort("high") == "low", "step-down: high -> low")
check(LLM:fallbackEffort("low") == "minimal", "step-down: low -> minimal")
check(LLM:fallbackEffort("none") == "minimal",
      "step-down: none -> minimal (the default is NOT the floor)")
check(LLM:fallbackEffort("minimal") == nil, "step-down: minimal is the floor")

-- The step-down must never write to the shared provider table, or it would
-- change the user's setting for the session and the menu would show it.
LLM:buildReasoningBody({}, or_cfg, "minimal")
check(or_cfg.reasoning_effort == "high", "stepping down does not mutate the provider config")

print("\n=== main.lua ===")
local Grimoria = require("main")
local p = Grimoria:new{}
p.loc = { t = function(_, k) return k end, getLanguage = function() return "en" end }
check(type(p.holdDeviceAwake) == "function", "holdDeviceAwake exists")
check(type(p.releaseDeviceAwake) == "function", "releaseDeviceAwake exists")
check(type(p.runFetch) == "function", "runFetch exists")
check(type(p.selectOpenRouterModel) == "function", "selectOpenRouterModel exists")
check(p:getProviderModel("openrouter") == "google/gemini-3.7-flash",
      "getProviderModel: " .. tostring(p:getProviderModel("openrouter")))
check(p:getProviderModel("nosuch") == nil, "getProviderModel is nil for an unknown provider")
check(type(p.selectReasoningEffort) == "function", "selectReasoningEffort exists")
check(p:getProviderEffort("openrouter") == "high",
      "getProviderEffort: " .. tostring(p:getProviderEffort("openrouter")))
or_cfg.reasoning_effort = nil
check(p:getProviderEffort("openrouter") == "default",
      "unset effort reads back as 'default', never as 'off'")
or_cfg.reasoning_effort = "high"

print()
print(fails == 0 and "RESULT: all checks passed" or ("RESULT: " .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
