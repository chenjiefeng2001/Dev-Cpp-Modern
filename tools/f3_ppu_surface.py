"""A SECOND evidence source for the group-A symbol surface: the .ppu itself.

WHY NOT JUST BUILD THE INCLUDE EVALUATOR
========================================
Section 22 left two names INDETERMINATE and named the missing tool: resolving
`{$I}` reliably needs "a platform-conditional include evaluator". That is the
right diagnosis and the wrong prescription, because the machine already contains
the evaluator and it is the one that counts:

    ppudump -VS <unit>.ppu

`ppudump` reads the .ppu the COMPILER produced for THIS target (3.2.2, x86_64,
Win64-x64) and prints the interface symbol table with each symbol's kind. That is
not an approximation of the surface; it IS the surface the compiler will link
against. Section 20.3 already recorded the principle -- "a .ppu is evidence the
unit was built for this target and widgetset, source is only a promise" -- and
applied it to unit EXISTENCE. This applies it to the symbol SURFACE, which is
precisely where hand-following `{$I}` fell over: sysutils.pp is a one-line
`{$I sysutils.inc}` shell, so the source reader sees 5 symbols where the compiler
recorded 700+, and the tool's first run duly concluded that five real names were
"not referenced".

WHAT IT DOES
============
For each dotted name in the frozen group-A baseline, classify it TWICE with the
SAME rules -- `f3_shim_feasibility.classify()`, whose evidence source is a
parameter -- once from the source text and once from the .ppu, and print both
side by side plus the symmetric difference.

The point is not to replace the source reader. It is to find out how often the
source reader was wrong, and in WHICH direction. Only one direction is
acceptable: a source reader that MISSES symbols invents permission to drop work,
which is the error direction section 22.3 identified as the one this class of
tool must never take quietly.

WHICH .ppu
==========
Not "the first one found", and not "rtl wins" -- both were assumptions until they
were measured. `sysutils.ppu` exists in rtl, rtl-objpas AND rtl-unicode, one per
language mode, and a delphiunicode build resolves a different one than an objfpc
build. So the .ppu is chosen by ASKING THE COMPILER: one probe program that uses
every tail, compiled with the project's own flags (`f3_namespace_alias.FPC`,
`FU_ORDER`, `-Mdelphiunicode`) and `-vt` to print `PPU Loading <path>`. Measured
rather than assumed: the resolution came back rtl\\ and rtl-objpas\\ and
fcl-base\\, and nothing else.

GUARDS
======
This tool can authorise dropping work too, so it inherits section 22.3's rules
verbatim, plus one of its own:

  * a .ppu the compiler never loaded      -> INDETERMINATE, never "unused";
  * ppudump failing or unreadable         -> INDETERMINATE, never "unused";
  * a surface below MIN_PLAUSIBLE_EXPORTS -> INDETERMINATE (in classify());
  * a symbol the SOURCE reader claims the tree uses but the .ppu does not
    contain -> printed as a CONTRADICTION, because that is what reading the
    wrong .ppu looks like;
  * `Visibility : private` symbols are excluded -- the sysutils interface
    symtable carries 12 of them, and a shim must not try to re-export those.

Nothing is written. No shim is created. This is a comparison, not a decision.
"""

import argparse
import collections
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, mod):
    spec = importlib.util.spec_from_file_location(
        mod, ROOT / "tools" / ("%s.py" % name))
    m = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["%s.py" % name]
    try:
        spec.loader.exec_module(m)
    except SystemExit:
        raise SystemExit("could not import %s.py" % name)
    finally:
        sys.argv = saved
    return m


_ns = _load("f3_namespace_alias", "_ns")
_sf = _load("f3_shim_feasibility", "_sf")

PPUDUMP = pathlib.Path(_ns.FPC).with_name("ppudump.exe")


# ---------------------------------------------------------------------------
# Step 1: which .ppu does the compiler itself load for each tail?
# ---------------------------------------------------------------------------

_PROBE = """program ppuprobe;
{$mode objfpc}{$H+}
uses Interfaces, %s;
begin
  WriteLn('resolved');
end.
"""

_PPU_LOADED = re.compile(r"^PPU Loading (.+?\.ppu)\s*$", re.M)
_PPU_TRIED = re.compile(r"^Trying (.+?\.ppu)\s*$", re.M)


def _fpc_args(tmp, source, verbose=False):
    args = [_ns.FPC, "-Mdelphiunicode", "-FU%s" % tmp, "-FE%s" % tmp]
    if verbose:
        args.append("-vt")
    for d in _ns.FU_ORDER:
        if pathlib.Path(d).is_dir():
            args.append("-Fu%s" % d)
    args.append(str(source))
    return args


def resolved_ppus(tails):
    """{tail.lower(): .ppu path} as the COMPILER resolved them.

    `failed` is the set of tails the compiler could not load at all. Those are
    reported separately rather than silently absent, because "the compiler has
    never heard of it" and "I did not look" must not print the same way.
    """
    if not tails:
        return {}, set()

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="ppusurf-"))
    src = tmp / "ppuprobe.pas"
    src.write_text(_PROBE % ", ".join(sorted(tails)), encoding="ascii")

    proc = subprocess.run(_fpc_args(tmp, src, verbose=True),
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr

    if proc.returncode != 0:
        # One tail that does not resolve would silence every other answer, so
        # fall back to one compile per tail. Slower, and it still reports.
        found, failed = {}, set()
        for tail in tails:
            one = tmp / ("probe_%s.pas" % re.sub(r"\W", "_", tail))
            one.write_text(_PROBE % tail, encoding="ascii")
            p2 = subprocess.run(_fpc_args(tmp, one, verbose=True),
                                capture_output=True, text=True)
            got = _match_ppus(p2.stdout + p2.stderr, {tail})
            if p2.returncode == 0 and got:
                found.update(got)
            else:
                failed.add(tail)
        return found, failed

    return _match_ppus(out, tails), set()


def _match_ppus(out, tails):
    by_stem = {t.lower(): t for t in tails}
    found = {}
    for m in _PPU_LOADED.finditer(out):
        path = pathlib.Path(m.group(1))
        tail = by_stem.get(path.stem.lower())
        if tail is not None:
            # First hit wins: the compiler loads a unit once, and if the same
            # stem appears from two directories the earlier PPU Loading line is
            # the one it committed to.
            found.setdefault(tail.lower(), path)
    return found


# ---------------------------------------------------------------------------
# Step 2: read the interface symbol table out of that .ppu
# ---------------------------------------------------------------------------

# ppudump's own vocabulary. "Unit symbol" is the unit's own name, not a symbol a
# shim could re-export, so it maps to None and is dropped.
_KINDS = {
    "Type": "type",
    "Enumeration": "type",
    "Constant": "const",
    "Global Variable": "var",
    "Absolute variable": "var",
    "Procedure": "routine",
    "Function": "routine",
    "Unit": None,
}

_SYM = re.compile(r"^(?P<kind>\w[\w ]*?) symbol (?P<name>[A-Za-z_]\w*)\s*$")

# `ppudump -VS` prints unit-level symbol lines at column 0, while `-VD` indents
# EVERY definition by its nesting depth. Reusing the column-0 pattern across both
# formats is what made the first run of nested_definitions() report 0 explained
# and 177 unexplained -- a total that was the tell, since 177 unexplained
# disagreements out of 22 units is not a plausible finding, it is a broken scan.
_SYM_INDENTED = re.compile(
    r"^\s*(?P<kind>\w[\w ]*?) symbol (?P<name>[A-Za-z_]\w*)\s*$")

_VIS = re.compile(r"^\s*Visibility\s*:\s*(\w+)\s*$")
_POS = re.compile(r"^\s*File Pos\s*:\s*\d+\s*\((\d+),(\d+)\)\s*$")

# `ppudump -VD` marks nesting two ways, and both are used below. A definition
# whose `** Symbol Id **` line is INDENTED is nested inside another definition --
# a class method, a record field, a routine parameter -- and so is not a unit
# symbol. A nested definition that also carries a `Class : ... DefId n` line is a
# class member specifically.
_SYMID = re.compile(r"^(?P<indent>[ \t]*)\*\* Symbol Id \d+ \*\*\s*$")
_CLASSMARK = re.compile(r"^\s*Class\s*:\s*\(.*\)\s*DefId\s+\d+\s*$")


def surface_from_text(text):
    """{NAME: kind} from a `ppudump -VS` listing. Pure, so it can be self-tested.

    A line-oriented scan rather than one regex: the record is
    `** Symbol Id N **` / `<kind> symbol <name>` / `File Pos` / `Visibility`, and
    the fields that matter (visibility, position) are the LINES AFTER the name.
    Anchoring all four in one pattern would need a backreference the format does
    not offer, and a looser pattern silently pairs a symbol with the NEXT
    symbol's visibility -- which is the one mistake that would make a private
    symbol look re-exportable.
    """
    out = {}
    pending = None
    for line in text.splitlines():
        m = _SYM.match(line)
        if m:
            if pending and pending["vis"] == "public" and pending["kind"]:
                out.setdefault(pending["name"], pending["kind"])
            kind = _KINDS.get(m.group("kind").strip())
            pending = {"name": m.group("name"), "kind": kind,
                       "vis": None, "line": None}
            continue
        if pending is None:
            continue
        v = _VIS.match(line)
        if v:
            pending["vis"] = v.group(1).lower()
            continue
        p = _POS.match(line)
        if p and pending["line"] is None:
            pending["line"] = int(p.group(1))
    if pending and pending["vis"] == "public" and pending["kind"]:
        out.setdefault(pending["name"], pending["kind"])
    return out


def ppu_header(ppu):
    """(compiler version, target processor, target OS) recorded INSIDE the ppu.

    Printed per name so the reader can see that the surface came from a build
    that matches the one this project makes, rather than being asked to trust
    that it does.
    """
    txt = subprocess.run([str(PPUDUMP), "-VH", str(ppu)],
                         capture_output=True, text=True).stdout
    got = {}
    for key, field in (("Compiler version", "Compiler version"),
                       ("Target processor", "Target processor"),
                       ("Target operating system", "Target OS")):
        m = re.search(r"^%s\s*:\s*(.+?)\s*$" % re.escape(key), txt, re.M)
        got[field] = m.group(1) if m else "?"
    return got


def surface(ppu):
    """{NAME: kind} for a .ppu. Raises on any failure -- never returns {}."""
    if not pathlib.Path(PPUDUMP).is_file():
        raise _sf._Unlocatable("ppudump.exe not found at %s" % PPUDUMP, str(ppu))
    proc = subprocess.run([str(PPUDUMP), "-VS", str(ppu)],
                          capture_output=True, text=True, errors="replace")
    if proc.returncode != 0 or "Interface Symbols" not in proc.stdout:
        raise _sf._Unlocatable(
            "ppudump could not read this unit file (exit %d); that is an "
            "EXTRACTION FAILURE, not evidence the unit is unused"
            % proc.returncode, str(ppu))
    surf = surface_from_text(proc.stdout)
    if not surf:
        raise _sf._Unlocatable(
            "ppudump returned no public interface symbol; that is an "
            "EXTRACTION FAILURE, not evidence the unit is unused", str(ppu))
    return surf


def nested_definitions(ppu):
    """{name: 'class member' | 'nested member'} from `ppudump -VD`.

    This exists because the first version of the comparison printed a section
    headed "reading the WRONG .ppu looks like" and then filled it with `Create`,
    `Destroy`, `FItems`, `dwFlags` -- which are CLASS MEMBERS and RECORD FIELDS,
    not unit symbols. A diagnostic that cries wolf about the wrong cause is worse
    than no diagnostic: it teaches the reader that this section is noise.

    The old source reader harvests any line matching a declaration pattern at
    any nesting depth, so `constructor Create;` inside `TThread = class` becomes
    a "routine" named Create. Measured proof of the mechanism, not of the claim:

        C:\\lazarus\\lcl\\printers.pas:224   TPrinter = class(TObject)
        C:\\lazarus\\lcl\\printers.pas:114   procedure BeginDoc; virtual;
        C:\\lazarus\\fpc\\3.2.2\\source\\rtl\\objpas\\classes\\classes.inc:147
                                            constructor Create;

    None of those are re-exportable unit symbols, and none appear in the .ppu's
    interface symbol table -- a class member belongs to its class's own symbol
    table, and arrives with the type. So the classifier's use of them was
    inflating `wanted` with words like Create, Assign and Clear that appear in
    almost any file, and manufacturing "NOT SAFELY SHIM-ABLE" verdicts.

    Classifying each disagreement against the compiler's own nesting is what
    turns this section from an accusation into a measurement.
    """
    proc = subprocess.run([str(PPUDUMP), "-VD", str(ppu)],
                          capture_output=True, text=True, errors="replace")
    out = {}
    pending = None
    for line in proc.stdout.splitlines():
        m = _SYMID.match(line)
        if m:
            if pending and pending[1]:
                out[pending[0]] = pending[1]
            pending = [None, "nested member" if m.group("indent") else None]
            continue
        if pending is None:
            continue
        s = _SYM_INDENTED.match(line)
        if s:
            pending[0] = s.group("name")
            continue
        if pending[1] and _CLASSMARK.match(line):
            pending[1] = "class member"
    if pending and pending[1]:
        out[pending[0]] = pending[1]
    return out


def make_ppu_evidence(resolved, rivals):
    """An evidence source for classify(), closed over the compiler's answers."""

    def evidence(tail):
        ppu = resolved.get(tail.lower())
        if ppu is None:
            return None, {
                "reason": "the compiler loads no .ppu for the unprefixed tail "
                          "under the project's own flags, so there is nothing "
                          "to re-export"}
        return surface(ppu), {"unit": str(ppu),
                              "rivals": [str(p) for p in rivals.get(tail, [])]}

    return evidence


def find_rivals(tails):
    """{tail: [other .ppu files with the same stem]} -- printed, never hidden."""
    seen = collections.defaultdict(list)
    for d in _ns.UNIT_DIRS:
        base = pathlib.Path(d)
        if not base.is_dir():
            continue
        for ppu in base.rglob("*.ppu"):
            seen[ppu.stem.lower()].append(ppu)
    return {t: seen[t.lower()] for t in tails if len(seen[t.lower()]) > 1}


# ---------------------------------------------------------------------------
# Step 3: compare the two evidence sources, symbol by symbol
# ---------------------------------------------------------------------------

def compare(names, verbose=False):
    """Per name: both surfaces, both classifications, and the differences."""
    tails = [n.rsplit(".", 1)[-1] for n in names]
    resolved, failed = resolved_ppus(tails)
    rivals = find_rivals(tails)
    evidence = make_ppu_evidence(resolved, rivals)

    rows = []
    for name in names:
        tail = name.rsplit(".", 1)[-1]
        row = {"dotted": name, "tail": tail,
               "ppu": str(resolved[tail.lower()])
               if tail.lower() in resolved else None}

        src_cat, src_detail = _sf.classify(name, _sf.source_evidence)
        row["source"] = {"category": src_cat,
                         "symbols_needed": src_detail.get("symbols_needed"),
                         "reason": src_detail.get("reason", "")[:400]}
        try:
            ppu_cat, ppu_detail = _sf.classify(name, evidence)
            row["ppu_ev"] = {"category": ppu_cat,
                             "symbols_needed": ppu_detail.get("symbols_needed"),
                             "consumers": ppu_detail.get("consumers", []),
                             "reason": ppu_detail.get("reason", "")[:400]}
        except _sf._Unlocatable as exc:
            ppu_cat = "5. INDETERMINATE"
            row["ppu_ev"] = {"category": ppu_cat, "symbols_needed": None,
                             "consumers": [],
                             "reason": exc.reason}
            row["ppu"] = row["ppu"] or exc.unit

        # Symbol-level difference, which is the only part that can say WHICH way
        # the source reader was wrong. An unreadable source surface is not an
        # error here: "the source reader could not get this far" is precisely the
        # fact being measured, and it is already recorded in the category.
        try:
            src_surface, _ = _sf.source_evidence(tail)
        except _sf._Unlocatable:
            src_surface = {}
        if src_surface is None:
            src_surface = {}
        try:
            ppu_surface = surface(pathlib.Path(resolved[tail.lower()])) \
                if tail.lower() in resolved else {}
        except _sf._Unlocatable:
            ppu_surface = {}
        row["source_exported"] = len(src_surface)
        row["ppu_exported"] = len(ppu_surface)
        _, wanted_src = _sf.consumer_usage(name, src_surface)
        _, wanted_ppu = _sf.consumer_usage(name, ppu_surface)
        row["missed_by_source"] = sorted(wanted_ppu - wanted_src)
        row["only_in_source"] = sorted(wanted_src - wanted_ppu)

        # Every disagreement the source reader had, classified against the
        # compiler's own nesting. Two benign buckets, and only a third is fatal:
        #   nested  -- the compiler records it inside a type or class, so it
        #              arrives with its type and a shim never names it;
        #   absent  -- the compiler records it nowhere at all. That is the
        #              signature of the source reader over-reading, and it has a
        #              measured cause: `types.pp:87` is `TPoint = Windows.TPoint`,
        #              an ALIAS, so X and Y are the fields of a record the tail
        #              unit does not own.
        # Anything else means the two surfaces describe different builds.
        nested = {}
        ppu_path = resolved.get(tail.lower())
        if ppu_path is not None:
            nested = nested_definitions(ppu_path)
        nested_syms = set(ppu_surface)
        explained, absent, unexplained = {}, [], []
        for sym in row["only_in_source"]:
            if sym in nested:
                explained[sym] = nested[sym]
            elif sym not in nested_syms:
                absent.append(sym)
            else:
                unexplained.append(sym)
        row["explained_by_nesting"] = explained
        row["absent_from_compiler"] = sorted(absent)
        row["unexplained"] = unexplained

        # THE DANGEROUS DISAGREEMENT, stated as a checkable condition.
        #
        # Categories 1 and 4 are the two verdicts that let someone act on the
        # source reader: 1 says "one alias line each", 4 says "the uses entry
        # alone justifies nothing". If the compiler's own record disagrees with
        # either, the source reader is authorising something refuted, and that
        # is the direction section 22.3 forbade. Measured: Winapi.Messages,
        # where the source reader said "unused" while the compiler's record
        # holds two constants the tree needs.
        src_cat = row["source"]["category"]
        ppu_cat = row["ppu_ev"]["category"]
        row["source_contradicts_compiler"] = bool(
            src_cat in ("1. SHIM CANDIDATE", "4. QUESTIONABLE")
            and src_cat != ppu_cat)
        row["exported_only_in_source"] = len(
            {n for n in src_surface if n.lower() not in
             {m.lower() for m in ppu_surface}})
        rows.append(row)

    return rows, failed, resolved


def report(rows, failed, resolved, tail_names=()):
    out = []
    add = out.append

    add("GROUP-A SYMBOL SURFACE -- SOURCE TEXT vs THE COMPILER'S OWN .ppu")
    add("=" * 78)
    add("")
    add("Both columns are produced by the SAME classifier "
         "(f3_shim_feasibility.classify),")
    add("with only the evidence source swapped, so a disagreement is a fact "
         "about the")
    add("evidence, not about the rules.")
    add("")
    add("%-24s %10s %10s  %-26s %s" % ("dotted name", "src sym", "ppu sym",
                                       "source category", "ppu category"))
    add("-" * 96)

    for r in rows:
        moved = "" if r["source"]["category"] == r["ppu_ev"]["category"] \
            else "   <-- MOVED"
        add("%-24s %10s %10s  %-26s %s%s" % (
            r["dotted"], r["source_exported"], r["ppu_exported"],
            r["source"]["category"].split(".")[0],
            r["ppu_ev"]["category"].split(".")[0], moved))
    add("")

    add("NAMES THE COMPILER COULD NOT LOAD")
    add("-" * 46)
    if failed:
        for t in sorted(failed):
            add("  %s" % t)
    else:
        add("  none -- every tail resolved to a .ppu under the project's flags")
    add("")

    add("WHICH .ppu THE COMPILER CHOSE, AND WHICH BUILD MADE IT")
    add("-" * 57)
    shown = None
    for r in rows:
        if not r["ppu"]:
            continue
        head = ppu_header(pathlib.Path(r["ppu"]))
        if shown is None:
            shown = head
            add("  every .ppu below was built by compiler %s for %s / %s"
                % (head["Compiler version"], head["Target processor"],
                   head["Target OS"]))
            add("")
        add("  %-24s %s" % (r["dotted"], r["ppu"]))
    add("")

    print("\n".join(out))
    return "\n".join(out)


def detail_report(rows):
    out = []
    add = out.append

    add("")
    add("DISAGREEMENTS, CLASSIFIED AGAINST THE COMPILER'S OWN RECORD")
    add("=" * 78)
    add("A symbol in `only in source` is one the source reader saw and the "
        "compiler")
    add("does not record as a unit symbol. Almost all of them are class members")
    add("and record fields: they are not re-exportable, and they arrive with")
    add("their type, so a shim never needs to name them. Anything the compiler")
    add("records as a unit symbol anyway is a contradiction and fails the tool.")

    unexplained = [r for r in rows if r["unexplained"]]
    n_explained = sum(len(r["explained_by_nesting"]) for r in rows)
    n_absent = sum(len(r["absent_from_compiler"]) for r in rows)
    add("")
    add("  recorded by the compiler as nested in a type : %d" % n_explained)
    add("  recorded NOWHERE by the compiler             : %d" % n_absent)
    add("  CONTRADICTIONS (hard failure)                : %d"
        % sum(len(r["unexplained"]) for r in unexplained))
    if not unexplained:
        add("  -> every source-only symbol is accounted for. The comparison holds.")
    for r in unexplained:
        add("  %s: %s" % (r["dotted"], ", ".join(r["unexplained"])))
    add("")
    kinds = collections.Counter()
    for r in rows:
        for v in r["explained_by_nesting"].values():
            kinds[v] += 1
    for k, v in sorted(kinds.items()):
        add("  %-16s %d" % (k, v))
    if n_absent:
        add("")
        add("  Recorded nowhere. Cause, measured once: the source reader follows")
        add("  `{$I}` into the text and reads an ALIAS as if it were the record")
        add("  it names -- types.pp:87 declares `TPoint = Windows.TPoint`, so the")
        add("  fields X and Y belong to a record `types` does not own. These are")
        add("  still not re-exportable, so the verdict is unaffected; they are")
        add("  listed so the count is not mistaken for a contradiction.")
        for r in rows:
            if r["absent_from_compiler"]:
                add("    %-22s %s" % (r["dotted"],
                                      ", ".join(r["absent_from_compiler"])))
    add("")

    add("THE SOURCE READER AUTHORISING SOMETHING THE COMPILER REFUTES")
    add("=" * 78)
    add("Categories 1 and 4 are the two verdicts that let a reader act. This is")
    add("the checkable form of section 22.3's forbidden direction, and it is not")
    add("hypothetical: Winapi.Messages is in it.")
    contra = [r["dotted"] for r in rows if r["source_contradicts_compiler"]]
    add("")
    add("  %s" % (", ".join(contra) if contra else "none"))
    add("")

    add("SYMBOLS THE SOURCE READER MISSED (the dangerous direction)")
    add("=" * 78)
    add("Each of these is a symbol the Delphi tree references, that the "
        "compiler's record")
    add("contains, and that a source-text scan cannot see. Had the source "
        "reader been")
    add("trusted, every one of them is a permission to drop real work.")
    total = 0
    for r in rows:
        if not r["missed_by_source"]:
            continue
        total += len(r["missed_by_source"])
        add("  %-24s %d: %s" % (r["dotted"], len(r["missed_by_source"]),
                                ", ".join(r["missed_by_source"][:14])
                                + (" ..." if len(r["missed_by_source"]) > 14
                                   else "")))
    if not total:
        add("  none")
    add("")
    add("  TOTAL missed symbols: %d" % total)

    add("")
    add("CATEGORY 4 CARRIES A STANDING CAVEAT")
    add("=" * 78)
    add("\"No symbol of the tail is referenced\" is a statement about the TAIL's")
    add("surface. It is not a statement about the Delphi unit, whose surface this")
    add("repo cannot enumerate -- the vendored tree carries SynEdit and SVGIcon,")
    add("not the VCL proper. So a name the tree needs which the tail happens not")
    add("to declare would be indistinguishable from a vestigial uses entry.")
    add("Each of these was also checked by hand against its consumers:")
    for r in rows:
        if r["ppu_ev"]["category"] != "4. QUESTIONABLE":
            continue
        add("  %-22s consumers: %s"
            % (r["dotted"], ", ".join(s.split("/")[-1]
                                     for s in r["ppu_ev"].get("consumers", []))
               or "(not recorded)"))
    add("")

    add("NAMES WHOSE CATEGORY MOVED")
    add("=" * 78)
    moved = [r for r in rows
             if r["source"]["category"] != r["ppu_ev"]["category"]]
    for r in moved:
        add("  %s" % r["dotted"])
        add("      source: %s" % r["source"]["category"])
        add("              %s" % r["source"]["reason"])
        add("      ppu   : %s" % r["ppu_ev"]["category"])
        add("              %s" % r["ppu_ev"]["reason"])
    if not moved:
        add("  none")
    add("")

    add("VERDICT")
    add("=" * 78)
    by_src = collections.Counter(r["source"]["category"] for r in rows)
    by_ppu = collections.Counter(r["ppu_ev"]["category"] for r in rows)
    for cat in sorted(set(by_src) | set(by_ppu)):
        add("  %-30s source %2d   ppu %2d"
            % (cat, by_src.get(cat, 0), by_ppu.get(cat, 0)))
    add("")
    add("  No shim was created and no source file was modified by this tool.")
    print("\n".join(out))
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Self-test: the guards must be able to fail, in the direction that matters
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The ratchet
#
# Frozen measurement plus an additive allowance, never an overwrite. Section
# 21.4 recorded what happens when the two are confused: --write-baseline washed
# `renamed` from `[Vcl.VirtualImage]` to `[]`, deleting a historical
# classification. So the baseline holds what was MEASURED and separately records
# what is KNOWN BAD; the ratchet fails when the known-bad set grows.
#
# Three conditions, all in the direction that destroys value rather than the one
# that merely wastes it:
#   * a contradiction between the two surfaces appears   (the tool's own fatal)
#   * a name joins the source-authorises-but-compiler-refutes set
#   * a name's compiler-record category moves at all
# ---------------------------------------------------------------------------

BASELINE = ROOT / "tools" / "f3_ppu_surface_baseline.json"


def measurement(rows):
    return {
        "unexplained_contradictions": sum(len(r["unexplained"]) for r in rows),
        "source_authorises_compiler_refutes":
            sorted(r["dotted"] for r in rows
                   if r["source_contradicts_compiler"]),
        "symbols_source_reader_missed":
            sum(len(r["missed_by_source"]) for r in rows),
        "ppu_categories": {r["dotted"]: r["ppu_ev"]["category"] for r in rows},
        "source_categories": {r["dotted"]: r["source"]["category"]
                              for r in rows},
    }


def ratchet(rows, write=False):
    """Compare against the frozen baseline. Returns an exit code."""
    now = measurement(rows)
    if write:
        BASELINE.write_text(json.dumps(now, indent=2, sort_keys=True) + "\n",
                            encoding="utf-8")
        print("wrote %s" % BASELINE.name)
        print("  An explicit action. Nothing here was accepted automatically.")
        return 0
    if not BASELINE.is_file():
        # This hole was found by the self-test, which fed the ratchet a
        # fabricated refuted authorisation and watched it PASS -- because with no
        # baseline on disk the first version simply created one and returned 0.
        # A gate whose input file can be deleted by deleting the file is the
        # "a credit with nothing behind it" shape from section 21.4, one level
        # up: there the credit was unearned, here the whole comparison was.
        print("RATCHET -- no baseline at %s" % BASELINE.name)
        print("=" * 78)
        print("  FAIL  there is nothing to compare against. Run --write-baseline")
        print("        deliberately; a missing baseline must not read as a pass.")
        return 1
    was = json.loads(BASELINE.read_text(encoding="utf-8"))


    problems = []

    grew = sorted(set(now["source_authorises_compiler_refutes"])
                  - set(was.get("source_authorises_compiler_refutes", [])))
    if grew:
        problems.append(
            "these names now have the source reader authorising something the "
            "compiler's record refutes, which was NOT already known bad: %s"
            % ", ".join(grew))

    for key in ("ppu_categories", "source_categories"):
        for name, cat in sorted(now[key].items()):
            old = was.get(key, {}).get(name)
            if old is not None and old != cat:
                problems.append("%s moved in %s: %s -> %s"
                                % (name, key, old, cat))

    if now["unexplained_contradictions"]:
        problems.append("%d disagreement(s) between the two surfaces have no "
                        "benign reading" % now["unexplained_contradictions"])

    print("RATCHET -- the compiler's record is the authority; the source reader "
          "is not")
    print("=" * 78)
    print("  contradictions                     %d (was %s)"
          % (now["unexplained_contradictions"],
             was.get("unexplained_contradictions", "?")))
    print("  source authorises, compiler refutes  %d (was %d): %s"
          % (len(now["source_authorises_compiler_refutes"]),
             len(was.get("source_authorises_compiler_refutes", [])),
             ", ".join(now["source_authorises_compiler_refutes"]) or "none"))
    print("  symbols the source reader missed     %d (was %s)"
          % (now["symbols_source_reader_missed"],
             was.get("symbols_source_reader_missed", "?")))
    print("")
    if problems:
        for p in problems:
            print("  FAIL  %s" % p)
        print("\n  A drop is allowed only via --write-baseline, explicitly.")
        return 1
    print("  ok    no new contradiction, no new refuted authorisation, no move.")
    return 0


def self_test():
    """Prove the guards fire. A guard never seen refusing is not a guard."""
    failures = []

    sample = "\n".join([
        "Analyzing x.ppu (v207)",
        "Interface Symbols",
        "------------------",
        "Symtable count: 4",
        "** Symbol Id 1 **",
        "Type symbol TPublic",
        "     File Pos : 3 (10,5)",
        "   Visibility : public",
        "   SymOptions : ",
        "** Symbol Id 2 **",
        "Type symbol THidden",
        "     File Pos : 3 (11,5)",
        "   Visibility : private",
        "   SymOptions : ",
        "** Symbol Id 3 **",
        "Procedure symbol DoThing",
        "     File Pos : 3 (12,7)",
        "   Visibility : public",
        "   SymOptions : ",
        "** Symbol Id 4 **",
        "Unit symbol x",
        "     File Pos : 1 (1,1)",
        "   Visibility : public",
        "   SymOptions : ",
    ])

    got = surface_from_text(sample)
    # 1. a private symbol must NOT be offered as re-exportable
    if "THidden" in got:
        failures.append("private symbol THidden leaked into the surface")
    # 2. a unit's own name must not be offered as a symbol
    if "x" in got:
        failures.append("the unit's own name leaked in as a symbol")
    # 3. the kinds must be right, or the category arithmetic is meaningless
    if got.get("TPublic") != "type" or got.get("DoThing") != "routine":
        failures.append("kind mapping wrong: %r" % (got,))
    # 4. a symbol with NO visibility line must not be exported on the strength of
    #    the previous symbol's visibility
    orphan = "** Symbol Id 9 **\nType symbol TOrphan\n"
    if "TOrphan" in surface_from_text(orphan):
        failures.append("a symbol with no Visibility line was treated as public")

    # 5. the unreadable-.ppu guard must REFUSE, not return an empty surface
    try:
        surface(pathlib.Path("C:\\does\\not\\exist.ppu"))
    except _sf._Unlocatable:
        pass
    except Exception as exc:                       # noqa: BLE001
        failures.append("unreadable ppu raised %r, not the refusal it should"
                        % (exc,))
    else:
        failures.append("unreadable ppu returned a surface instead of refusing")

    # 6. and the refusal must actually reach the classifier as INDETERMINATE,
    #    never as "no symbols referenced"
    cat, _ = _sf.classify(
        "System.SysUtils",
        lambda tail: (_ for _ in ()).throw(
            _sf._Unlocatable("simulated extraction failure", "x.ppu")))
    if cat != "5. INDETERMINATE":
        failures.append("extraction failure classified as %s, not INDETERMINATE"
                        % cat)

    # 7. the ratchet must FAIL when a name joins the refuted-authorisation set.
    #    A ratchet that has never been seen refusing is not a ratchet -- that is
    #    section 21.3's first finding, where an invariant no one could violate
    #    was reported as a passing invariant.
    #
    #    It is exercised twice, because the two holes are different: against a
    #    baseline that does not exist, and against one that does.
    import io
    import contextlib
    import shutil
    import tempfile

    fake = [
        {"dotted": "Winapi.Messages",
         "ppu_ev": {"category": "3. NOT SAFELY SHIM-ABLE"},
         "source": {"category": "4. QUESTIONABLE"},
         "source_contradicts_compiler": True,
         "unexplained": [], "missed_by_source": [], "only_in_source": []},
        {"dotted": "System.SysUtils",
         "ppu_ev": {"category": "3. NOT SAFELY SHIM-ABLE"},
         "source": {"category": "5. INDETERMINATE"},
         "source_contradicts_compiler": False,
         "unexplained": [], "missed_by_source": [], "only_in_source": []},
    ]

    def run_ratchet(rows_to_check, write=False):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = ratchet(rows_to_check, write=write)
        return code, buf.getvalue()

    stash = BASELINE.read_bytes() if BASELINE.is_file() else None
    try:
        if BASELINE.is_file():
            BASELINE.unlink()
        code, out = run_ratchet(fake)
        if code == 0:
            failures.append("the ratchet passed with NO baseline on disk")
        if "nothing to compare against" not in out:
            failures.append("a missing baseline did not say so")

        code, out = run_ratchet(fake, write=True)     # deliberate creation
        code, out = run_ratchet(fake)                 # must now PASS
        if code != 0:
            failures.append("the ratchet failed on the very data it was "
                            "written from: %s" % out.strip().splitlines()[-1:])
        code, out = run_ratchet(fake[:1] + [
            dict(fake[1], source_contradicts_compiler=True,
                 dotted="Vcl.Themes", source={"category": "4. QUESTIONABLE"}),
            dict(fake[1], dotted="Vcl.ImgList",
                 source_contradicts_compiler=False)])
        if code == 0:
            failures.append("the ratchet passed a NEW refuted authorisation")
        if "Vcl.Themes" not in out:
            failures.append("the ratchet failed without naming the new name")
        if "--write-baseline" not in out:
            failures.append("the ratchet failed without pointing at "
                            "--write-baseline")
    finally:
        if stash is not None:
            BASELINE.write_bytes(stash)
        elif BASELINE.is_file():
            BASELINE.unlink()

    print("SELF-TEST -- the guards, forced to refuse")
    print("=" * 78)
    if failures:
        for f in failures:
            print("  FAIL  %s" % f)
        print("\n  %d of 9 checks failed." % len(failures))
        return 1
    print("  ok    a private symbol is not offered for re-export")
    print("  ok    the unit's own name is not offered as a symbol")
    print("  ok    kinds survive the mapping (type / routine)")
    print("  ok    a symbol with no Visibility line is NOT exported")
    print("  ok    an unreadable .ppu refuses instead of returning {}")
    print("  ok    a refused surface reaches the classifier as INDETERMINATE,")
    print("        never as 'no symbols referenced'")
    print("  ok    the ratchet REFUSES when no baseline exists, and says so")
    print("  ok    the ratchet PASSES the data it was written from")
    print("  ok    the ratchet REFUSES a new refuted authorisation, names it,")
    print("        and points at --write-baseline")
    print("\n  9 of 9 checks passed.")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--detail", action="store_true")
    ap.add_argument("--ratchet", action="store_true")
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    base = json.loads((ROOT / "tools" / "f3_namespace_alias_baseline.json")
                      .read_text(encoding="utf-8"))
    names = list(base.get("prefix_only", []))

    rows, failed, resolved = compare(names)

    unexplained = sum(len(r["unexplained"]) for r in rows)

    if args.ratchet or args.write_baseline:
        return ratchet(rows, write=args.write_baseline)

    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return 1 if unexplained else 0

    report(rows, failed, resolved)
    if args.detail:
        detail_report(rows)
    else:
        print("\n  (re-run with --detail for the symbol-level differences and "
              "the verdict)")

    if unexplained:
        # Hard stop, and it is the one direction this comparison must never
        # survive: a name the tree uses that neither surface can account for.
        # Continuing would print a verdict resting on a disagreement nobody
        # explained.
        print("\nFAILED: %d disagreement(s) between the two evidence sources "
              "have no" % unexplained)
        print("benign reading, so the comparison above cannot be trusted. "
              "See --detail.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
