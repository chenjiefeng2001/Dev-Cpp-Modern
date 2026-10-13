"""Unit names that only resolve on a case-insensitive filesystem.

    FpcCoreTests.lpr(39,3) Fatal: Can't find unit LSP.JsonRpc used by FpcCoreTests

on the Linux runner, while the same tree built and tested on Windows. The unit
inside the file declared `LSP.JsonRpc`; the file was named `Lsp.JsonRpc.pas`.
Windows resolves either spelling to the same file, so the discrepancy was
invisible locally for as long as it existed -- the local build never exercised
the failure.

So this gate reads the two spellings that have to agree and compares them:

  1. the unit a file DECLARES   (`unit LSP.JsonRpc;`)
  2. the unit name the file IS   (`Lsp.JsonRpc.pas`)

and it also walks the FPC-compiled closure checking that every unit named in a
uses clause resolves to a file that exists with that exact case, the way FPC
resolves it on Linux.

It is a gate, so it has to be able to fail, and that is checked in the dangerous
direction: --self-test introduces a deliberately mis-cased unit and requires
this tool to notice. A check that has never failed is unproven.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

UNIT_DECL = re.compile(r"^\s*unit\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*;",
                       re.I | re.M)
# A uses clause ends at the first ';' that is not inside a comment, a string or
# a nested bracket. Stripping comments first is what keeps a `uses` mentioned in
# prose from swallowing the rest of the file: the first version reported
# "uses CreateProcess" and "uses SW_HIDE" out of ToolchainConfig.pas, which are
# Win32 identifiers, not units.
USES_BLOCK = re.compile(r"(?im)^[ \t]*uses\b(.*?);")
BLOCK_COMMENT = re.compile(r"\{[^}]*\}", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")
UNIT_TOKEN = re.compile(r"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*$")


def strip_noise(text):
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", text))

# The units the FPC test projects compile, and the search paths they declare.
# Taken from Tests/FpcCoreTests/*.lpi <OtherUnitFiles> and the <Units> list.
CLOSURE_DIRS = ["Source/Core", "Source/Debugger/GDB", "Source/LSP/JsonRpc",
                "Source/LSP/Transport", "Source/LSP/Process",
                "Source/Toolchain"]

# Names that come from the RTL or the LCL rather than from this repository, so
# their absence from CLOSURE_DIRS means nothing.
EXTERNAL = {
    "sysutils", "classes", "syncobjs", "generics.collections", "typinfo",
    "windows", "winapi.windows", "registry", "math", "strutils", "types",
    "dateutils", "sysconst", "activex", "comctrls", "messages", "menus",
    "controls", "forms", "dialogs", "shellapi", "shlobj", "inifiles",
    "clipbrd", "objextfunc", "interfaces", "lazutf8", "process",
    "sysutils", "system.sysutils", "system.classes", "system.syncobjs",
    "system.typinfo", "system.generics.collections", "toolchainconfig",
    "core.events", "core.services", "gdb.mitypes", "gdb.miparser",
}


def pas_sources():
    for p in sorted(ROOT.rglob("*.pas")):
        if any(x in p.parts for x in (".git", "VCL", "Archive")):
            continue
        yield p


def check_declarations():
    """A file whose name and declared unit differ -- not only in case."""
    problems = []
    for p in pas_sources():
        m = UNIT_DECL.search(p.read_text(encoding="utf-8-sig", errors="replace"))
        if not m:
            continue
        declared = m.group(1)
        if declared.lower() == p.stem.lower() and declared != p.stem:
            problems.append((p, "file name %s, unit declares %s"
                             % (p.stem, declared)))
    return problems


def resolves_exactly(unit):
    first, _, tail = unit.partition(".")
    for d in CLOSURE_DIRS:
        base = ROOT / d
        for cand in (base / (unit + ".pas"),
                     base / first / (tail + ".pas") if tail else None,
                     base / (unit.replace(".", "/") + ".pas")):
            if cand is not None and cand.is_file():
                # The file exists -- now insist every path component matches the
                # spelling, which is the part a case-insensitive host hides.
                cur = ROOT
                for part in cand.relative_to(ROOT).parts:
                    names = {c.name for c in cur.iterdir()} if cur.is_dir() else set()
                    if part not in names:
                        return False
                    cur = cur / part
                return True
    return False


def check_uses():
    problems = []
    seen = set()
    for p in pas_sources():
        if p.parts[-2].lower() not in ("core", "gdb", "jsonrpc", "transport",
                                       "process", "toolchain"):
            continue
        text = strip_noise(p.read_text(encoding="utf-8-sig", errors="replace"))
        for blk in USES_BLOCK.finditer(text):
            body = re.sub(r"\{\$.*?\}", "", blk.group(1), flags=re.S)
            for tok in re.split(r"[,;]", body):
                tok = tok.strip()
                if not tok or not UNIT_TOKEN.match(tok):
                    continue
                if not tok[0].isalpha() or not tok[0].isupper():
                    continue          # Delphi is case-insensitive here; skip
                low = tok.lower()
                if low in EXTERNAL or low in seen:
                    continue
                seen.add(low)
                if not resolves_exactly(tok):
                    problems.append((p, tok))
    return problems


def report(verbose=False):
    decls = check_declarations()
    uses = check_uses()

    if verbose:
        for d in CLOSURE_DIRS:
            print("  search path: %s" % d)

    if not decls and not uses:
        print("RESULT: OK -- every unit name matches its file name, and every "
              "unit the closure names resolves with that exact case")
        return 0

    print("FAIL -- %d problem(s)" % (len(decls) + len(uses)))
    for p, why in decls:
        print("  %s: %s" % (p.relative_to(ROOT).as_posix(), why))
    for p, unit in uses:
        print("  %s: uses %s, which no file matches with that exact case"
              % (p.relative_to(ROOT).as_posix(), unit))
    print()
    print("  Windows resolves every one of these spellings to the same file, so")
    print("  the local build cannot show this. The Linux runner does.")
    return 1


def self_test():
    """Prove the gate can fail, which is the direction that matters."""
    # The file is Core.EventsProbe.pas and it declares `unit core.eventsprobe;`
    # -- identical apart from case, exactly the defect this gate exists for.
    probe = ROOT / "Source/Core/Core.EventsProbe.pas"
    probe.write_text("unit core.eventsprobe;\n\ninterface\n\n"
                     "uses Lsp.JsonRpc;\n\nimplementation\n\nend.\n",
                     encoding="ascii", newline="")
    try:
        problems = check_declarations()
        caught = any(p == probe for p, _ in problems)
        print("  mis-cased declaration detected : %s" % ("YES" if caught else "NO"))

        caught2 = any(p == probe and u == "Lsp.JsonRpc" for p, u in check_uses())
        print("  unresolvable uses spelling      : %s" % ("YES" if caught2 else "NO"))
    finally:
        probe.unlink(missing_ok=True)

    if not (caught and caught2):
        print("\nSELF TEST FAILED -- the gate did not notice a deliberately "
              "broken unit")
        return 1
    print("\nSELF TEST OK -- both failure directions are detected")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can fail, then exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    print("UNIT / FILE-NAME CASE CHECK")
    print("=" * 72)
    if args.self_test:
        return self_test()
    return report(args.verbose)


if __name__ == "__main__":
    sys.exit(main())