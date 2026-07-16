#!/usr/bin/env python3
"""Normalize assets/opxy.svg (TE artwork pasted from browser devtools) into a
valid standalone SVG, then `make gui` converts it to the vector PDF skin.

Handles both paste shapes:
  - a bare <g ...>...</g> (or loose <path> elements) → wrapped in an <svg> root
    with the artwork's viewBox (0 0 741 265)
  - a full <svg> element → kept as-is
Also strips clip-path attributes whose <clipPath> definition is missing
(devtools copies often lose <defs>, and a dangling reference can blank paths).
"""
import re, sys, os

SRC = "assets/opxy.svg"
DST = "assets/opxy-normalized.svg"

if not os.path.exists(SRC):
    sys.exit(f"{SRC} not found")

raw = open(SRC, encoding="utf8", errors="ignore").read().strip()

# Sanity: the TE artwork is ~80+ KB of <path> data. Anything else is a bad paste
# (e.g. the clipboard held something other than the SVG when it was saved).
if len(raw) < 20_000 or "<path" not in raw:
    sys.exit(f"{SRC} doesn't look like the OP-XY artwork "
             f"({len(raw)} bytes, contains <path>: {'<path' in raw}). "
             "Re-copy the <svg>/<g> element from the TE guide via devtools and save again.")

# strip dangling clip-path references
if "clip-path" in raw and "<clipPath" not in raw:
    raw = re.sub(r'\s*clip-path="[^"]*"', "", raw)

if "<svg" not in raw[:2000].lower():
    raw = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 741 265">\n'
           + raw + "\n</svg>\n")

open(DST, "w", encoding="utf8").write(raw)
print(f"skin normalized → {DST} ({len(raw)//1024} KB)")
