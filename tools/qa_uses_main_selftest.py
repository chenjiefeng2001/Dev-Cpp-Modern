#!/usr/bin/env python3
"""
Failability proof for qa_check.py's `uses main` ratchet.

AGENTS.md's submission rule: a gate reported as passing must come with proof
that it CAN fail, and that it fails FOR ITS OWN REASON. This breaks
ProjectOptionsFrm three ways and requires the gate to tell them apart.

  A  a real `uses main` in code      -> MUST be caught
  B  the word "main" in a uses-clause comment, and only there -> MUST pass
  C  the file as committed           -> MUST pass

WHY B EXISTS AT ALL
==================
The ratchet scans for `uses ... main ... ;`. It used to run that scan over the
RAW file text while the neighbouring MainForm-reference check ran over
comment-stripped text. The result was that prose inside a uses-clause comment
read as a live dependency: ProjectOptionsFrm failed with

    Source/ProjectOptionsFrm.pas: error: new `uses main` (F1 exit criterion is zero)

for no reason other than a comment explaining why MainUi belongs in the
IMPLEMENTATION list. That is a gate crying wolf, and a gate that cries wolf is
one nobody keeps running.

Run:  python tools/qa_uses_main_selftest.py
Exit: 0 when all three cases behave, 1 otherwise. Always restores the file.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = ROOT / "Source" / "ProjectOptionsFrm.pas"
MARKER = "  MainUi;"


def run_gate():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "qa_check.py")],
                       capture_output=True, text=True, cwd=str(ROOT))
    out = r.stdout + r.stderr
    return "new `uses main`" in out, out


def main():
    if not TARGET.is_file():
        print("SKIP: %s is not in the tree" % TARGET.name)
        return 0
    original = TARGET.read_bytes()
    text = original.decode("utf-8-sig")
    if MARKER not in text:
        print("SKIP: %s no longer has the %r anchor this test rewrites"
              % (TARGET.name, MARKER))
        return 0

    problems = []
    try:
        hit, _ = run_gate()
        print("C  committed file                     -> %s"
              % ("FALSE ALARM" if hit else "pass"))
        if hit:
            problems.append("C: the committed tree already trips the ratchet")

        TARGET.write_bytes(
            text.replace(MARKER, "  MainUi, main;", 1).encode("utf-8"))
        hit, out = run_gate()
        print("A  real `uses main` in code           -> %s"
              % ("caught" if hit else "MISSED"))
        if not hit:
            problems.append("A: a real `uses main` is not caught -- the gate is dead")
            print(out.strip()[-300:])

        TARGET.write_bytes(
            text.replace(MARKER,
                         "  // this unit reaches main, deliberately\n" + MARKER,
                         1).encode("utf-8"))
        hit, out = run_gate()
        print("B  word 'main' in a comment only      -> %s"
              % ("FALSE ALARM" if hit else "pass"))
        if hit:
            problems.append("B: prose in a comment still trips the ratchet")
            print(out.strip()[-300:])
    finally:
        TARGET.write_bytes(original)

    print()
    if problems:
        print("SELF TEST FAILED:")
        for p in problems:
            print("  - " + p)
        return 1
    print("SELF TEST OK: real coupling caught, comment-only prose ignored")
    return 0


if __name__ == "__main__":
    sys.exit(main())
