#!/usr/bin/env python3
"""f3_fpc_closure_scan.py -- compile each unit of main.pas's closure, one by
one, against a real LCL, and report what still blocks the closure.

WHY THIS EXISTS
===============
`python tools/f3_compile_cost.py` already measures what a form's closure
COSTS in units and lines, and `tools/f3_namespace_alias.py` measures what a
single pattern (dotted unit names)contributes. Neither answers the question
this one was built for: which of the main.pas closure's own units can be
COMPILED by FPC today, and what exactly is the first thing that stops the
ones that cannot.

That question is the one doc/F3-SVG section 18 labelled F3-7 and could not
answer: the closure is 89 units / 51,303 LOC, so compiling `main.pas` in one
go produces one fatal error per unit in file order and no ranking. Answering
it requires compiling each unit in ISOLATION, which needs one small program
per unit (`uses Interfaces, <unit>;`) -- the LCL's Forms unit needs the
`Interfaces` symbol the widgetset registers, and omitting it produces
sixteen Undefined-symbol errors that look like unit resolution failures and
are not. (Same rule as tools/f3_namespace_alias.py's probe_compiles.)

MEASURED, on purpose
====================
This tool prints, per unit: OK / FAIL, the IDENTIFIERS the compiler could not
find (a BEGINNING of a symbol surface for a compatibility shim), and the
first errors. Aggregated over the closure those two columns are the actual
worklist:

  * `Can't find unit X used by Y` -- X is either a vendored Delphi unit that
    needs a port (the ClassBrowsing family) or a dead reference.
  * `Identifier not found "Z"` -- a typed surface a compat shim must
    re-export; each one appears with the number of owning units.

Exit 0 = every unit compiles. Non-zero = blockers remain (the output is the
worklist). Run it after any port/rewrite: the point is that the numbers move
for a reason that can be named.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FPC = r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"

FU = [
    # The vendored-SynEdit port comes FIRST, before the LCL's own synedit
    # units -- deliberately. Once `uses SynEditTypes` resolves to our port,
    # every vendored-family unit must resolve to it too, or the app would be
    # handed two different TBufferCoord types (one per unit identity) and the
    # compile would fail on a type mismatch that looks like a bug in the port.
    # One universe, chosen once. Measured: promoting SynEditTypes alone while
    # the LCL's synedittypes.pp stayed earlier in the order resolved it to the
    # LCL's, which has no ESynError.
    str(ROOT / "Source" / "Fpc" / "UI" / "SynEdit"),
    r"C:\lazarus\lcl\units\x86_64-win64\win32",
    r"C:\lazarus\lcl\units\x86_64-win64",
    r"C:\lazarus\components\lazutils\lib\x86_64-win64",
    r"C:\lazarus\components\synedit\units\x86_64-win64\win32",
    # The LCL synedit's SOURCE directory, not just its compiled units. The
    # win32 ppu dir alone is not enough: synedit.pp references LazSynIMMBase
    # (lazsynimmbase.pas line 27), and FPC must compile that unit from
    # source when a probe links synedit. Without it every unit that uses
    # SynEdit fails with "Can't find unit LazSynIMMBase used by SynEdit" --
    # which reads as a missing port and is a missing search path.
    # Ordered after the win32 ppu dir so the compiled units still win.
    r"C:\lazarus\components\synedit",
    # The Source ROOT itself must be on the path, not just its subdirectories:
    # a rglob("*/") yields children only, and with the root missing every
    # unit declared directly under Source/ (main.pas, Editor.pas, all the
    # forms) resolves to nothing -- the scan then reports them as blocked by
    # units of their own name, which is nonsense that measures the scanner,
    # not the tree.
    str(ROOT / "Source"),
    # Every Source subdirectory that declares units. FPC resolves a dotted
    # unit name (`Lsp.Client`) by looking for a file with that exact name in
    # each -Fu directory, so the containing directories must be listed -- the
    # first version of this list omitted Source/LSP/Client and reported four
    # healthy LSP units as blocked by their own dependencies. The vendored
    # trees are deliberately absent: they cannot compile under FPC at all,
    # and their unit names must resolve to Source/Fpc ports, never to the
    # Delphi sources.
]
for _d in sorted((ROOT / "Source").rglob("*/")):
    if not _d.is_dir() or not any(_d.glob("*.pas")) or not _d.is_relative_to(ROOT):
        continue
    _rel = _d.relative_to(ROOT)
    if _rel.parts[0] == "Source" and any(
            p in _rel.parts for p in ("VCL", "Archive")):
        continue
    _s = str(_d)
    if _s not in FU:
        FU.append(_s)


def closure_units():
    """main.pas's own-unit closure, from tools/f3_compile_cost.py.

    Imported rather than re-transcribed: the closure is the tool that already
    owns that measurement, and a second implementation is exactly the
    "one fact, two copies" failure the rest of this repo keeps finding.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "_cc", ROOT / "tools" / "f3_compile_cost.py")
    m = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["f3_compile_cost.py"]
    try:
        spec.loader.exec_module(m)
    except SystemExit:
        pass
    finally:
        sys.argv = saved
    seen, _ = m.closure("main")
    return sorted(u for u in seen if m.unit_path.get(u) is not None)


def compile_unit(unit_name):
    tmp = tempfile.mkdtemp(prefix="closure-")
    src = pathlib.Path(tmp) / "wrap.pas"
    src.write_text("program wrap;\n{$mode objfpc}{$H+}\n"
                   "uses Interfaces, %s;\nbegin\nend.\n" % unit_name,
                   encoding="ascii")
    args = [FPC, "-Mdelphiunicode", "-FU%s" % tmp, "-FE%s" % tmp]
    for d in FU:
        args.append("-Fu%s" % d)
    args.append(str(src))
    proc = subprocess.run(args, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    missing, blocked = set(), []
    for line in out.splitlines():
        m = re.search(r'Identifier not found "(\w+)"', line)
        if m:
            missing.add(m.group(1))
        m = re.search(r"Can't find unit (\w+\.?\w*)", line)
        if m:
            blocked.append(m.group(1))
    return proc.returncode == 0, sorted(missing), blocked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", help="write the full result to this file")
    args = ap.parse_args()

    units = closure_units()
    ok = []
    blocked_by = {}
    missing_ids = {}
    for u in units:
        good, miss, blocked = compile_unit(u)
        if good:
            ok.append(u)
        for b in blocked:
            blocked_by.setdefault(b, set()).add(u)
        for mid in miss:
            missing_ids.setdefault(mid, set()).add(u)

    print("FPC CLOSURE SCAN -- main.pas's own units, compiled one by one")
    print("=" * 78)
    print("  compiled OK  : %d of %d" % (len(ok), len(units)))
    print("  still blocked: %d" % (len(units) - len(ok)))
    print()
    if blocked_by:
        print("BLOCKING UNITS (a uses clause names something that does not resolve)")
        for b, users in sorted(blocked_by.items(), key=lambda kv: -len(kv[1])):
            print("  %-28s %3d unit(s): %s"
                  % (b, len(users), ", ".join(sorted(users)[:4])
                     + (" ..." if len(users) > 4 else "")))
        print()
    if missing_ids:
        print("MISSING IDENTIFIERS (a surface a compat shim must re-export)")
        for i, users in sorted(missing_ids.items(), key=lambda kv: -len(kv[1])):
            print("  %-28s %3d unit(s): %s"
                  % (i, len(users), ", ".join(sorted(users)[:4])
                     + (" ..." if len(users) > 4 else "")))
        print()
    print("DETAIL")
    for u in units:
        if u in ok:
            continue
    if args.json:
        import json as _json
        pathlib.Path(args.json).write_text(
            _json.dumps({"ok": ok, "blocked": {k: sorted(v) for k, v in blocked_by.items()},
                         "missing": {k: sorted(v) for k, v in missing_ids.items()}},
                        indent=2), encoding="utf-8")
    return 0 if len(ok) == len(units) else 1


if __name__ == "__main__":
    sys.exit(main())
