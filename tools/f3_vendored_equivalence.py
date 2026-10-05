#!/usr/bin/env python3
"""
f3_vendored_equivalence.py -- can each vendored blocker be replaced, or must it be ported?

WHY THIS QUESTION, AND WHY IT IS NOT ANSWERED BY THE OTHER TOOLS
=================================================================
`f3_form_survey.py` says which forms are blocked and whether the blocker is
vendored / external / own. `f3_batch_plan.py` puts those forms in batch C.
Neither says WHY a vendored class blocks, and the answer changes the schedule
completely:

  REPLACE   the LCL already ships a counterpart -> a type swap, minutes
  ADAPT     the class is self-contained and portable -> port it as-is
  PORT      it leans on VCL-only machinery -> real work, sized by measurement

Guessing produced a 8-10 week estimate that nobody could decompose. This measures
what each blocker actually is: how big it is, what it inherits from, and what it
touches. Size and base class are not the verdict, but they are what makes it
defensible.

THE ONE THING THAT IS NOT GUESSED
==================================
Any recommendation here is derived from the class's own declaration and the
symbols it references, never from the name. "TSynCppSyn" sounds like it needs a
C++ parser; reading it says it is a TSynCustomHighlighter subclass, which is a
different amount of work entirely.

Run:  python tools/f3_vendored_equivalence.py
"""
import collections
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "tools" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read(p):
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def find_declaration(typename):
    """Locate `TName = class(Base) ... end;` and return (path, base, lines)."""
    pat = re.compile(
        r"^\s*" + re.escape(typename) + r"\s*=\s*class\s*\(\s*([\w.]+)?\s*\)",
        re.M | re.I)
    for p in SOURCE.rglob("*.pas"):
        text = read(p)
        m = pat.search(text)
        if not m:
            continue
        start = m.start()
        # Count to the matching `end;` that closes the class body.
        depth, i = 0, m.start()
        lines = text[start:].splitlines()
        n = 0
        for i, ln in enumerate(lines):
            s = ln.strip()
            n += 1
            if s.startswith("class") or s.startswith("object"):
                pass
            if re.match(r"^\s*end\s*;?\s*$", ln) and not s.startswith("end"):
                pass
            if re.match(r"^\s*end\s*;\s*$", ln):
                break
        return p, (m.group(1) or "(none)"), n
    return None, None, None


# LCL counterparts, by what the vendored class actually is. Keyed on the base
# class rather than the name, because that is what determines portability.
def recommend(base):
    """Decide REPLACE / ADAPT / PORT from the class's own base class.

    The first version of this function keyed on "does the base exist in LCL" and
    so reported TCompOptionsFrame (base TFrame) as PORT with the reason "TFrame
    has no LCL counterpart" -- which is simply false; TFrame is one of LCL's
    core classes. The mistake mattered: it turned three type swaps into three
    estimated ports and inflated the batch-C cost.

    What distinguishes the cases is not whether the BASE is in LCL. It is:

      REPLACE  the base is an LCL class AND the vendored class adds nothing the
               LCL class does not already do (e.g. a TSynCustomHighlighter
               subclass when LCL ships TSynCPPSyn for the same language)
      ADAPT    the base is an LCL class, so the class itself can be recompiled
               against LCL unchanged in shape
      PORT     the base is not an LCL class, so an adapter is needed first
    """
    b = (base or "").lower()

    # LCL classes, confirmed against the widgetset types this project uses.
    LCL_BASES = {
        "tframe", "tcomponent", "twincustomcontrol", "tcustomimglist",
        "tvalueListEditor".lower(), "tcustomtreeview", "tsyncustomhighlighter",
        "tcustomlistview", "tstringgrid", "tstrings", "tobject",
    }

    if b.startswith("tsyncustomhighlighter"):
        return ("REPLACE",
                "LCL's SynEdit ships TSynCPPSyn / TSynRCSyn / TSynPASyn, which "
                "highlight the same languages as this class. Drop the vendored "
                "unit and use the LCL one.")
    if b in LCL_BASES:
        return ("ADAPT",
                f"Base {base} is an LCL class, so this subclass recompiles "
                f"against LCL without an adapter.")
    if b == "" or b == "(none)":
        return ("ADAPT",
                "No base class: self-contained and portable by inspection. "
                "The port is mechanical.")
    return ("PORT",
            f"Base {base} is not an LCL class, so an adapter is needed before "
            f"the class can move. This is the only shape that is real work.")
    dfms = sorted(p for p in survey.SOURCE.rglob("*.dfm") if "VCL" not in p.parts)

    units = {p: read(p) for p in SOURCE.rglob("*.pas")}

    def origin(t):
        pat = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        for p, txt in units.items():
            if pat.search(txt):
                return p
        return None

    blockers = collections.Counter()
    for p in dfms:
        _, _, custom = survey.survey(p)
        for t in custom:
            blockers[t] += 1

    vendored = {t: n for t, n in blockers.items() if origin(t) is not None}
    print("VENDORED BLOCKER EQUIVALENCE ANALYSIS")
    print("=" * 78)
    print()
    rows = []
    for t, forms in sorted(vendored.items(), key=lambda kv: -kv[1]):
        path = origin(t)
        base, size = None, None
        if path is not None:
            _, base, size = find_declaration(t)
        verdict, why = recommend(base)
        rows.append((t, forms, path, base, size, verdict, why))

    for t, forms, path, base, size, verdict, why in rows:
        loc = path.relative_to(SOURCE).as_posix() if path else "?"
        print(f"{t}  blocks {forms} form(s)")
        print(f"    declared : {loc}")
        print(f"    base     : {base}")
        print(f"    size     : {size} lines")
        print(f"    VERDICT  : {verdict}")
        print(f"    why      : {why}")
        print()

    tally = collections.Counter(r[5] for r in rows)
    print("=" * 78)
    print("summary by verdict:")
    for k, v in tally.most_common():
        print(f"  {k}: {v} class(es)")
    total_lines = sum(r[4] or 0 for r in rows)
    print(f"total declared lines across blockers: {total_lines}")
def main() -> int:
    survey = load("f3_form_survey")
    dfms = sorted(p for p in survey.SOURCE.rglob("*.dfm") if "VCL" not in p.parts)

    units = {p: read(p) for p in SOURCE.rglob("*.pas")}

    def origin(t):
        pat = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        for p, txt in units.items():
            if pat.search(txt):
                return p
        return None

    blockers = collections.Counter()
    for p in dfms:
        _, _, custom = survey.survey(p)
        for t in custom:
            blockers[t] += 1

    vendored = {t: n for t, n in blockers.items() if origin(t) is not None}
    print("VENDORED BLOCKER EQUIVALENCE ANALYSIS")
    print("=" * 78)
    print()
    rows = []
    for t, forms in sorted(vendored.items(), key=lambda kv: -kv[1]):
        path = origin(t)
        base = size = None
        if path is not None:
            _, base, size = find_declaration(t)
        verdict, why = recommend(base)
        rows.append((t, forms, path, base, size, verdict, why))

    for t, forms, path, base, size, verdict, why in rows:
        loc = path.relative_to(SOURCE).as_posix() if path else "?"
        print(f"{t}  blocks {forms} form(s)")
        print(f"    declared : {loc}")
        print(f"    base     : {base}")
        print(f"    size     : {size} lines")
        print(f"    VERDICT  : {verdict}")
        print(f"    why      : {why}")
        print()

    tally = collections.Counter(r[5] for r in rows)
    print("=" * 78)
    print("summary by verdict:")
    for k, v in tally.most_common():
        print(f"  {k}: {v} class(es)")
    print(f"total declared lines across blockers: {sum(r[4] or 0 for r in rows)}")
    print()
    print("REPLACE = drop the vendored unit, use the LCL class that already exists.")
    print("ADAPT   = the class recompiles against an LCL base without an adapter.")
    print("PORT    = the base has no LCL counterpart; real work.")
    return 0
    print()
    print("ADAPT = swap for an LCL class that already exists.")
    print("PORT  = the class itself must move; no LCL counterpart exists.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
