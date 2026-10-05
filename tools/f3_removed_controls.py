#!/usr/bin/env python3
"""
f3_removed_controls.py -- keep the removed Win32-only controls removed.

WHY THIS FILE EXISTS
====================
Two controls were physically deleted because LCL has no counterpart and the
Delphi originals blocked conversion:

  TAnimate          RemoveForms.dfm / .pas   an AVI playback control
  TDdeServerConv    main.dfm / main.pas      Windows-only DDE IPC

The deletions were correct and are the reason `f3_form_ratchet.py` counts those
types no longer. But a deletion is not a property: nothing stopped either
control from being reintroduced by a merge, a revert, or a well-meaning
"restore the animation". A control that comes back is invisible to every other
gate -- the F3 ratchet only checks that the convertible count does not DROP
below its baseline, and these types are counted per-form, so a reintroduction
would show up as a single blocked form rather than as the regression it is.

This is that gate. It is a NEGATIVE assertion: the controls must be absent.

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
}

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
    print("PASS -- both controls are absent from live source.")
    print("        This gate is a negative assertion: it only fails on a")
    print("        reintroduction, so a green result says nothing about whether")
    print("        the removal was correct -- only that it still holds.")
    return 0


def main() -> int:
    return report(scan_live())


if __name__ == "__main__":
    sys.exit(main())