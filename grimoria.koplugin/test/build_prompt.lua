--[[
Build the request prompt using the REAL lib/llm.lua, off-device.

The point is that this is not a re-implementation: it loads the shipped module
and calls LLM:createPrompt, so what gets sent to OpenRouter below is what
the plugin sends. Only KOReader's own modules are stubbed, and only the ones
lib/llm pulls in at load time -- none of them take part in building a prompt.

  usage: lua build_prompt.lua <plugin_dir> <book_text_file> <out_prompt_file> [quotes_only]

A fourth argument of "quotes_only" builds the quotes-only prompt instead --
the one fetchQuotesOnly sends for an analysis that predates the quotes field.
]]

local plugin_dir, text_file, out_file, mode = ...
package.path = plugin_dir .. "/?.lua;" .. package.path

local function stub(name, tbl) package.loaded[name] = tbl end
stub("logger", {
    info = function() end, warn = function() end, dbg = function() end,
})
stub("socket.http", {})
stub("ssl.https", {})
stub("ltn12", {})
stub("json", {})

local LLM = require("lib/llm")

-- loadLanguage() would read KOReader's settings dir; go straight to the
-- prompt files, which is all createPrompt needs.
LLM.current_language = "en"
LLM:loadPrompts()

local fh = assert(io.open(text_file, "r"))
local book_text = fh:read("*a")
fh:close()

-- Same context continueWithFetch builds from BookText's meta. 56 chapters
-- included, so dev_budget = min(700, max(120, 56*12)) = 672.
local prompt = LLM:createPrompt(
    "12325-thap-giac-quan-thuviensach.vn", "Unknown",
    {
        book_text = book_text,
        truncated = false,
        chapter_count = 56,
        dev_budget = math.min(700, math.max(120, 56 * 12)),
        quotes_only = (mode == "quotes_only") or nil,
    })

local out = assert(io.open(out_file, "w"))
out:write(prompt)
out:close()

-- callChatGPT sends this as the system message, separately from the prompt.
local sys = assert(io.open(out_file .. ".system", "w"))
sys:write(LLM.prompts.system_instruction)
sys:close()

print("prompt chars   : " .. #prompt)
print("est. tokens    : " .. math.ceil(#prompt / 3))
print("text markers   : " ..
      tostring(prompt:find(LLM.TEXT_START, 1, true) ~= nil) .. " / " ..
      tostring(prompt:find(LLM.TEXT_END, 1, true) ~= nil))
if mode == "quotes_only" then
    print("has schema     : " .. tostring(prompt:find("QUOTES-ONLY run", 1, true) ~= nil))
    -- section_spoilers names identity_merges as a rule; the full schema's
    -- distinctive key is book_title, which a quotes-only run must not ask for.
    print("full schema out: " .. tostring(prompt:find('"book_title":', 1, true) == nil))
else
    print("has schema     : " .. tostring(prompt:find("identity_merges", 1, true) ~= nil))
    print("has quotes     : " .. tostring(prompt:find("QUOTES:", 1, true) ~= nil))
    print("has budget note: " .. tostring(prompt:find("LENGTH BUDGET", 1, true) ~= nil))
end
