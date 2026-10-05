#!/usr/bin/env python3
"""
f3_form_ratchet.py -- hold the F3 baseline still, in either direction.

WHAT IT GUARDS
==============
`f3_form_survey.py` reports how many of the 53 forms can be converted without
hand work. That number is only useful if it moves the way it is supposed to:
DOWN never (a regression means someone introduced a control the converter cannot
place), and UP as F3 converts forms.

A survey alone does not enforce either. A ratchet does, and it fails the build.

THE BASELINE, AND WHY IT IS A NUMBER AND NOT A LIST OF FILES
=============================================================
Measured 2026-10-04: 41 of 53 forms are convertible as-is; 12 name at least one
control the converter cannot place. The 12 are blocked mostly by this project's
OWN classes (TCompOptionsList, TdevShortcuts, TCppParser, ...), which is code
work, not a form problem -- so the meaningful metric is the count.

A per-file list would be stricter but also wrong here: fixing one form's controls
legitimately reveals another, and ratcheting on file identity would forbid
progress that is actually happening.

WHAT COUNTS AS A BLOCKER
========================
Anything in f3_form_survey.WIDGETSET is LCL-native and never counts. The default
is therefore "blocked", which is the safe direction: a control introduced later
shows up as a regression instead of being silently absorbed.

Run:  python tools/f3_form_ratchet.py [--baseline N] [--write-baseline N]
Exit: 0 when the count is at or below the baseline, 1 when it regressed.
"""
import argparse
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE_FILE = ROOT / "tools" / "f3_form_baseline.txt"
DEFAULT_BASELINE = 41


def load_survey():
    spec = importlib.util.spec_from_file_location(
        "f3_form_survey", ROOT / "tools" / "f3_form_survey.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_baseline() -> int:
    if BASELINE_FILE.is_file():
        try:
            return int(BASELINE_FILE.read_text(encoding="utf-8").strip())
        except ValueError:
            pass
    return DEFAULT_BASELINE


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", type=int, default=None)
    ap.add_argument("--write-baseline", type=int, default=None)
    args = ap.parse_args()

    if args.write_baseline is not None:
        BASELINE_FILE.write_text(f"{args.write_baseline}\n", encoding="utf-8")
        print(f"[WRITE] baseline = {args.write_baseline}")
        return 0

    survey = load_survey()
    blocked = []
    for p in sorted(survey.SOURCE.rglob("*.dfm")):
        if "VCL" in p.parts:
            continue
        _, _, custom = survey.survey(p)
        if custom:
            blocked.append((p.name, sorted(custom)))

    convertible = 53 - len(blocked)
    baseline = args.baseline if args.baseline is not None else read_baseline()

    print(f"convertible as-is: {convertible} / 53 (baseline {baseline})")
    for name, custom in blocked:
        print(f"  BLOCKED {name}: {', '.join(custom)}")

    if convertible < baseline:
        print(
            f"F3 RATCHET FAILED: convertible forms dropped from {baseline} to "
            f"{convertible}. A control was introduced that the Lazarus converter "
            f"cannot place, or a widgetset classification is now wrong.",
            file=sys.stderr,
        )
        return 1

    if convertible > baseline:
        # Improvement is allowed but never implicit: a ratchet that rises on its
        # own stops being a ratchet, because the review that a higher number
        # deserves would be skipped.
        print(
            f"NOTE: convertible forms ROSE to {convertible} (baseline {baseline}). "
            f"If that progress is intended, record it with "
            f"`--write-baseline {convertible}`."
        )
        return 0

    print("F3 ratchet: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())