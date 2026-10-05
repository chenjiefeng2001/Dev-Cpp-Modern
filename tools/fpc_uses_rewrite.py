#!/usr/bin/env python3
"""
fpc_uses_rewrite.py -- apply the FPC unit-spelling accommodation, per uses clause.

WHAT IT DOES
============
The Delphi tree spells RTL units `System.SysUtils`, `System.Classes` and so on.
FPC 3.2.2 has no `System.*` tree (measured: the string `reference to` appears in
none of its 84 RTL units; `System` does not exist as a directory), and it refuses
to compile a unit whose NAME contains a dot:

    Error: Illegal unit name: System.SysUtils (expecting SYSUTILS)

so an alias file cannot bridge this in any directory layout. Each uses clause is
therefore rewritten under {$IFDEF FPC}, keeping the Delphi spelling in {$ELSE}.
The Delphi build must keep resolving `System.SysUtils` -- it is the canonical
spelling there and the project already compiles against it.

WHY A TOOL AND NOT A REGEX
==========================
A regex across a MULTI-LINE uses clause is exactly the transform that silently
drops a unit name, and the resulting file then fails on a MISSING unit, which
reads like a search-path problem rather than a bad edit. So every rewrite here:

  * asserts the ORIGINAL line is present exactly once
  * derives the FPC spelling from the SAME line by token substitution
  * writes BOTH branches, so the transformation is visible in the file rather
    than depending on this tool being re-run

Run:  python tools/fpc_uses_rewrite.py           apply
      python tools/fpc_uses_rewrite.py --check   verify only
Exit: 0 when nothing is left to rewrite (or --check found none); 1 otherwise.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

FPC_DIRS = [
    SOURCE / "Core",
    SOURCE / "Debugger" / "GDB",
    SOURCE / "LSP" / "JsonRpc",
    SOURCE / "LSP" / "Transport",
    SOURCE / "LSP" / "Process",
    SOURCE / "Toolchain",
]

# Dotted Delphi spelling -> FPC spelling. Namespaces with no plain RTL
# counterpart are absent on purpose; Vcl/Winapi are never accommodated.
STRIP = {
    "System.SysUtils": "SysUtils",
    "System.Classes": "Classes",
    "System.SyncObjs": "SyncObjs",
    "System.Generics.Collections": "Generics.Collections",
    "System.Types": "Types",
    "System.IOUtils": "IOUtils",
    "System.TypInfo": "TypInfo",
    "System.Math": "Math",
    "System.Strings": "Strings",
    "System.DateUtils": "DateUtils",
    # Case mismatches between the .lpr and the unit declarations. Windows hides
    # these; the Linux CI job would not.
    "LSP.JsonRpc": "Lsp.JsonRpc",
    "LSP.Process": "Lsp.Process",
    "LSP.Process.Fpc": "Lsp.Process.Fpc",
    "LSP.Process.Factory": "Lsp.Process.Factory",
    "LSP.Transport": "Lsp.Transport",
}

TOKEN = re.compile(r"\b(" + "|".join(sorted(STRIP, key=len, reverse=True)) + r")\b")


def candidates():
    for d in FPC_DIRS:
        if d.is_dir():
            for p in sorted(d.rglob("*.pas")):
                yield p


def plan(p):
    """[(lineno, original, fpc_line, indent)] for every uses line needing work.

    Only lines inside a uses CLAUSE are considered: the same token in code or in
    a comment must not be rewritten.
    """
    raw = p.read_bytes()
    nl = "\r\n" if b"\r\n" in raw else "\n"
    lines = raw.decode("utf-8").split(nl)

    out = []
    in_uses = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r"^uses\b", stripped):
            in_uses = True
            # `uses SysUtils;` on one line is handled by the same substitution
            # path below; nothing special needed here.
            if stripped.rstrip().endswith(";"):
                in_uses = False
            continue
        if not in_uses:
            continue
        if stripped.startswith("//") or stripped.startswith("{"):
            continue
        if TOKEN.search(line):
            fpc_line = TOKEN.sub(lambda m: STRIP[m.group(1)], line)
            if fpc_line != line:
                out.append((i, line, fpc_line, len(line) - len(line.lstrip())))
        if stripped.endswith(";"):
            in_uses = False
    return nl, out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    todo = []
    for p in candidates():
        _nl, edits = plan(p)
        if edits:
            todo.append((p, edits))

    for p, edits in todo:
        print(f"  {p.relative_to(ROOT).as_posix()}")
        for i, old, new, _ind in edits:
            print(f"      L{i + 1}: {old.strip()[:60]}")
            print(f"          -> {new.strip()[:60]}")

    print()
    print(f"  {sum(len(e) for _p, e in todo)} line(s) in {len(todo)} unit(s)")
    if not todo:
        print("  PASS -- every FPC-facing uses clause already has both spellings.")
        return 0
    if args.check:
        print("  FAIL -- run without --check to apply.")
        return 1

    # Apply bottom-up so earlier line indices stay valid.
    for p, edits in todo:
        raw = p.read_bytes()
        nl = "\r\n" if b"\r\n" in raw else "\n"
        lines = raw.decode("utf-8").split(nl)
        for i, old, new, ind in sorted(edits, reverse=True):
            pad = " " * ind
            block = [
                f"{pad}{{$IFDEF FPC}}",
                f"{new}",
                f"{pad}{{$ELSE}}",
                f"{old}",
                f"{pad}{{$ENDIF}}",
            ]
            lines[i:i + 1] = block
        p.write_bytes(nl.join(lines).encode("utf-8"))
        print(f"  rewrote {p.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())