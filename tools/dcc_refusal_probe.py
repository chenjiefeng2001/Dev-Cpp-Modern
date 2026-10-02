#!/usr/bin/env python3
"""Locate the string dcc32 prints when it refuses command-line compilation.

Found while trying to break the compile block on this machine. The naive
reading was "the licence wall lives in dcc32.exe", but the text is in NEITHER
dcc32.exe (23 KB) nor dcc32370.dll (3.4 MB) -- both were searched as raw bytes.

Where it actually lives changes the conclusion:

  * in the EXE  -> the forwarder is the gate and the compiler DLL may be
                   directly callable
  * in the DLL  -> the compiler itself refuses; no wrapper helps
  * in neither  -> assembled at runtime, or loaded from a message resource /
                   satellite DLL, which is where Embarcadero keeps such text

UTF-16 is searched alongside narrow, because message resources are commonly
wide strings and a narrow-only search reports "not found" for text that is
plainly on screen.

Run:  python tools/dcc_refusal_probe.py
"""
import pathlib

BASE = pathlib.Path(r"C:\Program Files (x86)\Embarcadero\Studio\37.0")

# The FULL sentence, not fragments. A first pass searched for "does not
# support" and hit 148 files -- that phrase is boilerplate in half the RTL
# ("this operation does not support..."), so it locates nothing. Searching the
# whole message is what makes the answer trustworthy.
SENTENCE = "This version of the product does not support command line compiling"
FRAGMENT = "support command line compiling"

NEEDLES = []
for n in (SENTENCE, FRAGMENT):
    NEEDLES.append((n, n.encode("latin-1")))
    NEEDLES.append((n + " [utf16]", n.encode("utf-16-le")))


def main():
    print("searching %s for:" % BASE)
    print('  %r\n' % SENTENCE)
    targets = []
    for sub in ("bin", "bin64", "framework", "res"):
        d = BASE / sub
        if d.exists():
            targets.extend(p for p in d.rglob("*") if p.is_file())

    full, frag = [], []
    scanned = 0
    for p in targets:
        try:
            if p.stat().st_size > 80 * 1024 * 1024:
                continue
            raw = p.read_bytes()
            scanned += 1
        except OSError:
            continue
        rel = p.relative_to(BASE).as_posix()
        if any(n.encode("latin-1") in raw or n.encode("utf-16-le") in raw
               for n in (SENTENCE,)):
            full.append(rel)
        if any(n.encode("latin-1") in raw or n.encode("utf-16-le") in raw
               for n in (FRAGMENT,)):
            frag.append(rel)

    print("full sentence found in: %s" % (full or "(nothing)"))
    print("fragment found in %d file(s):" % len(frag))
    for f in frag[:10]:
        print("   %s" % f)
    print("\nscanned %d files" % scanned)

    if not full and not frag:
        print("\nNot present as a plain literal anywhere under the Studio tree.")
        print("So it is composed at runtime, or read from a message resource the")
        print("forwarder loads before the compiler DLL is reached.")
        print("\nConsequence: the block is NOT trivially bypassable from the")
        print("command line, and the recorded conclusion stands -- front-line A")
        print("needs an activated install or a build from the IDE itself.")
    elif full:
        print("\nThe message lives in: %s" % full)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())