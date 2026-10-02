#!/usr/bin/env python3
"""Regenerate tools/mainform_baseline.json (the F1 decoupling ratchet).

Usage:
    python tools/mainform_baseline.py            # refresh the baseline
    python tools/mainform_baseline.py --check    # report drift, do not write

Run this ONLY right after intentionally decoupling a unit, and review the
diff: the ratchet is the mechanism that keeps main.pas from re-gaining
coupling. Never raise a cap to make the gate green.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_scope  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
OUT = ROOT / "tools" / "mainform_baseline.json"
VENDORED_PREFIXES = ("FastMM",)

# Sanctioned anti-corruption layers: the ONLY units allowed to reference
# MainForm.* / `uses main`. Each entry is a future migration seam, so keep the
# list minimal and prefer semantic entry points over widget access.
FACADES = ("Source/UI/MainUi.pas",)

# The god form defines the coupling, so its own `MainForm.` uses are Self
# references, not consumers. Exempt on the same logic as FACADES above --
# see scan_scope.GOD_FORM for why this is an exemption and not a rewrite.
SELF_OWNED = (scan_scope.GOD_FORM,)

# `Application.MainForm` is a VCL property, not this project's own global, and
# it needs no `uses main` to compile -- so it is excluded, exactly as
# _MAINFORM_OWNER already excludes it below. The two dimensions disagreed: the
# owner regex carried this exclusion and a comment explaining it, while the ref
# regex did not, so `Utils.pas` had two `Application.MainForm.Handle` uses that
# the ref count charged and the owner count ignored.
#
# IGNORECASE closes the same hole from the other side: `Application.mainform`
# (all lowercase) is the same property spelled differently, and a case-sensitive
# pattern simply missed it. tools/regex_impact.py measures the exact delta
# before and after this change; today IGNORECASE alone accounts for 0 refs
# because every lowercase site was already migrated, and the -2 comes entirely
# from the exclusion.
_MAINFORM_REF = re.compile(r"(?<!Application\.)\bMainForm\s*\.", re.IGNORECASE)
# A bare `MainForm` (dialog owner, no member access) is a distinct coupling
# shape that _MAINFORM_REF cannot see. It is ratcheted separately so that
# closing the `MainForm.` leaks never inflates or hides this one.
# `Application.MainForm` is the VCL property, not our god form.
_MAINFORM_OWNER = re.compile(r"(?<!Application\.)\bMainForm\b(?!\s*\.\s*\w)")
# A unit that declares the global itself owns it: the real main.pas, plus the
# same-named-but-unrelated Tools/PackMaker/main.pas and Tools/Packman/Main.pas.
_MAINFORM_DECL = re.compile(r"(?mi)^\s*MainForm\s*:\s*\w")
_USES_MAIN = re.compile(r"(?ims)^\s*uses\b[^;]*?\bmain\b[^;]*;")
# Comment/string stripping now lives in scan_scope.strip_pascal_code. The three
# private copies this file, qa_check and (briefly) comment_bleed each grew were
# all the same wrong regex: `\{[^}]*\}` stops at the first closing brace, so a
# whole routine wrapped in `{ ... }` was only partly removed and the remainder
# was scanned as live code. See scan_scope for the full account.
strip_noise = scan_scope.strip_pascal_code


def scan():
    refs, uses, owners = {}, {}, {}
    for p in sorted(SOURCE.rglob("*.pas")):
        rel = p.relative_to(ROOT).as_posix()
        if scan_scope.is_excluded(rel) or p.name.startswith(VENDORED_PREFIXES):
            continue
        # The god form's own `MainForm.` uses are Self references. Excluding
        # the file at scan time (rather than at each of the eight accounting
        # sites below) means no future statistic can forget the exemption.
        if rel in SELF_OWNED:
            continue
        text = p.read_text(encoding="utf-8-sig", errors="replace")
        # ONE call for the whole file, not one per line: comment depth has to be
        # carried across line boundaries or a `{` on its own line never closes.
        code = strip_noise(text)
        n = len(_MAINFORM_REF.findall(code))
        if n:
            refs[rel] = n
        if _USES_MAIN.search(text):
            uses[rel] = True
        # a unit that declares the global owns it -- not a leak
        if not _MAINFORM_DECL.search(
                re.split(r"(?mi)^\s*implementation\s*$", text)[0]):
            o = len(_MAINFORM_OWNER.findall(code))
            if o:
                owners[rel] = o
    return refs, uses, owners


def main(argv):
    refs, uses, owners = scan()
    total = sum(v for k, v in refs.items() if k not in FACADES)
    if "--check" in argv:
        if not OUT.exists():
            print("missing baseline: %s" % OUT)
            return 1
        old = json.loads(OUT.read_text(encoding="utf-8"))
        grew = []
        for rel, n in refs.items():
            if rel in FACADES:
                continue  # sanctioned anti-corruption layer
            cap = old.get("refs", {}).get(rel)
            if cap is None or n > cap:
                grew.append((rel, cap, n))
        for rel, n in owners.items():
            if rel in FACADES:
                continue
            cap = old.get("owner_refs", {}).get(rel)
            if cap is None or n > cap:
                grew.append((rel + " [owner]", cap, n))
        new_uses = [rel for rel in uses if rel not in FACADES]
        print("refs: %d (baseline %d); uses main: %d (baseline %d); "
              "owner: %d (baseline %d); facade: %d in %d unit(s); violations: %d"
              % (total, sum(old.get("refs", {}).values()), len(new_uses),
                 len(old.get("uses_main", {})),
                 sum(v for k, v in owners.items() if k not in FACADES),
                 sum(old.get("owner_refs", {}).values()),
                 sum(v for k, v in refs.items() if k in FACADES),
                 len(FACADES), len(grew)))
        for rel, cap, n in grew:
            print("  GREW %s: %s -> %d" % (rel, cap, n))
        return 1 if grew else 0

    data = {
        "_comment": ("F1 decoupling ratchet. Regenerate with "
                     "`python tools/mainform_baseline.py` after a unit is "
                     "intentionally decoupled. Caps must never be raised."),
        "_facade": ("Sanctioned anti-corruption layers: the only units allowed "
                    "to reference MainForm.*. Keep the list as short as "
                    "possible -- every entry is a future migration seam."),
        "_owner_refs": ("Bare `MainForm` used as a dialog owner (no member "
                        "access). Invisible to the `refs` regex, fatal to the "
                        "build once `main` leaves the uses clause."),
        "measured": "2026-09-27",
        "total_refs": sum(v for k, v in refs.items() if k not in FACADES),
        "facade_refs": sum(v for k, v in refs.items() if k in FACADES),
        "facade": list(FACADES),
        "refs": {k: v for k, v in sorted(refs.items(), key=lambda kv: -kv[1])
                 if k not in FACADES},
        "owner_refs": {k: v for k, v in sorted(owners.items(),
                                               key=lambda kv: -kv[1])
                       if k not in FACADES},
        "uses_main": {rel: True for rel in sorted(uses)
                      if rel not in FACADES},
    }
    # Facades are exempt: MainUi legitimately names `main` in its implementation
    # uses -- that is the anti-corruption layer doing its job, not a leak.
    real_uses = [rel for rel in uses if rel not in FACADES]
    OUT.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print("wrote %s: %d refs across %d files, %d `uses main` units, "
          "%d bare-owner refs"
          % (OUT.relative_to(ROOT), total, len(refs), len(real_uses),
             sum(v for k, v in owners.items() if k not in FACADES)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
