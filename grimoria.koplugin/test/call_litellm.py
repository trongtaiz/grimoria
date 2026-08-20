#!/usr/bin/env python3
"""
Send the plugin's prompt through the `custom` provider (a LiteLLM proxy),
exactly as callChatGPT builds it for that provider.

Differences from call_openrouter.py, each one load-bearing on this stack:
  - endpoint and key come from the environment, never from this file --
    the plugin folder ships, and a real endpoint must not ship with it
      GRIMORIA_CUSTOM_ENDPOINT  full chat/completions URL
      GRIMORIA_CUSTOM_API_KEY   (alias LITELLM_API_KEY)
  - reasoning is the top-level `reasoning_effort` field (LiteLLM validates
    it), not OpenRouter's `reasoning = { effort = ... }` object
  - User-Agent stays curl/8.7.1: Cloudflare 403s unknown UAs with code 1010
  - a nonce is appended to the prompt: the proxy's response cache replays
    byte-identical requests, so an uncached probe must not be byte-identical

usage: call_litellm.py <model> <effort> [prompt_file] [out_file]
       (files are relative to GRIMORIA_TEST_WORK, default private/fixtures)
"""
import json
import os
import sys
import time
import urllib.request

MODEL = sys.argv[1] if len(sys.argv) > 1 else "gpt-5.6-sol"
EFFORT = sys.argv[2] if len(sys.argv) > 2 else "high"
WORK = os.environ.get(
    "GRIMORIA_TEST_WORK", os.path.join("..", "..", "private", "fixtures")
)
PROMPT_NAME = sys.argv[3] if len(sys.argv) > 3 else "prompt.txt"
PROMPT_FILE = os.path.join(WORK, PROMPT_NAME)
suffix = "" if EFFORT == "none" else f"_{EFFORT}"
OUT_NAME = (
    sys.argv[4]
    if len(sys.argv) > 4
    else f"reply_{MODEL.replace('/', '_')}{suffix}.json"
)
OUT = os.path.join(WORK, OUT_NAME)

endpoint = os.environ["GRIMORIA_CUSTOM_ENDPOINT"]
key = os.environ.get("GRIMORIA_CUSTOM_API_KEY") or os.environ["LITELLM_API_KEY"]
prompt = open(PROMPT_FILE, encoding="utf-8").read()
system = open(PROMPT_FILE + ".system", encoding="utf-8").read()

# Defeats the proxy's byte-identical response cache without touching what the
# model is asked to do.
prompt += f"\n\n(request nonce, ignore: {int(time.time())})"

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
    payload["reasoning_effort"] = EFFORT
body = json.dumps(payload).encode("utf-8")

req = urllib.request.Request(
    endpoint,
    data=body,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {key}",
        "Accept": "text/event-stream",
        "User-Agent": "curl/8.7.1",
    },
    method="POST",
)

print(f"model      : {MODEL}")
print(f"request    : {len(body)} bytes")
print(f"reasoning  : {EFFORT}")
t0 = time.time()

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
            data = line[6:]
            if data == "[DONE]":
                continue
            try:
                obj = json.loads(data)
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
print(f"reasoning on the wire: {reasoning_bytes} bytes")
if usage:
    reasoned = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    completion = usage.get("completion_tokens") or 0
    print(f"budget     : {completion}/64000 completion "
          f"({reasoned} reasoning + {completion - reasoned} answer), "
          f"{64000 - completion} left")
open(OUT, "w", encoding="utf-8").write(text)
print(f"written    : {OUT}")
