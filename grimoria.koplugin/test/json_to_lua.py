#!/usr/bin/env python3
"""Turn the model's JSON reply into a Lua literal, so the shipped Lua code can
be run against it without needing KOReader's json module."""
import json
import sys


def lit(v, indent="  "):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        out = v.replace("\\", "\\\\").replace('"', '\\"')
        out = out.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return '"' + out + '"'
    if isinstance(v, list):
        if not v:
            return "{}"
        inner = ",\n".join(indent + "  " + lit(x, indent + "  ") for x in v)
        return "{\n" + inner + "\n" + indent + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        inner = ",\n".join(
            f'{indent}  ["{k}"] = ' + lit(x, indent + "  ") for k, x in v.items())
        return "{\n" + inner + "\n" + indent + "}"
    raise TypeError(type(v))


raw = open(sys.argv[1], encoding="utf-8").read()
txt = raw.replace("```json", "").replace("```", "").strip()
data = json.loads(txt)
open(sys.argv[2], "w", encoding="utf-8").write("return " + lit(data) + "\n")
print(f"wrote {sys.argv[2]}")
