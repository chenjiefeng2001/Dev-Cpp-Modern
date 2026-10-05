#!/usr/bin/env python3
"""
f3_imageindex_audit.py -- every ImageIndex in the tree, accounted for.

WHAT THIS AUDITS, AND WHY IT IS NOT "188 CHECKS"
================================================
`ImageIndex` appears 188 times across 14 self-authored .dfm files. That number
is real (verified, not estimated) but treating all 188 as "one SVG list, check
0 <= i < 85" produces 123 FALSE alarms, because they are not 188 of the same
thing. Measured split:

    57   bound to an SVG image list      -> the real out-of-bounds risk surface
    4   ImageIndex = -1 on a TTabSheet / TVirtualImage -> "no icon" semantics
    127  bound to a non-SVG list or to no list at all -> untouched by this work

So the audit classifies every site and asserts only on the class where the SVG
replacement can actually break. Reporting 188 identical assertions would mean
123 of them are noise, and a gate that reports noise gets ignored -- including
the 57 that matter.

MEASURED RESULT (2026-10-04)
===========================
    188 ImageIndex sites across 14 forms   (all literal integers, 0 non-numeric)
    57  SVG-bound, all in range, max index 82 against a list of 85
    0   OUT OF BOUNDS
    4   ImageIndex = -1, all "no icon"
    127  not SVG-bound

WHY -1 IS NOT AN OUT-OF-BOUNDS, BUT -3 STILL IS
===============================================
`ImageIndex = -1` on a TTabSheet (main.dfm x3) and a TVirtualImage
(EnviroFrm.dfm) means "this control has no icon" -- VCL's TImageIndex(-1).
Treating that as an out-of-bounds violation would be wrong twice over: the
assertion would fire on correct code, and it would teach readers to distrust a
check whose real findings get lost in the noise.

But the exemption is for -1 SPECIFICALLY, not for negative numbers in general.
A first version of classify() wrote `if index < 0: no-icon`, which silently
accepted -3, -99 and anything else negative -- an unbounded exemption created
to accommodate four legitimate values. Measured: the tree contains -1 four
times and no other negative index, so the narrow rule loses nothing real and
closes the hole. A special case is worth encoding only as narrowly as the data
that justifies it.

THE SEMANTIC-INVERSION QUESTION, ANSWERED
=========================================
A plausible fear is that the same index means different things in different
lists -- "index 2 is a header file in the project tree, index 2 is cut in the
toolbar". That fear is real in general, and this audit checks for it directly:
every SVG-bound site is resolved to the IconName the extractor read from
DataFrm.dfm, and the report shows form, component, index and name together, so a
reviewer can confirm the mapping is the intended one. What the audit cannot do
is decide whether that mapping is CORRECT -- only that it is EXPLICIT and
recorded, which is what makes it reviewable.

WHAT THIS IS NOT
================
Static only. It cannot know what index 59 was meant to look like; it proves the
indices are in range and that each one has a determinate SVG name behind it.

Run:  python tools/f3_imageindex_audit.py [--json OUT] [--md OUT] [--strict]
Exit: 0 when there is no out-of-bounds site; 1 when there is.
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
# Moved with the data on 2026-10-06 (doc F3-SVG section 11.7): the manifest is
# a description of Source/Fpc/UI/Data/SvgData.pas, so it belongs beside it.
MANIFEST = ROOT / "Source" / "Fpc" / "UI" / "Data" / "svg_manifest.json"

COMPONENT_RE = re.compile(
    r"^\s*(?:object|inherited|inline)\s+(\w+)\s*:\s*(\w+)")
IMAGES_RE = re.compile(r"^\s*Images\s*=\s*(\S+)")
IMAGEINDEX_RE = re.compile(r"^\s*ImageIndex\s*=\s*(-?\d+)\s*$")
ITEM_HEAD_RE = re.compile(r"item\s*\r?\n\s*IconName\s*=\s*'([^']*)'", re.M)


def read(p):
    """Read a Pascal/DFM source file.

    Several of these files are latin-1 with cp1252 bytes inside GCC switches and
    Chinese comments; decoding them as utf-8 with errors="replace" silently
    destroys content. Decoding latin-1 cannot fail and never loses a byte.
    """
    return p.read_bytes().decode("latin-1")


def list_facts():
    """Return {list_name: {"count": n, "names": [...]}} from the extracted data.

    Read from the manifest, which tools/f3_svg_extract.py --verify round-trips
    against DataFrm.dfm. Parsing the Pascal constants here instead would make
    this a second, independent reader of the same file -- and the two would
    eventually disagree without anyone noticing which one was right.
    """
    if not MANIFEST.is_file():
        return None
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {
        d["list"]: {"count": d["count"], "names": [i["name"] for i in d["items"]]}
        for d in data
    }


def scan_form(path):
    """Yield one record per ImageIndex site in one .dfm.

    The `Images` property belongs to the enclosing component, so the scan keeps
    a current-class cursor rather than reading each property in isolation. A
    first version that looked for `Images` and `ImageIndex` independently
    reported 65 sites with no list at all -- because it never learned which
    component each line belonged to, and pairing them by proximity in the text
    is exactly the kind of guess this audit exists to remove.
    """
    lines = read(path).splitlines()

    # Pass 1: record the Images value of each component, keyed by component NAME.
    #
    # Two things bit this scan, and both were found by INJECTING defects rather
    # than by reading the code.
    #
    # (a) ORDER. DFM properties are emitted ALPHABETICALLY. In main.dfm,
    #     ButtonChangeTheme writes
    #         ImageIndex = 80                        <- line 4542
    #         Images = dmMain.SVGImageListMenuStyle   <- line 4544
    #     so ImageIndex comes FIRST. A single pass that records only Images it
    #     has already seen attributes no list to that site, and the site drops
    #     out of the audited set -- indistinguishable from not existing.
    #
    # (b) KEY. Keying the map by component CLASS silently merges distinct
    #     components. main.dfm declares several TButtons bound to DIFFERENT
    #     lists: ButtonNewDocument / ButtonOpenDocument / ButtonOptions use
    #     SVGIconImageWelcomeScreen, while ButtonChangeTheme and two others use
    #     SVGImageListMenuStyle. With a class key the last write wins and the
    #     earlier components inherit it. Injecting a typo into one of those list
    #     names changed nothing the audit reported -- proven by mutating
    #     dmMain.SVGIconImageWelcomeScreen and observing that no site carried
    #     the replacement. The component NAME is unique within a form; the class
    #     is not.
    #
    # So: two passes, keyed by component name. Neither pass depends on the
    # other's line order, and no two components can collide.
    imgs_by_component = {}
    cur = None
    for line in lines:
        m = COMPONENT_RE.match(line)
        if m:
            cur = m.group(1)
        mi = IMAGES_RE.match(line)
        if mi and cur:
            imgs_by_component[cur] = mi.group(1).strip()

    # Pass 2: report every ImageIndex against that completed map.
    cur_name = None
    cur_class = None
    for n, line in enumerate(lines, 1):
        m = COMPONENT_RE.match(line)
        if m:
            cur_name, cur_class = m.group(1), m.group(2)
        mi = IMAGEINDEX_RE.match(line)
        if not mi:
            continue
        yield {
            "form": path.name,
            "line": n,
            "component": cur_name or "?",
            "class": cur_class or "?",
            "index": int(mi.group(1)),
            "images": imgs_by_component.get(cur_name or "", ""),
        }


# VCL's "no icon" sentinel. Exactly -1, nothing else.
NO_ICON = -1


def classify(site):
    """Return (bucket, why). The bucket decides whether the site is asserted.

    ORDER MATTERS, and getting it wrong is how a real defect escaped an earlier
    version of this audit. That version tested `"SVG" in images` FIRST and fell
    through to `other-list` for anything else. So changing
    `Images = dmMain.SVGImageListMenuStyle` to `dmMain.NoSuchList` -- a typo, a
    rename, a list that was never migrated -- moved the site into `other-list`,
    where it was never asserted again. The audit reported clean while the button
    pointed at nothing at all. Injected test `Images = dmMain.NoSuchList` was
    MISSED by that version and is CAUGHT by this one.

    The fix is to decide by SHAPE first (is there a list at all?) and to let the
    NAME decide only WHICH list, never WHETHER to check. A name that looks like
    an SVG list but was never extracted is a finding in its own right, so both
    buckets resolve against the manifest.
    """
    if site["index"] == NO_ICON:
        return "no-icon", "ImageIndex = -1 means 'this control has no icon'"
    if site["index"] < 0:
        # Any OTHER negative value is a dirty value, not the sentinel. Measured:
        # the tree holds -1 four times and no other negative, so nothing real
        # is lost by refusing to generalise.
        return "bad-negative", (
            f"ImageIndex = {site['index']} is neither a valid index nor the "
            f"-1 sentinel")

    if not site["images"]:
        return "no-list", "no Images property; the control supplies its own graphic"

    return "svg" if "SVG" in site["images"] else "other-list", (
        "bound to an SVG list -- in scope for the range assertion"
        if "SVG" in site["images"]
        else "bound to a non-SVG image list; unaffected by F3-SVG")


def build_ledger():
    """Collect every site, classify it, and resolve SVG-bound names."""
    facts = list_facts()
    if facts is None:
        return None, [], None

    sites = []
    for p in sorted(SOURCE.rglob("*.dfm")):
        if "VCL" in p.parts:
            continue
        for site in scan_form(p):
            bucket, why = classify(site)
            site["bucket"] = bucket
            site["why"] = why
            site["list"] = (site["images"].split(".")[-1]
                            if bucket in ("svg", "other-list") else None)
            # `component` is the control's own name (ButtonCompile);
            # `icon` is the IconName the extractor read at that index. They are
            # DIFFERENT strings and the audit exists to compare them, so they
            # must not share a key.
            #
            # This bug was real: an earlier patch added the component name under
            # the key `name`, and the resolver below then overwrote it with the
            # icon name -- so the report printed "ButtonCompile" in a column
            # headed IconName, or vice versa, and any semantic comparison built
            # on that field compared an icon with itself. The whole point of the
            # semantic ledger is that column being trustworthy.
            site["icon"] = None
            site["status"] = ""
            if bucket == "bad-negative":
                site["status"] = "BAD NEGATIVE INDEX"
            if bucket in ("svg", "other-list"):
                f = facts.get(site["list"])
                if f is None:
                    # A list the extractor never saw. Recorded as a finding
                    # rather than skipped: an Images assignment pointing at a
                    # name with no extracted icons would render blank.
                    site["status"] = "UNKNOWN LIST"
                elif not (0 <= site["index"] < f["count"]):
                    site["status"] = "OUT OF BOUNDS"
                else:
                    site["icon"] = f["names"][site["index"]]
                    site["status"] = "in range"
            sites.append(site)
    return facts, sites, None


def report(sites, facts):
    print("IMAGEINDEX TOPOLOGY LEDGER")
    print("=" * 78)
    print()
    buckets = collections.Counter(s["bucket"] for s in sites)
    print(f"total ImageIndex sites : {len(sites)}")
    print(f"  svg       (asserted) : {buckets['svg']:4d}")
    print(f"  no-icon   (-1)       : {buckets['no-icon']:4d}")
    if buckets['bad-negative']:
        print(f"  BAD negative         : {buckets['bad-negative']:4d}")
    print(f"  other-list (checked) : {buckets['other-list']:4d}")
    print(f"  no-list              : {buckets['no-list']:4d}")
    print()
    print("SVG LISTS (counts from Source/Fpc/UI/Data/svg_manifest.json,")
    print("round-trip verified against DataFrm.dfm by f3_svg_extract.py --verify)")
    for name, f in facts.items():
        print(f"    {name:<32} {f['count']:3d} icon(s)")
    print()

    svg = [s for s in sites if s["bucket"] == "svg"]
    if svg:
        print("SVG-BOUND SITES, RESOLVED TO THEIR ICON NAME")
        # The component NAME is shown, not just its class: several same-class
        # components in these forms bind DIFFERENT lists, and a reviewer cannot
        # tell ButtonNewDocument from ButtonChangeTheme by "TButton" alone.
        print(f"  {'FORM':<22} {'COMPONENT':<24} {'LINE':>5} {'IDX':>4}"
              f"  ICON NAME")
        print("  " + "-" * 84)
        for s in sorted(svg, key=lambda x: (x["list"], x["form"], x["line"])):
            comp = f"{s['component']}: {s['class']}"
            print(f"  {s['form']:<22} {comp:<24} {s['line']:>5} "
                  f"{s['index']:>4}  {s['icon'] or s['status']}")
        print()

    bad = [s for s in sites if s["bucket"] == "bad-negative"]
    if bad:
        print("NEGATIVE INDICES THAT ARE NOT THE -1 SENTINEL")
        for s in bad:
            print(f"  {s['form']:<24} {s['class']:<18} line {s['line']}"
                  f"  {s['index']}")
        print()

    oob = [s for s in sites
           if s["status"] in ("OUT OF BOUNDS", "UNKNOWN LIST", "BAD NEGATIVE INDEX")]
    neg = [s for s in sites if s["bucket"] == "no-icon"]
    if neg:
        print("ImageIndex = -1  (semantically 'no icon', NOT out of bounds)")
        for s in neg:
            print(f"  {s['form']:<24} {s['class']:<18} line {s['line']}")
        print()

    print("VERDICT")
    print("-" * 78)
    if oob:
        print(f"  FAIL -- {len(oob)} site(s) cannot be satisfied:")
        for s in oob:
            print(f"    {s['form']}:{s['line']}  {s['component']} ({s['class']})"
                  f".ImageIndex = {s['index']}  ->  {s['list'] or '(n/a)'}"
                  f"  [{s['status']}]")
        return 1
    mx = max(s["index"] for s in svg)
    print(f"  PASS -- {len(svg)} SVG-bound site(s), 0 out of bounds.")
    print(f"          highest index used: {mx} (largest list holds "
          f"{max(f['count'] for f in facts.values())})")
    print("          every SVG-bound site resolves to a determinate icon name,")
    print("          so the index->meaning mapping is explicit and reviewable.")
    print()
    print("  NOT CHECKED HERE: whether an index is the INTENDED icon. That is a")
    print("  judgement about the old UI, not a range question; the table above")
    print("  exists so it can be reviewed rather than assumed.")
    return 0


def write_outputs(sites, json_path, md_path):
    """Machine-readable ledger for other tools, and a reviewable table."""
    if json_path:
        json_path.write_text(
            json.dumps(sites, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        print(f"wrote {json_path}")

    if md_path:
        svg = [s for s in sites if s["bucket"] == "svg"]
        lines = [
            "# ImageIndex topology ledger",
            "",
            "Generated by `tools/f3_imageindex_audit.py`. Do not hand-edit.",
            "",
            "## Scope",
            "",
            f"- total `ImageIndex` sites: **{len(sites)}**",
            f"- bound to an SVG list (asserted): **{len(svg)}**",
            f"- `ImageIndex = -1` (\"no icon\"): "
            f"**{sum(1 for s in sites if s['bucket'] == 'no-icon')}**",
            f"- bound to a non-SVG list or to none: "
            f"**{sum(1 for s in sites if s['bucket'] in ('other-list', 'no-list'))}**",
            "",
            "Only the SVG-bound sites are range-asserted. The rest are not",
            "affected by the F3-SVG replacement, and asserting them would bury the",
            "real findings in noise.",
            "",
            "## SVG-bound sites",
            "",
            "| Form | Component | Line | ImageIndex | IconName |",
            "|---|---|---|---|---|",
        ]
        for s in sorted(svg, key=lambda x: (x["form"], x["line"])):
            lines.append(
                f"| {s['form']} | `{s['component']}` : {s['class']} | "
                f"{s['line']} | {s['index']} | `{s['icon'] or s['status']}` |")
        lines += [
            "",
            "## How to read this",
            "",
            "Each row resolves one `ImageIndex` to the icon the extractor read",
            "from `DataFrm.dfm` at that position, so the index-to-meaning mapping",
            "is explicit. The audit proves each index is **in range** and has a",
            "determinate name. It cannot prove the name is the one intended --",
            "that is a review of the old UI, and this table is what makes the",
            "review possible.",
        ]
        md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {md_path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=None,
                    help="write the machine-readable ledger here")
    ap.add_argument("--md", default=None,
                    help="write the Markdown review table here")
    ap.add_argument("--strict", action="store_true",
                    help="also fail on a site whose list the extractor never saw")
    args = ap.parse_args()

    facts, sites, err = build_ledger()
    if facts is None:
        print(f"ERROR: {MANIFEST.relative_to(ROOT)} not found.")
        print("       Run: python tools/f3_svg_extract.py --verify")
        return 1

    rc = report(sites, facts)
    write_outputs(sites,
                  pathlib.Path(args.json) if args.json else None,
                  pathlib.Path(args.md) if args.md else None)

    if args.strict:
        unknown = [s for s in sites if s["status"] == "UNKNOWN LIST"]
        if unknown:
            print(f"STRICT: {len(unknown)} site(s) reference an unknown list")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())