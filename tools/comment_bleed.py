#!/usr/bin/env python3
"""How much of the ratchet is actually inside comments?

`mainform_baseline.strip_noise` removes block comments with `\{[^}]*\}`, which
stops at the FIRST closing brace. Delphi code nests braces (a commented-out
routine that itself contains a `begin/end` block is written with plain braces
in this repo), so a long `{ ... }` region is only partly stripped and the
remainder is scanned as if it were live code.

That is not hypothetical: devCFG.pas wraps a whole disabled procedure in
`{ ... }` spanning ~40 lines, and the ratchet charges its `with MainForm do`
as a live coupling.

This tool re-counts the baseline with a line-tracking block-comment stripper
and prints, per file, how many counted references are really inside comments.
Nothing is modified -- it answers "how much of the 49 is not real".

Usage:  python tools/comment_bleed.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tools" / "mainform_baseline.json"

_LINE = re.compile(r"//.*$")
_BLOCK_LINE = re.compile(r"\(\*.*?\*\)", re.S)
_STR = re.compile(r"'(?:''|[^'])*'")


def strip_lines(text, track):
    """Line-aware comment stripper.

    Pascal block comments are `{ ... }` and nest. A single line can therefore
    open a comment, contain a commented-out routine, and close again. The
    naive `\{[^}]*\}` regex stops at the first `}`, which is why the ratchet
    charged commented-out code as live.

    This walks the text once, carrying brace depth across lines, and records
    for every line whether the code that survived it came from inside a
    comment. A character only counts as code when depth == 0 and we are not
    inside a string literal.
    """
    out = []
    depth = 0            # >0 while inside a { } block comment
    in_str = False
    for raw in text.splitlines():
        line_chars = []
        started_outside = (depth == 0)
        i = 0
        while i < len(raw):
            ch = raw[i]
            nxt = raw[i:i + 2]
            if in_str:
                line_chars.append(ch)
                if ch == "'":
                    if raw[i + 1:i + 2] == "'":
                        line_chars.append("'")
                        i += 2
                        continue
                    in_str = False
                i += 1
                continue
            if depth > 0:
                if nxt == "}":
                    depth -= 1
                    i += 2
                    continue
                if ch == "{":
                    depth += 1
                    i += 1
                    continue
                i += 1
                continue
            # depth == 0
            if nxt == "(*":
                depth += 1
                i += 2
                continue
            if nxt == "//":
                break
            if nxt == "*)":
                depth = max(0, depth - 1)
                i += 2
                continue
            if ch == "{":
                depth += 1
                i += 1
                continue
            if ch == "'":
                in_str = True
                line_chars.append(ch)
                i += 1
                continue
            line_chars.append(ch)
            i += 1
        code = _BLOCK_LINE.sub("", "".join(line_chars))
        code = _STR.sub("''", code)
        out.append((code, started_outside))
        track.append(started_outside)
    return out


def main():
    data = json.loads(BASELINE.read_text(encoding="utf-8"))
    ref_re = re.compile(r"(?<!Application\.)\bMainForm\s*\.", re.IGNORECASE)
    total_live = total_dead = 0
    rows = []
    for rel, counted in sorted(data.get("refs", {}).items()):
        path = ROOT / rel
        if not path.exists():
            continue
        raw = path.read_bytes()
        for enc in ("utf-8-sig", "gbk"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        track = []
        lines = strip_lines(text, track)
        live = dead = 0
        for code, started_outside in lines:
            n = len(ref_re.findall(code))
            # A line can both open and close a block comment. When the stripper
            # emitted real text for it, that text is live code regardless of
            # where the line started; only an emptied line carries no evidence.
            if not code.strip():
                continue
            if started_outside:
                live += n
            else:
                dead += n
        total_live += live
        total_dead += dead
        if dead or live != counted:
            rows.append((rel, counted, live, dead))

    print("%-40s %5s %5s %5s" % ("file", "ratchet", "live", "comment"))
    print("-" * 60)
    for rel, counted, live, dead in rows:
        print("%-40s %5d %5d %5d  <-- %d not real"
              % (rel, counted, live, dead, dead))
    print("-" * 60)
    print("ratchet total : %d" % sum(v for v in data.get("refs", {}).values()))
    print("actually live : %d" % total_live)
    print("inside comment: %d" % total_dead)
    return 0


if __name__ == "__main__":
    sys.exit(main())