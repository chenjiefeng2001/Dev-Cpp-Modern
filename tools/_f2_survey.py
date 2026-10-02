#!/usr/bin/env python3
"""Survey what the two front-lines need before anyone starts writing code.

Front-line A (IDE compile + smoke) cannot run here: there is no Delphi IDE.
Front-line B (LCL SynEdit) cannot COMPILE here either: no fpc/lazbuild/ppcx64
on PATH. That does not make B worthless -- it makes it a DESIGN + SCAFFOLD
task, and this script exists so the design rests on measured facts rather
than on the roadmap's assumptions.
"""
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Source"


def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def grep(path, needle, limit=6):
    try:
        text = read(path)
    except OSError:
        return []
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        if needle in line:
            out.append((i, line.strip()))
            if len(out) >= limit:
                break
    return out


def main():
    print("== toolchain availability (decides what can be BUILT vs only designed) ==")
    for c in ("fpc", "lazbuild", "ppcx64", "dcc32"):
        print("  %-9s %s" % (c, shutil.which(c) or "NOT FOUND"))

    print("\n== front-line A: the automated suite the roadmap wants to run ==")
    for unit in ("Tests.pas", "TestsDUnitX.pas"):
        hits = grep(SRC / unit, "actRunTests")
        print("  Source/%-18s actRunTests: %d hit(s)" % (unit, len(hits)))
        for i, line in hits[:4]:
            print("      %d: %s" % (i, line[:96]))

    print("\n== front-line B: what an LCL SynEdit probe would actually need ==")
    lcl = sorted(p for p in SRC.rglob("*.pas")
                 if "lcl" in p.read_bytes()[:400].decode("latin-1").lower())
    print("  units already referencing LCL : %d" % len(lcl))
    for p in lcl[:8]:
        print("      %s" % p.relative_to(ROOT).as_posix())

    syn = sorted(p for p in (SRC / "VCL" / "SynEdit").rglob("*.pas"))
    print("  vendored SynEdit units        : %d" % len(syn))
    total = sum(len(read(p).splitlines()) for p in syn)
    print("  vendored SynEdit lines        : %d" % total)

    print("\n  LSP client units that would need a new editor host:")
    for p in sorted((SRC / "LSP" / "Client").rglob("*.pas")):
        n = len(read(p).splitlines())
        text = read(p)
        mark = "TCustomSynEdit" if "TCustomSynEdit" in text else "-"
        print("      %-46s %5d lines  %s"
              % (p.relative_to(ROOT).as_posix(), n, mark))
    return 0


if __name__ == "__main__":
    sys.exit(main())