#!/usr/bin/env python3
"""Narrow the EZeroDivide cause by measuring each candidate across ALL 116 icons.

Reads the failing set from svg/failed/ -- written by RasterProbe, the program
that already identifies them -- and the whole set from DataFrm.dfm through
f3_svg_extract's own parser. An earlier attempt re-parsed SvgData.pas in Python
and was wrong (696 icons for an 85-icon list), so that parser is not used here.

For each candidate attribute, prints the failing/working split. A candidate that
separates the two sets is named; one that does not is printed as rejected rather
than quietly dropped, because a rejected hypothesis is a result too.

TWO KINDS OF CANDIDATE
======================
The candidates under CANDIDATES are cheap text shapes: `<polygon`, `style=`, a
curve letter inside a `d=` attribute. This tool was first built with those
alone, and across all 18 of them NONE separated the sets -- the best any could
do was "in all failures (not exclusive)", which proves nothing. That is why the
runnable table is followed by STRUCT_CANDIDATES: the cause of a division by
zero is arithmetic, not spelling, and it needs the arc's START and END points,
which exist only once the current point has been tracked through every preceding
command.

path_arcs lives here rather than being copied into the fix tool
(f3_svg_zerochord.py imports it): one definition of "what an arc in this path
is" cannot then drift away from another.

Run:  python tools/f3_svg_divzero.py
Exit: 0 always -- this is a diagnostic, not a gate.
"""
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAIL = ROOT / "Tests" / "FpcCoreTests" / "svg" / "failed"
DFM = ROOT / "Source" / "DataFrm.dfm"

CANDIDATES = {
    "polygon":        r"<polygon\b",
    "polyline":       r"<polyline\b",
    "circle":         r"<circle\b",
    "ellipse":        r"<ellipse\b",
    "rect":           r"<rect\b",
    "line":           r"<line\b",
    "use":            r"<use\b",
    "clipPath":       r"<clipPath\b",
    "mask":           r"<mask\b",
    "linearGradient": r"<linearGradient\b",
    "radialGradient": r"<radialGradient\b",
    "style-attr":     r"\bstyle\s*=",
    "fill-attr":      r"\bfill\s*=",
    "opacity":        r"\bopacity\s*=",
    "stroke":         r"\bstroke\s*=",
    "curve-A":        r'\bd="[^"]*[Aa]',
    "curve-Q":        r'\bd="[^"]*[Qq]',
    "curve-C":        r'\bd="[^"]*[Cc]',
}

# ---------------------------------------------------------------------------
# Path grammar walk (STRUCT candidates need points, not spellings).
# ---------------------------------------------------------------------------
_TOKEN_RE = re.compile(
    r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
_LETTER_RE = re.compile(r"^[A-Za-z]$")
_ARGC = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4,
         "Q": 4, "T": 2, "A": 7, "Z": 0}
# Commands whose last two arguments are an (x, y) pair.
_XY_LAST = ("L", "C", "S", "Q", "T")
_D_ATTR_RE = re.compile(r'\bd="([^"]*)"')

# Computed candidates, appended to the table after the regex ones.
STRUCT_CANDIDATES = ("zero-chord-arc", "zero-radius-arc")


def walk_path_groups(d):
    """Yield one record per argument group in path data `d`.

    A record is (letter_idx, arg_slice, arc): letter_idx is the index of the
    command letter that introduced the group (None before the first letter),
    arg_slice the slice of token indices holding this group's arguments, and
    arc either None or (x1, y1, x2, y2, rx, ry) for an elliptical arc group.

    INDICES, not just values, are what the fix tool needs: to delete an arc it
    must know WHICH tokens to drop and whether the command letter in front of
    it is shared with a group that survives. Handing only the values over would
    make it re-derive the walk, and two walks of one grammar is exactly how a
    detector and its fix drift apart.

    The walk follows the grammar: a command letter is remembered until the next
    arrives (parameter sets may repeat without it), extra pairs after M are
    line-tos whose end point is the same either way, H/V move one coordinate,
    and Z returns to the sub-path start. Anything unparseable STOPS the walk
    rather than guessing -- a wrong current point would silently fabricate or
    hide a zero-length arc, which is worse than reporting none.
    """
    toks = list(_TOKEN_RE.finditer(d))
    i = 0
    cmd = None
    letter_idx = None
    x = y = sx = sy = 0.0
    while i < len(toks):
        m = toks[i]
        if _LETTER_RE.match(m.group(0)):
            cmd = m.group(0)
            letter_idx = i
            i += 1
            if cmd.upper() == "Z":
                x, y = sx, sy
                cmd = None
                letter_idx = None
            continue
        if cmd is None:
            break
        rel = cmd.islower()
        c = cmd.upper()
        n = _ARGC[c]
        if i + n > len(toks):
            break
        try:
            vals = [float(toks[i + k].group(0)) for k in range(n)]
        except ValueError:
            break
        arg = slice(i, i + n)
        i += n
        arc = None
        if c == "A":
            rx, ry, _phi, _fa, _fs, a, b = vals
            nx, ny = (x + a, y + b) if rel else (a, b)
            arc = (x, y, nx, ny, rx, ry)
            x, y = nx, ny
        elif c == "M":
            if rel:
                x, y = x + vals[0], y + vals[1]
            else:
                x, y = vals
            sx, sy = x, y
        elif c in _XY_LAST:
            if rel:
                x, y = x + vals[-2], y + vals[-1]
            else:
                x, y = vals[-2], vals[-1]
        elif c == "H":
            x = x + vals[0] if rel else vals[0]
        elif c == "V":
            y = y + vals[0] if rel else vals[0]
        yield (letter_idx, arg, arc)


def path_arcs(d):
    """Yield (x1, y1, x2, y2, rx, ry) for every arc segment in path data `d`.

    x1,y1 is the current point BEFORE the arc, x2,y2 the point after it, both in
    the coordinate system of the path data. An arc whose endpoints coincide is
    what the SVG implementation notes single out (F.6.2: such an arc is
    omitted), so equality is exactly the property under test -- and it must
    therefore come from a faithful walk of the grammar, not from a regex.
    """
    for _letter, _arg, arc in walk_path_groups(d):
        if arc is not None:
            yield arc


def degenerate_arcs(svg):
    """(zero-chord count, zero-radius count) over every arc in this SVG.

    zero-chord  -- x1==x2 and y1==y2. fpvectorial's CalcEllipseCenter computes
                   m := (sqr(rx*ry) - ...) / (sqr(rx*y1p) + sqr(ry*x1p)) with
                   x1p = y1p = 0: denominator 0, numerator (rx*ry)^2 > 0. The
                   division happens BEFORE its own SameValue guard can run
                   (fpvutils.pas:550), so it is an unguarded EZeroDivide.
    zero-radius -- CalcEllipseCenter exits early on rx=0 or ry=0, so it cannot
                   divide by them. Kept as its own row to show it REJECTED.
    """
    zero_chord = 0
    zero_radius = 0
    for m in _D_ATTR_RE.finditer(svg):
        for x1, y1, x2, y2, rx, ry in path_arcs(m.group(1)):
            if x1 == x2 and y1 == y2:
                zero_chord += 1
            if rx == 0 or ry == 0:
                zero_radius += 1
    return zero_chord, zero_radius


def load_everything():
    spec = importlib.util.spec_from_file_location(
        "f3_svg_extract", ROOT / "tools" / "f3_svg_extract.py")
    ex = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ex)
    lists = ex.parse_lists(DFM.read_text(encoding="utf-8-sig", errors="replace"))
    return [it["svg"] for l in lists for it in l["items"]]


def has(svg):
    r = {k: bool(re.search(v, svg)) for k, v in CANDIDATES.items()}
    zero_chord, zero_radius = degenerate_arcs(svg)
    r["zero-chord-arc"] = zero_chord > 0
    r["zero-radius-arc"] = zero_radius > 0
    return r


def main() -> int:
    if not FAIL.is_dir():
        print("no dumped failures at %s -- run RasterProbe.exe first" % FAIL)
        return 1

    bad = [p.read_text(encoding="utf-8", errors="replace")
           for p in sorted(FAIL.glob("*.svg"))]
    everything = load_everything()

    badf = [has(s) for s in bad]
    allf = [has(s) for s in everything]
    n_bad, n_all = len(badf), len(allf)

    print("failing %d of %d icons (failing set read from svg/failed/)"
          % (n_bad, n_all))
    print()
    print("%-16s %9s %8s  %s" % ("attribute", "in FAIL", "in ALL", "verdict"))
    print("-" * 56)

    for k in list(CANDIDATES) + list(STRUCT_CANDIDATES):
        b = sum(1 for f in badf if f[k])
        a = sum(1 for f in allf if f[k])
        if b == n_bad and a == n_bad:
            v = "PERFECT SEPARATOR"
        elif b == n_bad and a > n_bad:
            v = "in all failures (not exclusive)"
        elif a == n_bad:
            v = "EXACT: matches the failing set"
        elif b == 0:
            v = "rejected: in no failure"
        else:
            v = "-"
        print("%-16s %9d %8d  %s" % (k, b, a, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())