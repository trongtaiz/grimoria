#!/usr/bin/env python3
"""Build the throwaway fixture test_legacy.lua needs.

Pure Lua cannot create a directory, so the settings and sidecar folders that
test represents a pre-rename install with have to be made from outside.

Nothing here is secret: the "key" is a literal placeholder, and the cache files
are empty markers -- test_legacy only ever asks which path gets opened, never
what is inside it.

  usage: python3 make_legacy_fixture.py <dir>
"""
import os
import shutil
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "tmp_legacy_fixture"
shutil.rmtree(root, ignore_errors=True)

FILES = {
    # Present under BOTH names, different values: the current one must win.
    "settings/grimoria/gemini_model.txt": "new-model",
    "settings/xray/gemini_model.txt": "old-model",
    # Only under the old name: must still be found.
    "settings/xray/openrouter_api_key.txt": "sk-or-v1-legacy",
    # Blank means "unset", not "set to empty".
    "settings/grimoria/blank.txt": "   \n",
    "settings/grimoria/padded.txt": "  trimmed \n",
    # A pre-rename analysis with no current counterpart.
    "sdr/xray_cache.lua": "return {}\n",
    # Notes under both names: the current one must win.
    "sdr/grimoria_notes.lua": "return {}\n",
    "sdr/xray_notes.lua": "return {}\n",
    # Must never be mistaken for an analysis.
    "sdr/xray_versions.lua": "return {}\n",
    "sdr/metadata.epub.lua": "return {}\n",
}

for rel, body in FILES.items():
    path = os.path.join(root, *rel.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)

print("fixture at %s (%d files)" % (root, len(FILES)))
