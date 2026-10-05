#!/usr/bin/env python3
"""Decide the smallest correct fix for "F2613 Unit 'Core.Events' not found".

Background
----------
The Phase-4 baseline introduced three units named Core.Events, Core.Services and
Core.ServicesImpl, stored as Source/Core/Events.pas etc. Delphi resolves a
dotted unit name by concatenating each part as a FILE name -- Core.Events means
the file Core.Events.pas -- so with `Core` on the search path it looks for
Source/Core/Core.Events.pas, which does not exist.

Every other dotted unit in this repo follows the opposite convention and works:

    Source/LSP/JsonRpc/Lsp.JsonRpc.pas    unit LSP.JsonRpc
    Source/Debugger/GDB/GdbMiParser.pas   unit GDB.MiParser
    Source/LSP/Process/Lsp.Process.pas    unit LSP.Process

i.e. the file name repeats the dotted prefix. Core is the only one that does
not, which is why it alone fails.

The fix options differ in blast radius, and that is what this script measures:
renaming units touches 9 files and every reference; adding search-path entries
touches the project file and the .dpr, and leaves the naming inconsistent.

Run:  python tools/core_unit_fix_survey.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Source"
DPROJ = SRC / "devcpp.dproj"
DPR = SRC / "devcpp.dpr"


def read(p):
    return p.read_bytes().decode("latin-1", errors="replace")


def dotted_units():
    """unit name -> path, for every unit whose name contains a dot."""
    out = {}
    for p in SRC.rglob("*.pas"):
        t = read(p)
        m = re.search(r"(?mi)^\s*unit\s+([\w.]+)\s*;", t)
        if m and "." in m.group(1):
            out[m.group(1).lower()] = p
    return out


def main():
    units = dotted_units()
    print("== dotted units in this repo ==")
    print("   %-24s %-8s %s" % ("unit", "verbose?", "path"))
    for name in sorted(units):
        p = units[name]
        stem = p.stem.lower()
        want = name.lower()
        # The convention: file stem repeats the dotted name.
        verbose = stem == want
        mark = "OK " if verbose else "MISMATCH"
        print("   %-24s %-8s %-46s %s"
              % (name, "", p.relative_to(SRC).as_posix(), mark))

    bad = [n for n, p in units.items() if p.stem.lower() != n]
    print("\n%d of %d dotted units deviate from the convention"
          % (len(bad), len(units)))
    for n in sorted(bad):
        print("   %-22s -> %s" % (n, units[n].relative_to(SRC).as_posix()))

    print("\n== blast radius: files naming the deviating units ==")
    total = 0
    for name in sorted(bad):
        users = []
        for p in sorted(SRC.rglob("*.pas")):
            t = read(p)
            for m in re.finditer(r"(?ims)^\s*uses\b(.*?);", t):
                if re.search(r"\b%s\b" % re.escape(name), m.group(1), re.I):
                    users.append(p)
        print("   %-22s referenced by %d unit(s): %s"
              % (name, len(users), ", ".join(u.name for u in users[:8])))
        total += len(users)
    print("   total call sites to rewrite if renaming: %d" % total)

    print("\n== option B: add search-path entries instead ==")
    dp = read(DPROJ)
    m = re.search(r"(?ims)<DCC_UnitSearchPath>(.*?)</DCC_UnitSearchPath>", dp)
    cur = m.group(1).strip()
    print("   DCC_UnitSearchPath currently has a bare `Core` entry: %s"
          % ("Core" in cur.split(";")))
    print("   With the bare entry, Core.Events resolves to:")
    print("      Source/Core/Core.Events.pas   exists=%s"
          % (SRC / "Core" / "Core.Events.pas").exists())
    print("   Naming the files Core.Events.pas etc. makes it resolve with the")
    print("   EXISTING search path and no project-file change at all.")

    print("\n== recommendation ==")
    print("   Rename the three files to repeat the unit prefix. Rationale:")
    print("     - it needs NO change to devcpp.dproj, devcpp.dpr or the FPC")
    print("       projects, so it cannot break the FPC side that currently works;")
    print("     - it makes Core follow the convention every other dotted unit in")
    print("       this repo already follows, so the next person is not misled;")
    print("     - the alternative (a `Core.`-prefixed search path) leaves the")
    print("       inconsistency in place and is easy to trip over again.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
