#!/usr/bin/env python3
"""
f3_load_routes.py -- what actually stands between the converted .lfm files and
a real `lazbuild`, ordered by how much each blocker buys.

WHY THIS EXISTS RATHER THAN A SECTION OF THE PLAN
================================================
The F3 plan has carried several different "how many forms does SVG unblock"
answers -- 13, 15, 9, and a prose estimate of "the rest is batch C". They
disagreed because each was derived by hand at a different moment, and a
hand-maintained list of blocked forms goes stale the first time someone
converts a form. That is the same reason f3_batch_plan.py exists.

So this recomputes the answer from the tree every run, and it reports the
thing a stage estimate actually needs: NOT "how many forms are blocked" but
"which single blocker, if retired, converts N forms". The first number sets
the mood; the second is the schedule.

WHAT IT MEASURES
================
  * The set of forms f3_dfm_to_lfm.py has actually converted -- read from
    Source/Fpc/UI/Forms/_generated.json, NOT from a batch letter. A form that
    was converted by hand and a form the converter emitted are both "converted"
    for this purpose, and neither should have to be remembered in two places.
  * For each, the control types f3_form_survey.py reports as non-convertible,
    MINUS the ones later sprints have already retired: the SVG work
    (TSVGIconImageList -> TLclSvgImageList) and F3-3
    (TVirtualImage -> TLclVirtualImage).
  * The blocker roll-up, sorted by forms-unblocked-per-blocker.

WHY THE SVG EXCLUSION IS SUBTRACTED AND NOT ASSUMED AWAY
========================================================
`TSVGIconImageList` still appears as a blocker for DataFrm, NewProjectFrm and
Packman/Main -- forms the converter either refused or deliberately did not
emit in full. Subtracting the class name everywhere would erase those three
real remaining gaps and report C batch as cleaner than it is. So the exclusion
is scoped to the forms that actually received a converted .lfm, and the
producer-side gaps are printed separately instead.

Run:  python tools/f3_load_routes.py
Exit: 0 always. This is a ROADMAP, not a gate -- it has no opinion about
      whether the current state is acceptable, only about what it costs.
"""
import collections
import importlib.util
import json
import pathlib
import re
import sys

# Paths here are repo-relative POSIX strings, so basename comes from pathlib,
# not os.path -- os.path on Windows does not split on '/'.
def short(p):
    return pathlib.PurePosixPath(p).name

ROOT = pathlib.Path(__file__).resolve().parent.parent
FORMS_DIR = ROOT / "Source" / "Fpc" / "UI" / "Forms"
MANIFEST = FORMS_DIR / "_generated.json"

# Retired by the SVG work: the class name is gone from the emitted LFM, and the
# control it became is load-tested (Tests/FpcCoreTests/svg/SvgLfmProbe.lpr).
SVG_RETIRED = {"TSVGIconImageList"}

# Retired by sprint F3-3: the converter renames TVirtualImage ->
# TLclVirtualImage (Source/Fpc/UI/Controls/LclVirtualImage.pas), and the
# converted nodes + extracted PNGs are load-tested (ImgCollProbe.lpr).
F33_RETIRED = {"TVirtualImage"}

# Retired by sprint F3-4 (the CompOptions frame-port, doc F3-SVG section
# 15/16). Two different reasons, one outcome -- CompOptionsFrm and
# ProjectOptionsFrm no longer name a control the route cannot account for:
#
#   TCompOptionsList  RETIRED, not ported. The vendored control's entire
#                     value-add was hand-rolling a pick-list editor on top
#                     of VCL private members (EditList, StyleServices);
#                     LCL's TValueListEditor gives esPickList rows a
#                     native cbsPickList editor (valedit.pas:1267), so the
#                     frame's `vle` field is now the stock class and no
#                     live source references the vendored unit any more
#                     (f3_removed_controls.py asserts it stays that way).
#   TCompOptionsFrame PORTED, not retired. The class still names itself in
#                     three LFMs, but the frame is own code whose every
#                     symbol is an LCL-native API (verified line by line,
#                     section 15.3) -- the Pascal logic is unchanged, so
#                     the unit compiles under both Delphi and Lazarus and
#                     the class resolves at stream time.
F34_RETIRED = {"TCompOptionsList", "TCompOptionsFrame"}

# All exclusions are scoped to forms that actually received a converted .lfm
# (blockers_of only runs on the converted set), so producer-side gaps such as
# Packman/Main keep their real blockers.
RETIRED = SVG_RETIRED | F33_RETIRED | F34_RETIRED


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def converted_forms():
    """Every .lfm the converter emitted, keyed by its source DFM's repo path."""
    if not MANIFEST.is_file():
        return {}
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {v["source"]: k for k, v in data.items() if v.get("rule") == "dfm-to-lfm"}


def blockers_of(survey, dfm_path):
    _, _, custom = survey.survey(dfm_path)
    return sorted(set(custom) - RETIRED)


def main() -> int:
    survey = load("f3_form_survey")
    converted = converted_forms()
    if not converted:
        print("ERROR: %s is missing or empty -- run f3_dfm_to_lfm.py first"
              % MANIFEST.relative_to(ROOT))
        return 1

    # The 15 SVG consumers: converted forms that still name an SVG list.
    svg_consumers = {}
    for src, lfm in sorted(converted.items()):
        dfm = ROOT / "Source" / src
        if not dfm.is_file():
            continue
        if survey.SVG_USE_RE.search(survey.read(dfm)):
            svg_consumers[src] = lfm

    clear, blocked = {}, {}
    for src, lfm in svg_consumers.items():
        b = blockers_of(survey, ROOT / "Source" / src)
        (clear if not b else blocked)[src] = b

    print("F3 LOAD ROUTES -- from the converted .lfm set to a real lazbuild")
    print("=" * 78)
    print()
    print(f"  converted .lfm in total     : {len(converted)}")
    print(f"  of which SVG consumers      : {len(svg_consumers)}")
    print(f"  CLEARED by the SVG work     : {len(clear)}")
    print(f"  still blocked by other code : {len(blocked)}")
    print()

    print("CLEARED -- next verification is to LOAD these, nothing more to build")
    print("-" * 78)
    for src in sorted(clear):
        print(f"  {src}")
    print()
    print("  These convert with no blocking control AND their icon lists are")
    print("  now real, so `f3_lfm_check.py` is the only thing between them and a")
    print("  compile. They are the cheapest remaining evidence in the whole plan.")
    print()

    print("STILL BLOCKED")
    print("-" * 78)
    for src in sorted(blocked):
        print(f"  {src}")
        for t in blocked[src]:
            print(f"      {t}")
    print()

    # The schedule number: one blocker, N forms.
    roll = collections.Counter()
    for bs in blocked.values():
        for t in bs:
            roll[t] += 1
    print("BLOCKER ROLL-UP (sorted by forms unblocked per blocker)")
    print("-" * 78)
    if not roll:
        print("  none")
    for t, n in roll.most_common():
        who = sorted(s for s, bs in blocked.items() if t in bs)
        print(f"  {t:<32} {n} form(s)  {', '.join(short(w) for w in who)}")
    print()

    # A blocker shared by N forms is worth more than N single-form blockers,
    # but ONLY if the forms are otherwise ready. Say both numbers rather than
    # letting "retire one control" imply "one form".
    shared = [t for t, n in roll.items() if n > 1]
    print("MINIMAL FIRST MOVES")
    print("-" * 78)
    if shared:
        for t in sorted(shared, key=lambda x: (-roll[x], x)):
            print(f"  retire {t:<30} -> unblocks {roll[t]} form(s)")
    singles = [t for t, n in roll.items() if n == 1]
    if singles:
        print()
        print("  single-form blockers (retiring one of these buys exactly one form):")
        for t in sorted(singles):
            print(f"    {t:<30} -> {', '.join(short(s) for s, bs in blocked.items() if t in bs)}")
    print()

    print("PRODUCER-SIDE GAPS (missing CONTROLS, not form blockers)")
    print("-" * 78)
    decl_re = re.compile(r"^\s*object\s+(\w+)\s*:\s*(TSVGIcon\w+)\s*$")
    declared = {}
    for p in survey.SOURCE.rglob("*.dfm"):
        if "VCL" in p.parts:
            continue
        for line in survey.read(p).splitlines():
            m = decl_re.match(line)
            if m:
                declared.setdefault(
                    p.relative_to(survey.SOURCE).as_posix(), set()).add(m.group(2))

    hard, soft = [], []
    for src, types in sorted(declared.items()):
        if src in converted:
            continue
        remaining = types - SVG_RETIRED
        (hard if remaining else soft).append((src, sorted(remaining)))
    for src, types in hard:
        print(f"  {src}: {', '.join(types)}  -- no LCL counterpart yet")
    for src, _types in soft:
        # Printed WITH the reason, never as an empty line. The first version of
        # this loop printed `DataFrm.dfm:` followed by nothing, because the only
        # SVG class it declares is the retired TSVGIconImageList -- and an empty
        # line here reads as "no gap" when the real reason is a different
        # blocker entirely.
        print(f"  {src}: SVG classes all converted, but it still has no form .lfm "
              f"for a reason outside this plan's SVG scope")
    print()
    print("Run this again after converting a form; the route list recomputes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
