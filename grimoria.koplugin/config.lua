-- Grimoria API Configuration

return {
    gemini_api_key = "PASTE-YOUR-KEY-HERE",

    -- Every gemini-2.5-* model now returns 404 "no longer available to new
    -- users", which is why the shipped default stopped working.
    -- Measured on a full 20-character index, 3 runs each:
    --   gemini-3.5-flash       3/3 clean  ~43 s  ~10,300 tokens/book
    --   gemini-3.6-flash       2/3 clean  ~60 s   ~7,300 tokens/book
    --   gemini-3.5-flash-lite  3/3 clean  ~18 s   cheapest
    --   gemini-flash-latest    2/3 clean         503s under load, avoid
    gemini_model = "gemini-3.5-flash",

    default_provider = "gemini",

    -- The "chatgpt" provider talks plain OpenAI chat-completions, so it works
    -- against any OpenAI-compatible endpoint -- GLM, OpenRouter, a local server.
    -- Uncomment and set all three to use one:
    -- chatgpt_endpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    -- chatgpt_api_key  = "your-glm-key",
    -- chatgpt_model    = "glm-4-plus",
    -- default_provider = "chatgpt",

    -- OpenRouter: one key for every vendor's models. The model is the full
    -- slug from https://openrouter.ai/models, vendor prefix included.
    -- Set the key in Menu -> Grimoria -> AI Settings -> OpenRouter: API key, or in
    -- settings/grimoria/openrouter_api_key.txt. Deliberately not here: this file
    -- ships inside the plugin folder, so a key written here travels with any
    -- copy of the plugin.
    openrouter_model = "google/gemini-3.7-flash",
    -- openrouter_api_key = "sk-or-v1-...",   -- prefer settings/grimoria/openrouter_api_key.txt
    -- default_provider = "openrouter",

    -- How hard the model thinks before answering: none | minimal | low |
    -- medium | high | xhigh. Defaults to "high" in lib/llm.lua, because a
    -- per-chapter index of a whole novel is long-horizon work and the models'
    -- own default thinking level is low -- which reads as shallow summaries.
    -- Thinking tokens are billed as output tokens on top of the answer, so
    -- turning this down is the lever if a book gets expensive.
    -- openrouter_reasoning_effort = "high",

    -- The "custom" provider is the same OpenAI wire format but kept separate,
    -- so a real OpenAI key and a proxy can both be configured and switched
    -- between. Set it here, in Menu -> Grimoria -> AI Settings -> Custom AI,
    -- or per-field in settings/grimoria/custom_{api_key,model,endpoint}.txt.
    --
    -- Deliberately no key here: this file ships inside the plugin folder, so
    -- anything written here travels with a copy of the plugin. Keys belong in
    -- settings/grimoria/, which stays outside it.
    -- custom_name     = "My proxy",
    -- custom_endpoint = "https://your-endpoint.example/v1/chat/completions",
    -- custom_model    = "gpt-4o-mini",
    -- Effort, where the model doesn't already encode it in its name:
    --   none | minimal | low | medium | high | xhigh
    -- Some proxies expose per-effort model names ("...-high") and reject the
    -- parameter; others only accept the parameter. Leave unset if the model
    -- name already carries the effort.
    -- custom_reasoning_effort = "xhigh",
    -- custom_api_key = "sk-...",           -- prefer settings/grimoria/custom_api_key.txt
    -- default_provider = "custom",

    settings = {
        auto_fetch_on_open  = false,
        cache_duration_days = -1,
        max_characters      = 20,
    }
}