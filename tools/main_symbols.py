#!/usr/bin/env python3
"""Cross-check a unit against the symbols main.pas publishes at unit scope.

Why this exists
---------------
The F1 ratchet (tools/mainform_baseline.py) counts exactly one shape of
dependency: ``MainForm.<member>``. That regex is structurally blind to every
*other* way a unit can depend on the god-form unit. The one that bites in
practice is a **bare** ``MainForm`` handed over as a dialog owner::

    with TProjectOptionsFrm.Create(MainForm) do try   // not matched by the
                                                     // ratchet, but still a
                                                     // real `uses main` edge

A unit can therefore satisfy the ratchet and still stop compiling the moment
`main` is dropped from its uses clause. This tool is the mechanical net for that
class of mistake: it extracts what main.pas publishes *at unit scope* in its
interface section -- type names, unit-level vars/consts and unit-level
routines -- and reports which of them a given unit still references.

Class *members* are deliberately excluded: they are only reachable through the
`MainForm` global, so `MainForm.<member>` is already covered by the ratchet, and
counting them here would only produce false positives.

`Application.MainForm` is excluded as well, and that exclusion is load-bearing.
It is the VCL's own property off `Forms`, not this project's global, and it
resolves with no `uses main` in sight. main.pas publishes `MainForm`, so a plain
identifier sweep charges every `Application.MainForm.<x>` read to main.pas and
calls a unit that has no such edge a leaker -- which is how `Utils.pas` was
reported as still coupled while holding nothing but two Win32 handle reads.
See the negative-lookbehind note on _IDENTIFIER for why the rule is copied
rather than derived.

Usage:
    python tools/main_symbols.py Source/Project.pas
    python tools/main_symbols.py Source/Project.pas --verbose

Exit code 0 = unit references no main.pas symbol, 1 = leaks remain.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"
MAIN = SOURCE / "main.pas"

_LINE_COMMENT = re.compile(r"//.*$")
_BLOCK_COMMENT = re.compile(r"\{[^}]*\}|\(\*.*?\*\)", re.S)
_STRING_LITERAL = re.compile(r"'(?:''|[^'])*'")

_TYPE_NAME = re.compile(r"^\s*(\w+)\s*=\s*(?:packed\s+|strict\s+)*"
                        r"(?:class|record|object|interface|set\s+of)\b", re.I)
_ENUM_TYPE = re.compile(r"^\s*(\w+)\s*=\s*(?:\(\s*)?(?:strict\s+)?"
                        r"(?:private\s+)?enum\b", re.I)
_OPEN_BLOCK = re.compile(r"=\s*(?:packed\s+|strict\s+)*"
                         r"(?:class|record|object|interface)\b", re.I)
_SECTION = re.compile(r"^\s*(var|const|type|resourcestring)\b", re.I)
_VAR_ENTRY = re.compile(r"^\s*(\w+)\s*:")
_ROUTINE = re.compile(r"^\s*(?:function|procedure|constructor|destructor)\s+(\w+)",
                      re.I)
_KEYWORDS = {
    "begin", "end", "uses", "unit", "type", "var", "const", "function",
    "procedure", "property", "class", "record", "object", "interface",
    "private", "public", "protected", "published", "strict", "packed",
    "resourcestring", "string", "integer", "boolean", "word", "byte",
    "set", "of", "and", "or", "not", "in", "is", "as", "nil", "true",
    "false", "self", "result", "if", "then", "else", "case", "with",
    "for", "while", "repeat", "until", "downto", "to", "try", "except",
    "finally", "raise", "goto", "array", "file", "out", "inout",
}


def strip_noise(text):
    """Drop comments and string literals so only real code is scanned."""
    text = _BLOCK_COMMENT.sub(" ", text)
    return "\n".join(_STRING_LITERAL.sub("''", _LINE_COMMENT.sub("", ln))
                     for ln in text.splitlines())


def _interface_part(text):
    """Return the unit text up to its implementation section."""
    m = re.search(r"(?mi)^\s*implementation\s*$", text)
    return text[:m.start()] if m else text


def unit_scope_symbols(text):
    """Identifiers the unit publishes at unit scope in its interface section.

    Walks the interface section while tracking ``= class/record/... end;``
    nesting, so class members are never mistaken for unit-level declarations.
    """
    names, depth, in_section = set(), 0, None
    for line in _interface_part(text).splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if depth == 0:
            sec = _SECTION.match(stripped)
            if sec:
                in_section = sec.group(1).lower()
                continue
            for pat in (_TYPE_NAME, _ENUM_TYPE):
                m = pat.match(stripped)
                if m:
                    names.add(m.group(1))
            # A unit-level routine is never written as Class.Method.
            m = _ROUTINE.match(stripped)
            if m and "." not in m.group(1):
                names.add(m.group(1))
            if in_section in ("var", "const", "resourcestring"):
                m = _VAR_ENTRY.match(line)
                if m and not _ROUTINE.match(stripped):
                    names.add(m.group(1))
        if _OPEN_BLOCK.search(stripped):
            depth += 1
        elif depth and re.match(r"(?i)^end\b", stripped):
            depth -= 1
    return {n for n in names if n and n.lower() not in _KEYWORDS
            and not n[0].isdigit()}


# Every identifier the code names, with one exclusion.
#
# `(?<!Application\.)` is the negative assertion this tool was missing, and it
# is copied verbatim from the ratchet (`_MAINFORM_REF` / `_MAINFORM_OWNER` in
# mainform_baseline.py) on purpose. Copying is the whole point: the two tools
# answer the same question -- "does this unit name something main.pas owns?" --
# so a spelling one accepts and the other charges is a defect in the *pair*,
# and the only durable fix is to make the definitions literally identical.
# Deriving it independently is what produced the third such disagreement, and
# the ratchet already carries the rationale in prose at the definition.
#
# Without it, main.pas's `MainForm` export matched the tail of
# `Application.MainForm.Handle`: the unit had no `uses main` edge at all, yet
# every audit called it a leaker. The fix is NOT to weaken the check -- that
# would have silenced a correct tool to agree with a wrong one -- but to remove
# the edge the check was honestly complaining about (Utils.pas now goes through
# MainUi.MainFormHandle), and to align the definition so the complaint is not
# raised spuriously in the first place.
#
# IGNORECASE closes the matching hole from the other side: `Application.mainform`
# is the same property spelled differently, and a case-sensitive sweep would
# miss it and let a real `MainForm` in the same file hide behind the spelling.
# The ratchet made the same call for the same reason.
#
# A caveat worth stating rather than hiding: the assertion is a negative
# LOOKBEHIND, so it only guards the 12 characters `Application.` immediately
# before the identifier. `Application . MainForm` (spaced) or an aliased
# `Forms.Application.MainForm` reached through a local `with` are NOT covered.
# That is the same blind spot the ratchet has, so the two stay in agreement --
# which is the property being protected. Tightening both is a separate change.
_IDENTIFIER = re.compile(r"(?<!Application\.)\b[A-Za-z_]\w*\b", re.IGNORECASE)


def referenced(path):
    code = strip_noise(path.read_text(encoding="utf-8-sig", errors="replace"))
    return set(_IDENTIFIER.findall(code))


def main(argv):
    verbose = "--verbose" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__)
        return 2
    target = (ROOT / args[0]).resolve()
    if not target.exists():
        print("missing unit: %s" % target)
        return 2

    syms = unit_scope_symbols(
        MAIN.read_text(encoding="utf-8-sig", errors="replace"))
    own = unit_scope_symbols(
        target.read_text(encoding="utf-8-sig", errors="replace"))
    leaks = sorted(syms & referenced(target) - own)

    print("main.pas publishes %d unit-scope symbols; %s references %d of them"
          % (len(syms), target.name, len(leaks)))
    if not leaks:
        print("  (none -- unit is free of main.pas symbols)")
    for name in leaks:
        if not verbose:
            print("  %s" % name)
            continue
        for i, line in enumerate(target.read_text(
                encoding="utf-8-sig", errors="replace").splitlines(), 1):
            if re.search(r"\b%s\b" % re.escape(name), line):
                print("  %5d: %s" % (i, line.strip()))
    return 1 if leaks else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
