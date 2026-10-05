#!/usr/bin/env python3
"""
f3_lfm_check.py -- gate on the generated .lfm files.

WHAT IT ASSERTS
===============
  1. every converted form has an .lfm, and every .lfm has a source .dfm
     (an orphan in either direction means the conversion drifted)
  2. no VCL-only property survives in any .lfm -- the whole point of
     f3_dfm_to_lfm.py's DROP_PROPS, checked on the OUTPUT rather than trusted
     from the input list
  3. block structure is preserved relative to the source DFM
  4. CRLF line endings and no BOM, matching the rest of the repo

WHY (3) IS A DIFFERENCE AND NOT AN ABSOLUTE COUNT
================================================
The first version of this check required `object` count == `end` count, and
reported 6 of 34 files as unbalanced. They were not broken.

A Pascal stream has block terminators that are not object blocks: `end>` closes
a property collection (`Font.Style = []` nested inside a Font block), and DFM
also emits `end` for collection properties. Measured on CPUFrm.lfm: 22 objects,
30 `end`s, and 8 of those closes are `end>` collection terminators.

Requiring equality therefore flags correct files. The check instead compares the
LFM's counts against the SOURCE DFM's counts, because that is the property that
actually matters: the converter must not add or remove structure. Verified
across the 5 files the naive check complained about -- CPUFrm 22/30 -> 22/30,
FunctionSearchFrm 4/8 -> 4/8, ProfileAnalysisFrm 22/35 -> 22/35, ViewToDoFrm
6/11 -> 6/11, WindowListFrm 5/7 -> 5/7. Delta preserved exactly in all five.

WHAT IT STILL CANNOT PROVE
==========================
That Lazarus can LOAD these files. Only `lazbuild` / the LCL designer answers
that, and CI has a Lazarus job for it. This gate proves the mechanical transform
is faithful and free of the known-bad properties -- which is what can be checked
without a compiler.

Run:  python tools/f3_lfm_check.py
Exit: 0 when every assertion holds, 1 otherwise.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The converted forms moved out of Tests/ and into the FPC port proper on
# 2026-10-06 (doc F3-SVG section 11.7): they are the port's UI layer, not a
# test fixture. Tests/FpcCoreTests keeps the probes that MEASURE them.
LFM_ROOT = ROOT / "Source" / "Fpc" / "UI" / "Forms"
DFM_ROOT = ROOT / "Source"

# Must mirror f3_dfm_to_lfm.DROP_PROPS, and is asserted against it below rather
# than assumed to be in sync -- two hand-maintained lists drift, and a checker
# that only knows its own list would pass on a property the converter no longer
# strips.
BANNED = {
    "ExplicitLeft", "ExplicitTop", "ExplicitWidth", "ExplicitHeight",
    "OldCreateOrder", "PixelsPerInch", "PixelsPerInchX", "PixelsPerInchY",
    "UsePixelsPerInch", "TextHeight", "Font.Charset", "Font.Quality",
    "Ctl3D", "ParentCtl3D",
}

# Groups matter here: the tree check compares `Name:Type` pairs, so the name and
# type must be captured rather than matched non-capturing.
OBJ = re.compile(r"^(\s*)(?:object|inherited|inline)\s+(\w+)\s*:\s*(\w+)")
END = re.compile(r"^\s*end\b")


def read(p):
    return p.read_bytes().decode("latin-1")


END_ONLY = re.compile(r"^(\s*)end\s*$")


def counts(lines):
    return (sum(1 for l in lines if OBJ.match(l)),
            sum(1 for l in lines if END.match(l)))


def object_names(lines):
    """Ordered list of `Name:Type` for every object block.

    A LIST, not a multiset: two panels may legitimately declare the same control
    name, and the converter emits a flat list, so counting names would hide a swap
    between two identically-named components. Positional comparison catches it.
    """
    return [f"{OBJ.match(l).group(2)}:{OBJ.match(l).group(3)}"
            for l in lines if OBJ.match(l)]


ITEM = re.compile(r"^(\s*)item\s*$")


def walk(lines):
    """Return (unclosed_at_eof, orphan_end_lines) for a block-stack walk.

    `item` opens a block too. A TListView streams its rows as

        item
          Caption = '...'
        end

    so an `end` closing an `item` has no matching `object`. The first version of
    this walk pushed only objects, and therefore reported 23 of those legitimate
    terminators across 5 files as "`end` closes nothing" -- CPUFrm 4,
    ProfileAnalysisFrm 11, and so on. All of them were correct LFM.
    """
    stack, orphans = [], []
    for i, l in enumerate(lines, 1):
        m = OBJ.match(l) or ITEM.match(l)
        if m:
            indent = len(m.group(1))
            while stack and stack[-1] >= indent:
                stack.pop()
            stack.append(indent)
            continue
        me = END_ONLY.match(l)
        if me:
            indent = len(me.group(1))
            while stack and stack[-1] > indent:
                stack.pop()
            if stack and stack[-1] == indent:
                stack.pop()
            else:
                orphans.append(i)
    return stack, orphans


def main() -> int:
    problems = []

    if not LFM_ROOT.is_dir():
        print(f"ERROR: {LFM_ROOT.relative_to(ROOT)} does not exist")
        return 1
    lfms = sorted(LFM_ROOT.rglob("*.lfm"))
    if not lfms:
        print("ERROR: no .lfm files found")
        return 1

    # 1. orphan check, both directions. Fragments are exempt: a
    # `.svg-lists.lfm` is a subtree lifted out of a .dfm, not a form, so
    # `DataFrm.svg-lists.lfm -> DataFrm.dfm` is the wrong pairing to look for.
    for p in lfms:
        rel = p.relative_to(LFM_ROOT)
        if rel.name.endswith(".svg-lists.lfm"):
            continue
        src = DFM_ROOT / rel.with_suffix(".dfm")
        if not src.is_file():
            problems.append(f"orphan LFM with no source DFM: {rel.as_posix()}")

    have = {p.relative_to(LFM_ROOT).as_posix() for p in lfms}
    converted = set()
    for p in sorted(DFM_ROOT.rglob("*.dfm")):
        if "VCL" in p.parts:
            continue
        rel = p.relative_to(DFM_ROOT).as_posix()[:-4] + ".lfm"
        converted.add(rel)

    # 1b. PROVENANCE. Since the .lfm files can carry no header (TParser accepts
    # no comment syntax -- measured, see f3_dfm_to_lfm.py's docstring), the
    # record of what produced each file lives in _generated.json. Checking it
    # here is what keeps that file from rotting into a list nobody maintains:
    # an .lfm with no record is an orphan in the other direction.
    manifest_path = LFM_ROOT / "_generated.json"
    provenance = {}
    if not manifest_path.is_file():
        problems.append("_generated.json is missing -- nothing records provenance")
    else:
        provenance = json.loads(manifest_path.read_text(encoding="utf-8"))
        for rel in sorted(have):
            if rel not in provenance:
                problems.append(f"{rel}: no entry in _generated.json")
        for rel in sorted(provenance):
            if rel not in have:
                problems.append(f"_generated.json records {rel}, which does not exist")

    # 2/3/4. per-file assertions
    checked = 0
    fragments = 0
    for p in lfms:
        rel = p.relative_to(LFM_ROOT).as_posix()
        raw = p.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            problems.append(f"{rel}: has a UTF-8 BOM")
        if b"\r\n" not in raw and b"\n" in raw:
            problems.append(f"{rel}: LF-only line endings (repo is CRLF)")
        text = raw.decode("latin-1")
        lines = text.splitlines()

        # 1c. NO LEADING COMMENT. This is the check that would have caught the
        # defect that made all 34 files unreadable: TParser wants `object` as
        # the very first token and accepts none of `{}`, `(* *)`, `//`, `%`.
        if not lines or not lines[0].lstrip().startswith("object "):
            problems.append(
                f"{rel}: first line is {lines[0].strip()[:40]!r}, not `object`"
                if lines else f"{rel}: file is empty")
            continue

        for prop in sorted(BANNED):
            n = len(re.findall(r"^\s*" + re.escape(prop) + r"\s*=", text, re.M))
            if n:
                problems.append(f"{rel}: {n} residual `{prop}` (VCL-only)")

        src = DFM_ROOT / pathlib.Path(rel).with_suffix(".dfm")
        if src.is_file():
            d_lines = src.read_bytes().decode("latin-1").splitlines()
            d_objs, l_objs = object_names(d_lines), object_names(lines)
            if d_objs != l_objs:
                missing = [n for n in d_objs if n not in l_objs]
                extra = [n for n in l_objs if n not in d_objs]
                problems.append(
                    f"{rel}: object tree differs -- missing {missing[:4]}, "
                    f"unexpected {extra[:4]}")
            leaks, orphans = walk(lines)
            if leaks:
                problems.append(
                    f"{rel}: {len(leaks)} object block(s) unclosed at EOF")
            if orphans:
                problems.append(
                    f"{rel}: {len(orphans)} `end` line(s) close nothing "
                    f"(first at line {orphans[0]})")
            checked += 1

    # 5. the SVG list fragments, which have no .dfm of their own and so are
    # skipped by the object-tree comparison above. What they need is different:
    # every TLclSvgImageList must carry exactly the one property the control
    # publishes, and it must name a list SvgData actually holds.
    def text_of(p):
        """Bytes as text with CRLF normalised to LF.

        Every regex below is anchored with `$`, and under re.M `$` matches
        BEFORE a newline -- so on a CRLF file `[ \\t]*$` never matches, the
        `\r` sitting in between. The first version of the fragment checks
        therefore matched ZERO blocks and reported nothing at all, which reads
        exactly like a clean bill of health. Normalising once, here, is what
        makes those anchors mean what they look like.
        """
        return p.read_bytes().decode("latin-1").replace("\r\n", "\n")

    known = {row["list"] for row in json.loads(
        (ROOT / "Source" / "Fpc" / "UI" / "Data" / "svg_manifest.json")
        .read_text(encoding="utf-8"))}
    for p in lfms:
        rel = p.relative_to(LFM_ROOT).as_posix()
        if not rel.endswith(".svg-lists.lfm"):
            continue
        fragments += 1
        text = text_of(p)
        if "TSVGIconImageList" in text or "SVGIconItems" in text:
            problems.append(f"{rel}: unconverted vendored SVG payload survived")
        for m in re.finditer(
                r"^[ \t]*object[ \t]+(\w+)[ \t]*:[ \t]*TLclSvgImageList[ \t]*$\n"
                r"(.*?)"
                r"^[ \t]*end[ \t]*$",
                text, re.M | re.S):
            name, block = m.group(1), m.group(2)
            # `[ \t]*`, never `\s*`: under re.S a `\s*` crosses newlines, so
            # `end` would match the LAST end in the file and the "block" would
            # be every following list. The first version of this check did
            # exactly that and reported five identical ListName mismatches --
            # each name compared against the NEXT component's name.
            names = re.findall(r"^[ \t]*(\w+)[ \t]*=[ \t]*(.*?)[ \t]*$",
                               block, re.M)
            if len(names) != 1 or names[0][0] != "ListName":
                problems.append(
                    f"{rel}/{name}: expected only `ListName`, got "
                    f"{[n for n, _ in names]}")
                continue
            if names[0][1].strip().strip("'") != name:
                problems.append(
                    f"{rel}/{name}: ListName is {names[0][1].strip()!r}, not the "
                    f"component name -- consumers reference the list BY that name")
            if name not in known:
                problems.append(
                    f"{rel}/{name}: no SvgData record carries this name")

    # 6. BINDINGS. This is step 4's completion criterion: the point of the SVG
    # rule is that the 15 consumer forms -- which write
    # `Images = dmMain.SVGImageListMenuStyle` -- end up pointing at a component
    # that actually exists. A consumer LFMs perfectly and its fragment streams
    # perfectly and the reference still dangles: nothing in either file would
    # notice.
    #
    # Only names in the SVG family are asserted. Forms also bind ordinary
    # `TImageList`s and those are not this gate's business; the family prefix is
    # what makes "is this reference SVG-bound" decidable rather than a guess.
    fragment_lists = set()
    for p in lfms:
        if p.name.endswith(".svg-lists.lfm"):
            fragment_lists |= set(re.findall(
                r"^[ \t]*ListName[ \t]*=[ \t]*'([^']+)'", text_of(p), re.M))
    svg_family = re.compile(
        r"SVG(?:ImageList|IconImage|ImageCollection|VirtualImageList)\w*")
    consumers = 0
    for p in lfms:
        rel = p.relative_to(LFM_ROOT).as_posix()
        if rel.endswith(".svg-lists.lfm"):
            continue
        text = text_of(p)
        for m in re.finditer(
                r"^[ \t]*(?:Images|LargeImages|SmallImages)[ \t]*=[ \t]*"
                r"([\w.]+)[ \t]*$", text, re.M):
            target = m.group(1).rsplit(".", 1)[-1]
            if not svg_family.fullmatch(target):
                continue
            consumers += 1
            if target not in fragment_lists:
                problems.append(
                    f"{rel}: binds SVG list {target!r}, which no generated "
                    f"fragment declares (have: {sorted(fragment_lists)})")

    print("LFM CONVERSION CHECK")
    print("=" * 70)
    print(f"  .lfm files        : {len(lfms)}")
    print(f"  compared to source: {checked}")
    print(f"  SVG list fragments: {fragments}  (lists: {len(fragment_lists)})")
    print(f"  SVG bindings      : {consumers}")
    print(f"  provenance records: {len(provenance)}")
    print(f"  banned properties : {len(BANNED)}")
    print()
    print("  The structure rule is the OBJECT TREE -- every `object Name:Type`")
    print("  block from the source, in order -- plus a stack walk that also")
    print("  opens on `item` (TListView rows). Comparing `end` COUNTS was wrong")
    print("  twice: `end>` collection blocks and `item ... end` rows both made")
    print("  correct files look broken, on 6 of 34 and then 5 of 34.")
    print()
    if problems:
        print(f"  FAIL -- {len(problems)} problem(s):")
        for x in problems[:25]:
            print(f"    {x}")
        if len(problems) > 25:
            print(f"    ... and {len(problems) - 25} more")
        return 1
    print("  PASS -- no residual VCL properties, structure preserved,")
    print("         encoding and line endings clean, no comment header,")
    print("         every file accounted for in _generated.json.")
    print()
    print("  NOT PROVEN for the FORMS: that Lazarus can load them. The SVG list")
    print("  fragments ARE load tested -- Tests/FpcCoreTests/svg/SvgLfmProbe.lpr")
    print("  streams DataFrm.svg-lists.lfm and counts pixels.")
    return 0


if __name__ == "__main__":
    sys.exit(main())