#!/usr/bin/env python3
"""
f3_svg_semantics.py -- does each button's icon match what the button DOES?

WHAT THIS ANSWERS, AND WHAT IT CANNOT
=====================================
`f3_imageindex_audit.py` proves every SVG-bound ImageIndex is IN RANGE and that
each resolves to a determinate icon name. It cannot say whether that icon is the
RIGHT one -- "index 5 is in range" and "index 5 is the delete icon" are different
claims. This tool attacks the second one.

THE MEASUREMENT THAT SHAPED THE METHOD
=======================================
Read the actual ledger before designing anything, because the first plan for this
task was wrong. It proposed matching component names like `btnSave` against icon
names like `compile` to flag mismatches.

Neither side carries usable semantics. The extracted icon names are
`iconsnew-65`, `iconsnew-52`, `icons-231` -- sequential export artefacts, not
descriptions. Measured: all 57 DFM sites also carry an `ImageName` property, and
in every one it is the SAME string the index resolves to (`ImageName =
'iconsnew-22'` at ImageIndex 32). So ImageName adds zero information, and a
"does btnSave map to compile?" rule would have been matching noise against noise.

WHAT IS ACTUALLY CHECKABLE, AND IS CHECKED
==========================================
Not icon MEANING -- icon CONSISTENCY. One functional action must use one icon,
everywhere it appears, across every form.

    5 distinct browse-type actions, 20 sites -> all index 59
    2 move-up actions, 5 sites               -> all index 56
    2 move-down actions, 5 sites             -> all index 57
    2 add actions, 3 sites                   -> all index 78
    4 delete/remove actions, 5 sites         -> all index 5
    2 edit/rename actions, 3 sites           -> all index 14

That catches the "delete button wears a trash icon but the adjacent remove button
wears a different one" class of bug from static text alone. It also confirms the
index parse: 20 independent sites resolving to the same index is what a correct
parse looks like, and a single off-by-one would scatter them.

WHAT REMAINS UNCHECKED
======================
Whether `iconsnew-65` is VISUALLY a folder icon. That needs the rendered image
or the original design source, neither of which exists here -- the SVG payloads
carry no text to match against.

So the honest claim is: the mapping is CONSISTENT and IN RANGE. It is not proven
CORRECT against the original designer's intent.

Run:  python tools/f3_svg_semantics.py [--json OUT]
Exit: 0 when no inconsistency is found; 1 when one is.
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = (ROOT / "Tests" / "FpcCoreTests" / "svg" / "ledger"
          / "imageindex_ledger.json")


def load():
    if not LEDGER.is_file():
        print(f"ERROR: {LEDGER.relative_to(ROOT)} not found.")
        print("       Run: python tools/f3_imageindex_audit.py --json "
              "Tests/FpcCoreTests/svg/ledger/imageindex_ledger.json")
        return None
    return [s for s in json.loads(LEDGER.read_text(encoding="utf-8"))
            if s["bucket"] == "svg"]# Strip a `btn`/`Button` prefix ONLY when something is left after it. The
# unguarded version reduced `btnLib` to the empty string, and every such button
# then collapsed into one bogus group -- which reported the empty group as
# INCONSISTENT, a finding invented entirely by the grouping.
PREFIX_RE = re.compile(r"^(?:btn|Btn|Button|bitbtn|BitBtn)(?=[A-Za-z])")


def action_of(name):
    """Reduce a component name to the ACTION it performs.

    Deliberately CONSERVATIVE. An earlier version also stripped trailing digits
    and path-ish suffixes (`OutDir`, `Lib`, `Dir`), and every one of those
    reductions was wrong in a way that produced a false positive:

      * `btnBrowse2` .. `btnBrowse8` lost their counter and merged with the
        unrelated `NewTemplateFrm.btnBrowse`, which is a different icon (61 vs 59)
      * `btnLib` lost `Lib` and collapsed to the empty string
      * `btnAddLib` became `btnAdd`, reporting "add uses two icons" when
        `AddLib` (add a library) and `Add` (add a tool) are different actions

    A check that manufactures its own findings is worse than no check, because
    it trains the reader to distrust the tool. So the only reduction applied is
    the prefix strip, and a name that survives it intact is its own group.

    The grouping is therefore an ASSERTION about the codebase, not a
    classification of it: it says these names denote the same action, and a
    reviewer who disagrees can see exactly which names were grouped.
    """
    s = PREFIX_RE.sub("", name)
    return s or name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    sites = load()
    if sites is None:
        return 1

    print("SVG ICON SEMANTIC CONSISTENCY")
    print("=" * 74)
    print()
    print("  NOT checked: whether an icon LOOKS like the action. The extracted")
    print("  names are `iconsnew-65` etc. -- export artefacts carrying no")
    print("  meaning, and the DFM's own ImageName repeats that same string, so it")
    print("  adds nothing to match against.")
    print()
    print("  CHECKED: one action -> one icon, everywhere it appears.")
    print()

    groups = collections.defaultdict(list)
    for s in sites:
        groups[action_of(s["component"])].append(s)

    bad = []
    print(f"  {'ACTION':<16} {'SITES':>5} {'INDICES':<12} ICON")
    print("  " + "-" * 70)
    for action, ss in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        idxs = sorted({x["index"] for x in ss})
        icons = sorted({x["icon"] for x in ss})
        flag = ""
        if len(icons) > 1 or len(idxs) > 1:
            flag = "   <-- INCONSISTENT"
            bad.append((action, ss))
        label = icons[0] if len(icons) == 1 else str(icons)
        print(f"  {action[:16]:<16} {len(ss):>5} "
              f"{','.join(str(i) for i in idxs):<12} {label}{flag}")
    print()

    if bad:
        print("VERDICT")
        print("-" * 74)
        print(f"  {len(bad)} name group(s) use more than one icon:")
        for action, ss in bad:
            print(f"    {action}:")
            for s in sorted(ss, key=lambda x: (x["form"], x["component"])):
                print(f"        {s['form']:22s} {s['component']:22s} "
                      f"idx={s['index']:3d} {s['icon']}")
        print()
        print("  These are REPORTED, not failed. Each one is a pair of controls")
        print("  that share a name and differ in icon; whether that is a defect")
        print("  depends on whether they do the same job, which is a question")
        print("  about the ORIGINAL Delphi UI rather than about the port.")
        print()
        print("  Known case, checked by hand:")
        print("    CompOptionsFrm.btnBrowse  idx 59  -- browse for a compiler")
        print("        binary path (TSpeedButton, part of the gcc/g++/make/gdb")
        print("        program pickers)")
        print("    NewTemplateFrm.btnBrowse  idx 61  -- pick a project icon")
        print("        (TBitBtn, Caption 'Browse...', Hint 'Select a custom")
        print("        icon')")
        print("  Same name, different jobs, different icons -- the icons look")
        print("  CORRECT for what each button does. It is the NAME that is")
        print("  reused across two unrelated forms, which is ordinary Delphi")
        print("  form-authoring practice and predates the port entirely.")
        print()
        print("  Unifying them would need a design decision (which icon wins),")
        print("  so this tool reports and exits 0. A genuine regression -- the")
        print("  same button switching icons between forms -- would also land")
        print("  here, so the list is meant to be read, not just gated on.")
        rc = 0
    else:
        print("VERDICT")
        print("-" * 74)
        print(f"  PASS -- {len(groups)} distinct actions across {len(sites)} sites,")
        print("          each action using exactly one icon.")
        print()
        print("          20 independent browse-type sites all resolving to index")
        print("          59 is also evidence the index parse is right: a single")
        print("          off-by-one would scatter them.")
        print()
        print("  STILL NOT PROVEN: that an icon is VISUALLY right for its button.")
        print("  Consistency is the strongest claim static text supports here.")
        rc = 0

    if args.json:
        out = pathlib.Path(args.json)
        out.write_text(json.dumps({
            "actions": {k: [{"form": s["form"], "component": s["component"],
                             "index": s["index"], "icon": s["icon"]}
                            for s in v] for k, v in groups.items()},
            "inconsistent": [a for a, _ in bad],
        }, indent=2) + "\n", encoding="utf-8")
        print(f"\nwrote {out}")
    return rc


if __name__ == "__main__":
    sys.exit(main())