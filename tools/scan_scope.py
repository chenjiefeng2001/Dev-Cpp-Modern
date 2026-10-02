"""Shared path policy for every tool under tools/.

The scanners walk Source/ recursively, which is right for the coupling ratchet
but wrong for anything that has been deliberately taken out of the build.
Source/Archive/ holds units verified dead by tools/dead_unit_check.py: absent
from devcpp.dproj AND named by no compiled unit. Counting them would keep a
number alive for code that cannot break anything -- and, worse, would make the
ratchet report a "new" coupling the moment a file is moved there, which reads
as a regression when it is the opposite.

One definition, imported everywhere, so a second archive directory cannot be
added in one tool and forgotten in another.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Directory prefixes (repo-relative, posix) that are outside the measured
# surface. Add to this tuple rather than editing a scanner in place.
EXCLUDED_PREFIXES = (
    "Source/VCL/",       # vendored third-party VCL
    "Source/Archive/",   # units verified dead and removed from the build
)

# The unit that DEFINES the coupling, so it cannot be a consumer of it.
#
# main.pas holds four `MainForm.` references, all inside TMainForm's own
# methods -- `MainForm.Visible := false` in FormClose, `MainForm.fDebugger`
# in OnInputEvalReady, and so on. `MainForm` there IS `Self`. Rewriting them
# to `Self.` would drop the headline number by four without removing a single
# real dependency: that is metric cosmetics, and this project already refused
# the same trade once (F1-l declined to "clean" two dead units for the same
# reason).
#
# So they are EXEMPT rather than rewritten, which puts them on exactly the same
# footing as the facade exemption that has existed since F1: MainUi is exempt
# because it is the layer that DEFINES the anti-corruption boundary, main.pas is
# exempt because it is the layer that DEFINES the coupling. A subject is not
# audited by a rule it wrote for its own targets.
#
# A hard path, not a "does it declare MainForm" test, on purpose:
# Tools/PackMaker/main.pas and Tools/Packman/Main.pas also declare a global of
# that name and both are unrelated same-named units, so a declaration test
# would exempt the wrong two files.
GOD_FORM = "Source/main.pas"


def is_excluded(rel_path):
    """True when a repo-relative posix path is outside the measured surface."""
    rel = str(rel_path).replace("\\", "/")
    return any(rel.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def is_god_form(rel_path):
    """True for the unit that defines the god form (exempt from the ratchet)."""
    return str(rel_path).replace("\\", "/") == GOD_FORM


# ---------------------------------------------------------------------------
# Comment stripping
#
# Three tools needed this and each grew its own copy, all three of them wrong
# in the same way. The regex they all used was
#
#     re.compile(r"\{[^}]*\}|\(\*.*?\*\)", re.S)
#
# which stops at the FIRST closing brace. Pascal block comments nest, and this
# repo disables whole routines by wrapping them in a bare `{` ... `}` -- a
# disabled `begin/end` block is full of braces, so the match ended at the first
# `end;` inside and everything after it was scanned as if it were live code.
#
# The concrete casualty: devCFG.pas wraps ~40 lines of disabled code in a
# comment, and its `with MainForm do` inside was being charged to the ratchet
# as a live coupling. It was not live; the ratchet was simply unable to see
# the comment end.
#
# This walks the text once, carrying brace depth across lines, so a comment
# that opens and closes on the same line and a comment spanning forty both come
# out right. It lives here so the three tools cannot drift apart a third time.
# ---------------------------------------------------------------------------

def strip_pascal_code(text):
    """Return `text` with comments blanked and string literals emptied.

    Brace depth is tracked across line boundaries, so nested `{ }` inside a
    block comment cannot terminate it early, and `(* *)` comments are handled
    as well. `''` inside a literal is an escaped quote and does not end it.
    """
    out = []
    depth = 0        # >0 while inside a { } comment
    paren = 0        # >0 while inside a (* *) comment
    in_str = False
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        nxt2 = text[i:i + 2]
        if in_str:
            if ch == "'":
                if nxt2 == "''":
                    # Escaped quote: emit one marker, consume both chars.
                    out.append("''")
                    i += 2
                    continue
                # Closing quote: emit the marker and leave the literal.
                out.append("''")
                in_str = False
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if depth > 0 or paren > 0:
            # Inside a comment. `(* *)` wins over `{ }` so a brace inside a
            # paren comment does not open a second, unterminated brace region
            # -- that mistake swallowed the rest of the file in the first
            # draft of this function and the unit test caught it.
            if paren > 0:
                if nxt2 == "*)":
                    paren -= 1
                i += 1
                out.append("\n" if ch == "\n" else " ")
                continue
            if nxt2 == "(*":
                paren += 1
                i += 1
                out.append(" ")
                continue
            if ch == "{":
                depth += 1
                i += 1
                out.append(" ")
                continue
            if ch == "}":
                depth -= 1
                i += 1
                out.append(" ")
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        # code
        if nxt2 == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if nxt2 == "(*":
            paren += 1
            i += 2
            continue
        if nxt2 == "*)":
            paren = 0
            i += 2
            continue
        if ch == "{":
            depth += 1
            i += 1
            continue
        if ch == "}":
            depth = 0
            i += 1
            continue
        if ch == "'":
            in_str = True
            out.append("''")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)