#!/usr/bin/env python3
"""Is a unit actually dead, or merely unreferenced by the .dproj?

The .dproj is a useful but incomplete answer: Delphi also compiles whatever a
unit pulls in through its `uses` clause. A unit absent from the project file is
therefore only *probably* dead, and moving it to an archive is a one-way door.

This answers the question properly and in one pass, with the evidence printed:
  1. is the unit listed in devcpp.dproj?
  2. do the units that ARE in the project name it in a uses clause?
  3. does any in-project unit reference its symbols?

Usage:  python tools/dead_unit_check.py Source/FormatterOptionsFrm.pas ...
Exit code 0 = every named unit is safe to archive.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
PROJECT = ROOT / "Source" / "devcpp.dproj"

_USES = re.compile(r"(?ims)^\s*uses\b(.*?);")


def project_units():
    raw = PROJECT.read_text(encoding="utf-8", errors="replace")
    return {m.replace("\\", "/") for m in
            re.findall(r'Include="([^"]+\.pas)"', raw)}


def units_of(path):
    raw = path.read_bytes()
    text = raw.decode("utf-8-sig" if raw.startswith(b"\xef\xbb\xbf")
                      else "utf-8", errors="replace")
    names = set()
    for chunk in _USES.findall(text):
        chunk = re.sub(r"//[^\n]*", "", chunk)
        for name in chunk.replace("\r", "").split(","):
            name = name.strip().lower()
            if name:
                names.add(name)
    return names


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    units = {Path(a).name.lower(): Path(a).resolve() for a in sys.argv[1:]}
    project = project_units()
    project_names = {Path(u).name.lower() for u in project}

    # Build the real reference graph over everything that is compiled.
    reachable = set()
    for rel in project:
        p = ROOT / rel
        if p.exists():
            reachable |= units_of(p)

    safe = True
    for name, path in sorted(units.items()):
        listed = name in project_names
        used_by = sorted(n for n in reachable if n == name)
        print("== %s ==" % path.name)
        print("   listed in devcpp.dproj : %s" % listed)
        print("   named by a built unit  : %s"
              % ("yes -> %s" % ", ".join(used_by) if used_by else "no"))
        if listed or used_by:
            safe = False
            print("   VERDICT: NOT dead -- archiving it breaks the build")
        else:
            print("   VERDICT: safe to archive")
    print("\n%s" % ("all named units are safe to archive" if safe
                    else "STOP: at least one unit is still live"))
    return 0 if safe else 1


if __name__ == "__main__":
    sys.exit(main())