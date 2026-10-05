#!/usr/bin/env python3
"""
fpc_dialect_scan.py -- every place the FPC build needs a dialect accommodation.

WHY THIS TOOL
=============
The first real compile of this project (2026-10-05, FPC 3.2.2 / Lazarus 4.4 --
the first time a compiler had ever run here) died at

    Core.Events.pas(25,3) Fatal: Can't find unit System.SysUtils

The port plan listed this as dialect risk #2 and offered two fallbacks: "add
aliases in the .lpi" or "strip the prefixes once". The first is IMPOSSIBLE,
not merely awkward:

    Error: Illegal unit name: System.SysUtils (expecting SYSUTILS)

FPC refuses to compile a unit whose NAME contains a dot, so no alias shim can
work in any directory layout -- the shim is rejected before it is resolved. Two
layouts were tried and both failed for this same underlying reason:

    flat  fpc_alias/System.SysUtils.pas  -> Fatal: I/O error: File not open
    nested fpc_alias/System/SysUtils.pas -> Illegal unit name

`-FN<scope>` does not help either: it extends the search order, it does not
synthesise units, and FPC's RTL has no System.* tree (measured: no `System`
directory under units/x86_64-win64).

That leaves the second fallback, and this tool is what makes it safe: the change
must be per-unit and under {$IFDEF FPC}, or the Delphi build loses
`System.SysUtils` -- the canonical Delphi spelling.

Vcl.* and Winapi.* are reported but NEVER accommodated: those are exactly the
dependencies F3 exists to remove, and aliasing them would hide the coupling.

Run:  python tools/fpc_dialect_scan.py [--preview]
Exit: 0 when every FPC-facing unit is dialect-clean; 1 otherwise.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

# Directories the FPC core test links. Keep in step with the $units list in
# tools/build_fpc_core.ps1 -- two lists that drift is one more thing to get wrong.
FPC_DIRS = [
    SOURCE / "Core",
    SOURCE / "Debugger" / "GDB",
    SOURCE / "LSP" / "JsonRpc",
    SOURCE / "LSP" / "Transport",
    SOURCE / "LSP" / "Process",
    SOURCE / "Toolchain",
]

# Dotted name -> what FPC should be given instead.
#
# The `System.*` half is measured, not assumed. The first real compile of this
# project (2026-10-05, FPC 3.2.2, Lazarus 4.4 -- the first time a compiler had
# ever run here) failed with
#
#     Core.Events.pas(25,3) Fatal: Can't find unit System.SysUtils
#
# and the plan's suggested fix -- an alias shim -- is IMPOSSIBLE, not merely
# awkward. FPC rejects a unit whose NAME contains a dot:
#
#     Error: Illegal unit name: System.SysUtils (expecting SYSUTILS)
#
# Two layouts were built and both failed for that one reason: a flat file gave
# `Fatal: I/O error: File not open`, and the correct nested layout
# (fpc_alias/System/SysUtils.pas) gave the error above. `-FN<scope>` does not
# help either: it extends the search order, it does not synthesise units, and
# FPC's RTL has no `System` directory at all.
#
# The `LSP.*` half is a CASE mismatch found by the same compile: the .lpr says
# LSP.JsonRpc while the unit declares Lsp.JsonRpc. Windows hides this; the Linux
# CI job would not have.
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
    "LSP.JsonRpc": "Lsp.JsonRpc",
    "LSP.Process": "Lsp.Process",
    "LSP.Process.Fpc": "Lsp.Process.Fpc",
    "LSP.Process.Factory": "Lsp.Process.Factory",
    "LSP.Transport": "Lsp.Transport",
}

# The FPC build mode. NOT -Mdelphi: that is Delphi 7, which has no anonymous
# methods, and Core.Events declares
#     TCompilerProgressHandler = reference to procedure(...)
# Measured: `reference to` is rejected in EVERY mode (-Mdelphi,
# -Mdelphiunicode, -Mfpc, -Mobjfpc), each also with {$modeswitch
# anonymousfunctions}, and the string `reference to` appears in NONE of the 84
# shipped RTL units. So the type was changed to a plain method pointer, spelled
# `of object` -- `of TObject` is a syntax error, because the word after `of` is
# the OBJECT keyword, not a type name.
FPC_MODE = "delphiunicode"

USES_RE = re.compile(r"^(\s*)uses\s*$", re.M)


def read(p):
    return p.read_bytes().decode("utf-8")


def units():
    out = []
    for d in FPC_DIRS:
        if d.is_dir():
            out += sorted(d.rglob("*.pas"))
    return out


def uses_segments(text):
    """Yield the body of every uses clause, up to its terminating `;`."""
    for m in USES_RE.finditer(text):
        yield text[m.end():m.end() + 500].split(";")[0]


def strip_comments(line):
    """Drop // and { } comments so a mention in prose is not a finding."""
    line = re.sub(r"//.*$", "", line)
    line = re.sub(r"\{\$.*?\}", "", line)
    line = re.sub(r"\{[^}]*\}", "", line)
    return line


def scan():
    """[(path, [(spelling, replacement)])] for units needing accommodation."""
    findings = []
    for p in units():
        text = read(p)
        hits = []
        for ns, repl in STRIP.items():
            # Only inside a uses clause. The same token in code or in a comment
            # must not be rewritten, and a bare search over the whole file would
            # rewrite both.
            if any(re.search(r"\b" + re.escape(ns) + r"\b", seg)
                   for seg in uses_segments(text)):
                hits.append((ns, repl))
        if hits:
            findings.append((p, sorted(set(hits))))
    return findings


# Anonymous-method syntax, which FPC 3.2.2 does not have at all.
#
# Measured across every mode and with {$modeswitch anonymousfunctions}: all
# rejected, and the token does not appear in any of the 84 shipped RTL units.
# A unit that reintroduces it will not compile, and the failure message names a
# line rather than the construct, so this check exists to make the cause obvious.
ANON_RE = re.compile(r"\breference\s+to\s+(?:function|procedure)\b", re.I)


def anon_findings():
    out = []
    for p in units():
        for n, line in enumerate(read(p).splitlines(), 1):
            if ANON_RE.search(strip_comments(line)):
                out.append((p, n, line.strip()))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true",
                    help="print the $IFDEF form to apply; change nothing")
    args = ap.parse_args()

    findings = scan()
    anon = anon_findings()
    vcl = set()
    for d in FPC_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.pas")):
            for m in re.finditer(r"\b((?:Vcl|Winapi)\.[A-Za-z0-9_.]+)", read(p)):
                vcl.add((p.relative_to(ROOT).as_posix(), m.group(1)))

    print("FPC DIALECT SCAN")
    print("=" * 70)
    print(f"  units in FPC scope : {len(units())}")
    print(f"  needing rewrite    : {len(findings)}")
    print(f"  anonymous methods  : {len(anon)}")
    print()
    for p, hits in findings:
        print(f"  {p.relative_to(ROOT).as_posix()}")
        for ns, repl in hits:
            print(f"      {ns:32s} -> {repl}")

    if anon:
        print()
        print("  ANONYNOUS METHODS (FPC 3.2.2 has no `reference to`):")
        for p, n, line in anon:
            print(f"      {p.relative_to(ROOT).as_posix()}:{n}  {line[:56]}")

    if vcl:
        print()
        print(f"  VCL/Win32 REFERENCES IN FPC SCOPE ({len(vcl)}) -- NOT accommodated")
        for rel, tok in sorted(vcl)[:14]:
            print(f"      {rel}: {tok}")
        print("      These are what F3 has to remove. Aliasing them would hide the")
        print("      coupling rather than surface it.")
    print()

    if args.preview:
        print("THE REWRITE (per uses clause; NOT applied here)")
        print("-" * 70)
        for p, hits in findings:
            print(f"  {p.relative_to(ROOT).as_posix()}")
            print("      {$IFDEF FPC}")
            for _ns, repl in hits:
                print(f"      uses {repl};")
            print("      {$ELSE}")
            for ns, _repl in hits:
                print(f"      uses {ns};")
            print("      {$ENDIF}")
        print()
        print("  Applied by hand, per unit. A regex across a MULTI-LINE uses clause")
        print("  is exactly the transform that silently drops a unit name, and the")
        print("  resulting file then fails on a MISSING unit rather than a typo.")
        return 0

    if findings or anon:
        print(f"  {len(findings)} unit(s) with Delphi-only names, "
              f"{len(anon)} anonymous method(s).")
        return 1
    print("  PASS -- every FPC-facing unit is dialect-clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())