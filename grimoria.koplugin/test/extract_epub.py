#!/usr/bin/env python3
"""
Mimic lib/booktext.lua for an EPUB, outside KOReader.

Same contract as the plugin: walk the TOC in order, take the text between one
entry's anchor and the next, and emit it with "=== CHAPTER n: title ===" markers
so the model can attribute what it finds to a chapter.

`--scheme` matches BookText.CHAPTER_SCHEME. Scheme 1 is consecutive
pair-bucketing (every analysis stored before scheme 2). Scheme 2 (default)
groups by spine file when the TOC exceeds MAX_CHAPTERS, which is the printed
chapter on Calibre-split EPUBs. A book whose TOC is already <= 60 is
identical under both.
"""
import html
import re
import sys
import zipfile

MAX_CHAPTERS = 100
MAX_CHARS = 1000000
CHAPTER_SCHEME = 2


def strip_tags(fragment: str) -> str:
    fragment = re.sub(r"(?is)<(script|style).*?</\1>", " ", fragment)
    fragment = re.sub(r"(?i)<(br|/p|/div|/h[1-6])[^>]*>", "\n", fragment)
    fragment = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(fragment)
    text = re.sub(r"[ \t\xa0]+", " ", text)
    text = re.sub(r"\n\s*\n\s*", "\n\n", text)
    return text.strip()


def pair_bucket(chapters, max_chapters=MAX_CHAPTERS):
    per = -(-len(chapters) // max_chapters)
    grouped = []
    for i in range(0, len(chapters), per):
        chunk = chapters[i:i + per]
        title = chunk[0]["title"]
        if len(chunk) > 1 and chunk[-1]["title"] != title:
            title = f'{title} – {chunk[-1]["title"]}'
        grouped.append({"title": title,
                        "body": "\n".join(c["body"] for c in chunk),
                        "file": chunk[0].get("file")})
    return grouped


def group_by_file(chapters):
    grouped = []
    run = [chapters[0]]
    for ch in chapters[1:]:
        if ch.get("file") == run[0].get("file"):
            run.append(ch)
        else:
            title = run[0]["title"]
            if run[-1]["title"] != title:
                title = f'{title} – {run[-1]["title"]}'
            grouped.append({"title": title,
                            "body": "\n".join(c["body"] for c in run),
                            "file": run[0].get("file")})
            run = [ch]
    title = run[0]["title"]
    if run[-1]["title"] != title:
        title = f'{title} – {run[-1]["title"]}'
    grouped.append({"title": title,
                    "body": "\n".join(c["body"] for c in run),
                    "file": run[0].get("file")})
    if len(grouped) < 2 or len(grouped) == len(chapters):
        return None
    return grouped


def main(path: str, out_path: str, scheme: int = CHAPTER_SCHEME,
         max_chapters: int = MAX_CHAPTERS) -> None:
    z = zipfile.ZipFile(path)
    ncx_name = next(n for n in z.namelist() if n.endswith("toc.ncx"))
    ncx = z.read(ncx_name).decode("utf-8", "replace")

    entries = []
    for nav in re.findall(r"<navPoint[^>]*>.*?</navPoint>", ncx, re.S):
        t = re.search(r"<text>(.*?)</text>", nav, re.S)
        s = re.search(r'src="(.*?)"', nav)
        if t and s:
            src = s.group(1)
            file_part, _, anchor = src.partition("#")
            entries.append({
                "title": html.unescape(t.group(1)).strip(),
                "file": file_part,
                "anchor": anchor,
            })

    # Text of each spine file, keyed by name, split at anchor ids.
    bodies = {}
    for e in entries:
        if e["file"] not in bodies:
            bodies[e["file"]] = z.read(e["file"]).decode("utf-8", "replace")

    chapters = []
    for i, e in enumerate(entries):
        doc = bodies[e["file"]]
        start = 0
        if e["anchor"]:
            m = re.search(r'id="%s"' % re.escape(e["anchor"]), doc)
            start = m.start() if m else 0
        nxt = entries[i + 1] if i + 1 < len(entries) else None
        if nxt and nxt["file"] == e["file"] and nxt["anchor"]:
            m2 = re.search(r'id="%s"' % re.escape(nxt["anchor"]), doc)
            end = m2.start() if m2 else len(doc)
        else:
            end = len(doc)
        chapters.append({"title": e["title"], "body": strip_tags(doc[start:end]),
                         "file": e["file"]})

    how = "none"
    if len(chapters) > max_chapters:
        if scheme == 1:
            chapters, how = pair_bucket(chapters, max_chapters), "pairs"
        else:
            by_file = group_by_file(chapters)
            if by_file and len(by_file) <= max_chapters:
                chapters, how = by_file, "fragments"
            else:
                chapters, how = pair_bucket(by_file or chapters, max_chapters), "pairs"

    buf, total, included, truncated = [], 0, 0, False
    for i, ch in enumerate(chapters, 1):
        if not ch["body"]:
            continue
        header = f'\n=== CHAPTER {i}: {ch["title"]} ===\n'
        if total + len(header) + len(ch["body"]) > MAX_CHARS:
            truncated = True
            break
        buf.append(header)
        buf.append(ch["body"])
        total += len(header) + len(ch["body"])
        included += 1

    text = "".join(buf)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(text)

    print(f"chapters in TOC : {len(entries)}")
    print(f"chapters emitted: {included} (scheme={scheme}, how={how}, "
          f"grouped={len(entries) > max_chapters}, truncated={truncated})")
    print(f"characters      : {len(text)}")
    print(f"est. tokens     : {-(-len(text) // 3)}")
    for i, ch in enumerate(chapters, 1):
        if 44 <= i <= 50:
            print(f"  ch{i}: {ch['title'][:60]}  ({len(ch['body'])} chars)")


if __name__ == "__main__":
    scheme = CHAPTER_SCHEME
    max_chapters = MAX_CHAPTERS
    args = [a for a in sys.argv[1:] if a]
    if "--scheme" in args:
        i = args.index("--scheme")
        scheme = int(args[i + 1])
        del args[i:i + 2]
    if "--max-chapters" in args:
        i = args.index("--max-chapters")
        max_chapters = int(args[i + 1])
        del args[i:i + 2]
    main(args[0], args[1], scheme, max_chapters)
