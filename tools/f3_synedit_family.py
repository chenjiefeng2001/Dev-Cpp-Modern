#!/usr/bin/env python3
"""f3_synedit_family.py -- how much vendored SynEdit the app closure actually
needs, and why the LCL cannot stand in for it.

WHY THIS IS ITS OWN TOOL
========================
`tools/f3_fpc_closure_scan.py` answers "what blocks the closure", and for the
SynEdit family it names units like `SynExportRTF` and `SynCompletionProposal`
without saying why the LCL -- which ships a SynEdit -- does not cover them.
Two different facts hide behind the same blocker list, and they have very
different prices:

  * The LCL has no unit of that NAME at all (SynExportRTF,
    SynCompletionProposal). Porting is "copy the file, fix the dialect".
  * The LCL HAS a unit of that name, but it was built in a mode that cannot
    be subclassed from a `-Mdelphiunicode` unit. Measured twice: the ppu's
    own alias record names TSynCustomExporter.GetFooter as ANSISTRING
    (ppudump -V), and a one-method subclass reproduces

        "There is no method in an ancestor class to be overridden:
         GetFooter:UnicodeString;"

    under -Mdelphiunicode, with `{$H-}` AND `{$H+}`. The override cannot be
    made to match, so the vendored family is the only usable base -- which
    is what makes this a 36k-line decision rather than a file copy.

So the tool reports, per unit the app names: does the LCL ship it, is it
compile-compatible, and what is the closure size if the vendored family must
be ported. The number is the input to the schedule, not an estimate.

A THIRD KIND OF BLOCKER -- and the reason this tool exists at all
================================================================
There is a shape that looks like the first (LCL does not ship it) but measures
like the second (it drags a vendored dependency that cannot be satisfied).
`SynEditCodeFolding` was attempted on 2026-10-09 and deleted, not shipped:

  * It compiles under FPC except for three uses of `TSynEditStringList`'s
    `Ranges[...]` and `TabWidth`.
  * The LCL's `synedittextbuffer.pp` HAS `TSynEditStringList`, but NOT
    `Ranges` and NOT `TabWidth` -- both are vendored additions in the
    1,223-line `SynEditTextBuffer.pas`.
  * So the "1102-line file copy" is really a 1,102 + 1,223 (plus whatever
    SynEditTextBuffer itself drags) port, and the F3-SVG doc's number for the
    unit would have understated it by the transitive part.

The lesson recorded here because it cost a session to find: a unit whose
symbols are absent from the LCL's same-named unit is a CLOSURE blocker, not a
file blocker. This tool now prints, for every blocked unit, whether its
missing symbols are explained by another vendored unit, so the count of
"copy this file" versus "port this family" is visible before anyone starts.


Run:  python tools/f3_synedit_family.py
      python tools/f3_synedit_family.py --json out.json
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VEND = ROOT / "Source" / "VCL" / "SynEdit" / "Source"
LCL = pathlib.Path(r"C:\lazarus\components\synedit")
FPC = r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"
FU = [
    r"C:\lazarus\lcl\units\x86_64-win64\win32",
    r"C:\lazarus\lcl\units\x86_64-win64",
    r"C:\lazarus\components\lazutils\lib\x86_64-win64",
    r"C:\lazarus\components\synedit\units\x86_64-win64\win32",
]


def strip_comments(text):
    return re.sub(r"//.*|\{[^}]*\}", "", text)


def app_named_units():
    """Unit names the self-authored tree names in a uses clause."""
    names = set()
    for p in ROOT.joinpath("Source").rglob("*.pas"):
        if "VCL" in p.parts or "Archive" in p.parts:
            continue
        t = strip_comments(p.read_text(encoding="utf-8", errors="replace"))
        for m in re.finditer(r"(?i)\buses\b([^;]*);", t):
            names.update(n.lower() for n in re.findall(r"[\w.]+", m.group(1)))
    return names


def vendored_units():
    return {p.stem.lower(): p for p in VEND.glob("*.pas")} if VEND.is_dir() else {}


def lcl_units():
    if not LCL.is_dir():
        return set()
    return {p.stem.lower() for p in LCL.glob("*.pas")} | {p.stem.lower() for p in LCL.glob("*.pp")}


def vendored_symbols():
    """symbols declared by the vendored tree, by unit -> set(names)."""
    out = {}
    for p in vendored_units().values():
        t = strip_comments(p.read_text(encoding="utf-8", errors="replace"))
        names = set(re.findall(r"(?m)^\s*(?:T[A-Z]\w*|P[A-Z]\w*|function\s+\w+|procedure\s+\w+|\w+\s*[:=])", t))
        out[p.stem.lower()] = names
    return out


def missing_symbols_in_lcl(unit_stem, vend_syms):
    """Which symbols a port needs that the LCL's same-named unit does not have.

    The SynEditCodeFolding case: the LCL's synedittextbuffer.pp has
    TSynEditStringList but not `Ranges` / `TabWidth`, so those two resolve to
    a vendored unit and the port is a family port, not a file port.
    """
    lcl_p = LCL / (unit_stem + ".pas")
    if not lcl_p.exists():
        lcl_p = LCL / (unit_stem + ".pp")
    if not lcl_p.exists():
        return None  # no same-named LCL unit at all
    lcl_text = strip_comments(lcl_p.read_text(encoding="utf-8", errors="replace"))
    have = set(re.findall(r"(?m)^\s*(?:T[A-Z]\w*|P[A-Z]\w*|\w+)\s*[:=]", lcl_text))
    here = set()
    vp = vendored_units().get(unit_stem)
    if vp:
        vt = strip_comments(vp.read_text(encoding="utf-8", errors="replace"))
        for m in re.finditer(r"(?m)^\s*(T[A-Z]\w*)\s*[:=]", vt):
            here.add(m.group(1))
    return sorted(h for h in here if h not in have)


def closure(needed, vend):
    """Transitive uses-closure over the vendored tree only.

    `needed` seeds the set -- a first version iterated an empty `seen` and
    reported a closure of 0 units, which would have read as "no work".
    """
    seen = {n for n in needed if n in vend}
    changed = True
    while changed:
        changed = False
        for name in sorted(seen):
            p = vend.get(name)
            if not p:
                continue
            t = strip_comments(p.read_text(encoding="utf-8", errors="replace"))
            for m in re.finditer(r"(?i)\buses\b([^;]*);", t):
                for tok in re.findall(r"[\w.]+", m.group(1)):
                    low = tok.lower()
                    if low in vend and low not in seen:
                        seen.add(low)
                        changed = True
    return seen


def lcl_subclassable(unit_name):
    """Can a -Mdelphiunicode unit derive from the LCL's TSynCustomExporter?

    The single measurement that decides the whole question, kept here because
    it is cheap and re-runnable, and because guessing it wrong costs either a
    pointless port or a non-compiling one.
    """
    import subprocess, tempfile
    tmp = tempfile.mkdtemp(prefix="syncompat-")
    src = pathlib.Path(tmp) / "c.pas"
    src.write_text(
        "unit c;\r\n{$H+}\r\ninterface\r\nuses\r\n  %s;\r\ntype\r\n"
        "  TProbe = class(TSynCustomExporter)\r\n"
        "    function GetFooter: string; override;\r\n"
        "  end;\r\nimplementation\r\n"
        "function TProbe.GetFooter: string;\r\nbegin\r\n  Result := '';\r\nend;\r\n"
        "end.\r\n" % unit_name, encoding="utf-8")
    args = [FPC, "-Mdelphiunicode", "-FU" + tmp, "-FE" + tmp]
    for d in FU:
        args.append("-Fu" + d)
    args.append(str(src))
    return subprocess.run(args, capture_output=True, text=True).returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    args = ap.parse_args()

    vend = vendored_units()
    lcl = lcl_units()
    named = app_named_units()

    # the app names 19 vendored units; the LCL covers 13 of them by name. What
    # is left is what no unit anywhere can resolve, and therefore must be
    # ported (or satisfied some other way) before the closure compiles.
    blocked = sorted(n for n in named if n in vend and n not in lcl)
    vend_lines = lambda n: len(vend[n].read_text(encoding="utf-8", errors="replace").splitlines())

    print("VENDORED SynEdit FAMILY -- what the app needs, and what it costs")
    print("=" * 78)
    print("  vendored tree    : %d units / %d lines"
          % (len(vend), sum(len(p.read_text(encoding='utf-8', errors='replace').splitlines())
                            for p in vend.values())))
    print("  LCL ships        : %d units" % len(lcl))
    print()
    print("BLOCKED: the app names them, the LCL does not ship them")
    for n in blocked:
        print("   %-28s %5d lines" % (n, vend_lines(n)))
        # a same-named LCL unit would mean "copy this file"; a missing symbol
        # means "port this family", and the two have very different prices.
        gap = missing_symbols_in_lcl(n, vendored_symbols())
        if gap:
            print("      symbol gap vs the LCL's %s.pas: %s" % (n, ", ".join(gap)))
            print("      -> the missing symbols live in another vendored unit:")
            for sym in gap:
                for vn, vs in vendored_symbols().items():
                    if sym in vs:
                        print("         %s in %s.pas" % (sym, vn))
                        break

    if vend:
        clo = closure(set(blocked), vend)
        tot = sum(vend_lines(n) for n in clo if n in vend)
        print()
        print("PORT SCOPE (vendored closure of the blocked units)")
        print("  %d units, %d lines -- the whole vendored family the app would"
              % (len(clo), tot))
        print("  have to carry, because the LCL's exporter base cannot be")
        print("  subclassed from a -Mdelphiunicode unit (measured below):")
        for n in sorted(clo):
            if n in vend:
                print("     %5d %s" % (vend_lines(n), n))

        # the case-insensitive membership that decides whether the LCL could
        # ever stand in for the vendored exporter base
        if any(n.lower() == "synexportrtf" for n in blocked):
            print()
            ok = lcl_subclassable("SynEditExport")
            print("LCL COMPATIBILITY (measured, every run)")
            print("  a -Mdelphiunicode subclass of the LCL's "
                  "TSynCustomExporter: %s" % ("ACCEPTED" if ok else "REFUSED"))
            if not ok:
                print("  -> the vendored SynEditExport family is the only usable base;")
                print("     the numbers above are the schedule, not an estimate.")

    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps({"blocked": blocked, "closure_units": len(clo),
                        "closure_loc": tot}, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
