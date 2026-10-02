#!/usr/bin/env python3
"""F1-n step 2: route Utils.pas's two Application.MainForm uses through the facade.

WHY THIS AND NOT A TOOL FIX
----------------------------
`main_symbols.py` reports Utils.pas as still referencing MainForm, and
`uses_main_audit` calls that BLOCKED. Both are right about the text and wrong
about the meaning: the two hits are `Application.MainForm.Handle`, the VCL's own
property, which needs no `uses main` at all -- it comes from `Forms`. The
ratchet's _MAINFORM_REF excludes it on purpose; main_symbols never got the same
exclusion.

Silencing main_symbols would make the tool agree with itself and leave the unit
still `uses main` for a unit it does not really depend on. The honest fix is the
one that removes the edge: `MainUi.MainFormHandle` already exists from F1-l and
returns the same handle, deliberately without an Assigned guard so the
failure mode stays identical.

The `uses` clause therefore loses `main` as a real consequence, not as a
cosmetic edit -- which is what makes this plan B rather than plan A.

Usage:  python tools/_f1n2_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UTILS = ROOT / "Source" / "Utils.pas"
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    raw = path.read_bytes()
    return raw.decode("utf-8-sig" if raw.startswith(b"\xef\xbb\xbf")
                      else "utf-8", errors="replace")


def edit(path, rules, uses=None):
    eol = eol_of(path)
    text = read_raw(path)
    plan = []
    for old, new, want in rules:
        o, n = old.replace("\n", eol), new.replace("\n", eol)
        got = text.count(o)
        if got != want:
            print("  ABORT %s: pattern hit %d, expected %d\n    %r"
                  % (path.name, got, want, old.strip()[:90]))
            return False
        plan.append((o, n))
    if uses:
        o, n = uses
        o, n = o.replace("\n", eol), n.replace("\n", eol)
        if text.count(o) != 1:
            print("  ABORT %s: uses anchor hit %d, expected 1"
                  % (path.name, text.count(o)))
            return False
        plan.append((o, n))
    for o, n in plan:
        text = text.replace(o, n)
    if DRY:
        print("  DRY  %s: %d rule(s) ok" % (path.name, len(plan)))
        return True
    path.write_bytes(text.encode("utf-8"))
    print("  OK   %s: %d rule(s) applied" % (path.name, len(plan)))
    return True


# Two call sites, one shape, distinguished by the ShellExecute verb they pass.
# Separate rules on purpose: these are two separate public functions
# (ExecuteFile / ExecuteFileAsAdmin) and a merged pattern would couple them.
UTILS_RULES = [
    ("  Result := ShellExecute(Application.MainForm.Handle, nil,\n",
     "  Result := ShellExecute(MainUi.MainFormHandle, nil,\n", 1),
    ("  Result := ShellExecute(Application.MainForm.Handle, 'runas',\n",
     "  Result := ShellExecute(MainUi.MainFormHandle, 'runas',\n", 1),
]

# `main` is ALREADY gone from the uses clause: step 1 removed it, because the
# only reason Utils.pas named main was these two Application.MainForm reads,
# and step 1's other three couplings went through MainUi too. So there is no
# uses clause to edit here -- only the two call sites. The audit will confirm
# `uses main` drops 3 -> 2 on its own.
UTILS_USES_OLD = None
UTILS_USES_NEW = None


def main():
    print("F1-n step 2 migration %s" % ("(dry run)" if DRY else ""))
    if not edit(UTILS, UTILS_RULES):
        print("BATCH ABORTED -- Utils.pas untouched.")
        return 1
    print("all 1 file(s) written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())