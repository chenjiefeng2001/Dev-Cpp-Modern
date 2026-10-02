#!/usr/bin/env python3
"""Checks for scan_scope: the comment stripper and the two path exemptions.

The stripper matters in both directions. Wrong the safe way (keeping code it
should have dropped) only inflates a number. Wrong the dangerous way (dropping
code it should have kept) makes the ratchet blind -- and the symptom of that is
a SMALLER number, which looks like good news. The thing being replaced had
exactly that bug and it went unnoticed for a dozen batches.

Run:  python tools/_scan_scope_test.py
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scan_scope import strip_pascal_code, is_excluded, is_god_form  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

CASES = [
    ("x = 1; { a { b } c } y = 2;", ["x = 1;", "y = 2;"], ["a { b }"],
     "nested braces"),
    ("a; (* co { m } ent *) b;", ["a;", "b;"], ["co { m }"],
     "brace inside paren comment"),
    ("a; (* multi\nline { x } *) b;", ["a;", "b;"], ["multi", "line"],
     "multi-line paren"),
    # A literal is replaced by the marker '' but its CONTENT is kept, so
    # 'it''s' legitimately survives. Only the line comment must not.
    ("s := 'it''s'; // note\nt := 1;", ["s := ", "it", "t := 1;"], ["note"],
     "escaped quote + line comment"),
    ("{ whole routine disabled\n  with MainForm do begin\n  end;\n}\nafter := 1;",
     ["after := 1;"], ["MainForm", "disabled"], "the devCFG case"),
    ("'literal with { brace';\ny := 2;", ["y := 2;", "literal"], [],
     "brace inside string"),
    ("a := 1; { unterminated", ["a := 1;"], [],
     "unterminated treated as comment"),
]

ok = True
for src, keep, drop, label in CASES:
    got = strip_pascal_code(src)
    bad = []
    for k in keep:
        if k not in got:
            bad.append("LOST %r" % k)
    for d in drop:
        if d in got:
            bad.append("LEAKED %r" % d)
    if bad:
        ok = False
    print("%s %-32s -> %r" % ("OK  " if not bad else "FAIL", label, got))
    for b in bad:
        print("       %s" % b)

# path scope
bad = 0
for rel, want in [("Source/Archive/x.pas", True), ("Source/VCL/y.pas", True),
                  ("Source/Debugger.pas", False), ("Source/UI/MainUi.pas", False)]:
    got = is_excluded(rel)
    if got != want:
        bad += 1
        print("FAIL is_excluded(%s) = %s, want %s" % (rel, got, want))
if bad:
    ok = False
    print("scope prefixes FAILED (%d)" % bad)
else:
    print("OK   scope prefixes")

# God-form exemption: exactly the real main.pas and NOT the two same-named
# units that also declare a `MainForm` global. A declaration-based exemption
# would drop a real consumer along with them, which is why GOD_FORM is a path.
bad = 0
for rel, want in [("Source/main.pas", True),
                  ("Source\\main.pas", True),
                  ("Source/Tools/PackMaker/main.pas", False),
                  ("Source/Tools/Packman/Main.pas", False),
                  ("Source/Debugger.pas", False)]:
    got = is_god_form(rel)
    if got != want:
        bad += 1
        print("FAIL is_god_form(%s) = %s, want %s" % (rel, got, want))
if bad:
    ok = False
    print("god-form exemption FAILED (%d)" % bad)
else:
    print("OK   god-form exemption (incl. backslash form)")

# The exemption's premise: those three units really do declare a MainForm
# global. If that ever stops being true, GOD_FORM deserves a second look.
DECL = re.compile(r"(?mi)^\s*MainForm\s*:\s*\w+")
holders = 0
for rel in ("Source/main.pas", "Source/Tools/PackMaker/main.pas",
            "Source/Tools/Packman/Main.pas"):
    raw = (ROOT / rel).read_bytes()
    txt = ""
    for enc in ("utf-8-sig", "gbk"):
        try:
            txt = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if DECL.search(txt):
        holders += 1
    else:
        print("NOTE %s no longer declares MainForm -- review GOD_FORM" % rel)
print("OK   %d/3 known declaration-holders still declare it" % holders)

print("\nSCAN_SCOPE TEST: %s" % ("OK" if ok else "FAILED"))
sys.exit(0 if ok else 1)
