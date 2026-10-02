#!/usr/bin/env python3
"""Audit every `uses main` unit: can this one drop the god-form unit?

Usage:
    python tools/uses_main_audit.py            # all units in the baseline list
    python tools/uses_main_audit.py --all      # every unit with a `uses main`
    python tools/uses_main_audit.py Source/LangFrm.pas

Two independent questions are asked per unit, because they fail differently:

1. Does it still *name* something main.pas owns?  -- tools/main_symbols.py
   Catches `MainForm`, `TMainForm`, and any other unit-scope export.

2. Did it silently inherit a symbol from a unit that was only reachable
   *through* main.pas?  Delphi's transitive visibility means dropping `main`
   also drops every symbol those units published. This is the failure mode that
   compiles nowhere near the edit, so it gets its own reachability diff.

A unit is reported SAFE only when both answers are empty. Nothing is ever
rewritten here -- this tool exists to make the decision mechanical before
anyone touches a uses clause.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_symbols as ms  # noqa: E402
import scan_scope  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Source"
BASELINE = ROOT / "tools" / "mainform_baseline.json"


def _facades():
    """Mirror the `facade` list in mainform_baseline.py.

    Read from the baseline rather than re-declared, so the two cannot drift.
    """
    try:
        return set(json.loads(
            BASELINE.read_text(encoding="utf-8")).get("facade", ()))
    except (OSError, ValueError):
        return {"Source/UI/MainUi.pas"}


FACADES = _facades()

_USES = re.compile(r"(?ims)^\s*uses\b[^;]*?\bmain\b[^;]*;")
_OWN_DECL = re.compile(
    r"(?m)^\s*(\w+)\s*(?::\s*\w+)?=\s*(?:packed\s+|strict\s+)*"
    r"(?:class|record|object|interface)\b"
    r"|^\s*(?:function|procedure|constructor|destructor)\s+(\w+)\b"
    r"|^\s*(\w+)\s*=\s*(?:\(\s*)?(?:strict\s+)?(?:private\s+)?enum\b"
    r"|^\s*(\w+)\s*:\s*\w")


def index_source_units():
    index = {}
    for p in sorted(SRC.rglob("*.pas")):
        if scan_scope.is_excluded(p.relative_to(ROOT).as_posix()):
            continue
        if p.name.startswith("FastMM"):
            continue
        rel = p.relative_to(SRC).with_suffix("").as_posix().lower()
        index.setdefault(rel, p)
    return index


def units_of(path):
    """Every unit named in any uses clause of `path`, lowercased."""
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    names = set()
    for chunk in re.findall(r"(?ims)^uses\b(.*?);", text):
        chunk = re.sub(r"//[^\n]*", "", chunk)
        for name in chunk.replace("\r", "").split(","):
            name = name.strip().lower()
            if name:
                names.add(name)
    return names


def own_declarations(path):
    text = ms.strip_noise(
        path.read_text(encoding="utf-8-sig", errors="replace"))
    names = ms.unit_scope_symbols(text)
    for m in _OWN_DECL.finditer(text):
        names.update(g for g in m.groups() if g)
    return names


def audit(path, index):
    syms = ms.unit_scope_symbols(
        (SRC / "main.pas").read_text(encoding="utf-8-sig", errors="replace"))
    used = ms.referenced(path)
    own = own_declarations(path)

    direct = sorted((syms & used) - own)

    mine = units_of(path)
    lost = units_of(SRC / "main.pas") - mine - {"main"}
    transitive = {}
    for unit in sorted(lost):
        other = index.get(unit)
        if other is None or other == path:
            continue
        published = ms.unit_scope_symbols(
            other.read_text(encoding="utf-8-sig", errors="replace"))
        hit = (published & used) - own
        if hit:
            transitive[unit] = sorted(hit)
    return direct, transitive


def main(argv):
    show_all = "--all" in argv
    args = [a for a in argv if not a.startswith("--")]
    index = index_source_units()

    if args:
        targets = [(ROOT / a).resolve() for a in args]
    elif show_all:
        # The sanctioned facade legitimately keeps `uses main` -- that is what
        # makes it the anti-corruption layer. Listing it here alongside real
        # candidates made the summary count one unit more than the baseline,
        # which is the same reporting-vs-checking mismatch F1-g fixed for the
        # QA progress line. Filter it out so both tools agree on the
        # population.
        targets = [p for _, p in index.items() if _USES.search(
            p.read_text(encoding="utf-8-sig", errors="replace"))
            and p.relative_to(ROOT).as_posix() not in FACADES]
    else:
        data = json.loads(BASELINE.read_text(encoding="utf-8"))
        targets = [ROOT / rel for rel in sorted(data.get("uses_main", {}))]

    safe = unsafe = 0
    for path in targets:
        if not path.exists():
            print("missing: %s" % path)
            continue
        direct, transitive = audit(path, index)
        verdict = "SAFE" if not direct and not transitive else "BLOCKED"
        if verdict == "SAFE":
            safe += 1
        else:
            unsafe += 1
        print("%-8s %s" % (verdict, path.relative_to(ROOT).as_posix()))
        for name in direct:
            print("           names a main.pas export: %s" % name)
        for unit, hits in sorted(transitive.items()):
            print("           would lose via main: %s -> %s"
                  % (unit, ", ".join(hits)))
    print("\n%d unit(s): %d SAFE to drop `uses main`, %d blocked"
          % (safe + unsafe, safe, unsafe))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
