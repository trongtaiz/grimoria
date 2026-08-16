#!/usr/bin/env python3
"""
Send the plugin's prompt to OpenRouter, exactly as callChatGPT builds it.

Same body (model, temperature, max_tokens, top_p, response_format, stream) and
the same SSE handling, so a failure here is a failure the device would also
see. Writes the raw reply, and reports finish_reason + token usage.
"""
import json
import os
import sys
import time
import urllib.request

MODEL = sys.argv[1] if len(sys.argv) > 1 else "google/gemini-3.7-flash"
# Second argument is the reasoning effort, matching the provider table's
# default. "none" sends no reasoning field, which is NOT the same as off --
# the endpoint refuses to disable thinking and answers effort:"none" with a
# 400, so omission is the only way to get the provider's own default.
EFFORT = sys.argv[2] if len(sys.argv) > 2 else "high"
# Where the prompt is read from and the reply written to. The book text and
# everything derived from it are never committed -- the fixture is a
# copyrighted novel -- so this defaults to private/ at the repo root,
# which .gitignore excludes in full. Override with GRIMORIA_TEST_WORK=<dir>.
WORK = os.environ.get(
    "GRIMORIA_TEST_WORK", os.path.join("..", "..", "private", "fixtures")
)
PROMPT_FILE = os.path.join(WORK, "prompt.txt")
suffix = "" if EFFORT == "none" else f"_{EFFORT}"
OUT = os.path.join(WORK, f"reply_{MODEL.replace('/', '_')}{suffix}.json")

key = os.environ["OPENROUTER_API_KEY"]
prompt = open(PROMPT_FILE, encoding="utf-8").read()
system = open(PROMPT_FILE + ".system", encoding="utf-8").read()

payload = {
    "model": MODEL,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": prompt},
    ],
    "temperature": 0.4,
    "max_tokens": 64000,
    "top_p": 0.95,
    "response_format": {"type": "json_object"},
    "stream": True,
}
if EFFORT != "none":
    # exclude keeps the thoughts off the wire. They are billed either way, but
    # a high-effort pass on a novel is tens of thousands of tokens a Kindle
    # would receive, buffer and discard over the same link that already drops
    # whole-book replies.
    payload["reasoning"] = {"effort": EFFORT, "exclude": True}
body = json.dumps(payload).encode("utf-8")

req = urllib.request.Request(
    "https://openrouter.ai/api/v1/chat/completions",
    data=body,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {key}",
        "Accept": "text/event-stream",
        "HTTP-Referer": "https://github.com/koreader/koreader",
        "X-Title": "KOReader Grimoria",
        "User-Agent": "curl/8.7.1",
    },
    method="POST",
)

print(f"model      : {MODEL}")
print(f"request    : {len(body)} bytes")
t0 = time.time()

print(f"reasoning  : {EFFORT}")
parts, finish, usage, err = [], None, None, None
first_byte = None
reasoning_bytes = 0
with urllib.request.urlopen(req, timeout=1800) as resp:
    print(f"HTTP       : {resp.status}")
    buf = b""
    for chunk in resp:
        if first_byte is None:
            first_byte = time.time() - t0
            print(f"first byte : {first_byte:.1f}s")
        buf += chunk
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            line = line.decode("utf-8", "replace").rstrip("\r")
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                continue
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if obj.get("error"):
                err = obj["error"]
            for c in obj.get("choices") or []:
                delta = c.get("delta") or {}
                if isinstance(delta.get("content"), str):
                    parts.append(delta["content"])
                    if len(parts) % 200 == 0:
                        print(f"  ... {len(parts)} chunks, "
                              f"{sum(len(p) for p in parts)} chars, "
                              f"{time.time() - t0:.0f}s", flush=True)
                if isinstance(delta.get("reasoning"), str):
                    reasoning_bytes += len(delta["reasoning"])
                if c.get("finish_reason"):
                    finish = c["finish_reason"]
            if obj.get("usage"):
                usage = obj["usage"]

elapsed = time.time() - t0
text = "".join(parts)
print(f"elapsed    : {elapsed:.1f}s")
print(f"finish     : {finish}")
print(f"usage      : {usage}")
print(f"error      : {err}")
print(f"reply chars: {len(text)}")
print(f"reasoning on the wire: {reasoning_bytes} bytes (0 = exclude worked)")
if usage:
    # The number that decides whether "high" is safe on a whole book: thinking
    # and answering are paid for out of the same 64000-token completion budget,
    # so this is what the truncation ladder has to stay ahead of.
    reasoned = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    completion = usage.get("completion_tokens") or 0
    print(f"budget     : {completion}/64000 completion "
          f"({reasoned} reasoning + {completion - reasoned} answer), "
          f"{64000 - completion} left")
open(OUT, "w", encoding="utf-8").write(text)
print(f"written    : {OUT}")
