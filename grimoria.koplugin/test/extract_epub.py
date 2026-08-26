#!/usr/bin/env python3
"""
Mimic lib/booktext.lua for an EPUB, outside KOReader.

It follows the OPF spine, not just the files named directly by toc.ncx, so a
TOC entry covers every XHTML file up to the next entry. Scheme 3 also mirrors
Grimoria's recovery of printed subchapters that start a spine file but are
missing from the navigation document.
"""
import html
import posixpath
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import unquote

MAX_CHAPTERS = 100
MAX_CHARS = 1000000
CHAPTER_SCHEME = 3


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

def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def resolve_member(base: str, href: str) -> str:
    return posixpath.normpath(posixpath.join(base, unquote(href.split("#", 1)[0])))


def package_structure(z):
    opf_name = next(n for n in z.namelist() if n.endswith(".opf"))
    root = ET.fromstring(z.read(opf_name))
    manifest = {
        item.attrib["id"]: item.attrib["href"]
        for item in root.iter()
        if local_name(item.tag) == "item"
        and "id" in item.attrib and "href" in item.attrib
    }
    base = posixpath.dirname(opf_name)
    spine = [
        resolve_member(base, manifest[item.attrib["idref"]])
        for item in root.iter()
        if local_name(item.tag) == "itemref"
        and item.attrib.get("idref") in manifest
    ]
    ncx_item = next(
        (item for item in root.iter()
         if local_name(item.tag) == "item"
         and item.attrib.get("media-type") == "application/x-dtbncx+xml"),
        None,
    )
    ncx_name = (resolve_member(base, ncx_item.attrib["href"])
                if ncx_item is not None
                else next(n for n in z.namelist() if n.endswith("toc.ncx")))
    return spine, ncx_name


def navigation_entries(z, ncx_name, spine):
    root = ET.fromstring(z.read(ncx_name))
    base = posixpath.dirname(ncx_name)
    file_indexes = {name: i for i, name in enumerate(spine)}
    entries = []
    for nav in root.iter():
        if local_name(nav.tag) != "navPoint":
            continue
        label = next((e for e in nav.iter() if local_name(e.tag) == "text"), None)
        content = next((e for e in nav.iter() if local_name(e.tag) == "content"), None)
        if label is None or content is None or "src" not in content.attrib:
            continue
        src = html.unescape(content.attrib["src"])
        file_part, _, anchor = src.partition("#")
        member = resolve_member(base, file_part)
        if member not in file_indexes:
            continue
        entries.append({
            "title": "".join(label.itertext()).strip(),
            "file": member,
            "file_index": file_indexes[member],
            "anchor": anchor,
        })
    return entries


def first_blocks(doc: str):
    blocks = []
    for match in re.finditer(r"(?is)<p\b[^>]*>(.*?)</p>", doc):
        text = strip_tags(match.group(1))
        if text:
            blocks.append((match.start(), "p", text))
    for match in re.finditer(r"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>", doc):
        text = strip_tags(match.group(1))
        if text:
            blocks.append((match.start(), "h", text))
    return sorted(blocks)


def printed_section_number(text: str):
    return int(text) if re.fullmatch(r"\d+", text) and 1 <= int(text) <= 20 else None


def fragment_signal(doc: str):
    blocks = first_blocks(doc)
    if not blocks:
        return None
    _, kind, first = blocks[0]
    second_number = (printed_section_number(blocks[1][2])
                     if len(blocks) > 1 else None)
    number = printed_section_number(first)
    if kind == "h":
        return ({"heading": first, "number": second_number}
                if second_number else None)
    if number:
        return {"number": number}
    if second_number and len(first.encode("utf-8")) <= 160 and re.search(r"\w", first):
        return {"heading": first, "number": second_number}
    return None


def refine_entries(entries, spine, docs):
    groups = [[] for _ in entries]
    for file_index, member in enumerate(spine):
        signal = fragment_signal(docs[member])
        if not signal:
            continue
        owner = next((i for i, entry in enumerate(entries)
                      if entry["file_index"] == file_index), None)
        if owner is None:
            owner = next((i for i in range(len(entries) - 1, -1, -1)
                          if entries[i]["file_index"] <= file_index), None)
        if owner is not None:
            groups[owner].append({**signal, "file": member,
                                  "file_index": file_index})

    refined = []
    for entry, signals in zip(entries, groups):
        anchor = next((s for s in signals if s["file"] == entry["file"]), None)
        numeric_count = sum(s.get("number") is not None for s in signals)
        base = entry["title"]
        parent = entry.copy()
        if anchor and anchor.get("number") and numeric_count >= 2:
            parent["title"] = f'{base} · {anchor["number"]}'
        refined.append(parent)

        for signal in signals:
            if signal["file"] == entry["file"]:
                continue
            title = None
            if signal.get("heading"):
                base = signal["heading"]
                title = (f'{base} · {signal["number"]}'
                         if signal.get("number") else base)
            elif signal.get("number") and numeric_count >= 2:
                title = f'{base} · {signal["number"]}'
            if title:
                refined.append({
                    "title": title, "file": signal["file"],
                    "file_index": signal["file_index"], "anchor": "",
                })
    return refined


def entry_offset(entry, doc):
    if not entry["anchor"]:
        return 0
    match = re.search(r'''(?i)\bid\s*=\s*["']%s["']'''
                      % re.escape(entry["anchor"]), doc)
    return match.start() if match else 0


def attach_bodies(entries, spine, docs):
    chapters = []
    for i, entry in enumerate(entries):
        nxt = entries[i + 1] if i + 1 < len(entries) else None
        chunks = []
        for file_index in range(entry["file_index"],
                                nxt["file_index"] + 1 if nxt else len(spine)):
            doc = docs[spine[file_index]]
            start = entry_offset(entry, doc) if file_index == entry["file_index"] else 0
            end = (entry_offset(nxt, doc)
                   if nxt and file_index == nxt["file_index"] else len(doc))
            if end > start:
                chunks.append(doc[start:end])
            if nxt and file_index == nxt["file_index"]:
                break
        chapters.append({
            "title": entry["title"],
            "body": strip_tags("\n".join(chunks)),
            "file": entry["file"],
        })
    return chapters



def main(path: str, out_path: str, scheme: int = CHAPTER_SCHEME,
         max_chapters: int = MAX_CHAPTERS) -> None:
    z = zipfile.ZipFile(path)
    spine, ncx_name = package_structure(z)
    entries = navigation_entries(z, ncx_name, spine)
    docs = {
        member: z.read(member).decode("utf-8", "replace")
        for member in spine
    }

    starts = refine_entries(entries, spine, docs) if scheme >= 3 else entries
    chapters = attach_bodies(starts, spine, docs)

    how = "fragments" if len(starts) > len(entries) else "none"
    bucketed = len(chapters) > max_chapters
    if bucketed:
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
          f"grouped={bucketed}, truncated={truncated})")
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
