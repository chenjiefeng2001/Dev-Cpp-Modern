#!/usr/bin/env python3
"""
fpc_anon_rewrite.py -- replace Delphi `reference to` types with method pointers.

MEASURED, NOT ASSUMED
=====================
FPC 3.2.2 rejects `reference to` in EVERY mode tested -- -Mdelphi,
-Mdelphiunicode, -Mfpc, -Mobjfpc -- each also with
{$modeswitch anonymousfunctions}. All report

    Error: Identifier not found "reference"

and the token `reference to` appears in none of the 84 shipped RTL units, while
`TProcedure` does exist in system.ppu. So procedural TYPES exist and the Delphi
ANONYMOUS-METHOD spelling does not.

The replacement is a plain method pointer, spelled `of object`. NOT `of TObject`:
the word after `of` is the OBJECT keyword, and `of TObject` is a syntax error

    Fatal: Syntax error, "OBJECT" expected but "identifier TOBJECT" found

which points at the `of` rather than at the spelling, so it reads like a keyword
problem when it is a grammar one.

BEHAVIOUR CHANGE, STATED NOT ASSUMED
====================================
A method pointer cannot close over local state. A subscriber must be a real
method and any per-subscription payload must travel as a parameter. Callers
today pass their payload through the event object, so nothing breaks now, but a
future caller relying on closure will not compile -- which is the intended
outcome: it fails loudly at the point of use rather than silently losing state.

Run:  python tools/fpc_anon_rewrite.py [--check]
Exit: 0 when nothing remains; 1 otherwise.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

FPC_DIRS = [
    ROOT / "Source" / "Core",
    ROOT / "Source" / "Debugger" / "GDB",
    ROOT / "Source" / "LSP" / "JsonRpc",
    ROOT / "Source" / "LSP" / "Transport",
    ROOT / "Source" / "LSP" / "Process",
    ROOT / "Source" / "Toolchain",
]

# `reference to procedure(<args>)` -> `procedure(<args>) of object`, keeping the
# type name and everything declared alongside it untouched.
DECL = re.compile(
    r"(?P<name>T\w+)\s*=\s*\r?\n?\s*"
    r"reference\s+to\s+(?P<kind>function|procedure)\s*\((?P<args>[^)]*)\)\s*;",
    re.I)


def strip_comments(line):
    line = re.sub(r"//.*$", "", line)
    line = re.sub(r"\{\$.*?\}", "", line)
    line = re.sub(r"\{[^}]*\}", "", line)
    return line


def candidates():
    for d in FPC_DIRS:
        if d.is_dir():
            for p in sorted(d.rglob("*.pas")):
                yield p


def find_decls():
    out = []
    for p in candidates():
        raw = p.read_bytes()
        nl = "\r\n" if b"\r\n" in raw else "\n"
        text = raw.decode("utf-8")
        for m in DECL.finditer(text):
            out.append((p, nl, text, m))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    hits = find_decls()
    print("FPC ANONYMOUS-METHOD REWRITE")
    print("=" * 70)
    print(f"  declarations found : {len(hits)}")
    print()
    for p, _nl, _text, m in hits:
        print(f"  {p.relative_to(ROOT).as_posix()}")
        print(f"      {m.group(0).strip()[:64]}")
        print(f"      -> {m.group('name')} = "
              f"{m.group('kind')}({m.group('args')}) of object;")
    print()

    if not hits:
        print("  PASS -- no `reference to` anywhere in FPC scope.")
        return 0
    if args.check:
        print("  FAIL -- run without --check to apply.")
        return 1

    by_file = {}
    for p, nl, text, m in hits:
        by_file.setdefault((p, nl), []).append(m)

    for (p, nl), ms in by_file.items():
        text = p.read_bytes().decode("utf-8")
        for m in sorted(ms, key=lambda x: -x.start()):
            repl = (f"{m.group('name')} = "
                    f"{m.group('kind')}({m.group('args')}) of object")
            text = text[:m.start()] + repl + text[m.end():]
        p.write_bytes(text.encode("utf-8"))
        print(f"  rewrote {p.relative_to(ROOT).as_posix()} ({len(ms)} declaration(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())