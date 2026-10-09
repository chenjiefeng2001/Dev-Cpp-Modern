#!/usr/bin/env python3
"""How much of main.pas's blocker list is NAMESPACE SPELLING rather than
missing functionality?

WHY THIS QUESTION IS WORTH A TOOL
=================================
doc/F3-SVG section 18 concluded that compiling ANY form means compiling
main.pas, and section 19.8 recommended attacking main.pas rather than inverting
the MainUi facade. Before committing a schedule to that, the 44 "absent" units
in main's closure need splitting, because two very different things hide under
that one label:

  A. PREFIX-ONLY. The unit exists in the LCL/RTL under its plain Delphi name and
     the only thing wrong is the namespace prefix: `System.SysUtils` where FPC
     wants `SysUtils`. This is spelling. It is real work but bounded, and it
     needs no new code.

  B. REAL MISSING. The unprefixed tail does not exist either
     (`Vcl.WinXCtrls`, `Vcl.Styles.Hooks`). This is functionality.

Conflating them would make the main.pas effort look like 44 units of porting
work when most of it is 27 renames. Conflating them the other way -- calling a
prefix a free lunch -- would hide 21 real blockers.

WHAT IS MEASURED, AND HOW
=========================
1. The transitive uses-closure of main.pas, using the same extractor as
   f3_compile_cost.py so the two tools cannot disagree about the graph.
2. Every UNRESOLVED unit with a dot in it, split into A and B.
3. Whether the A set really is compilable. This is the part a name comparison
   cannot establish, so it is PROVEN by generating one throwaway program that
   uses every group-A unit with its prefix dropped and compiling it. If a unit
   is in group A but still fails to compile, the tool says so and the group is
   wrong. This is the same "loads is weaker than you think" trap that
   SynRcProbe exists to avoid, applied to namespaces.

The compiled check is what makes this worth more than the spelling. It is
exactly the sort of claim that reads plausibly and is false: `Vcl.Themes` has a
tail `themes` and LCL HAS a themes unit, but whether `uses Themes` links under
this widgetset is a question only the compiler can answer.

USAGE
  python tools/f3_namespace_alias.py            # measure
  python tools/f3_namespace_alias.py --ratchet  # gate: group B must not grow
  python tools/f3_namespace_alias.py --write-baseline
"""

import argparse
import collections
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Reuse the closure walker rather than reimplementing it.
#
# Two copies of the uses-extractor would eventually disagree, and when they do
# the disagreement is invisible: both print plausible tables. Section 18.6
# already records this class of bug (a dotted-unit tokenizer that silently
# dropped 17 units), so the discipline here is import, do not copy.
# ---------------------------------------------------------------------------
spec = importlib.util.spec_from_file_location(
    "_f3cc", ROOT / "tools" / "f3_compile_cost.py")
_cc = importlib.util.module_from_spec(spec)
_argv = sys.argv
sys.argv = ["f3_compile_cost.py"]           # the module parses argv at import
try:
    spec.loader.exec_module(_cc)
except SystemExit:
    raise SystemExit("could not import f3_compile_cost.py")
finally:
    sys.argv = _argv


# ---------------------------------------------------------------------------
# What FPC can actually see.
#
# COMPILED .ppu FILES, not source names. Two reasons, and the second one bit:
#
#   1. A .ppu is proof the unit was built for THIS target and widgetset. A
#      source file is only a promise.
#   2. This Lazarus tree does not even contain sources for units it ships
#      compiled. Verified by walking it: lcl\tabctrls.pp, lcl\richtext.pp and
#      lcl\panels.pp are all absent from C:\lazarus\lcl, yet the standard LCL
#      certainly has those units. Scanning source names therefore reports them
#      as "NOT FOUND", which is a fact about this installation, not about LCL.
#
# The first version of this file scanned source names and reported SysUtils,
# Classes, Math and Forms as having no counterpart -- a confident, entirely
# wrong table produced by one bug: stripping extensions with f[:-4] when
# '.pp' is three characters and '.pas' is four, so 'forms.pp' became 'form'.
# Measured against compiled units instead, the answer is stable.
# ---------------------------------------------------------------------------
# The LCL/component set first, then the FPC UNITS tree.
#
# The second group is not optional. Without it the first measurement reported
# SysUtils, Classes, Math, Types, Variants, Contnrs, DateUtils, SyncObjs and
# WideStrUtils as "real missing" -- i.e. it claimed that nine RTL units FPC
# definitely ships do not exist. They are in fpc\...\units\x86_64-win64\rtl and
# friends, which is a different tree from the one being scanned.
#
# That produced a table reading "33% is just spelling" when the true figure was
# 56%, and it biased the conclusion in the direction that looks worse for the
# work. Both halves of this mistake were invisible because every row was
# individually plausible.
UNIT_DIRS = [
    r"C:\lazarus\lcl\units\x86_64-win64",
    r"C:\lazarus\components\lazutils\lib\x86_64-win64",
    r"C:\lazarus\components\synedit\units\x86_64-win64",
    r"C:\lazarus\components\lazcontrols\lib\x86_64-win64",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\rtl",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\rtl-objpas",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\rtl-generics",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\rtl-extra",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\fcl-base",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\winunits-base",
    r"C:\lazarus\fpc\3.2.2\units\x86_64-win64\winunits-jedi",
]

FU_ORDER = [                      # same -Fu order as the probe build scripts
    r"C:\lazarus\lcl\units\x86_64-win64\win32",
    r"C:\lazarus\lcl\units\x86_64-win64",
    r"C:\lazarus\components\lazutils\lib\x86_64-win64",
    # FPC-side units, so a port/shim entry can be verified by COMPILING it
    # rather than by looking at it -- the strongest check available here and
    # the only one that exercises the uses clause and the class declarations.
    str(ROOT / "Source" / "Fpc" / "UI" / "Controls"),
    str(ROOT / "Source" / "Fpc" / "UI" / "Compat"),
    str(ROOT / "Source" / "Fpc" / "UI" / "Data"),
    str(ROOT / "Source"),
]

FPC = r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"


def compiled_units():
    """Unit names FPC can link, read off real .ppu files."""
    names = set()
    for d in UNIT_DIRS:
        p = pathlib.Path(d)
        if not p.is_dir():
            continue
        for ppu in p.rglob("*.ppu"):
            names.add(ppu.stem.lower())
    return names


def shim_for(dotted):
    """An FPC compatibility shim that satisfies this dotted unit name, if any.

    Added after Source/Fpc/UI/Compat/Vcl.VirtualImage.pas. The mechanism is the
    one F3-6 used for TSynRCSyn: the Delphi tree keeps `uses Vcl.VirtualImage`,
    and the FPC search path resolves that name to a unit we wrote.

    It matters for the REPORTING, not for the counts. Once the shim exists the
    dotted name resolves, so `Vcl.VirtualImage` leaves the absent list and the
    "renamed into ours" group goes 1 -> 0. Nothing about the underlying
    classification improved; a file appeared. Reporting only the new numbers
    would show progress that the tool did not measure, so the report states the
    original classification alongside the mechanism that now satisfies it.

    The FILENAME is not enough to identify a shim, and trusting it was the first
    version's bug -- twice over. The first attempt assumed the shim sat directly
    in Source/Fpc/, which is wrong (it is in Source/Fpc/UI/Compat/), so the
    report printed "unresolved" while the mechanism was demonstrably working.
    The second attempt looked for the right file but still trusted the path.

    So the test is now the one that cannot drift: walk the FPC tree and find the
    unit that DECLARES this dotted name. A file named right but declaring
    something else is not a shim, and a file declaring the right name wherever it
    lives is.
    """
    decl = re.compile(r"(?mi)^\s*unit\s+%s\s*;" % re.escape(dotted))
    # Search ALL of Source/ except the vendored trees, NOT just Source/Fpc.
    #
    # Searching only Source/Fpc made invariant 2 ("lives in the FPC tree")
    # unreachable by construction: a misplaced shim was never FOUND, so the check
    # that rejects it could never run. An invariant nobody can violate is not an
    # invariant. Searching wider means a shim dropped into Source/UI is located
    # and then rejected on its location, which is the failure worth reporting.
    #
    # Source/VCL is excluded on purpose. The vendored Delphi tree really does
    # declare units like `SynHighlighterRC`; treating one of those as our FPC shim
    # would invert the entire point of the mechanism.
    source_root = ROOT / "Source"
    if not source_root.is_dir():
        return None
    for pas in sorted(source_root.rglob("*.pas")):
        parts = pas.relative_to(ROOT).parts
        if "VCL" in parts or "Archive" in parts:
            continue
        try:
            text = pas.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if decl.search(text):
            return pas
    return None


def _declared_symbols(pas):
    """Public type ALIASES this shim publishes: [(name, target_name), ...].

    Aliases only, and that restriction is the point. A shim is required to
    re-export the ORIGINAL symbol name onto an existing implementation; a shim
    that declared a fresh class would be a port wearing a shim's clothes, and
    the canonical `Vcl.VirtualImage` declares none.
    """
    try:
        text = pas.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    body = re.split(r"(?mi)^\s*implementation\s*$", text)[0]
    out = []
    for m in re.finditer(r"(?m)^\s*(\w+)\s*=\s*([\w.]+)\s*;", body):
        name, target = m.group(1), m.group(2)
        # `T = class(...)` and `T = record` are declarations, not aliases.
        # The target may be QUALIFIED: `TOpenPictureDialog = ExtDlgs.TOpenPictureDialog`
        # is how a shim re-exports an LCL class that shares its namespace. The
        # first version's pattern (\w+) silently accepted no target containing
        # a dot, so the whole ExtDlgs shim read as "publishes no type alias"
        # while it published four of them.
        if target.split(".")[-1].lower() in ("class", "record", "object",
                                             "interface", "type", "procedure",
                                             "function"):
            continue
        out.append((name, target))
    return out


# Where the Lazarus/FPC SOURCES live, per compiled-unit root.
#
# UNIT_DIRS are unit OUTPUT directories: C:\lazarus\lcl\units\x86_64-win64
# (containing nogui/ and win32/). The sources are three levels above that, not
# two -- the first version of this function walked up two, landed on
# units/x86_64-win64/win32, found no .pas there, and reported ALL 22 group-A
# names as "not safely shim-able: the unprefixed tail has no source here".
#
# That is the worst possible shape for a wrong answer: every row was
# self-consistent, the table printed cleanly, and the conclusion -- that the
# shim pattern does not generalise -- was the opposite of the truth.
SOURCE_ROOTS = (
    r"C:\lazarus\lcl",
    r"C:\lazarus\components\lazutils",
    r"C:\lazarus\components\synedit",
    r"C:\lazarus\components\lazcontrols",
    r"C:\lazarus\fpc\3.2.2\source",
)


def compiled_unit_paths():
    """Every unit SOURCE file visible to FPC, keyed by unit name.

    compiled_units() answers "what names resolve"; this answers "where is the
    code", which the feasibility classifier needs in order to enumerate the
    symbols a shim would have to re-export.

    Walks the source trees rather than deriving a path from a .ppu location,
    because the derivation was wrong twice and each time it produced a clean,
    confident, inverted conclusion.
    """
    found = {}
    for root in SOURCE_ROOTS:
        base = pathlib.Path(root)
        if not base.is_dir():
            continue
        for pas in base.rglob("*.pas"):
            found.setdefault(pas.stem.lower(), pas)
        for pp in base.rglob("*.pp"):
            found.setdefault(pp.stem.lower(), pp)
    return found


def _declares_symbol(pas, symbol):
    """Does this unit declare `symbol` (a type, class, const or var)?"""
    try:
        text = pas.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    body = re.split(r"(?mi)^\s*implementation\s*$", text)[0]
    return bool(re.search(r"(?m)^\s*%s\s*=" % re.escape(symbol), body))


def check_shim_invariants(shims):
    """The explicit shim contract, checked rather than asserted in prose.

    Four invariants, each of which was violated in practice at least once:

      1. EXISTS AND DECLARES THE NAME. A file called Vcl.VirtualImage.pas that
         declares `unit SomethingElse` is not a shim. (The first version of the
         detector trusted the filename.)
      2. LIVES IN THE FPC TREE. A shim under Source/*.pas would put an FPC unit
         in the Delphi compiler's path -- exactly what qa_check.py --profile
         delphi exists to prevent, and what the original "just rename the four
         uses clauses" plan would have done.
      3. RE-EXPORTS BY ALIAS ONTO A UNIT THAT EXISTS. This is the identity
         requirement: a subclass does not preserve the original type, so DFM
         streaming would fail to compile.
      4. THE DELPHI TREE STILL REFERENCES THE DOTTED NAME. If this fails,
         somebody renamed the Delphi `uses` clauses and the shim is dead code
         pretending to be a mechanism.

    Invariant 4 is the one worth arguing for: it is what makes "Delphi tree
    untouched" a checked fact rather than a claim. The shim can only exist
    while the Delphi tree still needs it.
    """
    failures = []
    for dotted in sorted(shims):
        shim = shim_for(dotted)
        meta = shims[dotted]
        kind = (meta or {}).get("kind", "compatibility shim")

        if shim is None:
            failures.append("%s: declared shim, but no unit declares that name"
                            % dotted)
            continue

        try:
            rel = shim.relative_to(ROOT).as_posix()
        except ValueError:
            rel = str(shim)
        if not rel.replace("\\", "/").startswith("Source/Fpc/"):
            failures.append("%s: shim at %s is OUTSIDE Source/Fpc/ -- an FPC "
                            "unit in the Delphi tree breaks the delphi profile"
                            % (dotted, rel))

        if kind == "native port":
            # A port is real code under the original unit name, so the alias
            # requirement does not apply -- insisting on it would forbid the
            # mechanism itself. The check that does apply is stronger than any
            # syntax reading: the unit must COMPILE. A port that compiles has a
            # satisfying uses clause and real declarations by construction;
            # guessing the class name from the unit tail failed on the shared
            # types unit (devMonitorTypes declares no class at all, only types)
            # and on the form unit (TfrmShortcutsEditor, not TdevShortcuts...),
            # which is two name conventions invented to describe the wrong thing.
            ok, out = probe_compiles([dotted])
            if not ok:
                fails = [l for l in out.splitlines() if "Fatal" in l or "Error:" in l]
                failures.append("%s: port does not compile -- %s"
                                % (dotted, (fails[0].strip() if fails else out.strip()[:100])))
        else:
            aliases = _declared_symbols(shim)
            if not aliases:
                failures.append("%s: shim publishes no type alias -- it must "
                                "re-export the ORIGINAL name, not declare a new "
                                "class" % dotted)

            units = _repo_units()
            used = shim.read_text(encoding="utf-8", errors="replace")
            uses_names = []
            mu = re.search(r"(?ms)^\s*uses\b(.*?);", used)
            if mu:
                for part in mu.group(1).split(","):
                    nm = part.strip().split(" in ")[0].strip()
                    if re.fullmatch(r"\w+", nm):
                        uses_names.append(nm)

            # A shim may point at an LCL/RTL unit as well as a repo unit -- the
            # Vcl.ExtDlgs shim re-exports the LCL's own ExtDlgs classes, and
            # under the repo-only reading its uses clause "names no unit that
            # exists in this tree", which is false. `available` is what the
            # compiler itself resolves (compiled_units()).
            available = compiled_units()
            real_uses = [n for n in uses_names
                         if n.lower() in units or n.lower() in available]
            if not real_uses:
                failures.append("%s: shim's uses clause (%s) names no unit that "
                                "exists in this tree" % (dotted, ", ".join(uses_names)))

            for name, target in aliases:
                target_name = target.rsplit(".", 1)[-1]
                # Only a REPO unit can be grepped for the target symbol. A
                # target in an LCL/RTL unit (Compiled_units() resolves it) is
                # verified by the compiler at probe time instead -- the tool's
                # other checks already compile a program that uses every group
                # A tail.
                if any(n.lower() in units
                       and _declares_symbol(units[n.lower()], target_name)
                       for n in real_uses):
                    continue
                if not any(n.lower() in units for n in real_uses):
                    continue  # all targets are LCL/RTL units: compile-verified
                failures.append("%s: alias %s = %s, but none of the units it uses "
                                "(%s) declares that symbol -- the re-export points "
                                "at nothing"
                                % (dotted, name, target, ", ".join(real_uses) or "-"))

        # Invariant 4, applied to both kinds.
        refd = False
        for pas in (ROOT / "Source").rglob("*.pas"):
            rel_p = pas.relative_to(ROOT).as_posix()
            if rel_p.startswith("Source/Fpc/"):
                continue
            try:
                txt = pas.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if re.search(r"(?mi)^\s*uses\b[^;]*\b%s\b[^;]*;" % re.escape(dotted),
                         txt):
                refd = True
                break
        if not refd:
            failures.append("%s: no Delphi-tree unit still references this "
                            "name -- the shim satisfies nothing" % dotted)

    return failures


def _repo_units():
    """Our own units under Source/, keyed by lowercased unit name."""
    out = {}
    for pas in (ROOT / "Source").rglob("*.pas"):
        if "VCL" in pas.parts or "Archive" in pas.parts:
            continue
        out[pas.stem.lower()] = pas
    return out


def _our_unit_for(dotted):
    """The repo unit that supersedes `dotted`, if one exists.

    Matched by the CLASS name the converter already renames, not by guessing a
    unit name. The authority is f3_dfm_to_lfm.py's CLASS_RENAME, so this asks
    "does the repo already ship what the converter maps this class to?" -- a
    question with a single recorded answer -- rather than inventing a naming
    convention and hoping.
    """
    conv = ROOT / "tools" / "f3_dfm_to_lfm.py"
    try:
        spec = importlib.util.spec_from_file_location("_conv", conv)
        m = importlib.util.module_from_spec(spec)
        saved = sys.argv
        sys.argv = ["f3_dfm_to_lfm.py"]
        try:
            spec.loader.exec_module(m)
        finally:
            sys.argv = saved
    except SystemExit:
        return None

    rename = getattr(m, "CLASS_RENAME", {})
    units = _repo_units()
    tail = unprefix(dotted.lower())
    if not tail:
        return None
    for cls, target in rename.items():
        # The rename must be for the class THIS unit is named after. Matching on
        # substring instead put `System.ImageList` in the renamed group via
        # `TSVGIconImageList -> TLclSvgImageList`, because the TARGET ends with
        # "ImageList". But TLclSvgImageList is not Delphi's System.ImageList;
        # nothing about it provides that unit. The first version of this
        # classifier reported a unit we already ship as evidence that a
        # different missing unit was fine -- and it printed the file it matched,
        # so the wrongness was legible and still shipped.
        src = cls[1:].lower() if cls.startswith("T") else cls.lower()
        if src != tail:
            continue
        cand = target[1:] if target.startswith("T") else target
        if cand.lower() in units:
            return units[cand.lower()]
    return None


def _declares_class(pas, cls_name):
    """Does this unit actually DECLARE the class, by name?

    A filename is not a declaration. ImageCollectionData.pas is the closest
    thing this repo has to `Vcl.ImageCollection`, and matching on its FILENAME
    put ImageCollection into group C -- "ours, but not a unit" -- which reads as
    though the work were done. It is not: that unit declares
    `TImageCollItem` and `TImageCollectionRec`, two record types. There is no
    TImageCollection anywhere in Source/Fpc. So the honest classification is
    group B, and the check has to be a declaration search rather than a name
    guess.
    """
    try:
        text = pas.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    pat = re.compile(r"\b%s\s*=\s*(?:class|record|interface|object)\b"
                     % re.escape(cls_name), re.IGNORECASE)
    return bool(pat.search(text))


def _our_component_for(dotted):
    """A component we already declare, under that name.

    Separate from _our_unit_for because a component can be used as a CONTROL but
    never as a `uses` target -- so the two are not interchangeable and conflating
    them would promise a rename that cannot compile.
    """
    tail = unprefix(dotted.lower())
    if not tail:
        return None
    for pas in (ROOT / "Source").rglob("*.pas"):
        parts = pas.parts
        if "VCL" in parts or "Archive" in parts:
            continue
        if not ("Controls" in parts or "Data" in parts
                or "Compatibility" in parts):
            continue
        if _declares_class(pas, "T" + tail.capitalize()):
            return pas
    return None


def unprefix(name):
    """`System.SysUtils` -> `sysutils`; returns None if there is no prefix."""
    if "." not in name:
        return None
    return name.rsplit(".", 1)[-1].lower()


def probe_compiles(units):
    """Does one program using all of `units` (prefixes dropped) actually build?

    This is the claim the whole tool exists to support, so it is verified by the
    compiler rather than by a name lookup. Returns (ok, output).

    `Interfaces` is first for the reason every probe in this repo gives: LCL's
    Forms references widgetset registration symbols that only the Interfaces
    unit brings in. Omitting it produces sixteen Undefined-symbol errors that
    look like a namespace problem and are not.
    """
    if not units:
        return True, "nothing to compile"
    if not pathlib.Path(FPC).is_file():
        return False, "fpc.exe not found at %s" % FPC

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="nsalias-"))
    src = tmp / "nsprobe.pas"
    body = ["program nsprobe;", "{$mode objfpc}{$H+}",
            "uses Interfaces, " + ", ".join(sorted(units)) + ";",
            "begin", "  WriteLn('compiled');", "end."]
    src.write_text("\n".join(body) + "\n", encoding="ascii")

    args = [FPC, "-Mdelphiunicode", "-FU%s" % tmp, "-FE%s" % tmp]
    for d in FU_ORDER:
        if pathlib.Path(d).is_dir():
            args.append("-Fu%s" % d)
    args.append(str(src))

    proc = subprocess.run(args, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    return proc.returncode == 0, out


def measure():
    seen, externals = _cc.closure("main")
    # Only genuinely ABSENT units are in scope. `classify()` already knows
    # which LCL/RTL names FPC resolves, and those can carry dots: this build
    # ships `System.UItypes` compiled, and the survey's own LCL_WIDGETSET list
    # contains the dotted `System.Utils`.
    #
    # Filtering by "has a dot" alone swept those in, which is how a unit FPC
    # already has ended up in a table headed "REAL MISSING". The first version
    # of this tool put `System.UItypes` in group B -- group B's whole meaning is
    # "we would have to write this", and nothing had to be written.
    unresolved = sorted(u for u in externals
                        if "." in u and _cc.classify(u) == "absent")

    available = compiled_units()

    # TWO outcomes, and both earlier versions of this classification were wrong
    # in opposite directions. Recording the shape of the mistake is the point:
    #
    #   v1 tested only the TAIL, so `Generics.Collections` -- which FPC ships
    #      under that exact dotted name (rtl-generics), as a genuine FPC
    #      namespace unit -- was filed as "real missing". A unit that already
    #      existed was put on the porting backlog.
    #   v2 dropped the classify() filter, so `System.UItypes` -- which THIS build
    #      ships compiled -- landed in "REAL MISSING", a table whose entire
    #      meaning is "we would have to write this". Nothing had to be written.
    #
    # A real FPC namespace unit is a unit that already exists, whatever its
    # spelling. So: if it compiles today, it is not a blocker, and the honest
    # categories are "resolves after dropping the prefix" vs "does not exist".
    # FIVE outcomes, and each extra group exists because a narrower tool
    # produced a wrong table:
    #
    #   0. ALREADY OK. FPC ships this exact dotted name.
    #   A. PREFIX-ONLY. The unprefixed tail exists in LCL/FPC. Spelling.
    #   R. RENAMED INTO OUR OWN UNIT. Nothing under that name, but this repo
    #      already ships a unit that provides the class, under OUR name.
    #   C. RIGHT NAME, WRONG SHAPE. Our unit exists under that name but is a
    #      COMPONENT (.pas), so it can never be a `uses` target.
    #   B. REAL MISSING. None of the above. Actual work.
    #
    # Group R is why this must not be a straight name comparison.
    # `Vcl.VirtualImage` has no counterpart and its tail is not an LCL unit, so a
    # two-group tool files it under "real missing" -- implying somebody has to
    # write it. Nobody does: Source/Fpc/UI/Controls/LclVirtualImage.pas has
    # existed since F3-3, and the converter already renames the CLASS
    # (`TVirtualImage -> TLclVirtualImage` in f3_dfm_to_lfm.py CLASS_RENAME).
    # What remains is renaming the UNIT in four uses clauses. Counting finished
    # work as a port would put it back on the backlog.
    #
    # Group C is the same discipline pointed the other way: `Vcl.ImageCollection`
    # names a component this repo writes (ImageCollectionData.pas), and a
    # component is not a unit. Renaming cannot fix it. Reporting it as a port
    # would send someone to write a unit that should not exist; reporting it as
    # a rename would promise an edit that cannot compile.
    already_ok, prefix_only, renamed, comp_only, real_missing = \
        [], [], [], [], []
    for u in unresolved:
        low = u.lower()
        tail = unprefix(low)
        if low in available:
            already_ok.append(u)          # FPC ships this dotted name itself
        elif tail and tail in available:
            prefix_only.append(u)
        elif _our_unit_for(u) is not None:
            renamed.append(u)
        elif _our_component_for(u) is not None:
            comp_only.append(u)
        else:
            real_missing.append(u)

    return {
        "main_closure_own_units": len([u for u in seen
                                       if u.lower() in _cc.unit_path]),
        "unresolved_dotted": len(unresolved),
        "already_ok": already_ok,
        "prefix_only": prefix_only,
        "renamed": renamed,
        "component_only": comp_only,
        "real_missing": real_missing,
    }


def rewrite_satisfied(dotted: str) -> bool:
    """Is this dotted name off the FPC path because of the source rewrite?

    tools/fpc_uses_rewrite.py rewrites a uses-clause entry into

        {$IFDEF FPC}
        <tail spelling>
        {$ELSE}
        <original dotted spelling>
        {$ENDIF}

    so the dotted name stays in the file for Delphi and leaves the FPC path.
    This returns True only when EVERY uses-clause occurrence of `dotted` in the
    self-authored tree sits inside such a Delphi-only branch. An occurrence on
    the FPC path means the flat result ("the name vanished from the closure")
    is NOT explained by the rewrite, and the ratchet must fail rather than
    quietly accept it. That mirror of shims is the point: last round this
    tool failed 21 names with "unexplained", and the explanation existed but
    was invisible, so the honest fix is a named mechanism, not a shrug.

    WHY A USES-CLAUSE CHECK AND NOT A GREP
    =====================================
    `System.SysUtils` appears in comments and prose across the tree all the
    time; counting those would report the mechanism as active when only the
    documentation mentions it. The clause check is the compiler-visible one,
    and it runs the same conditional-marker stack the rewriter itself uses.
    """
    decl = re.compile(r"\b%s\b" % re.escape(dotted), re.IGNORECASE)
    source_root = ROOT / "Source"
    if not source_root.is_dir():
        return False
    occurrences = 0
    for pas in sorted(source_root.rglob("*.pas")):
        parts = pas.relative_to(ROOT).parts
        if "VCL" in parts or "Archive" in parts:
            continue
        try:
            text = pas.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        in_uses = False
        cond = []
        for line in lines:
            s = line.strip()
            if re.match(r"^uses\b", s, re.IGNORECASE):
                in_uses = True
                cond = []
                continue
            if not in_uses:
                continue
            if s.startswith("{"):
                if re.match(r"^\{\$IFDEF(\s+FPC)?\}$", s, re.IGNORECASE):
                    fpc_block = bool(re.search(r"fpc\}$", s, re.IGNORECASE))
                    cond.append("fpc" if fpc_block else "other")
                elif s.startswith("{$ELSE"):
                    if cond:
                        cond.append("other" if cond[-1] == "fpc" else "fpc")
                elif s.startswith("{$ENDIF"):
                    if cond:
                        cond.pop()
                continue
            if decl.search(line):
                occurrences += 1
                protected = False
                for idx, kind in enumerate(cond):
                    if kind == "fpc" and len(cond) > idx + 1 and cond[idx + 1] == "other":
                        protected = True
                if not protected:
                    return False
            # The clause does NOT end at a `;` that sits inside an open
            # conditional -- the FPC branch's own line ends with `;` and the
            # Delphi branch after {$ELSE} is still the same uses clause.
            # Stopping there made the Delphi-side lines invisible to this
            # check and every rewritten name read as "occurrences == 0",
            # i.e. unexplained. The condition depth must be empty for a `;`
            # to mean the clause is over.
            if s.endswith(";") and not cond:
                in_uses = False
    return occurrences > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ratchet", action="store_true")
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args()

    m = measure()
    ok_names, po = m["already_ok"], m["prefix_only"]
    rn, co, rm = m["renamed"], m["component_only"], m["real_missing"]
    n = m["unresolved_dotted"]

    print("MAIN.PAS NAMESPACE ALIAS AUDIT")
    print("=" * 78)
    print()
    print("main.pas closure: %d self-authored unit(s); %d absent unit(s) "
          "carry a namespace dot." % (m["main_closure_own_units"], n))
    print()
    print("0. ALREADY RESOLVED -- FPC ships this exact dotted name; the "
          "survey's LCL set just does not know it")
    print("   %d of %d" % (len(ok_names), n))
    for u in ok_names:
        print("      %s" % u)
    print()
    print("A. PREFIX-ONLY -- the unit exists, only the spelling is Delphi's")
    print("   %d of %d" % (len(po), n))
    for u in po:
        print("      %-34s -> %s" % (u, u.rsplit(".", 1)[-1]))
    print()
    print("R. RENAMED INTO OUR OWN UNIT -- we already ship this class")
    print("   %d of %d" % (len(rn), n))
    for u in rn:
        rel = _our_unit_for(u)
        print("      %-28s -> %s" % (u, rel.relative_to(ROOT).as_posix()
                                      if rel else "?"))
    print()
    print("C. COMPONENT, NOT A UNIT -- ours, but unusable in a uses clause")
    print("   %d of %d" % (len(co), n))
    for u in co:
        rel = _our_component_for(u)
        print("      %-28s -> %s" % (u, rel.relative_to(ROOT).as_posix()
                                      if rel else "?"))
    print()
    print("B. REAL MISSING -- no unit anywhere under that name or its tail")
    print("   %d of %d" % (len(rm), n))
    for u in rm:
        print("      %s" % u)
    print()

    # The verification that turns a spelling claim into a compiled fact.
    # Historical classification vs current resolution. The baseline is the
    # measurement; this is how it is being satisfied. Both are printed, and the
    # first is never recomputed from the second.
    base_path_for_report = ROOT / "tools" / "f3_namespace_alias_baseline.json"
    if base_path_for_report.is_file():
        try:
            hist = json.loads(base_path_for_report.read_text(encoding="utf-8"))
        except ValueError:
            hist = {}
        originally_renamed = hist.get("renamed", [])
        if originally_renamed:
            print("RESOLUTION MECHANISM -- how the measured blockers are "
                  "being satisfied")
            print("   (the classification below is the MEASUREMENT; this is "
                  "not a new measurement)")
            for u in originally_renamed:
                if shim_for(u):
                    shim = shim_for(u)
                    loc = len(shim.read_text(encoding="utf-8",
                                             errors="replace").splitlines())
                    print("      %-24s -> compatibility shim %s"
                          % (u, shim.relative_to(ROOT).as_posix()))
                    print("        0 new classes, %d lines, Delphi tree "
                          "untouched" % loc)
                else:
                    print("      %-24s -> unresolved" % u)
            print()

    print("VERIFICATION -- compile one program using ALL of group A, "
          "prefixes dropped")
    tails = sorted({u.rsplit(".", 1)[-1] for u in po})
    ok, out = probe_compiles(tails)
    if ok:
        print("   PASSED: %d unit(s) compile. Group A is spelling, not work."
              % len(tails))
    else:
        fails = re.findall(r"(?:Error|Fatal):.*", out)
        print("   FAILED: group A is NOT purely spelling. The compiler says:")
        for line in fails[:12]:
            print("      %s" % line.strip())
        print("   Groups above are therefore not trustworthy as printed.")
    print()

    payload = {
        "main_closure_own_units": m["main_closure_own_units"],
        "already_ok_count": len(ok_names),
        "prefix_only_count": len(po),
        "renamed_count": len(rn),
        "component_only_count": len(co),
        "real_missing_count": len(rm),
        "already_ok": ok_names,
        "prefix_only": po,
        "renamed": rn,
        "component_only": co,
        "real_missing": rm,
        "note": "main.pas namespace spelling vs real blockers; doc/F3-SVG 19.8",
    }

    base_path = ROOT / "tools" / "f3_namespace_alias_baseline.json"
    if args.write_baseline:
        base_path.write_text(json.dumps(payload, indent=2,
                                        sort_keys=True) + "\n",
                             encoding="utf-8")
        print("[WRITE] %s" % base_path.name)
        return 0
    if args.ratchet:
        if not base_path.is_file():
            print("RESULT: %s is missing -- record it with --write-baseline"
                  % base_path.name)
            return 1
        base = json.loads(base_path.read_text(encoding="utf-8"))
        shims = base.get("shims", {})
        # Declared shim scope is ADDED to the historical numbers rather than
        # written over them. The baseline records what was MEASURED; a shim adds
        # real compile surface, and folding that into the baseline would make the
        # measurement describe a tree that never existed. So the expected current
        # value is historical + declared shim scope, and the gate still fails on
        # growth beyond what the shims account for.
        declared_units = 0
        for unit_name, meta in shims.items():
            # Only a shim that EXISTS may contribute scope. Counting declared
            # scope unconditionally let the gate pass with the shim deleted:
            # the baseline said +1 unit of shim scope, the tree no longer had
            # the unit, and the ratchet called it "82 <= 83, fine". A declared
            # allowance with nothing behind it is an allowance for nothing.
            if shim_for(unit_name) is None:
                print("  WARNING: baseline declares a shim for %s but no unit "
                      "declares that name -- its %d unit(s) of scope are NOT "
                      "being granted"
                      % (unit_name,
                         meta.get("scope_added", {}).get("own_units", 0)))
                continue
            declared_units += meta.get("scope_added", {}).get("own_units", 0)
        if declared_units:
            print("  (historical baseline %s, plus %d unit(s) of declared shim "
                  "scope, each verified present)"
                  % (base.get("main_closure_own_units"), declared_units))
        print("NAMESPACE RATCHET -- the real-missing set must not grow")
        print("-" * 78)
        grew = []
        for key, label in (("real_missing_count", "real_missing"),
                           ("component_only_count", "component only"),
                           ("renamed_count", "renamed into ours"),
                           ("prefix_only_count", "prefix_only"),
                           ("already_ok_count", "already resolved"),
                           ("main_closure_own_units", "own units")):
            b, n = base.get(key), payload.get(key)
            if key == "main_closure_own_units":
                b = (b or 0) + declared_units
            okk = b is not None and n <= b
            print("  %-16s expected %-5s now %-5s %s"
                  % (label, b, n, "ok" if okk else "GREW"))
            if not okk:
                grew.append(label)

        # A unit count DROPS when a shim makes a dotted name resolvable. That is
        # progress, and like every ratchet here it is not auto-accepted: the drop
        # is only legitimate if a shim accounts for it. Without this the gate would
        # either fail on a real improvement or, worse, be "fixed" by re-baselining
        # and lose the measurement entirely.
        for label, key in (("renamed into ours", "renamed_count"),
                           ("already resolved", "already_ok_count"),
                           ("prefix_only", "prefix_only_count")):
            b, n = base.get(key), payload.get(key)
            if b is not None and n < b:
                gone = set(base.get(label.split()[0], []))
                # Two legitimate mechanisms, and a name must be satisfied by one
                # of them for its drop to count. The second one is new: the
                # source rewrite keeps the Delphi spelling inside an
                # {$ELSE} branch, which removes the dotted name from the FPC
                # path (and therefore from the closure this tool measures).
                by_shim = [u for u in gone if shim_for(u)]
                by_rewrite = [u for u in gone
                              if not shim_for(u) and rewrite_satisfied(u)]
                unaccounted = [u for u in gone
                               if not shim_for(u) and not rewrite_satisfied(u)]
                print()
                print("  %s DROPPED %d -> %d" % (label, b, n))
                if by_shim:
                    print("    accounted for by compatibility shim(s): %s"
                          % ", ".join(sorted(by_shim)))
                if by_rewrite:
                    print("    accounted for by the FPC uses-rewrite (Delphi "
                          "spelling stays in an {$ELSE} branch): %s"
                          % ", ".join(sorted(by_rewrite)))
                if unaccounted:
                    print("    %d unit(s) left the measured set with NO shim "
                          "and no rewrite: %s"
                          % (len(unaccounted), ", ".join(sorted(unaccounted))))
                    print("    That is an unexplained improvement. Do not accept")
                    print("    it by re-baselining -- find out why they vanished.")
                    grew.append(label + " (unexplained drop)")
        # The shim contract is evaluated BEFORE any early return, and reported
        # alongside the counts rather than after them.
        #
        # It used to run last and only when the counts were clean, which made one
        # of the four invariants unreachable: a shim that declared the wrong unit
        # name also changes the counts, so the count path returned 1 first and
        # the contract message never printed. The failure was detected, but for
        # the wrong reason -- and a contract that reports itself only in the
        # absence of other failures is not really being enforced.
        bad = check_shim_invariants(shims)

        if grew or bad:
            if grew:
                print()
                print("RESULT: %s grew" % ", ".join(grew))
                print("  main.pas got harder for real, not just longer. Do not")
                print("  re-baseline this by accident.")
            if bad:
                print()
                print("SHIM CONTRACT -- violated by %d item(s):" % len(bad))
                for b in bad:
                    print("   FAIL  %s" % b)
            return 1
        print()
        # A port entry satisfies a different subset than an alias shim: the
        # compile check stands in for "re-exports by alias", because a port
        # declares the classes itself. Both subsets end with invariant 4.
        n_port = sum(1 for m in shims.values()
                     if m.get("kind") == "native port")
        print("SHIM CONTRACT: %d entr(y/ies) satisfy the contract"
              % len(shims))
        print("  (resolves to a real unit, lives in Source/Fpc/, %d alias "
              "shim(s) re-export by alias, %d native port(s) compile, "
              "Delphi tree still references the name)"
              % (len(shims) - n_port, n_port))

        print()
        print("RESULT: main.pas did not get harder")
        return 0 if ok else 1

    print("VERDICT")
    free = len(ok_names) + len(po) + len(rn)
    print("  %d of %d (%.0f%%) need no new code: already valid, spelling, or "
          "already ours under another name."
          % (free, n, 100.0 * free / max(1, n)))
    print("  %d of %d (%.0f%%) are components where a UNIT is expected -- a "
          "design problem, not a port." % (len(co), n,
                                            100.0 * len(co) / max(1, n)))
    print("  %d of %d (%.0f%%) need real work."
          % (len(rm), n, 100.0 * len(rm) / max(1, n)))
    # A verdict whose parts do not add up to the whole is worse than no verdict.
    assert len(ok_names) + len(po) + len(rn) + len(co) + len(rm) == n, \
        "the five groups must partition the absent dotted units"
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
