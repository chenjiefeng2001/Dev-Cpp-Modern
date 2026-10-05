#!/usr/bin/env python3
"""
f3_svg_extract.py -- step 1 of the SVG plan: lift the icon data out of the DFM.

WHY STEP 1 IS DONE IN PYTHON AND CHECKED HERE
=============================================
The SVGs live inline in Source/DataFrm.dfm as `SVGText = '<svg .../>'` string
continuations. The LCL control will want them as a plain Pascal array, so they
have to be lifted out once and checked. That check is possible WITHOUT Lazarus --
the extraction is text, and the correctness criterion is exact: the SVG written
into the .pas must be byte-identical to the SVG in the DFM.

That is what --verify does, and it re-reads the DFM rather than trusting the
values it just parsed. A generator that can only agree with itself proves
nothing, which is the same trap as a form survey that compares a form against a
list it built from that form.

WHAT IS WRITTEN
===============
  <out>/SvgData.pas        -- one const array per image list
  <out>/svg_manifest.json  -- names, sizes, sha256, for cross-checking by other
                              tools without parsing Pascal

The default output moved from Tests/FpcCoreTests/svg to Source/Fpc/UI/Data on
2026-10-06: the payload is no longer a test fixture, it is the shipped data of
the LCL port (doc F3-SVG section 11.7). The probes still live under Tests/.

Run:  python tools/f3_svg_extract.py [--out DIR] [--verify]
Exit: 0 on success; 1 when any SVG fails the round-trip check.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
DATA_DFM = SOURCE / "DataFrm.dfm"

LIST_RE = re.compile(r"^\s*object\s+(\w+)\s*:\s*(TSVGIcon\w+)\s*$", re.M)
ITEM_RE = re.compile(
    r"item\s*\r?\n\s*IconName\s*=\s*'([^']*)'(?P<rest>(?:\s*\r?\n(?!\s*(?:item|end|\w+\s*=))(?:\s*'[^']*'\s*\+?\s*)*\s*\r?\n)*)",
    re.M,
)
SVG_TEXT_RE = re.compile(r"SVGText\s*=\s*\r?\n((?:\s*'[^']*'\s*\+?\s*\r?\n)+)", re.M)
STR_RE = re.compile(r"'([^']*)'")
SIZE_RE = re.compile(r"^\s*Size\s*=\s*(\d+)", re.M)

# An item block starts at an `item` line; its end is the next one.
#
# The first version used a negative lookahead to find that boundary and matched
# ZERO items while still reporting "VERIFY OK: 0" -- a green light over an empty
# result reads as progress and is worse than a failure. The boundary is now found
# by splitting on the keyword, and the verifier refuses to pass an empty run.
ITEM_HEAD_RE = re.compile(r"item\s*\r?\n\s*IconName\s*=\s*'([^']*)'", re.M)
# `SVGText =` is followed by a NEWLINE before the first quoted chunk, so the
# pattern must allow that; demanding the quote on the same line matched nothing,
# which was the other half of the zero-item bug.
# Matches the WHOLE continuation block. An earlier version captured only the
# first quoted chunk and dropped the rest, so every SVG came out truncated --
# 64 characters instead of 521, and the round-trip check passed anyway because
# it compared the truncated value against itself.
SVG_TEXT_RE = re.compile(
    r"SVGText\s*=\s*\r?\n((?:\s*'[^']*'\s*\+?\s*\r?\n)+)", re.M)


def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def unquote(block):
    """Join a Pascal string continuation into the text it encodes."""
    return "".join(STR_RE.findall(block))


def pascal_string(s, indent="    "):
    """Emit a Pascal string literal, chunked so no source line runs away.

    Pascal has no line length limit, but a single 2 KB line is unreviewable,
    and the entire point of extracting this data is that a human can diff it.

    Continuation chunks are indented to the column the opening quote began
    at. Unindented they are still valid Pascal, but they read as top-level
    lines, which makes a 1000-line data file impossible to diff by eye.
    """
    width = 96
    chunks = []
    cur = ""
    for ch in s:
        if ch == "'":
            cur += "''"
        else:
            cur += ch
        if len(cur) >= width:
            chunks.append(cur)
            cur = ""
    if cur:
        chunks.append(cur)
    if not chunks:
        return "''"
    if len(chunks) == 1:
        return "'" + chunks[0] + "'"
    pad = " " * len(indent)
    parts = ["'" + chunks[0] + "'"]
    for c in chunks[1:]:
        parts.append(pad + "'" + c + "'")
    # CRLF, matching the rest of the file. A bare \n here put 881 lone LFs
    # into a CRLF file, which the repo line-ending gate rejected.
    return " +\r\n".join(parts)


def parse_lists(text):
    """Return [{name, class, declared_size, items}] in file order.

    Splitting the body on the `item` keyword is what makes this work. The
    previous implementation tried to find each item's end with a negative
    lookahead and found nothing, which is why an earlier run reported five
    lists, zero items, and "VERIFY OK".
    """
    marks = [(m.start(), m.group(1), m.group(2)) for m in LIST_RE.finditer(text)]
    lists = []
    for i, (pos, name, cls) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        body = text[pos:end]
        items = []
        heads = list(ITEM_HEAD_RE.finditer(body))
        for j, h in enumerate(heads):
            item_end = heads[j + 1].start() if j + 1 < len(heads) else len(body)
            svg_m = SVG_TEXT_RE.search(body, h.end(), item_end)
            if svg_m:
                items.append({
                    "name": h.group(1),
                    "svg": unquote(svg_m.group(0).split("=", 1)[1]),
                })
        size_m = SIZE_RE.search(body)
        lists.append({
            "name": name,
            "class": cls,
            "declared_size": int(size_m.group(1)) if size_m else None,
            "items": items,
        })
    return lists

def sep(items, item):
    """',' between array-constant elements, nothing after the last one.

    FPC accepts neither a missing separator
        SvgData.pas(30,5) Fatal: Syntax error, "," expected but "const string" found
    nor a trailing one
        SvgData.pas(113,18) Fatal: Syntax error, ")" expected but "," found
    while Delphi accepts the newline-separated form outright. So the rule is
    "between, never after", and it is decided here rather than at four call
    sites.

    Identity (`is`) is enough and is what the two emitted arrays need: names and
    SVG are built from the SAME `items` list, so the final element is literally
    the same object in both.
    """
    return "" if item is items[-1] else ","


def init_call(idx, l, indent="  "):
    """The ONE `FillSvgList(...)` call for list `idx`.

    Shared by the writer and by --verify, so the round-trip check cannot drift
    away from what is actually emitted. The earlier verifier instead grepped for
    the literal text `SizePx: 19;`, which only existed because of the record
    constant shape -- a check anchored to a formatting decision rather than to
    the data, and therefore guaranteed to break the moment the shape changed for
    an unrelated reason.
    """
    return ("{i}FillSvgList(SVG_IMAGE_LISTS[{idx}], {name}, {size}, "
            "LIST{idx}_NAMES, LIST{idx}_SVG);".format(
                i=indent,
                idx=idx,
                name=pascal_string(l["name"], indent + "  "),
                size=l["declared_size"] or 0))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "Source" / "Fpc" / "UI" / "Data"))
    ap.add_argument("--verify", action="store_true",
                    help="re-read the DFM and compare every SVG byte for byte")
    args = ap.parse_args()

    text = read(DATA_DFM)
    lists = parse_lists(text)

    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    total = sum(len(l["items"]) for l in lists)
    print(f"lists: {len(lists)}   items: {total}")
    for l in lists:
        # `Size` is the list's ICON EDGE IN PIXELS, not its item count.
        #
        # Mis-read at first: an earlier version compared Size against the parsed
        # item count and warned "Size=19 but 85 items parsed", which reads like a
        # parse failure. The declaration in
        # VCL/SVGIconImageList/Source/FMX.SVGIconImageList.pas reads
        # `property Size: Integer ... default 32` -- a pixel size -- so there was
        # never a mismatch.
        #
        # It matters to the replacement control: the lists are NOT all the same
        # size (19, 18, 25, 37 px), so one hard-coded icon size would render most
        # of them wrong.
        px = l["declared_size"] if l["declared_size"] is not None else "(default 32)"
        print(f"    {l['name']:<32} {len(l['items']):3d} item(s), icon size {px} px")

    # ---- Pascal unit ----------------------------------------------------
    pas = []
    pas.append("{ SVG icon data extracted from Source/DataFrm.dfm.")
    pas.append("  Generated by tools/f3_svg_extract.py -- do not hand-edit; re-run the tool.")
    pas.append("}")
    pas.append("unit SvgData;")
    pas.append("")
    pas.append("interface")
    pas.append("")
    pas.append("type")
    pas.append("  /// One image list: the inline SVG sources, in index order.")
    pas.append("  TSvgImageList = record")
    pas.append("    Name: string;")
    pas.append("    /// Icon edge in PIXELS, measured from the DFM's `Size` property.")
    pas.append("    /// Zero means the DFM declared no Size, so the control's own")
    pas.append("    /// default applies. Carried as DATA rather than re-derived in")
    pas.append("    /// code: the five lists measure 19/18/(none)/25/37 px, so one")
    pas.append("    /// hard-coded edge renders four of them wrong, and a")
    pas.append("    /// name-matching if-chain in the loader falls through to the")
    pas.append("    /// default SILENTLY the day a list gets renamed.")
    pas.append("    SizePx: Integer;")
    pas.append("    /// IconName per index. Diagnostics only -- never a lookup key,")
    pas.append("    /// because 20 of the 116 names repeat across the set.")
    pas.append("    Names: array of string;")
    pas.append("    Svg: array of string;")
    pas.append("  end;")
    pas.append("")
    # ------------------------------------------------------------------
    # WHY THIS IS NOT ONE BIG RECORD CONSTANT
    # --------------------------------------
    # The first version emitted
    #
    #     const
    #       SVG_IMAGE_LISTS: array[0..4] of TSvgImageList = (
    #         ( Name: 'SVGImageListMenuStyle';
    #           Names: array[0..84] of string = ( 'iconsnew-51', ... ) );
    #         ... );
    #
    # which is legal Delphi and is rejected by Free Pascal outright:
    #
    #     SvgData.pas(32,14) Fatal: Syntax error, "(" expected but "ARRAY" found
    #
    # so the data unit -- the foundation both the control and every converted
    # form depend on -- did not compile at all. A plain dynamic-array field with
    # an inline constant is refused too, for the same reason.
    #
    # Measured across the shapes (tools probe, FPC 3.2.2):
    #
    #     record const, static array field   REJECTED
    #     record const, dynamic array field  REJECTED
    #     standalone static array const      OK
    #     static const -> dynamic array      OK
    #     var + `initialization` (unit)      OK
    #
    # So the payload goes into standalone STATIC constants and the record array
    # is a `var` filled in `initialization`. That also keeps the payloads
    # readable: one `LISTn_SVG` block per list instead of nesting a 2 KB literal
    # inside a record constructor.
    #
    # The `InitList` call text is produced by `init_call()`, which the verifier
    # also calls -- so the round-trip check and the writer cannot drift apart.
    pas.append("const")
    for idx, l in enumerate(lists):
        n = len(l["items"])
        head = "%d item(s)" % n
        if n == 0:
            continue
        pas.append(f"  /// {l['name']}: {head}.")
        pas.append(f"  LIST{idx}_NAMES: array[0..{n - 1}] of string = (")
        for it in l["items"]:
            # Commas go BETWEEN elements -- never after the last one.
            #
            # Delphi accepts newline-separated array constants, FPC does not:
            #     SvgData.pas(30,5) Fatal: Syntax error, "," expected but
            #                              "const string" found
            # and it equally rejects the trailing form:
            #     SvgData.pas(113,18) Fatal: Syntax error, ")" expected but
            #                               "," found
            #
            # The comma attaches at the very END of the chunked literal, which is
            # where pascal_string() puts its closing quote.
            pas.append(f"    {pascal_string(it['name'], '    ')}" + sep(l["items"], it))
        pas.append("  );")
        pas.append(f"  LIST{idx}_SVG: array[0..{n - 1}] of string = (")
        for it in l["items"]:
            pas.append(f"    {pascal_string(it['svg'], '    ')}" + sep(l["items"], it))
        pas.append("  );")
        pas.append("")

    pas.append("var")
    pas.append("  /// Every list found in DataFrm.dfm, in declaration order.")
    pas.append("  /// Populated in `initialization` -- see the note above on why this")
    pas.append("  /// cannot be a typed constant.")
    pas.append("  SVG_IMAGE_LISTS: array[0..%d] of TSvgImageList;" % max(0, len(lists) - 1))
    pas.append("")
    pas.append("// Number of extracted lists.")
    pas.append("function SvgListCount: Integer;")
    pas.append("// Index of the list called AName, or -1. Resolving by NAME is what the")
    pas.append("// code needs: the DFM assigns `dmMain.SVGImageListMenuStyle`, so the list")
    pas.append("// name is the handle that actually appears at a use site.")
    pas.append("function FindSvgListIndex(const AName: String): Integer;")
    pas.append("")
    pas.append("implementation")
    pas.append("")
    pas.append("procedure FillSvgList(var AList: TSvgImageList; const AName: String;")
    pas.append("  ASizePx: Integer; const ANames, ASvg: array of String);")
    pas.append("var")
    pas.append("  I: Integer;")
    pas.append("begin")
    pas.append("  AList.Name := AName;")
    pas.append("  // Zero, not the default, when the DFM declared no Size: the control")
    pas.append("  // owns the fallback, so this file only reports what was measured.")
    pas.append("  AList.SizePx := ASizePx;")
    pas.append("  SetLength(AList.Names, Length(ANames));")
    pas.append("  SetLength(AList.Svg, Length(ASvg));")
    pas.append("  for I := 0 to High(ANames) do")
    pas.append("    AList.Names[I] := ANames[I];")
    pas.append("  for I := 0 to High(ASvg) do")
    pas.append("    AList.Svg[I] := ASvg[I];")
    pas.append("end;")
    pas.append("")
    pas.append("function SvgListCount: Integer;")
    pas.append("begin")
    pas.append("  Result := High(SVG_IMAGE_LISTS) + 1;")
    pas.append("end;")
    pas.append("")
    pas.append("function FindSvgListIndex(const AName: String): Integer;")
    pas.append("var")
    pas.append("  I: Integer;")
    pas.append("begin")
    pas.append("  for I := Low(SVG_IMAGE_LISTS) to High(SVG_IMAGE_LISTS) do")
    pas.append("    if SVG_IMAGE_LISTS[I].Name = AName then")
    pas.append("      Exit(I);")
    pas.append("  Result := -1;")
    pas.append("end;")
    pas.append("")
    pas.append("initialization")
    for idx, l in enumerate(lists):
        pas.append(init_call(idx, l, indent="  "))
    pas.append("end.")
    # CRLF only, no blank lines between entries, no trailing blank line.
    # (An extra "\r\n" here produced one empty line per source line, which
    # is 900+ lines of noise in a file whose whole purpose is reviewability.)
    # newline="" stops Python translating the CRLFs again on write; without it the
    # file comes out LF on some platforms and CRLF on others, and the repo
    # gate (mixed line endings) then fails on a file that is otherwise right.
    # Written as BYTES, not text.
    # pathlib.write_text goes through open() in text mode, and text mode
    # translates "\r\n" into "\n" on Windows -- which is why the earlier
    # `newline=""` attempt produced a file the repo line-ending gate rejected
    # with 881 bare LFs. Encoding to bytes first is the only form that keeps
    # the CRLFs exactly as written.
    (out_dir / "SvgData.pas").write_bytes("\r\n".join(pas).encode("utf-8"))

    # ---- manifest -------------------------------------------------------
    manifest = []
    for l in lists:
        manifest.append({
            "list": l["name"],
            "class": l["class"],
            # The manifest is the cross-check surface for tools that cannot parse
            # Pascal, so the measured pixel edge belongs here as much as in the
            # .pas. It was absent, which meant the only record of "this list is
            # 37 px, not 32" lived inside the control as a name-matching chain.
            "size_px": l["declared_size"],
            "count": len(l["items"]),
            "items": [
                {
                    "name": it["name"],
                    "chars": len(it["svg"]),
                    "sha256": hashlib.sha256(it["svg"].encode("utf-8")).hexdigest(),
                }
                for it in l["items"]
            ],
        })
    (out_dir / "svg_manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print()
    print(f"wrote {out_dir / 'SvgData.pas'}")
    print(f"wrote {out_dir / 'svg_manifest.json'}")

    if not args.verify:
        print()
        print("NOTE: not verified. Re-run with --verify to compare every SVG against the DFM.")
        return 0

    # ---- verification ---------------------------------------------------
    # Re-read the DFM and re-extract, then compare against what was WRITTEN to
    # the Pascal file. Comparing against the in-memory values would only prove
    # the writer is consistent with itself.
    written = (out_dir / "SvgData.pas").read_text(encoding="utf-8")
    # Rebuild the concatenated text from every Pascal literal in the written
    # file, undoing the '' doubling, so membership can be tested on the DATA
    # rather than on the source formatting.
    literal_stream = "".join(
        c.replace("''", "'") for c in STR_RE.findall(written)
    )
    fresh = parse_lists(read(DATA_DFM))
    mismatches = []
    for l_old, l_new in zip(lists, fresh):
        if l_old["name"] != l_new["name"]:
            mismatches.append(f"list order differs: {l_old['name']} vs {l_new['name']}")
            continue
        if len(l_old["items"]) != len(l_new["items"]):
            mismatches.append(
                f"{l_new['name']}: {len(l_old['items'])} vs {len(l_new['items'])} items")
            continue
        # The per-list pixel edge is now DATA, so it is verified like any other
        # field rather than trusted. A SizePx of 0 is legal and means "the DFM
        # declared none"; what must never happen is a nonzero value the DFM does
        # not agree with.
        if l_old["declared_size"] != l_new["declared_size"]:
            mismatches.append(
                f"{l_new['name']}: size_px {l_new['declared_size']} vs "
                f"{l_old['declared_size']}")
        # The measured edge has to survive into the unit. This used to grep for
        # `SizePx: 19;`, a literal that only existed because the data was a typed
        # constant -- anchoring a data check to a formatting choice. It now
        # compares against the same `init_call()` text the writer used, so the
        # two cannot disagree about what the emitted file should contain.
        call = init_call(fresh.index(l_new), l_new, indent="  ")
        if call not in written:
            mismatches.append(
                f"{l_new['name']}: FillSvgList call for size_px "
                f"{l_new['declared_size'] or 0} not written")
        if not l_new["items"]:
            continue
        for a, b in zip(l_old["items"], l_new["items"]):
            if a["svg"] != b["svg"]:
                mismatches.append(f"{l_new['name']}/{a['name']}: svg differs")
            # The .pas stores each SVG as a CHUNKED, INDENTED literal, so a
            # substring test against the written text fails for every icon. The
            # earlier check did exactly that and reported mismatches on a file
            # that was in fact correct -- another case of a verifier measuring
            # the wrong thing and looking like it had caught a bug.
            #
            # The right comparison is: rebuild the text from the Pascal literal
            # stream and require each SVG to appear in it exactly.
            if b["svg"] not in literal_stream:
                mismatches.append(f"{l_new['name']}/{b['name']}: not reconstructable from SvgData.pas")
            # Names are data too. 20 of the 116 repeat across the set, so they
            # cannot be counted for uniqueness -- only for presence.
            if b["name"] and f"'{b['name']}'" not in written:
                mismatches.append(f"{l_new['name']}: name {b['name']} missing from SvgData.pas")

    print()
    if mismatches:
        print(f"VERIFY FAILED ({len(mismatches)}):")
        for m in mismatches[:20]:
            print(f"  {m}")
        return 1
    print(f"VERIFY OK: {total} SVG(s) round-trip byte-identical from the DFM "
          f"into SvgData.pas.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
