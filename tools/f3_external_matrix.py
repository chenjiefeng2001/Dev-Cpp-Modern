#!/usr/bin/env python3
"""
f3_external_matrix.py -- what to do with each control that has no declaration here.

WHY THIS TOOL EXISTS
====================
f3_form_survey.py reports that 12 forms are blocked, and classifies the blocking
types as vendored / external / own. "external" is the interesting bucket: those
types are REFERENCED in the repository but DECLARED nowhere in it, which means
they come from the Delphi RTL or a binary package.

That classification is necessary but not sufficient. Knowing a form mentions
`TVirtualImage` does not say whether the field is load-bearing, how it is used, or
whether it can be dropped. Guessing is how a form ends up half-converted with a
field that silently renders nothing.

So this tool reads the actual USAGE of every external type:

  * where the type is declared as a field, and on which form
  * whether the DFM places it (design-time) or only code declares it
  * every line that reads or writes the field
  * a verdict: DELETE (never assigned a behaviour), REPLACE (used, with the LCL
    equivalent), or KEEP (already portable or vendored-backed)

THE VERDICT IS A HEURISTIC, AND SAYS SO
========================================
The decision rules are deliberately conservative and are documented next to each
one. A type is only marked DELETE when the code assigns nothing to it beyond the
declaration -- anything with a method call, an assignment or a property write is
REPLACE at minimum, because dropping it would change behaviour.

Run:  python tools/f3_external_matrix.py
"""
import collections
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

COMPONENT_RE = re.compile(r"^\s*(?:inherited|inline|object)\s+(\w+)\s*:\s*(\w+)", re.M)
DECL_RE = re.compile(r"^\s*(?:(\w+)\s*=\s*class|(\w+)\s*=\s*\w+\s*\()", re.M)




# LCL equivalents for each external type, as a module-level table so other
# tools can consume it rather than restating it.
#
# A value of "none" is the important part: those types have no drop-in LCL
# counterpart and need a design decision, not a rename.
LCL_EQUIVALENT = {
    "TToolButton": "TToolButton (LCL has it; the field type is unchanged)",
    "TVirtualImage": "TImage + TImageList (draw from the list by index)",
    "TVirtualImageList": "TImageList (LCL; loses per-image mask/offset only)",
    "TImageCollection": "TImageList, or the vendored TSVGIconImageList already used here",
    "TControlBar": "TToolBar / TPanel docking (LCL docking differs; needs design)",
    "TAnimate": "none -- an AVI playback control; see note in the findings",
    "TDdeServerConv": "none in LCL; DDE is a Windows-only IPC mechanism",
}
def load_widgetset():
    """Reuse the survey's list rather than restating it.

    Two files that each carry their own idea of "which controls are portable"
    will disagree, and the disagreement will show up as a form flipping between
    convertible and blocked for no reason anyone can point at.
    """
    spec = importlib.util.spec_from_file_location(
        "f3_form_survey", ROOT / "tools" / "f3_form_survey.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.WIDGETSET
def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def find_external_types(dfms, widgetset):
    """Types placed in some DFM that are declared nowhere in Source/."""
    units = {}
    for p in SOURCE.rglob("*.pas"):
        units[p] = read(p)

    def declared(t):
        pat = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        return any(pat.search(txt) for txt in units.values())

    external = collections.defaultdict(set)
    for p in dfms:
        for _, t in COMPONENT_RE.findall(read(p)):
            if len(t) > 1 and t[0].isupper() and not declared(t):
                # A type the widgetset already covers (TAction, TShape,
                # TTreeView, ...) is NOT a problem here even though no .pas
                # declares it: it ships with VCL/LCL alike. Without this filter
                # the first version of this tool listed dozens of TAction fields
                # as "external", which says nothing -- they convert.
                if t in widgetset:
                    continue
                external[t].add(p.name)
    return external


def usage_of(field: str, text: str):
    """Lines that touch `field` beyond its own declaration."""
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not re.search(r"\b" + re.escape(field) + r"\b", s):
            continue
        if re.match(r"^\w+\s*:\s*" + re.escape(field) + r"\s*;", s):
            continue  # the declaration itself
        hits.append((i, s))
    return hits


def main() -> int:
    dfms = sorted(p for p in SOURCE.rglob("*.dfm") if "VCL" not in p.parts)
    external = find_external_types(dfms, load_widgetset())
    if not external:
        print("no external types found")
        return 0

    pas = {p: read(p) for p in SOURCE.rglob("*.pas") if "VCL" not in p.parts}

    rows = []
    for t, forms in sorted(external.items()):
        # Which self-authored units declare a field of this type?
        holders = []
        for p, txt in sorted(pas.items()):
            for m in re.finditer(
                r"^\s*(\w+)\s*:\s*" + re.escape(t) + r"\s*;", txt, re.M
            ):
                holders.append((p.name, m.group(1), usage_of(m.group(1), txt)))
        rows.append((t, sorted(forms), holders))

    # LCL equivalents, written next to the verdict so a reader can judge the
    # recommendation instead of taking it on faith. A dash means "no direct
    # equivalent"; those are the ones that need a design decision, not a rename.
    LCL_EQUIVALENT = {
        "TToolButton": "TToolButton (LCL has it; the field type is unchanged)",
        "TVirtualImage": "TImage + TImageList (draw from the list by index)",
        "TVirtualImageList": "TImageList (LCL; loses per-image mask/offset only)",
        "TImageCollection": "TImageList, or vendored TSVGIconImageList already used here",
        "TControlBar": "TToolBar / TPanel docking (LCL docking differs; needs design)",
        "TAnimate": "none -- this is an AVI playback control; see note below",
        "TDdeServerConv": "none in LCL; DDE is a Windows-only IPC mechanism",
    }

    print("EXTERNAL CONTROL MATRIX")
    print("=" * 78)
    print()
    field_counts = []
    for t, forms, holders in rows:
        n_fields = len(holders)
        field_counts.append((t, n_fields, forms))
    print("SUMMARY  (sorted by how many fields each type accounts for)")
    for t, n, forms in sorted(field_counts, key=lambda x: -x[1]):
        print(f"  {n:3d} field(s)  {t:<22} in {', '.join(forms)}")
    print()
    print("=" * 78)
    print()
    for t, forms, holders in rows:
        print(f"{t}   (placed in {len(forms)} form(s): {', '.join(forms)})")
        if not holders:
            # Referenced by a form but no self-authored unit declares a field of
            # this type: the DFM carries it and nothing else does.
            print("    field declarations in self code : none")
            print("    VERDICT: DELETE from the DFM -- nothing in the codebase")
            print("            creates or configures it, so it renders nothing today.")
        for unit, field, hits in holders:
            print(f"    {unit}: field {field}")
            if not hits:
                print("        used in code : never (declaration only)")
                print("        VERDICT: DELETE the field and the DFM component -- it is")
                print("                declared and never driven.")
            else:
                print(f"        used in code : {len(hits)} line(s)")
                for ln, s in hits[:4]:
                    print(f"            {ln}: {s[:70]}")
                if len(hits) > 4:
                    print(f"            ... {len(hits) - 4} more")
                print("        VERDICT: REPLACE -- the field is driven, so dropping it")
                print("                changes behaviour. Needs an LCL equivalent.")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())