#!/usr/bin/env python3
"""Build the per-turn prompts for the MULTITURN experiment.

The theory under test (proposed 2026-08): instead of one request carrying the
whole book, send one request per chapter -- chapter k's text plus the SUMMARIES
AND ROSTER produced by the previous turns, never any later text. The model then
cannot leak what it has never seen: input-side spoiler protection, where the
shipped design's protection is output-side (tags + filter + guard).

This file only BUILDS prompts and folds replies into the running state; it
performs no network I/O (incremental_run.py does that) so it can be exercised
and inspected for free.

Reuses the shipped instruction block verbatim: everything createPrompt emits
before the book text (grounding, spoiler discipline, schema...) is sliced out
of the whole-book prompt.txt that build_prompt.lua produced, so the two flows
under comparison differ ONLY in what this experiment is about -- how much text
the model sees and what state accompanies it. The per-book LENGTH BUDGET
paragraph is dropped (each turn is one chapter; the budget problem it solves
cannot occur) and a MULTITURN block is appended.

State is deliberately lean: chapter summaries + a character roster (names,
aliases, first_chapter, latest role/occupation). No prose descriptions -- they
are the expensive part of the context, and the roster exists for NAME
CONSISTENCY, not for re-teaching the model the book. State never contains
anything from a later chapter than the turn being built, by construction.
"""

import json
import os
import re


# ---------------------------------------------------------------- slicing ----

def instruction_block(whole_prompt):
    """The shipped instruction block: everything before the real book text.

    The literal string <<<BOOK_TEXT_START>>> appears twice -- once inside
    grounding rule 1, once as the actual delimiter -- so the LAST occurrence
    is the one that starts the book. The LENGTH BUDGET paragraph (emitted for
    books over 25 chapters) is removed: it reasons about a whole book in one
    reply, which is exactly what a turn is not.
    """
    cut = whole_prompt.rfind("<<<BOOK_TEXT_START>>>")
    if cut < 0:
        raise ValueError("prompt.txt has no book-text marker")
    block = whole_prompt[:cut]
    block = re.sub(r"LENGTH BUDGET:.*?(?:\n\n|\Z)", "", block, flags=re.S)
    return block.rstrip() + "\n"


def output_language_clause(whole_prompt):
    """The OUTPUT LANGUAGE clause createPrompt puts after the book text."""
    end = whole_prompt.rfind("<<<BOOK_TEXT_END>>>")
    if end < 0:
        raise ValueError("prompt.txt has no book-text end marker")
    return whole_prompt[end + len("<<<BOOK_TEXT_END>>>"):].strip()


def split_chapters(book_text):
    """chapter index -> that chapter's text INCLUDING its === CHAPTER === line.

    The marker line is kept because grounding rule 5 says chapter numbers come
    only from the markers -- a turn's text must carry the book's own absolute
    number, the same invariant section analyses live by (test_range.lua).
    """
    marks = list(re.finditer(r"^=== CHAPTER (\d+)[^\n]*$", book_text, re.M))
    out = {}
    for i, m in enumerate(marks):
        stop = marks[i + 1].start() if i + 1 < len(marks) else len(book_text)
        out[int(m.group(1))] = book_text[m.start():stop].rstrip() + "\n"
    return out


# ------------------------------------------------------------------ state ----

def empty_state():
    return {"chapters": [], "roster": []}


def _latest(tagged):
    """Latest value of a chapter-tagged list, tolerating every legacy shape."""
    if isinstance(tagged, str):
        return tagged
    best, best_at = "", -1
    for item in tagged or []:
        if isinstance(item, dict) and item.get("value"):
            at = item.get("first_chapter") or 0
            if isinstance(at, (int, float)) and at >= best_at:
                best, best_at = item["value"], at
        elif isinstance(item, str) and item:
            best = item
    return best


def update_state(state, reply, turn):
    """Fold one turn's reply into the running state.

    Only data tagged AT OR BEFORE the turn is folded -- a model that
    disobeyed and tagged something later must not smuggle it into the next
    turn's context, where it would compound. (Belt and braces: the turn's
    text ends at chapter `turn`, so there should be nothing later anyway.)
    """
    for ch in reply.get("chapters") or []:
        idx = ch.get("index")
        if not isinstance(idx, int) or idx > turn:
            continue
        state["chapters"] = [c for c in state["chapters"] if c["index"] != idx]
        state["chapters"].append({
            "index": idx,
            "title": (ch.get("title") or "")[:120],
            "summary": (ch.get("summary") or "")[:600],
        })
    state["chapters"].sort(key=lambda c: c["index"])

    by_name = {r["name"]: r for r in state["roster"]}
    for c in reply.get("characters") or []:
        name = c.get("name")
        if not isinstance(name, str) or not name:
            continue
        r = by_name.get(name)
        if r is None:
            r = {"name": name, "first_chapter": c.get("first_chapter") or turn,
                 "aliases": [], "role": "", "occupation": ""}
            by_name[name] = r
            state["roster"].append(r)
        for a in c.get("aliases") or []:
            alias = a.get("alias") if isinstance(a, dict) else a
            if isinstance(alias, str) and alias and alias not in r["aliases"]:
                r["aliases"].append(alias)
        role, occ = _latest(c.get("role")), _latest(c.get("occupation"))
        if role:
            r["role"] = role
        if occ:
            r["occupation"] = occ
    return state


def seed_state(whole_reply, through):
    """State as if turns 1..through had already run, built from a saved
    whole-book reply.

    This is what makes the late-reveal pilot affordable: testing turn 47 (the
    identity merge) does not require 46 live turns first. Only data the reply
    tags at or before `through` is taken, so the seed contains nothing a
    reader at that point has not earned -- including the merge itself, which
    is the point of the exercise.
    """
    state = empty_state()
    for ch in whole_reply.get("chapters") or []:
        idx = ch.get("index")
        if isinstance(idx, int) and idx <= through:
            state["chapters"].append({
                "index": idx,
                "title": (ch.get("title") or "")[:120],
                "summary": (ch.get("summary") or "")[:600],
            })
    state["chapters"].sort(key=lambda c: c["index"])

    for c in whole_reply.get("characters") or []:
        name, first = c.get("name"), c.get("first_chapter")
        if not isinstance(name, str) or not name:
            continue
        if not isinstance(first, int) or first > through:
            continue
        aliases = []
        for a in c.get("aliases") or []:
            if isinstance(a, dict) and isinstance(a.get("alias"), str):
                at = a.get("first_chapter")
                if isinstance(at, int) and at <= through and a["alias"]:
                    aliases.append(a["alias"])

        def upto(tagged):
            best, best_at = "", -1
            for item in tagged or []:
                if isinstance(item, dict) and item.get("value"):
                    at = item.get("first_chapter")
                    if isinstance(at, int) and at <= through and at >= best_at:
                        best, best_at = item["value"], at
            return best

        state["roster"].append({
            "name": name, "first_chapter": first, "aliases": aliases,
            "role": upto(c.get("role")), "occupation": upto(c.get("occupation")),
        })
    return state


# ---------------------------------------------------------------- assembly ----

MULTITURN = """
MULTITURN ANALYSIS - how this request differs from the format above:

You are analysing this book ONE CHAPTER AT A TIME, in reading order. This
request covers ONLY chapter %d. Earlier chapters were analysed in earlier
requests; their results are in the PREVIOUS ANALYSIS STATE block below. You
have NEVER seen any chapter after %d, and nothing you write may assume one
exists. The reader's app merges each answer into the earlier ones, so:

1. Emit entries ONLY for what this chapter touches. "chapters" holds exactly
   one entry, "index": %d. Do not restate earlier chapters.
2. A character in the ROSTER is a RETURNING character: reuse their name from
   the roster EXACTLY, character for character. Give them a by_chapter entry
   for chapter %d only. Set "intro" to "" and "first_chapter" to the roster's
   value. Add role/gender/occupation entries ONLY if THIS chapter establishes
   a new value, tagged "first_chapter": %d; otherwise emit [] for that field.
3. A character NOT in the roster is NEW: give the full entry, with
   "first_chapter": %d and an intro written from this chapter's knowledge.
   ONE TEXTUAL IDENTITY = ONE ENTRY still applies: if this chapter introduces
   an unnamed or disguised figure, that figure is its own new entry.
4. "aliases": only spellings THIS chapter uses for the first time.
5. "identity_merges": ONLY if this chapter's own text confirms two roster
   identities are the same person. Use their exact roster names. Otherwise [].
6. Locations, themes and historical_figures: only ones this chapter
   introduces or materially develops, tagged "first_chapter": %d.
7. The chapter number comes from the === CHAPTER n === marker: use it exactly.

The state is context for consistency, not material to re-describe. Everything
you write must be grounded in THIS chapter's text.
"""


def state_block(state):
    return ("PREVIOUS ANALYSIS STATE (chapters already analysed, and the "
            "character roster):\n" + json.dumps(state, ensure_ascii=False, indent=1))


def build_turn_prompt(whole_prompt, state, turn, chapter_text):
    parts = [
        instruction_block(whole_prompt),
        MULTITURN % (turn, turn, turn, turn, turn, turn, turn),
    ]
    if state["chapters"] or state["roster"]:
        parts.append(state_block(state))
    else:
        parts.append("PREVIOUS ANALYSIS STATE: none - this is chapter 1, the "
                     "first request for this book.")
    parts.append("<<<BOOK_TEXT_START>>>\n" + chapter_text + "<<<BOOK_TEXT_END>>>")
    parts.append(output_language_clause(whole_prompt))
    return "\n\n".join(parts)


# A tiny CLI so a turn prompt can be eyeballed without running anything:
#   python incremental_prompts.py 3         (state folded from saved turns)
if __name__ == "__main__":
    import sys
    work = os.environ.get("GRIMORIA_TEST_WORK",
                          os.path.join("..", "..", "private", "fixtures"))
    turn = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    whole = open(os.path.join(work, "prompt.txt"), encoding="utf-8").read()
    book = open(os.path.join(work, "book_text.txt"), encoding="utf-8").read()
    chapters = split_chapters(book)
    inc = os.path.join(work, "incremental")
    state = empty_state()
    for k in sorted(chapters):
        if k >= turn:
            break
        path = os.path.join(inc, "turn_%02d.json" % k)
        if os.path.exists(path):
            update_state(state, json.loads(open(path, encoding="utf-8").read()), k)
    p = build_turn_prompt(whole, state, turn, chapters[turn])
    print(p)
    print("\n[%d chars, state: %d chapter(s), %d roster]" %
          (len(p), len(state["chapters"]), len(state["roster"])),
          file=sys.stderr)
