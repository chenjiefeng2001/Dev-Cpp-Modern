#!/usr/bin/env python3
"""
f3_batch_plan.py -- the F3 execution list, derived from measurement.

WHY A GENERATOR AND NOT A TABLE IN THE DOC
==========================================
The batch boundaries come from two facts that change as forms are converted:
which controls a form blocks on, and how many components it has. Writing the
batches into the plan document freezes a snapshot that silently goes stale the
first time someone converts a form -- and a stale batch list is worse than none,
because it is trusted.

This script recomputes the batches from the current tree, so the document can
quote a summary while the detail stays reproducible.

THE THREE BATCHES
==================
  A  mechanical      no blocking control at all; convert and move on
  B  field-level     blocked only by an external type, and every blocker has a
                     direct LCL equivalent -- convert, then swap the field type
  C  rebuild         blocked by vendored or own classes, which need an LCL
                     counterpart written before the form can convert at all

The A/B/C split is the point: B is not "hard", it is a type rename plus a DFM
edit, and lumping it with C was what made the original estimate read as if 53
forms needed hand work.

Run:  python tools/f3_batch_plan.py
"""
import collections
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    survey = load("f3_form_survey")
    matrix = load("f3_external_matrix")

    dfms = sorted(p for p in survey.SOURCE.rglob("*.dfm") if "VCL" not in p.parts)

    units = {p: survey.read(p) for p in survey.SOURCE.rglob("*.pas")}

    def origin(t):
        import re
        pat = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        for p, txt in units.items():
            if pat.search(txt):
                return "vendored" if "VCL" in p.parts else "own"
        return "external"

    batches = {"A": [], "A-svg": [], "B": [], "C": []}
    reasons = collections.defaultdict(list)

    # Show the path under Source/, not just the file name. Three forms are
    # called main.dfm / Main.dfm (Source/, Tools/PackMaker/, Tools/Packman/),
    # and Windows is case-insensitive, so short names collide in a listing and
    # two different 90 KB and 129 KB forms read as a single entry.
    def label(p):
        return p.relative_to(survey.SOURCE).as_posix()

    for p in dfms:
        root, types, custom = survey.survey(p)
        n = sum(types.values())
        # SUBTRACT THE RETIREMENTS -- as of F3-7 this tool finally did.
        #
        # It carried no retirement set at all, and that is why the two
        # instruments disagreed: f3_load_routes.py subtracted
        # f3_form_survey.RETIRED and called LangFrm / EnviroFrm CLEARED, while
        # this file put them in "BATCH B, blocked by TVirtualImage" -- a class
        # F3-3 had already replaced with TLclVirtualImage and load-tested via
        # ImgCollProbe. Same tree, same question, two answers.
        #
        # NOTE THE DIFFERENT SCOPING, and why it is not a bug: `blockers_of` in
        # f3_load_routes.py only ever runs on forms that already produced an
        # .lfm, which is what stops the subtraction from inventing a clearance
        # for Tools/Packman/Main's producer-side gap. This tool deliberately
        # buckets ALL 53 forms, including the ones never converted, so a blanket
        # subtraction here would report DataFrm as fine while it still carries
        # `TSynRCSyn` -- which LCL 4.4 does not have at all. Hence the two
        # different treatments of the SAME set, and hence the note in
        # f3_form_survey.RETIRED listing what is deliberately NOT in it.
        blocked_by = {t for t in custom if t not in survey.RETIRED}
        if not blocked_by:
            # Batch A means "the converter can read it". It does NOT mean the form
            # works afterwards: a form that draws from an SVG icon list converts
            # cleanly and then renders nothing. That distinction is the whole reason
            # the SVG decision was moved forward, so it is carried in the output
            # rather than left for someone to discover at run time.
            svg = bool(survey.SVG_USE_RE.search(survey.read(p)))
            (batches["A"] if not svg else batches["A-svg"]).append((label(p), n))
        else:
            kinds = {origin(t) for t in blocked_by}
            if kinds == {"external"} and all(t in matrix.LCL_EQUIVALENT
                                             and matrix.LCL_EQUIVALENT[t] != "none"
                                             for t in blocked_by):
                batches["B"].append((label(p), n))
            else:
                batches["C"].append((label(p), n))
            reasons[label(p)] = sorted(blocked_by)

    label = {
        "A": "MECHANICAL - no blocking control and no SVG dependency; "
             "converts and works as-is",
        "A-svg": "MECHANICAL BUT SVG-BOUND - converts cleanly, then renders "
                 "nothing until the SVG icon work lands. Do these AFTER the SVG "
                 "step: a converted-but-blank form is worse than an unconverted one.",
        "B": "FIELD-LEVEL - blocked only by an external type with a direct LCL "
             "equivalent; convert, then swap the field type",
        "C": "REBUILD - blocked by vendored or own classes; an LCL counterpart "
             "must be written before the form can convert",
    }
    print("F3 EXECUTION PLAN (recomputed from the current tree)")
    print("=" * 78)
    print()
    for k in ("A", "A-svg", "B", "C"):
        items = sorted(batches[k], key=lambda x: x[1])
        total = sum(c for _, c in items)
        print(f"BATCH {k}: {len(items):2d} form(s), {total:4d} components")
        print(f"        {label[k]}")
        for name, n in items:
            extra = ""
            if k not in ("A", "A-svg"):
                extra = "   <- " + ", ".join(reasons[name])
            print(f"          {name:<38} {n:4d} controls{extra}")
        print()

    total_forms = len(dfms)
    print(f"SUMMARY: {len(batches['A'])}/{total_forms} forms need no component rewrite")
    print(f"         and are self-contained (convert and run).")
    print(f"         {len(batches['A-svg'])} more convert but are blocked on the SVG icon work")
    print(f"         {len(batches['B'])} need a field-type swap only.")
    print(f"         {len(batches['C'])} need vendored/own classes rebuilt first.")
    print(f"         {len(batches['C'])} form(s) do, and they are the schedule risk.")
    print()
    print("Run this script again after converting a form; the batches recompute.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
