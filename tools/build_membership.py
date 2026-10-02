#!/usr/bin/env python3
"""Are the counted files even part of the Delphi build?

F1-l discovery: `Source/Tools/PackMaker/filefrm.pas` carries four `MainForm.`
references -- and is NOT listed in devcpp.dproj, so it is never compiled into
devcpp.exe. The ratchet counts it, the audit ratchets it, and the headline
number includes a coupling that cannot break anything: the unit is dead weight,
not debt.

This tool cross-references tools/mainform_baseline.json against the project's
DPR/DPROJ unit list and prints the difference, so "is this reference real?"
is answered mechanically instead of by eye.

Usage:  python tools/build_membership.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tools" / "mainform_baseline.json"
PROJECT = ROOT / "Source" / "devcpp.dproj"


def project_units():
    text = PROJECT.read_text(encoding="utf-8", errors="replace")
    # DCCReference elements carry the unit path; normalize to forward slashes.
    return {m.replace("\\", "/") for m in re.findall(r'Include="([^"]+\.pas)"', text)}


def main():
    data = json.loads(BASELINE.read_text(encoding="utf-8"))
    units = project_units()
    # Accept both "Source/X.pas" and "X.pas" spellings in the project file.
    by_base = {Path(u).name.lower(): u for u in units}

    files = sorted(data.get("refs", {}), key=lambda r: -data["refs"][r])
    missing, present = [], []
    for rel in files:
        hit = next((u for u in units
                    if u.lower().endswith(rel.lower().replace("\\", "/"))
                    or Path(u).name.lower() == Path(rel).name.lower()), None)
        (present if hit else missing).append((rel, data["refs"][rel]))

    total_coupled = sum(data["refs"].values())
    dead = sum(n for _, n in missing)

    print("project lists %d units\n" % len(units))
    print("== NOT in the build (couplings that cannot break anything) ==")
    for rel, n in missing:
        print("  %-40s %3d refs" % (rel, n))
    if not missing:
        print("  (none)")
    print("\n== in the build ==")
    print("  %d files, %d refs" % (len(present), total_coupled - dead))
    print("\nsummary: %d/%d counted refs live in units outside devcpp.dproj"
          % (dead, total_coupled))
    return 0


if __name__ == "__main__":
    sys.exit(main())
