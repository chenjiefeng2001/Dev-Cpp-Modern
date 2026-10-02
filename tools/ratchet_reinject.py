#!/usr/bin/env python3
"""Prove the ratchet is still armed at the current (lower) baseline.

Usage:
    python tools/ratchet_reinject.py Source/Tests.pas
    python tools/ratchet_reinject.py Source/Editor.pas --anchor "  MainUi.RefreshAppTitle;"

Injects a single `MainForm.*` reference into an already-decoupled unit, expects
the gate to reject it, then restores the file byte-for-byte and re-checks that
the gate is green again.

Why this is a permanent tool rather than a one-off: the Tests.pas batch shipped
a migration that passed every per-pattern hit-count assertion while still
leaving a live `MainForm.*` behind -- the missed call shape had no pattern at
all, so it had no assertion either. A ratchet that has never been re-tested is
indistinguishable from a ratchet that has stopped biting, so each batch ends by
proving it still bites at the new, lower baseline.

Exit 0 = gate rejected the injection and is green again afterwards.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INJECT = b"  MainForm.EditorList.GetEditor(-1, nil);\r\n"


def run_gate():
    return subprocess.run(
        [sys.executable, str(ROOT / "tools" / "qa_check.py"),
         "--profile", "delphi"],
        capture_output=True, text=True, cwd=str(ROOT))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    target = (ROOT / args[0]).resolve()
    if not target.exists():
        print("missing unit: %s" % target)
        return 2

    # Default anchor: the first indented MainUi call in the file. Every
    # decoupled unit has one, and it is a safe place to add a line.
    anchor = None
    if "--anchor" in argv:
        anchor = argv[argv.index("--anchor") + 1].replace(
            "\n", "\r\n").encode("utf-8") + b"\r\n"
    if anchor is None:
        m = re.search(rb"(?m)^[ \t]+MainUi\.\w+[^\r\n]*\r\n",
                      target.read_bytes())
        if not m:
            print("no default anchor found; pass --anchor explicitly")
            return 2
        anchor = m.group(0)

    original = target.read_bytes()
    if anchor not in original:
        print("anchor not found in %s:\n  %r" % (target.name, anchor))
        return 2

    target.write_bytes(original.replace(anchor, anchor + INJECT, 1))
    try:
        r = run_gate()
    finally:
        target.write_bytes(original)

    print("--- gate output with 1 injected MainForm reference into %s ---"
          % target.name)
    print((r.stdout + r.stderr).strip())
    print("gate exit code with injection: %d" % r.returncode)

    if target.read_bytes() != original:
        print("!! file was not restored byte-for-byte")
        return 1
    print("file restored byte-for-byte: yes")

    after = run_gate()
    print("gate exit code after restore: %d" % after.returncode)
    ok = (r.returncode == 1) and (after.returncode == 0)
    print("RESULT: %s" % ("ratchet armed" if ok else "RATCHET NOT PROVEN"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
