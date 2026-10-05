#!/usr/bin/env python3
"""Find every place that names the five renamed files by PATH (not by unit).

After renaming Core/Events.pas -> Core/Core.Events.pas (and four more), the
unit NAMES are unchanged -- every `uses Core.Events` still says the same thing,
because Delphi resolves the unit name against the search path at compile time,
not against a file list.

What DOES break is any tool or project file that names the FILE:

  * devcpp.dproj DCCReference entries (the IDE's unit list)
  * the FPC .lpi test projects (which reference files explicitly)
  * anything else that globs Source/Core/Events.pas

Run this before compiling, so a failure is attributed correctly instead of
being blamed on the rename or on the F1/F2 work.

Run:  python tools/find_stale_unit_paths.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Source"

RENAMED = [
    ("Core/Events.pas", "Core/Core.Events.pas"),
    ("Core/Services.pas", "Core/Core.Services.pas"),
    ("Core/ServicesImpl.pas", "Core/Core.ServicesImpl.pas"),
    ("Debugger/GDB/GdbMiParser.pas", "Debugger/GDB/GDB.MiParser.pas"),
    ("Debugger/GDB/GdbMiTypes.pas", "Debugger/GDB/GDB.MiTypes.pas"),
]

# Files that legitimately name these paths and must be updated.
CHECK = ["Source/devcpp.dproj", "Source/devcpp.dpr"] + [
    str(p.relative_to(ROOT)) for p in sorted((ROOT / "Tests").rglob("*.lpi"))
] + [
    str(p.relative_to(ROOT)) for p in sorted((ROOT / "Tests").rglob("*.lpr"))
]


def main():
    print("== rename map ==")
    for old, new in RENAMED:
        print("   %-34s -> %s" % (old, new))
        ok_new = (SRC / new).exists()
        ok_old = (SRC / old).exists()
        if not ok_new:
            print("      WARNING: target missing")
        if ok_old:
            print("      WARNING: source still present")

    stale = 0
    print("\n== stale FILE references (must be updated) ==")
    for rel in CHECK:
        p = ROOT / rel
        if not p.exists():
            continue
        t = p.read_bytes().decode("utf-8", errors="replace")
        hits = []
        for old, new in RENAMED:
            for pat in (old.replace("/", "/"), old.replace("/", "\\"),
                        new.replace("/", "\\")):
                pass
            # match the OLD path only; the new one is what we want to see
            for sep in ("/", "\\"):
                needle = old.replace("/", sep)
                if needle in t:
                    hits.append("%s (%s)" % (old, sep))
        if hits:
            stale += 1
            print("   %-40s references: %s" % (rel, ", ".join(sorted(set(hits)))))
    if not stale:
        print("   (none -- project files name units, not files)")

    print("\n== whole-tree scan for the old FILE names ==")
    hits = 0
    for p in ROOT.rglob("*"):
        if not p.is_file() or ".git" in p.parts:
            continue
        if p.suffix.lower() not in (".pas", ".dpr", ".dproj", ".lpi", ".lpr",
                                    ".cfg", ".md", ".py", ".yml", ".json"):
            continue
        try:
            t = p.read_bytes().decode("utf-8", errors="replace")
        except OSError:
            continue
        for old, _ in RENAMED:
            stem = old.rsplit("/", 1)[1][:-4]
            for sep in ("/", "\\"):
                if old.replace("/", sep) in t:
                    print("   %s -> %s" % (p.relative_to(ROOT), old))
                    hits += 1
                    break
    print("   %d hit(s)" % hits)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
