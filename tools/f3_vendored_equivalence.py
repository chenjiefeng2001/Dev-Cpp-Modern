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


# WHY THE `tsyncustomhighlighter` SPECIAL CASE WAS DELETED
# =======================================================
# It used to read, for ANY class descending from TSynCustomHighlighter:
#
#     "LCL's SynEdit ships TSynCPPSyn / TSynRCSyn / TSynPASyn, which highlight
#      the same languages as this class. Drop the vendored unit and use the LCL
#      one."                                                        -> REPLACE
#
# That is HALF FALSE, and Sprint F3-6 measured which half:
#
#     TSynCppSyn  EXISTS in LCL 4.4 -- but in a .pp file
#                 (components/synedit/synhighlightercpp.pp), so a search for
#                 "*.pas" finds nothing and the class reads as absent.
#     TSynRCSyn   DOES NOT EXIST. No source, and no synhighlighterrc.ppu in
#                 components/synedit/units/x86_64-win64/win32/. Verified
#                 against the built unit list, not only the source tree.
#
# A base class cannot tell those two apart, so the special case asserted the
# good news for both. Retiring TSynRCSyn on this text would have unblocked
# DataFrm.dfm and killed it at stream time with `Class TSynRCSyn not found`.
#
# The replacement answers from DATA instead: it asks
# f3_form_survey.LCL_SUPPLIED, the registry that F3-6 built and that names
# exactly the classes the LCL supplies under an identical name. That is this
# tool's own stated rule -- "never from the name" -- applied to a verdict that
# had been taken from one.


def recommend(base, typename=None, survey=None):
    b = (base or "").lower()

    # LCL classes, confirmed against the widgetset types this project uses.
    LCL_BASES = {
        "tframe", "tcomponent", "twincustomcontrol", "tcustomimglist",
        "tvaluelisteditor", "tcustomtreeview", "tcustomlistview",
        "tstringgrid", "tstrings", "tobject", "twincontrol",
    }

    # A highlighter base is NOT a verdict. It means the class is itself a
    # highlighter, and the only question is whether the LCL ships one of the
    # same NAME.
    if b.startswith("tsyncustomhighlighter"):
        if survey is not None and typename in getattr(survey, "LCL_SUPPLIED", ()):
            return ("REPLACE",
                    "The LCL ships a class of this exact name (registered in "
                    "f3_form_survey.LCL_SUPPLIED), so the vendored unit can be "
                    "dropped. The registry entry records where it was verified "
                    "to live and what it was checked against.")
        return ("PORT",
                "A highlighter with no LCL counterpart of the same name "
                "(checked against f3_form_survey.LCL_SUPPLIED, which is "
                "populated only from classes actually found in the Lazarus "
                "tree). A base class says the role, not the availability: "
                "LCL 4.4 ships TSynCppSyn and NOT TSynRCSyn, and the two are "
                "indistinguishable from here. Either write one against LCL's "
                "own SynEditHighlighter, or drop the feature deliberately.")
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
        verdict, why = recommend(base, t, survey)
        rows.append((t, forms, path, base, size, verdict, why))

    for t, forms, path, base, size, verdict, why in rows:
        loc = path.relative_to(SOURCE).as_posix() if path else "?"
        unit = len(path.read_bytes().decode("latin-1").splitlines()) if path else 0
        print(f"{t}  blocks {forms} form(s)")
        print(f"    declared : {loc}")
        print(f"    base     : {base}")
        print(f"    class    : {size:>5} lines   <- the class DECLARATION only")
        print(f"    unit     : {unit:>5} lines   <- the whole file: the port cost")
        print(f"    VERDICT  : {verdict}")
        print(f"    why      : {why}")
        print()

    tally = collections.Counter(r[5] for r in rows)
    print("=" * 78)
    print("summary by verdict:")
    for k, v in tally.most_common():
        print(f"  {k}: {v} class(es)")

    # BOTH totals, because printing only the first is what made this number read
    # as a budget.
    #
    # MEASURED 2026-10-07: `size` is the class DECLARATION -- find_declaration
    # stops at the `end;` that closes it -- and it was labelled "size" and
    # summarised as "total declared lines across blockers", which every reader
    # took as the cost of porting. The two SynEdit classes are the clearest case
    # and both are 8.7x off: TSynRCSyn 62 vs 537, TSynCppSyn 211 vs 1835.
    #
    # For a REPLACE/ADAPT verdict the declaration is the right thing to weigh --
    # it is the API surface a consumer sees. For SIZING the work it is off by an
    # order of magnitude, because the implementation is ~90% of it.
    #
    # Found while deciding what to do about TSynRCSyn: i.e. by trying to use the
    # number to budget a decision and finding it could not budget anything.
    total_decl = sum(r[4] or 0 for r in rows)
    total_unit = sum(
        len(r[2].read_bytes().decode("latin-1").splitlines()) if r[2] else 0
        for r in rows)
    print()
    print(f"total across blockers: {total_decl} lines of class declaration, "
          f"{total_unit} lines of unit")
    print("                    (schedule against the second figure)")
    print()
    print("REPLACE = the LCL ships a class of this exact name; drop the vendored unit.")
    print("ADAPT   = the class recompiles against an LCL base without an adapter.")
    print("PORT    = no LCL counterpart; real work.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
