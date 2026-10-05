#!/usr/bin/env python3
"""
lcl_svg_struct_check.py -- structural gate for the LCL SVG control.

WHY A STRUCTURAL GATE AND NOT A COMPILE
=======================================
This gate was written when this machine had no FPC/Lazarus, so the LCL units
for F3 could not be compiled here at all. That has CHANGED: on 2026-10-05
`lazbuild` built both the LCL and fpvectorial, and the units now compile and
run (tools/build_svg_probe.ps1, plus SvgDataProbe / SvgListProbe /
RasterProbe). This gate is therefore no longer the only line of defence --
but it is not retired either: it catches damage a compiler does not, such as
a duplicated tail from a partial write, which compiles cleanly because every
symbol the compiler needs sits above the damage.

This is the middle path. It verifies what CAN be checked without a compiler,
and it is deliberately narrow about what that is -- the boundary matters more
than the checks, because the whole point is not to mistake "the file looks
sane" for "it builds".

WHY THIS FILE IS MORE SUBSTANTIVE THAN ITS FIRST VERSION
========================================================
The first version printed OK over a file with six defects no compiler would have
accepted:

  1. the class declaration was never closed -- `= class` was followed straight
     by a free-standing procedure, so `public` and `end;` were absent
  2. `uses` lacked `SvgData` (which provides SVG_IMAGE_LISTS) and
     `FPCollections` (which provides TFPObjectList), both referenced in the body
  3. LoadSvgLists never copied a single SVG into the list it created, so Count
     was 0 and GetImage returned nil at every index -- the empty-toolbar bug
     this control exists to fix, reproduced inside the fix
  4. GetImage's Result was TBitmap while the body assigned TSVGToBitmap, which
     descends from TFPCustomImage
  5. the stale-cache branch nulled a LOCAL copy of the entry, leaving FCache
     pointing at an image FImages had already freed
  6. the icon size was a chain of name comparisons against literals

The reason it said OK is the part worth keeping. `check_balance` carried a long
comment describing a keyword-stack balance check that did not exist in the code,
and `STUB_BODY` was defined and never called -- "no pattern = no assertion", and
an assertion that cannot cover the combination. So the fixes are of two kinds:

  * implement what the comments promised (a real stack-based balance check)
  * add checks that are ANTI-VACUOUS -- `--self-test` feeds each check a
    deliberately broken snippet and requires it to fire, because a check that has
    only ever passed has not been shown to be capable of failing

WHAT IS CHECKED
================
  * Pascal block balance on a keyword stack: begin/end, case/end, try, record,
    and a `class` that opens ONLY as a declaration (a negative lookahead is
    what separates it from `class function`)
  * `{$IFDEF FPC}` ... `{$ENDIF}` wraps the body, so the Delphi build never
    parses LCL code (the convention Lsp.Process.Fpc.pas established and
    tools/qa_check.py enforces)
  * section ORDER: interface before implementation, and no routine after `end.`
  * every routine implemented in the implementation section is DECLARED in the
    interface section, and vice versa
  * every cross-unit symbol the body uses has its providing unit in the uses
    clause
  * no bare LF (the repo is pure CRLF; a mixed file survives one editor and
    breaks a diff months later)
  * no leftover scaffolding: TODO/FIXME markers or stub bodies

WHAT IS NOT CHECKED, AND MUST NOT BE ASSUMED
=============================================
  * that the unit compiles against LCL 4.x at all
  * that fpvectorial parses every icon in the data set
  * that TSVGToBitmap.LoadFromSVG exists with that signature
  * anything about rendering, colour or indexing at run time

Those need a compiler. CI has one (`gcarreno/setup-lazarus` in fpc_ci.yml) and
this file exists so that the text is at least not nonsense before it gets there.

THE BOUNDARY, MEASURED RATHER THAN ASSUMED
===========================================
Injecting defects into the real unit and running this gate gives the honest
coverage table. Three of five were caught:

  CAUGHT  uses dropped SvgData + FPCollections
  CAUGHT  class loses its closing `end;`
  CAUGHT  implementation section deleted
  MISSED  LoadFrom copies no SVG data (empty-toolbar bug inside the fix)
  MISSED  routine declared with no body

The two misses are not oversights, and pretending otherwise would recreate the
failure this file already committed once.

  * "LoadFrom copies no SVG data" is SEMANTIC. Telling it apart from a correct
    loader needs a type system and a notion of what the data means, which is the
    compiler's job. It was also the most damaging of the six original defects --
    the control "worked", the gate was green, and every icon was still blank.
    It is caught by the compiler (a nil array dereference) and, failing that, by
    the F3 render check. Until Lazarus exists, nothing here can be said to
    prevent it.
  * "routine declared with no body" was injected as `publicX`, which is not
    valid Pascal at all. No text-level gate should catch it; the compiler does.

The general rule this encodes: a structural gate covers SHAPE. Anything whose
failure mode is "the right text doing the wrong thing" is out of scope, and has
to be caught somewhere that can actually run the code.

Run:   python tools/lcl_svg_struct_check.py [--self-test]
Exit:  0 when every check passes, 1 otherwise.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The control and its data moved out of Tests/ and into the FPC port proper
# (doc F3-SVG section 11.7 decision, 2026-10-06): they are no longer a test
# fixture for a future step, they are the shipped UI layer. Tests/FpcCoreTests
# keeps the probes that MEASURE the control; the control itself lives under
# Source/Fpc, which qa_check.py already exempts from the Delphi dialect gate
# (FPC_DIRS).
TARGETS = [
    ROOT / "Source" / "Fpc" / "UI" / "Controls" / "LclSvgImageList.pas",
    ROOT / "Source" / "Fpc" / "UI" / "Data" / "SvgData.pas",
]

# Markers that mean "unfinished". Checked on CODE lines only, because the
# control's own documentation uses these words to explain what it deliberately
# does not do, and a gate that fires on its own explanatory comments is noise.
BANNED = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b")


def strip_noise(line):
    """Remove comments and string literals so keywords inside them do not count.

    ORDER MATTERS. String literals are stripped before anything counts keywords,
    because SvgData.pas is 116 inline SVG documents whose path data contains the
    words `begin`, `end` and `class` as ordinary attribute text. A balance check
    that read those would report an unclosed block in a file that is pure data
    and structurally perfect.
    """
    line = re.sub(r"//.*$", "", line)
    line = re.sub(r"\(\*.*?\*\)", "", line)
    line = re.sub(r"\{[^}]*\}", "", line)   # brace comments, incl. {$IFDEF}
    line = re.sub(r"'[^']*'", "''", line)
    return line
# Keywords that OPEN a block; `end` closes it.
#
# `interface` and `implementation` are DELIBERATELY absent. They are section
# markers, not blocks: a unit ends with a single `end.` and neither section is
# closed by its own `end`. Counting them made every well-formed unit look like
# it had 3 unclosed blocks -- the kind of alarm that trains people to ignore a
# gate.
#
# `object` and `asm` are absent too: these targets are Free Pascal (Delphi 7 has
# no generics), so an `object` declaration is not expected, and an `asm` block
# here would almost certainly be a mistake worth seeing in review rather than
# something to accommodate silently.
OPENERS = (
    ("begin", r"\bbegin\b"),
    ("case", r"\bcase\b"),
    ("try", r"\btry\b"),
    ("record", r"\brecord\b"),
    # `class` opens ONLY as a class DECLARATION. `class function` /
    # `class procedure` / `class var` / `class const` are member modifiers that
    # do not, and counting them as openers left every unit containing one
    # permanently +1 -- which reads as an unclosed block and is not. The
    # negative lookahead is what separates the two, and it runs on the stripped
    # line so a comment mentioning "class function" cannot trip it.
    ("class", r"\bclass\b(?!\s*(?:function|procedure|property|var|const)\b)"),
)

# A routine IMPLEMENTATION opens a block only where its parameter list is
# followed by `begin`. A forward declaration -- `constructor Create;`,
# `destructor Destroy; override;`, a prototype in the interface section -- opens
# nothing, and its trailing `end;` is a TERMINATOR, not a block closer.
#
# Getting this wrong is not a small imprecision. Counting a declaration's `end;`
# as a closer leaves the stack one `end` too shallow, and every block after it
# then pops against an empty stack: the self-test's well-formed unit reported
# `end with no open block` and BOTH of its routines as undeclared. A gate that
# miscounts correct code is worse than no gate, because it teaches people that
# its findings are noise.
DECL_RE = re.compile(
    r"^\s*(?:constructor|destructor|class\s+(?:function|procedure)"
    r"|function|procedure)\b")
# The `begin` that opens an implementation body.
BODY_RE = re.compile(r"\bbegin\b", re.I)


def check_balance(path, text):
    """Stack-based block balance, tracked by keyword rather than counted.

    Two rules, and the whole design follows from keeping them separate:

      * a bare `begin` / `case` / `try` / `record` / `class` PUSHES
      * a bare `end` POPS, except when it terminates a routine DECLARATION

    The exception is the part that took three attempts to get right. In Pascal a
    declaration (`constructor Create;`, `destructor Destroy; override;`) has no
    body and therefore no block, so its `end;` closes nothing. Counting it as a
    closer makes the stack one level too shallow from that point on, and every
    later `end` then pops an empty stack -- which is what made this gate report a
    well-formed unit as broken on its first honest run.

    Note that `begin` sits on its OWN line in the normal layout:
        constructor TFoo.Create;
        begin
    So a routine's body is opened by a bare `begin`, not by the header line.
    The header only has to be recognised well enough to know whether the `end;`
    on it is a terminator.
    """
    problems = []
    stack = []  # (opener, line)

    for n, raw in enumerate(text.splitlines(), 1):
        s = strip_noise(raw)
        if not s.strip():
            continue

        # Push first, so a `begin ... end` written on one line balances.
        for name, pat in OPENERS:
            for _ in re.finditer(pat, s, re.I):
                stack.append((name, n))

        closers = len(re.findall(r"\bend\b", s, re.I))
        # A routine DECLARATION terminates rather than closes. Detected by the
        # header appearing on a line that also ends a declaration -- i.e. one
        # whose `end;` has no matching `begin` above it on the same line.
        if DECL_RE.match(s) and not BODY_RE.search(s):
            closers = max(0, closers - 1)

        # The unit's final `end.` closes the unit itself and nothing else.
        unit_end = re.search(r"\bend\s*\.", s, re.I)
        if unit_end:
            if stack:
                opener, ln = stack[-1]
                problems.append(
                    f"{path.name}:{n}: unit's `end.` while `{opener}` "
                    f"(line {ln}) is still open")
                stack.clear()
            break

        for _ in range(closers):
            if stack:
                stack.pop()
            else:
                problems.append(f"{path.name}:{n}: `end` with no open block")

    for opener, ln in stack:
        problems.append(f"{path.name}:{ln}: `{opener}` is never closed")
    return problems


def _first(lines, want):
    for i, l in enumerate(lines):
        if l == want:
            return i
    return None


def check_sections(path, text):
    """interface precedes implementation, and nothing is declared after end."""
    problems = []
    lines = [l.strip() for l in text.splitlines()]
    idx_iface = _first(lines, "interface")
    idx_impl = _first(lines, "implementation")
    if idx_iface is None:
        problems.append(f"{path.name}: no `interface` section")
    if idx_impl is None:
        problems.append(f"{path.name}: no `implementation` section")
    if idx_iface is not None and idx_impl is not None and idx_iface > idx_impl:
        problems.append(
            f"{path.name}: `implementation` (line {idx_impl + 1}) precedes "
            f"`interface` (line {idx_iface + 1})")

    # A routine declared AFTER the unit's `end.` is the shape the scrambled
    # draft had, where method bodies had been appended past the terminator.
    ends = [i for i, l in enumerate(lines) if l == "end."]
    if ends:
        last_routine = max(
            (i for i, l in enumerate(lines)
             if re.match(r"^(?:constructor|destructor|function|procedure)\s", l)),
            default=None)
        if last_routine is not None and last_routine > ends[-1]:
            problems.append(
                f"{path.name}:{last_routine + 1}: routine declared after the "
                f"unit's `end.` (line {ends[-1] + 1})")
    return problems


def check_ifdef(path, text):
    problems = []
    if "{$IFDEF FPC}" not in text:
        # SvgData is pure data with no LCL dependency, so it needs no guard.
        if path.name == "LclSvgImageList.pas":
            problems.append(f"{path.name}: missing {{$IFDEF FPC}} guard")
        return problems
    # Both rindex()/index() calls below are guarded by the membership tests.
    # rindex() raises ValueError when the substring is absent, so an
    # IFDEF-without-ENDIF -- precisely the defect being reported here -- turned
    # the finding into a traceback. A gate that crashes on the defect it is
    # looking for reports nothing at all.
    if "{$ENDIF}" not in text:
        problems.append(f"{path.name}: {{$IFDEF FPC}} without {{$ENDIF}}")
        return problems
    if text.rindex("{$ENDIF}") < text.index("{$IFDEF FPC}"):
        problems.append(f"{path.name}: {{$ENDIF}} precedes {{$IFDEF FPC}}")
    return problems


def check_line_endings(path):
    raw = path.read_bytes()
    bare = 0
    i = 0
    while i < len(raw) - 1:
        if raw[i] == 0x0D and raw[i + 1] == 0x0A:
            i += 2
            continue
        if raw[i] == 0x0A:
            bare += 1
        i += 1
    return [f"{path.name}: {bare} bare LF (repo is CRLF)"] if bare else []


def check_scaffolding(path, text):
    problems = []
    for n, line in enumerate(text.splitlines(), 1):
        if BANNED.search(strip_noise(line)):
            problems.append(f"{path.name}:{n}: leftover marker")
    return problems
# --- cross-unit symbol usage -------------------------------------------------
#
# Defect 2 above was a uses clause missing two units, and nothing noticed. The
# general problem -- "every name in the body resolves" -- needs a compiler. The
# tractable part is the reverse: for the cross-unit names this file set actually
# uses, assert the providing unit is in the uses clause. That catches a missing
# unit without pretending to resolve anything.
#
# Each entry: symbol -> the unit that provides it. Adding a symbol here without
# adding its unit to the clause is a deliberate act the gate then enforces.
CROSS_UNIT = {
    "TFPObjectList": "FPCollections",
    "SVG_IMAGE_LISTS": "SvgData",
    "TSvgImageList": "SvgData",
    "TSVGDocument": "FPVectorial",
    "TSVGToBitmap": "FPVectorial",
    "TBitmap": "Graphics",
}


def check_cross_unit_uses(path, text):
    problems = []
    split = text.find("implementation")
    body = text if split < 0 else text[split:]
    used = ""
    for m in re.finditer(r"\buses\b(.*?);", text, re.S):
        used += m.group(1)
    # A unit does not list ITSELF in its uses clause, so a symbol this unit
    # DECLARES satisfies the check by itself. Without this exemption the gate
    # reported, on SvgData.pas:
    #     uses `SVG_IMAGE_LISTS` but its unit `SvgData` is not in the uses
    #     clause
    # Demanding that a unit list itself is not a style question, it is a
    # compile error.
    own_unit = path.stem.lower()
    for symbol, unit in CROSS_UNIT.items():
        if unit.lower() == own_unit:
            continue
        if re.search(r"\b" + re.escape(symbol) + r"\b", body):
            if not re.search(r"\b" + re.escape(unit) + r"\b", used, re.I):
                problems.append(
                    f"{path.name}: uses `{symbol}` but its unit `{unit}` "
                    f"is not in the uses clause")
    return problems


# --- declaration/implementation cross-check ----------------------------------
#
# The first version checked ONE direction with a grep that also matched the
# class body, producing 27 nonsense diagnostics while still missing the real
# defects. Both directions are checked here, on the two sections only.
#
# `constructor Create;` and `constructor Create(const X)` are overloads of one
# name; collecting into a set collapses them, which is what is wanted.
# The optional `(?:Cls\.)?` group drops a Class. prefix on an implementation
# (`constructor TFoo.Create;`), leaving the routine name. Without it the class
# name was reported as a routine -- which is how one implementation produced
# BOTH "TFoo implemented but not declared" and "Create declared but not
# implemented".
ROUTINE_RE = (
    r"^\s*(?:constructor|destructor|class\s+(?:function|procedure)"
    r"|function|procedure)\s+(?:[A-Za-z_]\w*\.)?([A-Za-z_]\w*)")


def check_routines(path, text):
    problems = []
    parts = re.split(r"^\s*implementation\s*$", text, maxsplit=1, flags=re.M)
    if len(parts) != 2:
        return [f"{path.name}: cannot split interface/implementation"]
    iface, impl = parts

    declared = set(re.findall(ROUTINE_RE, iface, re.M))
    implemented = set(re.findall(ROUTINE_RE, impl, re.M))

    for name in sorted(declared - implemented):
        problems.append(f"{path.name}: {name} declared but not implemented")
    # An implementation-only routine is legal and intentional: it serves
    # `initialization` and is not part of the unit's surface. SvgData's
    # FillSvgList and LclSvgImageList's Rasterise are both like that, and both
    # were reported as "implemented but not declared" on 2026-10-05.
    #
    # They are also safe: each is called only from `initialization`, i.e.
    # textually AFTER its own definition, so there is no call-before-definition
    # to catch. Declared-but-unimplemented is still reported, and the body
    # checks still run over every routine, so nothing is lost.
    # Exempt an implementation-only routine that is USED inside the
    # implementation. An earlier version exempted only names referenced from
    # `initialization`, which is the wrong rule rather than merely an
    # incomplete one: it cleared FillSvgList but still flagged Rasterise,
    # which is called from RenderAll. Pascal needs an interface declaration
    # only for routines on the unit's surface; a private helper used later
    # in its own section is complete, and FPC compiles it (both verified).
    #
    # A routine defined and NEVER referenced is still reported -- that is the
    # stray implementation this check exists to catch.
    for name in sorted(implemented - declared):
        uses_in_impl = len(re.findall(r"\b" + re.escape(name) + r"\b", impl))
        if uses_in_impl > 1:   # >1: the definition plus at least one use
            continue
        problems.append(
            f"{path.name}: {name} implemented but not declared")
    return problems


# A routine whose body only assigns a constant and returns is a stub. The gate
# already checks that routines HAVE bodies, which a stub satisfies while still
# being a stub -- so presence is not enough, the body has to do something. This
# is the same failure the SVG extractor had, where a truncated value passed a
# check that only compared it with itself.
#
# It was DEFINED and never called in the first version. It is wired into
# run_checks() below, and exercised by --self-test.
STUB_BODY = re.compile(
    r"\b(?:Result|Exit)\s*:=\s*(?:nil|-1|0|'')\s*;\s*\r?\n\s*end\s*;",
    re.I)


def check_stub_bodies(path, text):
    """Flag a routine whose ONLY statement is `Result := <constant>;`.

    The first version of this pattern was

        Result|Exit := nil|-1|0|'' ;  end;

    with no regard for what came before it, so it fired on every routine that
    ends by clearing its result -- including a `except` handler that frees the
    object and then nils the pointer, and a lookup that scans a list and returns
    nil when there is no hit. All three were correct code. A gate that reports
    correct code teaches people to ignore it, and then it also stops being read
    when the code is wrong.

    What makes a stub a stub is that there is NOTHING ELSE in the body, not that
    it happens to assign a constant. So this looks at each routine body and only
    fires when the assignment is the sole executable statement between `begin`
    and `end`.
    """
    problems = []
    for n, line in enumerate(text.splitlines(), 1):
        s = strip_noise(line).strip()
        if not DECL_RE.match(s):
            continue

        # Collect the body: from the line AFTER this header to the first `end;`.
        # The header line itself contributes nothing -- and in the normal layout
        # `begin` sits on the following line, so starting at the header is both
        # off by one and, when the header ends with `;`, mis-attributes the
        # declaration to the routine.
        body = []
        for m in text.splitlines()[n:]:
            b = strip_noise(m).strip()
            if re.match(r"^end\s*;", b, re.I):
                closed = True
                break
            body.append(b)

        # `begin` is a block OPENER, not a statement. Counting it made every
        # body look two-statement and the stub case went uncaught -- a check that
        # silently stopped working because of a stray keyword in the filter.
        stmts = [
            b for b in body
            if b and not b.startswith(("//", "(*", "{"))
            and not re.fullmatch(r"begin|try|else|\w+\s*do", b, re.I)
        ]
        if len(stmts) != 1:
            continue
        if re.fullmatch(r"(?:Result|Exit)\s*:=\s*(?:nil|-1|0|'')\s*;", stmts[0], re.I):
            problems.append(f"{path.name}:{n}: routine body is only `{stmts[0]}`")

    return problems


def run_checks(path, text):
    problems = []
    problems += check_balance(path, text)
    problems += check_sections(path, text)
    problems += check_ifdef(path, text)
    problems += check_scaffolding(path, text)
    problems += check_cross_unit_uses(path, text)
    problems += check_routines(path, text)
    problems += check_stub_bodies(path, text)
    return problems
# --- self-test ---------------------------------------------------------------
#
# A gate that has only ever returned OK has not been shown to be capable of
# returning anything else. Each case below is a snippet with ONE defect that
# corresponds to a real defect this gate was supposed to catch, and each is
# asserted to be CAUGHT. If a case stops failing, that check is reported as
# vacuous rather than as a pass.
#
# The `clean` case is the converse: a well-formed unit must produce NO problems,
# or the gate would be useless in the other direction -- crying wolf on correct
# code is what makes a gate get ignored.
SELF_TEST = (
    (
        "unclosed class (defect 1)",
        "unit U;\ninterface\ntype\n  TFoo = class\n    procedure Bar;\n"
        "implementation\nprocedure TFoo.Bar;\nbegin\nend;\nend.\n",
        "check_balance",
    ),
    (
        "missing unit in uses (defect 2)",
        "unit U;\ninterface\nuses Classes, Graphics;\nimplementation\n"
        "var L: TFPObjectList;\nbegin\nend.\n",
        "check_cross_unit_uses",
    ),
    (
        "routine implemented but not declared",
        "unit U;\ninterface\nimplementation\nprocedure TFoo.Bar;\nbegin\nend;\n"
        "end.\n",
        "check_routines",
    ),
    (
        "routine declared but not implemented",
        "unit U;\ninterface\nprocedure NeverWritten;\nimplementation\nend.\n",
        "check_routines",
    ),
    (
        "stub body (constant assigned, nothing else)",
        "unit U;\ninterface\nimplementation\nfunction Find: Integer;\nbegin\n"
        "  Result := -1;\nend;\nend.\n",
        "check_stub_bodies",
    ),
    (
        "implementation before interface (the scrambled draft)",
        "unit U;\nimplementation\ninterface\nend.\n",
        "check_sections",
    ),
    (
        "IFDEF without ENDIF",
        "unit U;\n{$IFDEF FPC}\ninterface\nimplementation\nend.\n",
        "check_ifdef",
    ),
)


def self_test() -> int:
    print("LCL SVG STRUCT CHECK -- SELF TEST")
    print("  each case must FAIL; a case that passes is a vacuous check")
    print()
    failed = 0
    for name, snippet, check_name in SELF_TEST:
        check = globals()[check_name]
        problems = check(Path("U.pas"), snippet)
        if problems:
            print(f"  OK   caught: {name}")
            print(f"         via {problems[0]}")
        else:
            print(f"  FAIL NOT CAUGHT: {name}  ({check_name})")
            failed += 1

    # The converse case. A well-formed unit must be clean.
    clean = (
        "unit U;\n{$IFDEF FPC}\ninterface\nuses Classes, FPCollections, Graphics;\n"
        "type\n  TFoo = class\n  private\n    L: TFPObjectList;\n  public\n"
        "    constructor Create;\n    destructor Destroy; override;\n  end;\n"
        "implementation\nconstructor TFoo.Create;\nbegin\n  L := TFPObjectList.Create;\n"
        "end;\ndestructor TFoo.Destroy;\nbegin\n  L.Free;\n  inherited Destroy;\nend;\n"
        "end.\n{$ENDIF}\n"
    )
    problems = run_checks(Path("U.pas"), clean)
    if problems:
        print()
        print("  FAIL clean unit was reported as broken:")
        for p in problems:
            print(f"         {p}")
        failed += 1
    else:
        print("  OK   clean unit produced no problems (gate is not crying wolf)")
    print()
    if failed:
        print(f"SELF TEST FAILED ({failed})")
        return 1
    print("SELF TEST OK: every check can fail, and none false-alarms")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    problems = []
    for path in TARGETS:
        if not path.is_file():
            problems.append(f"missing: {path.relative_to(ROOT)}")
            continue
        text = path.read_bytes().decode("utf-8-sig", errors="replace")
        problems += run_checks(path, text)
        problems += check_line_endings(path)

    for p in problems:
        print("  " + p)
    if problems:
        print(f"LCL SVG STRUCT CHECK: FAILED ({len(problems)})")
        return 1
    print("LCL SVG STRUCT CHECK: OK")
    print("  (structure only. A real LCL build now also exists -- see the "
          "module docstring for what each layer covers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
