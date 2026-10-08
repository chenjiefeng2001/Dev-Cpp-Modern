#!/usr/bin/env python3
"""
f3_retirement_check.py -- one retirement set, one home, and proof the tools use it.

WHY THIS FILE EXISTS
====================
Two tools answer "which forms are still blocked", and for most of 2026-10 they
answered differently on the SAME tree:

    f3_load_routes.py    subtracted a local RETIRED set and called
                         LangFrm / EnviroFrm CLEARED.
    f3_batch_plan.py     had no retirement set at all and put them in
                         "BATCH B, blocked by TVirtualImage" -- a class F3-3 had
                         already replaced with TLclVirtualImage and load-tested
                         through ImgCollProbe.

That is this project's most frequent structural failure: ONE FACT, TWO
HAND-MAINTAINED COPIES. Its standing remedy is "a single definition, so 'this
tool added it and that one forgot' is impossible". This gate is that remedy,
enforced rather than merely written down.

THE THREE THINGS IT CHECKS
==========================
  1. NOBODY RE-FORKS THE SET. A text scan over tools/*.py for a second
     `*RETIRED = {` literal. The definition in f3_form_survey.py is the only
     one allowed. This is the check that matters most, because the fork is
     what caused the disagreement: it is invisible until two tools are run.

  2. THE TWO INSTRUMENTS AGREE. Re-derives both verdicts from the imported
     modules -- never by reimplementing them, since a check that reimplements
     the thing it audits can agree with it while both are wrong -- and requires
     that no form the route tool calls CLEARED is batched B or C.

  3. EVERY CONVERTER RENAME IS ACCOUNTED FOR. The converse of the retirement
     set, and the one that catches a NEW hole: if `f3_dfm_to_lfm.CLASS_RENAME`
     renames a class away, some tool must record that retirement. A rename with
     no retirement entry means the converter does something the roadmap tools
     do not know about, which is precisely how the two instruments drift apart
     in the first place.

WHY 3 IS NOT TRIVIALLY TRUE
===========================
Checking "every retired class is in CLASS_RENAME" would be vacuous -- CLASS_RENAME
is the smaller set, and the assertion only says the two lists overlap. Checking
the REVERSE direction is the one with teeth: a rename the retirement set has
never heard of.

ANTl-IDLE
=========
`--self-test` feeds each check a deliberately broken world and requires it to
fail. A gate that has only ever printed OK is not evidence of anything; this
project has been bitten by that four times (the SVG extractor that lost 12x of
its data, a control whose LoadSvgLists loaded nothing, an .lfm set whose header
made every file unreadable, and a TBitmap.Assign that rejected a decoded PNG).

Run:  python tools/f3_retirement_check.py
Exit: 0 = consistent. 1 = inconsistent. 2 = self-test failed.
"""
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"

# The files allowed to contain a retirement-set literal.
DEFINITION_SITE = "f3_form_survey.py"
SELF = pathlib.Path(__file__).name

# A second definition looks like `FOO_RETIRED = {` or `RETIRED = {`. The
# definition site declares `RETIRED` with an inline dict and a docstring; every
# other occurrence of the pattern is a fork.
FORK_RE = re.compile(r"^\s*(?:[A-Z][A-Z0-9_]*_)?RETIRED\s*(?::[^=\n]+)?=\s*[\{\(]",
                     re.M)

# Forms whose status the retirements decided. Chosen because each one was
# actively mis-reported at some point: LangFrm/EnviroFrm by the missing
# subtraction, CompOptionsFrm/ProjectOptionsFrm by the frame-port, and
# EditorOptFrm by the LCL-supplied highlighter.
WATCH = [
    "LangFrm.dfm",
    "EnviroFrm.dfm",
    "CompOptionsFrm.dfm",
    "ProjectOptionsFrm.dfm",
    "EditorOptFrm.dfm",
    # Not CLEARED, and must stay that way -- a retirement for any of these would
    # be an invented clearance rather than a resolved blocker.
    "DataFrm.dfm",
    "Tools/Packman/Main.dfm",
    "main.dfm",
]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_forks():
    """(file, line number, text) for every second copy of a retirement set."""
    hits = []
    for p in sorted(TOOLS.glob("*.py")):
        if p.name in (DEFINITION_SITE, SELF):
            continue
        text = p.read_bytes().decode("utf-8", errors="replace")
        for m in FORK_RE.finditer(text):
            line = text[:m.start()].count("\n") + 1
            hits.append((p.name, line, m.group(0).strip()))
    return hits


def route_verdicts(survey, routes):
    """CLEARED / BLOCKED per converted form, straight from the route tool."""
    out = {}
    for src in sorted(routes.converted_forms()):
        dfm = ROOT / "Source" / src
        if not dfm.is_file():
            continue
        if not survey.SVG_USE_RE.search(survey.read(dfm)):
            continue
        b = routes.blockers_of(survey, dfm)
        out[src] = (not b, b)
    return out


def batch_verdicts(survey, matrix):
    """A/A-svg / B / C per form, re-derived with the same rules the batch plan
    prints -- from the imported modules, not by re-reading its source."""
    dfms = sorted(p for p in survey.SOURCE.rglob("*.dfm") if "VCL" not in p.parts)
    units = {p: survey.read(p) for p in survey.SOURCE.rglob("*.pas")}

    def origin(t):
        pat = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        for p, txt in units.items():
            if pat.search(txt):
                return "vendored" if "VCL" in p.parts else "own"
        return "external"

    out = {}
    for p in dfms:
        _, _, custom = survey.survey(p)
        blocked_by = {t for t in custom if t not in survey.RETIRED}
        rel = p.relative_to(survey.SOURCE).as_posix()
        if not blocked_by:
            out[rel] = "A"
        else:
            kinds = {origin(t) for t in blocked_by}
            all_eq = all(t in matrix.LCL_EQUIVALENT
                         and matrix.LCL_EQUIVALENT[t] != "none"
                         for t in blocked_by)
            out[rel] = "B" if kinds == {"external"} and all_eq else "C"
    return out


def unaccounted_renames(converter, retired):
    """Class names the converter renames away that no retirement records."""
    out = []
    for src, dst in converter.CLASS_RENAME.items():
        if src == dst:
            continue  # a no-op entry kept for documentation
        if src not in retired:
            out.append((src, dst))
    return out


def run(verbose=True):
    survey = load("f3_form_survey")
    routes = load("f3_load_routes")
    converter = load("f3_dfm_to_lfm")
    matrix = load("f3_external_matrix")

    failures = []

    if verbose:
        print("F3 RETIREMENT CHECK -- one set, one home, both tools using it")
        print("=" * 78)
        print()
        print("retirement set: f3_form_survey.RETIRED")
        for name, (sprint, why) in sorted(survey.RETIRED.items()):
            first = why.split(";")[0]
            print(f"  {name:22} [{sprint:>8}] {first}")
        print()

    # 1. no second copy
    forks = find_forks()
    if verbose:
        print("1. no tool re-declares the set")
    if forks:
        failures.append("forked retirement set")
        if verbose:
            for f, line, txt in forks:
                print(f"   FORK  {f}:{line}  {txt}")
    elif verbose:
        print(f"   OK    only {DEFINITION_SITE} declares it "
              f"({len(survey.RETIRED)} entries)")
    print()

    # 2. the two instruments agree
    rv = route_verdicts(survey, routes)
    bv = batch_verdicts(survey, matrix)
    if verbose:
        print("2. the two instruments agree on the forms the retirements decided")
        print("   %-26s %-30s %s" % ("form", "route", "batch"))
    for f in WATCH:
        if f not in rv:
            # The route tool only reports on forms that produced an .lfm AND
            # consume an SVG list. Saying "BLOCKED: " with an empty list for a
            # form it simply never considered reads as "blocked by nothing",
            # which is the opposite of true for DataFrm and Packman/Main.
            rtxt = "not a converted SVG consumer"
            btxt = bv.get(f, "(not found)")
            ok = btxt in ("B", "C")
            print("   %-26s %-30s %-6s %s" % (f, rtxt, btxt,
                                              "OK" if ok else "<-- should be B/C"))
            if not ok:
                failures.append(f"{f}: not converted, batched {btxt}")
            continue
        cleared, blockers = rv[f]
        rtxt = "CLEARED" if cleared else ("BLOCKED: " + ", ".join(blockers))
        btxt = bv.get(f, "(not found)")
        # CLEARED by the route tool but batched B/C means a retirement is being
        # applied in one instrument and not the other -- the exact drift this
        # gate exists to catch.
        ok = (btxt == "A") if cleared else (btxt in ("B", "C"))
        print("   %-26s %-30s %-6s %s" % (f, rtxt, btxt,
                                          "OK" if ok else "<-- DISAGREE"))
        if not ok:
            failures.append(f"{f}: route={rtxt} batch={btxt}")
    print()

    # 3. every converter rename is recorded
    holes = unaccounted_renames(converter, survey.RETIRED)
    if verbose:
        print("3. every class the converter renames away is recorded as retired")
    if holes:
        failures.append("converter renames with no retirement entry")
        if verbose:
            for src, dst in holes:
                print(f"   HOLE  {src} -> {dst} is in CLASS_RENAME but not in "
                      "RETIRED, so no tool knows the converter did it")
    elif verbose:
        n = sum(1 for s, d in converter.CLASS_RENAME.items() if s != d)
        print(f"   OK    all {n} rename(s) in CLASS_RENAME have a retirement entry")
    print()

    if verbose:
        print(f"route tool: CLEARED {sum(1 for c, _ in rv.values() if c)} of {len(rv)} "
              "converted SVG consumers")
        print()

    if failures:
        if verbose:
            print("RESULT: %d inconsistency(ies)" % len(failures))
            for f in failures:
                print(f"  - {f}")
        return 1
    if verbose:
        print("RESULT: one retirement set, no forks, the two instruments agree, "
              "and every converter rename is accounted for")
    return 0


def self_test():
    """Each check, fed a deliberately broken world. A gate that has only ever
    printed OK is not evidence of anything."""
    print("SELF-TEST (each check must be able to FAIL)")
    print("-" * 78)
    failures = 0

    # (a) a forked set must be found
    probe = TOOLS / "_f3retirement_selfcheck_probe.py"
    probe.write_text("SVG_RETIRED = {'TSVGIconImageList'}\n", encoding="utf-8")
    try:
        forks = find_forks()
        if forks:
            print("  OK    a second RETIRED literal is detected (%s:%d)"
                  % (forks[0][0], forks[0][1]))
        else:
            print("  FAIL  a forked retirement set was NOT detected")
            failures += 1
    finally:
        probe.unlink(missing_ok=True)

    # (b) with no fork in place, the real scan must be clean
    if find_forks():
        print("  FAIL  the scan reports a fork on the clean tree")
        failures += 1
    else:
        print("  OK    the clean tree reports no fork")

    # (c) a rename with no retirement entry must be reported
    class FakeConverter:
        CLASS_RENAME = {"TVirtualImage": "TLclVirtualImage",
                        "TSomethingNew": "TLclSomethingNew"}
    holes = unaccounted_renames(FakeConverter(), {"TVirtualImage"})
    if holes == [("TSomethingNew", "TLclSomethingNew")]:
        print("  OK    a rename absent from RETIRED is reported as a hole")
    else:
        print("  FAIL  expected one hole, got %r" % (holes,))
        failures += 1

    # (d) and the real converter must have none
    converter = load("f3_dfm_to_lfm")
    survey = load("f3_form_survey")
    real = unaccounted_renames(converter, survey.RETIRED)
    if not real:
        print("  OK    the real converter has no unrecorded rename")
    else:
        print("  FAIL  the real converter has %d unrecorded rename(s): %r"
              % (len(real), real))
        failures += 1

    print()
    if failures:
        print("RESULT: %d self-test check(s) FAILED -- the gate cannot be trusted"
              % failures)
        return 2
    print("RESULT: all self-test checks behaved")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if "--self-test" in args:
        return self_test()
    return run(verbose="--quiet" not in args)


if __name__ == "__main__":
    sys.exit(main())