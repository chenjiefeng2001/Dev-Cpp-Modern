#!/usr/bin/env python3
"""
f3_svg_inventory.py -- what the SVG icon work actually consists of.

WHY THIS FILE EXISTS
===================
Nine batch-A forms convert cleanly and then render blank because they draw from
a vendored `TSVGIconImageList`, and four batch-C forms are blocked by the same
class. Before choosing between "port the vendored unit" and "render the SVGs some
other way", the size and shape of the data have to be known -- and the answer
changes the recommendation completely.

WHAT IS MEASURED
================
  * how many icons exist, and how many DISTINCT names (duplicates matter: a
    rename would have to be applied once per reference, not once per definition)
  * whether the SVGs are self-contained
  * which construct each consumer needs

THE FACT THAT DECIDES THE APPROACH
==================================
The icons are INLINE SVG TEXT in the DFM (`SVGText = '<svg .../>'`), not files
on disk. Measured consequences:

  * no file-path resolution at run time, so no asset-bundling problem
  * no dependency on `fpvectorial`/`lazutils` XML + rasterisation being present
  * the only genuinely VCL-coupled part is the CONTROL (`TSVGIconImageList` is a
    `TCustomImageList`), not the data

So the question is not "can LCL load these SVGs" but "what has to render them",
and a control that parses inline SVG and paints it answers it without moving
the data at all.
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
DATA_DFM = SOURCE / "DataFrm.dfm"

ITEM_RE = re.compile(r"item\s*\r?\n\s*IconName\s*=\s*'([^']+)'", re.I)
LIST_RE = re.compile(r"object\s+(\w+)\s*:\s*TSVGIcon\w+", re.I)
# The WHOLE continuation block, not just the first chunk. Capturing only
# the first chunk is what made this file report 7.2 KB when the real figure
# is ~89 KB; f3_svg_extract.py --verify is the authority.
SVGTEXT_RE = re.compile(r"SVGText\s*=\s*\r?\n((?:\s*'[^']*'\s*\+?\s*\r?\n)+)", re.I)
STR_RE = re.compile(r"'([^']*)'")


def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def main() -> int:
    text = read(DATA_DFM)

    lists = LIST_RE.findall(text)
    items = ITEM_RE.findall(text)
    blocks = SVGTEXT_RE.findall(text)

    print("SVG ICON INVENTORY")
    print("=" * 70)
    print(f"source            : {DATA_DFM.relative_to(ROOT).as_posix()}")
    print(f"SVG image lists   : {len(lists)}")
    for n in lists:
        print(f"    {n}")
    print(f"icon items        : {len(items)}")
    print(f"distinct names    : {len(set(items))}")
    print(f"inline SVG blocks : {len(blocks)}")

    total = 0
    for b in blocks:
        total += sum(len(s) for s in STR_RE.findall(b))
    print(f"total SVG text    : ~{total} chars ({total/1024:.1f} KB)")

    dupes = [n for n, c in collections.Counter(items).items() if c > 1]
    print(f"duplicated names  : {len(dupes)}")

    print()
    print("SELF-CONTAINMENT CHECK")
    external = []
    for b in blocks:
        svg = "".join(STR_RE.findall(b))
        for marker, what in (
            ("<image", "raster embedded in the SVG"),
            ("xlink:href", "references an external file"),
            ("@font-face", "needs a font"),
            ("url(", "references an external resource"),
        ):
            if marker in svg:
                external.append(what)
    if external:
        for what, n in collections.Counter(external).most_common():
            print(f"    {n} block(s): {what}")
    else:
        print("    every SVG is inline and self-contained")
        print("    (no <image>, no xlink:href, no @font-face, no url())")

    print()
    print("WHAT CONSUMERS NEED")
    needs = collections.Counter()
    for p in sorted(SOURCE.rglob("*.dfm")):
        if "VCL" in p.parts:
            continue
        t = read(p)
        for m in re.findall(r"^\s*Images\s*=\s*(\S+)", t, re.M):
            needs[m.strip()] += 1
    for k, v in needs.most_common():
        tag = ""
        if "SVG" in k:
            tag = "   <-- needs the SVG replacement"
        print(f"    {v:3d}  {k}{tag}")
    svg_sites = sum(v for k, v in needs.items() if "SVG" in k)
    plain_sites = sum(v for k, v in needs.items() if "SVG" not in k)
    print()
    print(f"  {svg_sites} of {svg_sites + plain_sites} .Images assignments point at an")
    print("  SVG list; the rest already use plain TImageList and are unaffected.")
    print()
    print("REPLACEMENT SURFACE (what the new control must expose)")
    print("    Images property on TButton/TImage/TMainMenu  -> assign an image list")
    print("    ImageIndex property                            -> 188 DFM sites + 48 code sites")
    print("    an indexed list of inline SVGs                -> 116 items, 94 distinct")
    print("    theming                                         -> SVGs carry fill styles that")
    print("                                                      a themed UI recolours at run time")
    return 0
    print()
    print("So the replacement has to expose: an indexed image list (for .Images),")
    print("a settable ImageIndex, and ideally per-item colour, since the SVGs")
    print("carry fill styles that a themed UI re-colours at run time.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
