#!/usr/bin/env python3
"""
Validate an Grimoria reply the way the plugin does, then check the spoiler rule.

Two halves:

1. Structural — what validateAndCleanData in lib/llm.lua requires, plus the
   things it silently repairs (so a "pass" here means the device would show
   something sensible, not merely that json.decode succeeded).

2. Behavioural — the actual acceptance test for this book: Van and Morisu are
   two separate textual identities until the chapter where the text connects
   them, and only from that chapter does the plugin fuse their cards. This
   re-implements fuseCharacters + applyChapterFilter's character branch and
   runs it just before and just after the reveal.
"""
import json
import re
import sys
import unicodedata

TOTAL_CHAPTERS = 56
DEV_BUDGET = 672


def fold(s):
    """Strip Vietnamese diacritics so 'Vân' matches 'Van'."""
    return "".join(c for c in unicodedata.normalize("NFD", s or "")
                   if unicodedata.category(c) != "Mn").lower()


def load(path):
    raw = open(path, encoding="utf-8").read()
    txt = raw.replace("```json", "").replace("```", "").strip()
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        first, last = txt.find("{"), txt.rfind("}")
        if first >= 0 and last > first:
            return json.loads(txt[first:last + 1])
        raise


def fuse_characters(data, limit):
    """Port of fuseCharacters() in main.lua."""
    chars = data.get("characters") or []
    applies = {}
    for m in data.get("identity_merges") or []:
        if limit is None or m.get("chapter", 1) <= limit:
            for n in m.get("names") or []:
                applies[n] = id(m), m
    if not applies:
        return chars

    emitted, out = set(), []
    for c in chars:
        hit = applies.get(c.get("name"))
        if not hit:
            out.append(c)
            continue
        key, m = hit
        if key in emitted:
            continue
        emitted.add(key)
        fused = {
            "name": m.get("merged_name") or " / ".join(m.get("names") or []),
            "first_chapter": c.get("first_chapter", 1),
            "merge_chapter": m.get("chapter"),
            "by_chapter": [],
            "_members": list(m.get("names") or []),
        }
        for cc in chars:
            h2 = applies.get(cc.get("name"))
            if h2 and h2[0] == key:
                fused["first_chapter"] = min(fused["first_chapter"],
                                             cc.get("first_chapter", 1))
                for bc in cc.get("by_chapter") or []:
                    fused["by_chapter"].append({**bc, "as_name": cc.get("name")})
        out.append(fused)
    return out


def visible_characters(data, limit):
    """Port of applyChapterFilter()'s character branch."""
    fused = fuse_characters(data, limit)
    if limit is None:
        return fused
    return [c for c in fused if c.get("first_chapter", 1) <= limit]


def main(path):
    data = load(path)
    fails, warns = [], []

    def check(cond, msg):
        if not cond:
            fails.append(msg)
        print(("  PASS  " if cond else "  FAIL  ") + msg)
        return cond

    print("=" * 72)
    print("1. STRUCTURE")
    print("=" * 72)
    for key in ("book_title", "author", "author_bio", "book_language",
                "chapters", "characters", "identity_merges", "locations",
                "themes", "historical_figures"):
        check(key in data, f"top-level key present: {key}")

    chapters = data.get("chapters") or []
    idx = [c.get("index") for c in chapters]
    check(len(chapters) > 0, f"chapters returned: {len(chapters)}")
    check(idx == sorted(idx), "chapter indices are in order")
    check(len(set(idx)) == len(idx), "chapter indices are unique")
    check(max(idx or [0]) <= TOTAL_CHAPTERS,
          f"no chapter index above the book's {TOTAL_CHAPTERS} "
          f"(max seen: {max(idx or [0])})")
    check(all(c.get("summary") for c in chapters), "every chapter has a summary")

    chars = data.get("characters") or []
    check(len(chars) > 0, f"characters returned: {len(chars)}")
    check(all(c.get("name") for c in chars), "every character has a name")
    check(all(isinstance(c.get("first_chapter"), int) for c in chars),
          "every character has an integer first_chapter")
    bad_bc = [(c["name"], bc.get("chapter")) for c in chars
              for bc in (c.get("by_chapter") or [])
              if not isinstance(bc.get("chapter"), int)
              or not 1 <= bc["chapter"] <= TOTAL_CHAPTERS]
    check(not bad_bc, f"by_chapter chapter numbers all in 1..{TOTAL_CHAPTERS} "
                      f"({len(bad_bc)} bad)")
    total_bc = sum(len(c.get("by_chapter") or []) for c in chars)
    check(total_bc <= DEV_BUDGET * 1.5,
          f"by_chapter entries within the length budget: {total_bc} (asked ≤{DEV_BUDGET})")

    names = {c.get("name") for c in chars}
    merges = data.get("identity_merges") or []
    print(f"\n  identity_merges: {len(merges)}")
    orphan = []
    for m in merges:
        unknown = [n for n in (m.get("names") or []) if n not in names]
        if unknown:
            orphan.append((m.get("merged_name"), unknown))
        print(f"    ch{m.get('chapter'):>3}  {m.get('names')} -> "
              f"{m.get('merged_name')!r}")
    check(not orphan, f"every merge names a listed character ({len(orphan)} orphaned)")

    themes = data.get("themes") or []
    check(all(isinstance(t, dict) and "first_chapter" in t for t in themes),
          f"themes are chapter-tagged objects, not bare strings ({len(themes)} themes)")

    print()
    print("=" * 72)
    print("2. SPOILER BEHAVIOUR — Van / Morisu")
    print("=" * 72)

    van = [c["name"] for c in chars if re.search(r"\bvan\b", fold(c["name"]))]
    mor = [c["name"] for c in chars if "morisu" in fold(c["name"])]
    print(f"  identities matching 'Van'   : {van}")
    print(f"  identities matching 'Morisu': {mor}")

    target = None
    for m in merges:
        folded = [fold(n) for n in (m.get("names") or [])]
        blob = " ".join(folded) + " " + fold(m.get("merged_name"))
        if any(re.search(r"\bvan\b", f) for f in folded) and "morisu" in blob:
            target = m
            break
        if "morisu" in blob and any(re.search(r"\bvan\b", f) for f in [fold(m.get("merged_name"))]):
            target = m
            break

    if not check(target is not None,
                 "a merge connects the Van and Morisu identities"):
        print("\n  -> the reveal was not modelled as an identity_merge; "
              "the spoiler test below cannot run")
        print(f"\nRESULT: {len(fails)} failed check(s)")
        return 1

    reveal = target.get("chapter")
    print(f"\n  reveal chapter reported by the model: {reveal}")
    check(isinstance(reveal, int) and 40 <= reveal <= 52,
          f"reveal lands in the expected region (ch 47-48 +/- a few): {reveal}")

    before, after = max(1, reveal - 1), min(TOTAL_CHAPTERS, reveal)
    members = set(target.get("names") or [])

    vis_before = visible_characters(data, before)
    names_before = [c["name"] for c in vis_before]
    fused_before = [c for c in vis_before if c.get("merge_chapter")]
    shown_members = [n for n in names_before if n in members]

    print(f"\n  reading chapter {before} (before the reveal):")
    print(f"    visible characters : {len(vis_before)}")
    print(f"    merge members shown separately: {shown_members}")
    check(len(shown_members) >= 2,
          f"both identities are still listed separately at ch{before}")
    check(target.get("merged_name") not in names_before,
          f"the fused card {target.get('merged_name')!r} is NOT shown at ch{before}")
    check(not any(c.get("merge_chapter") == reveal for c in fused_before),
          f"this merge has not been applied at ch{before}")

    vis_after = visible_characters(data, after)
    names_after = [c["name"] for c in vis_after]
    print(f"\n  reading chapter {after} (at/after the reveal):")
    print(f"    visible characters : {len(vis_after)}")
    check(target.get("merged_name") in names_after,
          f"the fused card {target.get('merged_name')!r} IS shown at ch{after}")
    still = [n for n in names_after if n in members]
    check(not still, f"the separate identities are gone at ch{after} "
                     f"(still listed: {still})")

    # Leak check: neither merged identity's own pre-reveal text may name the
    # other one -- that is what would give the twist away.
    #
    # Matched on the name as written, NOT diacritic-folded: folding turns the
    # Vietnamese words "vấn" and "văn" into "van", so a folded search reports a
    # leak in every second sentence of this book. Other characters mentioning
    # either identity is also fine and not checked -- both are people the cast
    # openly meets; the secret is only that they are the same person.
    def visible_values(field, upto):
        """Flatten a chapter-tagged field to the text visible at `upto`.

        role/gender/occupation became lists of {value, first_chapter} so that a
        job or allegiance taken later in the book cannot be shown from the
        start. A plain string is still accepted: that is what every analysis
        written before the change holds, and what a model ignoring the schema
        sends back.
        """
        if isinstance(field, str):
            return [field]
        if not isinstance(field, list):
            return []
        out = []
        for item in field:
            if isinstance(item, str):
                out.append(item)
            elif isinstance(item, dict) and isinstance(item.get("value"), str):
                if (item.get("first_chapter") or 1) <= upto:
                    out.append(item["value"])
        return out

    leaks = []
    for c in vis_before:
        if c.get("name") not in members:
            continue
        blob = " ".join(filter(None, [
            c.get("intro"),
            *visible_values(c.get("role"), before),
            *visible_values(c.get("occupation"), before),
            *[bc.get("development") for bc in (c.get("by_chapter") or [])
              if bc.get("chapter", 1) <= before],
        ]))
        for other in members:
            if c.get("name") == other:
                continue
            if re.search(r"(?<!\w)%s(?!\w)" % re.escape(other), blob):
                leaks.append((c.get("name"), other))
    check(not leaks,
          f"neither identity's pre-reveal text names the other ({leaks})")

    theme_leaks = [t.get("theme") for t in themes
                   if t.get("first_chapter", 1) <= before
                   and "morisu" in fold(t.get("theme"))
                   and re.search(r"\bvan\b", fold(t.get("theme")))]
    check(not theme_leaks, f"no theme visible at ch{before} pairs the two names "
                           f"({theme_leaks})")

    print()
    print("=" * 72)
    print(f"RESULT: {len(fails)} failed check(s)")
    print("=" * 72)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
