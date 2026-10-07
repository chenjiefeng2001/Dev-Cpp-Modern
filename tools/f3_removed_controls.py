#!/usr/bin/env python3
"""
f3_removed_controls.py -- keep the removed Win32-only controls removed.

WHY THIS FILE EXISTS
====================
Three controls were physically deleted, or their last use deleted, because the
LCL has no counterpart:

  TAnimate          RemoveForms.dfm / .pas   an AVI playback control
  TDdeServerConv    main.dfm / main.pas      Windows-only DDE IPC
  TCompOptionsList  CompOptionsFrame.dfm     vendored TValueListEditor whose
                                             only real behaviour LCL gives
                                             natively for esPickList rows

The deletions were correct and are the reason `f3_form_ratchet.py` counts those
types no longer. But a deletion is not a property: nothing stopped either
control from being reintroduced by a merge, a revert, or a well-meaning
"restore the animation". A control that comes back is invisible to every other
gate -- the F3 ratchet only checks that the convertible count does not DROP
below its baseline, and these types are counted per-form, so a reintroduction
would show up as a single blocked form rather than as the regression it is.

This is that gate. It is a NEGATIVE assertion: the controls must be absent.

TCompOptionsList IS A DIFFERENT KIND OF ENTRY, AND THE GATE HAS TO KNOW IT
=======================================================================
The other two were deleted outright. TCompOptionsList still EXISTS, as
Source/VCL/CompOptionsList/CompOptionsList.pas, and it must:
  * keep existing -- it is in the Delphi package (Source/VCL/DevCpp.dpk:41)
    and deleting the file would break the Delphi build;
  * keep existing there in a form that NOTHING references -- the vendored
    control's only value-add was hand-rolling a pick-list editor on top of
    VCL private members (EditList, StyleServices), which LCL's
    TValueListEditor gives an esPickList row natively (valedit.pp:1267).

So this entry asserts that no LIVE source names it. That is a different claim
from the other two, and it is stated separately rather than folded in: a
reader who assumes "REMOVED means deleted" would be misled, and the vendored
file being present is exactly the evidence that the two cases differ.
`Source/Archive/FormatterOptionsFrm.pas` is dead code that is not in any
project file and still names the unit -- measured 2026-10-06 -- so the
exclusion is declared rather than implied.

WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT
================================================
  * zero occurrences of the control type or its field name in live
    Source/**/*.{pas,dfm}
  * the units that used to carry them still parse as far as this can tell
    (the component block is gone, the published field is gone)

It does NOT fail on a mention in a comment, in the tools that describe these
controls, in a doc, or in a binary. Those are records of the decision, not the
decision being undone -- and the alternative is a gate that fires on its own
documentation, which is how a gate gets ignored.

THE STALE BINARY
================
`Source/Packman.exe` is a committed Delphi build from 2026-09-09 and still
contains the strings `TAnimate` and `Animate1`. It is NOT a regression: it is
the artefact the removal was supposed to supersede, and no amount of editing
source changes what is inside an already-built exe. It is reported as INFO so
the discrepancy stays visible instead of being either silently ignored or
mistaken for a live reference.

Run:  python tools/f3_removed_controls.py
Exit: 0 when both controls are absent from live source; 1 otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

# control type -> (expected field/component names, human note)
REMOVED = {
    "TAnimate": (
        ["Animate1"],
        "AVI playback; no LCL equivalent. Removed from Packman RemoveForms.",
    ),
    "TDdeServerConv": (
        ["DdeServerConv"],
        "Windows-only DDE IPC; no LCL equivalent. Removed from the main form.",
    ),
    "TCompOptionsList": (
        # The UNIT name, not a component name. This entry was first written
        # with an empty list, on the reasoning that a retired control has no
        # DFM component block left -- and the injection test then put
        # `CompOptionsList` back into CompOptionsFrm.pas's uses clause and the
        # gate stayed green, because what a uses clause names is the UNIT and
        # the unit name does not contain the type name. A negative assertion
        # that misses the most likely way the thing comes back is decoration.
        ["CompOptionsList"],
        "RETIRED, not deleted: the unit stays (DevCpp.dpk) but nothing may use it.",
    ),
}

# Directories that are not live source, stated rather than implied.
#
# `Archive` holds superseded copies of units. `Source/Archive/FormatterOptionsFrm.pas`
# still names the CompOptionsList unit in its uses clause; it is in no project
# file and compiles nowhere (measured 2026-10-06: `rg CompOptionsList` outside
# Source/VCL and Source/Archive returns nothing). Excluding a directory is a
# decision with a reason attached, so the reason is the entry.
NOT_LIVE = {"Archive"}

# Binaries are excluded from the assertion on purpose; see the docstring.
TEXT_SUFFIXES = {".pas", ".dfm", ".inc"}


def read(p):
    return p.read_bytes().decode("latin-1")


def all_keywords():
    """Every control type AND field name the guard watches.

    Both matter and they are different strings: the DFM component block says
    `object Animate1: TAnimate` while the published field says `Animate1:
    TAnimate;`. A leftover of only one of the two is still a real defect -- the
    Delphi loader matches them by name -- so both are asserted. The first
    version keyed the result map by control type alone and raised KeyError on
    the first field name it looked up, which is how a gate that had never run
    turns out to have never run.
    """
    kws = []
    for ctl, (fields, _note) in REMOVED.items():
        kws.append(ctl)
        kws.extend(fields)
    return kws


def scan_live():
    """Return {keyword: [(path, line_no, text)]} over live source only."""
    hits = {k: [] for k in all_keywords()}
    for p in sorted(SOURCE.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if "VCL" in p.parts:
            continue
        if NOT_LIVE & set(p.parts):
            continue
        lines = read(p).splitlines()
        for n, line in enumerate(lines, 1):
            code = re.sub(r"//.*$", "", line)
            code = re.sub(r"\{\$.*?\}", "", code)
            for ctl, (fields, _note) in REMOVED.items():
                for kw in (ctl, *fields):
                    if re.search(r"\b" + re.escape(kw) + r"\b", code):
                        hits[kw].append((p, n, line.strip()))
    return hits


def report(hits):
    print("REMOVED-CONTROL GUARD")
    print("=" * 72)
    print()
    total = 0
    for ctl, (fields, note) in REMOVED.items():
        print(f"{ctl}")
        print(f"    {note}")
        for kw in (ctl, *fields):
            found = hits[kw]
            if not found:
                print(f"    {kw:<18} absent from live source   OK")
            else:
                total += len(found)
                print(f"    {kw:<18} REAPPEARED ({len(found)} site(s))")
                for p, n, s in found[:6]:
                    print(f"        {p.relative_to(ROOT).as_posix()}:{n}  {s[:64]}")
        if not fields:
            # A retired-but-present control has no DFM component block left
            # once it is retired; such an entry asserts on the unit name.
            print(f"    {'':<18} (no component name: the unit stays, the USE does not)")
        print()

    print("STALE ARTEFACTS (informational, not a regression)")
    print("-" * 72)
    found_bin = False
    for p in sorted(SOURCE.rglob("*.exe")):
        raw = p.read_bytes().lower()
        hits_here = [c for c in REMOVED if c.lower().encode() in raw]
        if hits_here:
            found_bin = True
            print(f"  {p.relative_to(ROOT).as_posix()}")
            print(f"      committed Delphi build still contains: {', '.join(hits_here)}")
            print("      no source references remain; this binary predates the")
            print("      removal and would be replaced by any Lazarus build.")
    if not found_bin:
        print("  none")
    print()

    if total:
        print(f"FAIL -- {total} reference(s) to removed controls in live source")
        return 1
    print(f"PASS -- all {len(REMOVED)} controls are absent from live source.")
    print("        This gate is a negative assertion: it only fails on a")
    print("        reintroduction, so a green result says nothing about whether")
    print("        the removal was correct -- only that it still holds.")
    return 0


def main() -> int:
    return report(scan_live())


if __name__ == "__main__":
    sys.exit(main())
