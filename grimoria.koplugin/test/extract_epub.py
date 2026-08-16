#!/usr/bin/env python3
"""
Mimic lib/booktext.lua for an EPUB, outside KOReader.

Same contract as the plugin: walk the TOC in order, take the text between one
entry's anchor and the next, and emit it with "=== CHAPTER n: title ===" markers
so the model can attribute what it finds to a chapter. Bucketing is applied at
the same threshold (MAX_CHAPTERS = 60) so chapter numbers match what the device
would produce for this book.
"""
import html
import re
import sys
import zipfile

MAX_CHAPTERS = 60
MAX_CHARS = 1000000


def strip_tags(fragment: str) -> str:
    fragment = re.sub(r"(?is)<(script|style).*?</\1>", " ", fragment)
    fragment = re.sub(r"(?i)<(br|/p|/div|/h[1-6])[^>]*>", "\n", fragment)
    fragment = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(fragment)
    text = re.sub(r"[ \t\xa0]+", " ", text)
    text = re.sub(r"\n\s*\n\s*", "\n\n", text)
    return text.strip()


def main(path: str, out_path: str) -> None:
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
        chapters.append({"title": e["title"], "body": strip_tags(doc[start:end])})

    # Same bucketing rule as BookText:getChapterList.
    if len(chapters) > MAX_CHAPTERS:
        per = -(-len(chapters) // MAX_CHAPTERS)
        grouped = []
        for i in range(0, len(chapters), per):
            chunk = chapters[i:i + per]
            title = chunk[0]["title"]
            if len(chunk) > 1 and chunk[-1]["title"] != title:
                title = f'{title} – {chunk[-1]["title"]}'
            grouped.append({"title": title,
                            "body": "\n".join(c["body"] for c in chunk)})
        chapters = grouped

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
    print(f"chapters emitted: {included} (grouped={len(entries) > MAX_CHAPTERS}, "
          f"truncated={truncated})")
    print(f"characters      : {len(text)}")
    print(f"est. tokens     : {-(-len(text) // 3)}")
    for i, ch in enumerate(chapters, 1):
        if 44 <= i <= 50:
            print(f"  ch{i}: {ch['title'][:60]}  ({len(ch['body'])} chars)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
