#!/usr/bin/env python3
"""Run the multiturn loop against OpenRouter -- one request per chapter.

    python3 incremental_run.py --from 1 --to 8
    python3 incremental_run.py --from 45 --to 48 --seed-through 44 \
        --seed-reply reply_google_gemini-3.7-flash.json

Defaults to dots-studio/dots-3-note-preview:free -- the newest capable free
model at the time of writing (280B MoE, 16B active, 512k context, understands
response_format) -- so the loop costs $0. Free models are rate-limited
(~50 requests/day without a $10 account balance), which is why every finished
turn is saved and skipped on re-run: a limit or a crash mid-loop wastes
nothing, rerunning the same command resumes where it stopped.

The request body and SSE handling mirror call_openrouter.py, which mirrors the
shipped callChatGPT -- same temperature, top_p, response_format, streaming and
usage accounting -- so the numbers logged here are comparable with the
whole-book runs recorded in private/fixtures/.

--seed-through builds the state from a saved WHOLE-BOOK reply instead of live
turns, which is what makes the late-reveal pilot affordable: turn 47 (the
identity merge) can be tested without paying for 46 turns first.

Every turn writes:
    incremental/turn_NN.json     the model's reply (raw JSON text)
    incremental/turn_NN.meta     finish reason, usage, timing -- the cost data
    incremental/state_NN.json    the state AFTER folding this turn
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request

import incremental_prompts as ip

AP = argparse.ArgumentParser()
AP.add_argument("--model", default="dots-studio/dots-3-note-preview:free")
AP.add_argument("--effort", default="none",
                help='reasoning effort; "none" omits the field entirely')
AP.add_argument("--from", dest="first", type=int, required=True)
AP.add_argument("--to", dest="last", type=int, required=True)
AP.add_argument("--seed-through", type=int, default=0,
                help="build state from a saved whole-book reply, chapters 1..N")
AP.add_argument("--seed-reply", default="reply_google_gemini-3.7-flash.json")
AP.add_argument("--max-tokens", type=int, default=16000)
args = AP.parse_args()

WORK = os.environ.get("GRIMORIA_TEST_WORK",
                      os.path.join("..", "..", "private", "fixtures"))
INC = os.path.join(WORK, "incremental")
os.makedirs(INC, exist_ok=True)

KEY = os.environ["OPENROUTER_API_KEY"]
WHOLE = open(os.path.join(WORK, "prompt.txt"), encoding="utf-8").read()
SYSTEM = open(os.path.join(WORK, "prompt.txt.system"), encoding="utf-8").read()
BOOK = open(os.path.join(WORK, "book_text.txt"), encoding="utf-8").read()
CHAPTERS = ip.split_chapters(BOOK)


def parse_reply(text):
    """The reply as JSON, tolerating a model that fenced it anyway."""
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
        t = re.sub(r"\s*```$", "", t)
    return json.loads(t)


def request(prompt, label):
    """One streamed chat completion; returns (text, meta). Retries 429/5xx --
    free-tier models throttle, and a loop of N turns must survive that."""
    payload = {
        "model": args.model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "temperature": 0.4,
        "max_tokens": args.max_tokens,
        "top_p": 0.95,
        "response_format": {"type": "json_object"},
        "stream": True,
    }
    if args.effort != "none":
        payload["reasoning"] = {"effort": args.effort, "exclude": True}
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY,
                 "Accept": "text/event-stream",
                 "HTTP-Referer": "https://github.com/koreader/koreader",
                 "X-Title": "KOReader Grimoria",
                 "User-Agent": "curl/8.7.1"},
        method="POST")

    for attempt in range(5):
        if attempt:
            wait = 2 ** (attempt + 1)   # 4, 8, 16, 32 -- free-tier 429s are slow to clear
            print("  retry %d in %ds" % (attempt, wait), flush=True)
            time.sleep(wait)
        t0 = time.time()
        parts, finish, usage, err = [], None, None, None
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                buf = b""
                for chunk in resp:
                    buf += chunk
                    while b"\n" in buf:
                        line, _, buf = buf.partition(b"\n")
                        line = line.decode("utf-8", "replace").rstrip("\r")
                        if not line.startswith("data: ") or line[6:] == "[DONE]":
                            continue
                        try:
                            obj = json.loads(line[6:])
                        except json.JSONDecodeError:
                            continue
                        if obj.get("error"):
                            err = obj["error"]
                        for c in obj.get("choices") or []:
                            delta = c.get("delta") or {}
                            if isinstance(delta.get("content"), str):
                                parts.append(delta["content"])
                            if c.get("finish_reason"):
                                finish = c["finish_reason"]
                        if obj.get("usage"):
                            usage = obj["usage"]
        except urllib.error.HTTPError as e:
            # Read the body: OpenRouter puts the real reason there, and a bare
            # "HTTP Error 400" says nothing about which of a dozen causes it
            # was (bad effort spelling, provider refusal, context overflow).
            try:
                detail = e.read().decode("utf-8", "replace")[:500]
            except Exception:
                detail = "(no body)"
            # "Provider returned error" is an UPSTREAM fault wrapped in a 400,
            # not a complaint about our request -- observed from AtlasCloud on
            # the free tier, on a turn whose neighbours were accepted. Retrying
            # lets OpenRouter route to a different provider, so it is worth a
            # retry where a genuine request-validation 400 would not be.
            upstream = "Provider returned error" in detail
            if e.code in (429,) or 500 <= e.code < 600 or upstream:
                print("  %s: HTTP %d (%s) %s"
                      % (label, e.code, "upstream" if upstream else "transient",
                         detail[:160]), flush=True)
                continue
            raise RuntimeError("%s: HTTP %d -- %s" % (label, e.code, detail))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print("  %s: %s (transient)" % (label, e), flush=True)
            continue

        text = "".join(parts)
        meta = {"model": args.model, "effort": args.effort,
                "prompt_chars": len(prompt), "reply_chars": len(text),
                "elapsed_s": round(time.time() - t0, 1),
                "finish": finish, "usage": usage, "error": err}
        if err or not text:
            print("  %s: empty/error reply (%s)" % (label, err), flush=True)
            continue
        # The shipped callChatGPT's rule, mirrored: an absent finish_reason
        # means the stream was cut, not that the model finished -- observed
        # on the free tier as a reply ending mid-string. Retry it; only a
        # reply that both finished AND parses is a turn.
        if finish is None:
            print("  %s: stream cut off at %d chars" % (label, len(text)),
                  flush=True)
            continue
        try:
            reply = parse_reply(text)
        except json.JSONDecodeError as e:
            # Keep the evidence: a model that finishes cleanly and still emits
            # unparseable JSON is a fact worth being able to look at, and the
            # retry is about to overwrite this attempt.
            bad = os.path.join(INC, "%s.bad" % label.replace(" ", "_"))
            open(bad, "w", encoding="utf-8").write(text)
            print("  %s: finished but not JSON (%s) -- saved %s"
                  % (label, e, bad), flush=True)
            continue
        return text, reply, meta
    raise RuntimeError("%s: no usable reply after 5 attempts" % label)


# ------------------------------------------------------------------- state ----

state = ip.empty_state()
if args.seed_through:
    seed = json.loads(open(os.path.join(WORK, args.seed_reply),
                           encoding="utf-8").read())
    state = ip.seed_state(seed, args.seed_through)
    print("state seeded from %s through ch %d: %d chapter(s), %d roster"
          % (args.seed_reply, args.seed_through,
             len(state["chapters"]), len(state["roster"])))

# Fold any already-saved turns below the range (resume support for from>1
# without --seed-through, and for re-running a partly finished range).
for k in sorted(CHAPTERS):
    if k >= args.first:
        break
    path = os.path.join(INC, "turn_%02d.json" % k)
    if os.path.exists(path):
        ip.update_state(state, parse_reply(open(path, encoding="utf-8").read()), k)

# -------------------------------------------------------------------- loop ----

totals = {"prompt_tokens": 0, "completion_tokens": 0, "elapsed": 0.0, "turns": 0}
for k in range(args.first, args.last + 1):
    if k not in CHAPTERS:
        print("turn %d: no such chapter marker, skipped" % k)
        continue
    out = os.path.join(INC, "turn_%02d.json" % k)
    if os.path.exists(out):
        print("turn %d: already done, folding into state" % k)
        ip.update_state(state, parse_reply(open(out, encoding="utf-8").read()), k)
        continue

    prompt = ip.build_turn_prompt(WHOLE, state, k, CHAPTERS[k])
    print("turn %d: %d prompt chars (state %d ch / %d roster) ..."
          % (k, len(prompt), len(state["chapters"]), len(state["roster"])),
          flush=True)
    text, reply, meta = request(prompt, "turn %d" % k)

    open(out, "w", encoding="utf-8").write(text)
    open(out + ".meta", "w", encoding="utf-8").write(
        json.dumps(meta, ensure_ascii=False, indent=1))
    ip.update_state(state, reply, k)
    open(os.path.join(INC, "state_%02d.json" % k), "w", encoding="utf-8").write(
        json.dumps(state, ensure_ascii=False, indent=1))

    u = meta["usage"] or {}
    totals["prompt_tokens"] += u.get("prompt_tokens") or 0
    totals["completion_tokens"] += u.get("completion_tokens") or 0
    totals["elapsed"] += meta["elapsed_s"]
    totals["turns"] += 1
    print("  done: %ds, finish=%s, in=%s out=%s"
          % (meta["elapsed_s"], meta["finish"],
             u.get("prompt_tokens"), u.get("completion_tokens")), flush=True)

print("\nloop totals: %d turn(s), %d prompt + %d completion tokens, %.0fs"
      % (totals["turns"], totals["prompt_tokens"],
         totals["completion_tokens"], totals["elapsed"]))
