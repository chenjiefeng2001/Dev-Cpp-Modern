#!/usr/bin/env python3
r"""Measure EXACTLY what the proposed _MAINFORM_REF fix would do.

The F1-l notes flagged a contradiction: `_MAINFORM_OWNER` excludes
`(?<!Application\.)` because "Application.MainForm is the VCL property, not our
god form", while `_MAINFORM_REF` has no such exclusion and is case-sensitive.
The plan predicted the fix would move the headline 51 -> 52. Predictions are
not measurements, so this computes the real number before anyone edits the
ratchet -- and it reports the counts per file, not just a total, so a surprise
can be traced to a specific line.

Run from any directory:
    python tools/regex_impact.py            # dry analysis, touches nothing
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

CURRENT = re.compile(r"\bMainForm\s*\.")
FIXED = re.compile(r"(?<!Application\.)\bMainForm\s*\.", re.IGNORECASE)


def strip_noise(text):
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"'[^'\n]*'", "''", text)
    return text


def main():
    rows = []
    for p in sorted(SOURCE.rglob("*.pas")):
        rel = p.relative_to(ROOT).as_posix()
        if rel.startswith("Source/VCL/"):
            continue
        raw = p.read_bytes()
        text = strip_noise(raw.decode("utf-8-sig"
                                     if raw.startswith(b"\xef\xbb\xbf")
                                     else "utf-8", errors="replace"))
        a = len(CURRENT.findall(text))
        b = len(FIXED.findall(text))
        if a or b:
            rows.append((rel, a, b))

    print("%-42s %6s %6s %7s" % ("file", "now", "fixed", "delta"))
    print("-" * 66)
    tot_a = tot_b = 0
    for rel, a, b in rows:
        d = b - a
        mark = "" if d == 0 else ("  <-- %+d" % d)
        print("%-42s %6d %6d %7s%s" % (rel, a, b, ("%+d" % d) if d else "0", mark))
        tot_a += a
        tot_b += b
    print("-" * 66)
    print("%-42s %6d %6d %+7d" % ("TOTAL", tot_a, tot_b, tot_b - tot_a))
    print("\nAnalysis: a NEGATIVE delta means the fix stops counting VCL"
          "\n`Application.MainForm` uses (they reach the same object by another"
          "\nname, which is the honest reading).  A POSITIVE delta means it"
          "\nstarts catching lowercase spellings the old regex missed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
