#!/usr/bin/env python3
"""Generate the variants the EZeroDivide diagnosis predicts, for SvgTry to judge.

The diagnosis (measured by tools/f3_svg_divzero.py) is that all 7 failures carry
an arc segment whose start and end points are IDENTICAL. fpvectorial converts
endpoint arcs with

    m := (sqr(rx*ry) - sqr(rx*y1p) - sqr(ry*x1p)) / (sqr(rx*y1p) + sqr(ry*x1p))

and with x1p = y1p = 0 the denominator is 0 while the numerator is (rx*ry)^2 > 0,
so CalcEllipseCenter divides by zero BEFORE the SameValue guard one line below
(fpvutils.pas:550). SvgParse confirms the raise happens inside ReadFromStream.

This tool performs the TEST, not the conclusion: variants with those arcs
removed go to svg/zerochord/, and three UNTOUCHED known-good icons to
svg/control/. Then

    SvgParse svg\\failed      -> 7 raised (the fault is in the parse)
    SvgTry   svg\\failed      -> 0 pass   (the judge can fail)
    SvgTry   svg\\control     -> 3 pass   (the judge is not blind)
    SvgTry   svg\\zerochord   -> 7 pass?  (the prediction)

The control directory exists because SvgTry's first version parsed its own
argument instead of the file and returned 0 for everything -- an all-zero judge
and an all-broken data set look identical. A control that PASSES is what makes
a failing verdict meaningful.

ASSERTED BEFORE ANY FILE IS WRITTEN (exit 1 otherwise)
======================================================
1. exactly 7 of 116 icons change, and they are the same 7 RasterProbe dumped
   into svg/failed/ -- an independent, Pascal-produced list;
2. for every changed icon the surviving token sequence is the original minus
   the dropped groups, counted token by token: nothing else was touched;
3. the detector finds no degenerate arc left in any output;
4. every output is pure ASCII, because the judges read raw bytes.

The SVG spec text for identical endpoints was NOT retrieved (the W3C pages come
back truncated), so no verbatim citation is made. Instead the blast radius is
MEASURED: each removed arc's radius is printed in pixels at its own list size,
which is what decides whether removing it can be seen.

Run:  python tools/f3_svg_zerochord.py
Exit: 0 on success, 1 if any assertion fails.
"""
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SVG_DIR = ROOT / "Tests" / "FpcCoreTests" / "svg"
DFM = ROOT / "Source" / "DataFrm.dfm"
FAILED = SVG_DIR / "failed"
OUT = SVG_DIR / "zerochord"
CONTROL = SVG_DIR / "control"
CONTROL_LIST = "SVGImageListProjectStyle"   # all 6 rendered, per RasterProbe


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "tools" / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dz = load("f3_svg_divzero")
ex = load("f3_svg_extract")


def strip_degenerate(d):
    """(new path data, dropped token count) with identical-endpoint arcs removed.

    Rebuilt from tokens rather than spliced: a comma lives in the GAP between
    two tokens, so deleting tokens in place leaves separators dangling and
    `a ,1,1,...` is not path data. Rebuilding emits one space between adjacent
    number tokens -- always legal -- and never a comma.
    """
    groups = list(dz.walk_path_groups(d))
    toks = list(dz._TOKEN_RE.finditer(d))
    drop = set()
    per_letter = {}
    for letter_idx, arg, arc in groups:
        degenerate = arc is not None and arc[0] == arc[2] and arc[1] == arc[3]
        key = letter_idx if letter_idx is not None else -1
        total, bad = per_letter.get(key, (0, 0))
        per_letter[key] = (total + 1, bad + (1 if degenerate else 0))
        if degenerate:
            drop.update(range(arg.start, arg.stop))
    # The command letter is shared by every parameter set that follows it, so it
    # may only go when NOTHING under it survives -- otherwise the surviving set
    # would be left without a command.
    for key, (total, bad) in per_letter.items():
        if key >= 0 and total == bad:
            drop.add(key)

    out = []
    prev_num = False
    for i, m in enumerate(toks):
        if i in drop:
            continue
        text = m.group(0)
        is_num = not text[0].isalpha()
        if prev_num and is_num:
            out.append(" ")
        out.append(text)
        prev_num = is_num
    new_d = "".join(out) if drop else d

    # The strongest local check available: the rebuilt path must be token-for-
    # token the original with EXACTLY the dropped indices missing. Any other
    # difference -- a mangled number, a lost command, a silent extra edit --
    # fails here rather than showing up as a rendering surprise later.
    kept = [m.group(0) for i, m in enumerate(toks) if i not in drop]
    if [m.group(0) for m in dz._TOKEN_RE.finditer(new_d)] != kept:
        raise AssertionError("rebuild is not the original minus the dropped tokens")
    return new_d, len(drop)


def strip_svg(svg):
    """The same transformation over every d="..." attribute of one SVG."""
    total = 0

    def repl(m):
        nonlocal total
        new, dropped = strip_degenerate(m.group(1))
        total += dropped
        return 'd="%s"' % new

    new = dz._D_ATTR_RE.sub(repl, svg)
    return new, total


def d_tokens(text):
    out = []
    for m in dz._D_ATTR_RE.finditer(text):
        out.extend(x.group(0) for x in dz._TOKEN_RE.finditer(m.group(1)))
    return out


VB_RE = re.compile(r'viewBox="0 0 ([\d.]+) [\d.]+"')


def main() -> int:
    lists = ex.parse_lists(DFM.read_text(encoding="utf-8-sig", errors="replace"))
    entries = [(l["name"], idx, it["name"], l["declared_size"] or 32, it["svg"])
               for l in lists for idx, it in enumerate(l["items"])]

    changed = []
    for lname, idx, iname, edge, svg in entries:
        new, dropped = strip_svg(svg)
        if new != svg:
            changed.append((lname, idx, iname, edge, svg, new, dropped))

    problems = []

    # 1: exactly 7 of 116 change, and they are RasterProbe's 7.
    if len(changed) != 7:
        problems.append("expected 7 changed icons, got %d" % len(changed))
    got = {"%s_%d_%s" % (c[0], c[1], c[2]) for c in changed}
    want = set()
    if FAILED.is_dir():
        for p in FAILED.glob("*.svg"):
            # RasterProbe names its dumps <n>_<list>_<index>_<name>.svg, where
            # <n> is only a dump counter; the key has three parts, not four.
            parts = p.stem.split("_", 3)
            want.add("%s_%s_%s" % (parts[1], parts[2], parts[3]))
    if not want:
        problems.append("svg/failed/ is empty -- run RasterProbe.exe first")
    elif got != want:
        problems.append("changed set != RasterProbe failed set:\n"
                        "    only here: %s\n    only there: %s"
                        % (sorted(got - want), sorted(want - got)))

    # 2/3/4: nothing degenerate survives, output is ASCII (the judges read raw
    # bytes), and the removed arcs are small enough not to be seen.
    max_px = 0.0
    for lname, idx, iname, edge, svg, new, dropped in changed:
        zc, _zr = dz.degenerate_arcs(new)
        if zc:
            problems.append("%s: %d degenerate arc(s) remain" % (iname, zc))
        if not new.isascii():
            problems.append("%s: output is not ASCII" % iname)
        vb = VB_RE.search(svg)
        units = float(vb.group(1)) if vb else 18.0
        for m in dz._D_ATTR_RE.finditer(svg):
            for x1, y1, x2, y2, rx, ry in dz.path_arcs(m.group(1)):
                if x1 == x2 and y1 == y2:
                    max_px = max(max_px, max(rx, ry) / units * edge)

    if problems:
        print("ASSERTION FAILED:")
        for p in problems:
            print("  -", p)
        return 1

    # Write variants under the SAME file names as failed/, so the judge's two
    # runs can be paired line by line.
    OUT.mkdir(parents=True, exist_ok=True)
    for p in OUT.glob("*.svg"):
        p.unlink()
    for lname, idx, iname, edge, svg, new, dropped in changed:
        (OUT / ("%s_%d_%s.svg" % (lname, idx, iname))).write_bytes(new.encode("ascii"))

    CONTROL.mkdir(parents=True, exist_ok=True)
    for p in CONTROL.glob("*.svg"):
        p.unlink()
    ctl = [e for e in entries if e[0] == CONTROL_LIST][:3]
    for lname, idx, iname, edge, svg in ctl:
        (CONTROL / ("%s_%d_%s.svg" % (lname, idx, iname))).write_bytes(svg.encode("ascii"))

    print("changed %d of %d icons -> %s" % (len(changed), len(entries), OUT))
    for lname, idx, iname, edge, svg, new, dropped in changed:
        print("  %-27s %-14s dropped %2d token(s)  %4d -> %4d bytes"
              % (lname, iname, dropped, len(svg), len(new)))
    print("control: %d untouched known-good icon(s) -> %s" % (len(ctl), CONTROL))
    print("largest removed arc radius renders to <= %.3f px at its list size" % max_px)
    print()
    print("judge with SvgTry.exe:")
    print("  baseline   SvgTry svg\\failed     -> expect 0 pass")
    print("  control    SvgTry svg\\control    -> expect %d pass (judge not blind)" % len(ctl))
    print("  prediction SvgTry svg\\zerochord  -> expect 7 pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
