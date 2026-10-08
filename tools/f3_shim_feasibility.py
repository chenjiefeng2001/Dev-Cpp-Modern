"""Classify the 22 group-A dotted units: could each be shimmed, and at what cost?

WHY THIS IS A SEPARATE EXPERIMENT, NOT A BATCH
===============================================
`Vcl.VirtualImage` was shimmable with ONE line because the Delphi tree names
exactly ONE symbol from it, and that symbol is a type. The same mechanism does
not generalise, and the reason was measured rather than assumed:

    unit Vcl.Forms;
    interface
    uses Forms;              <- NOT ENOUGH. FPC has no transitive interface
    implementation           visibility, so a client cannot see TForm.
    end.

That Error: Identifier not found "TForm" is the whole finding. A group-A shim
must re-declare every symbol the Delphi tree consumes from the LCL unit, so the
question "is this shim-able" is really "how many symbols, of which kinds".

So this tool MEASURES, per dotted name:

  * which symbols of the tail unit the Delphi tree actually references;
  * of what KIND each is (type / const / var / routine);
  * whether that kind survives a re-export shim at all.

and then assigns one of four categories:

  1. SHIM CANDIDATE      -- symbols exist and are all TYPE ALIASES, so the shim
                            is one line per symbol.
  2. ALREADY RESOLVABLE  -- the FPC side already resolves the dotted name; no
                            shim required.
  3. NOT SAFELY SHIM-ABLE-- at least one needed symbol is NOT a type, so an
                            alias cannot reproduce it. Needs implementation or
                            another mechanism.
  4. QUESTIONABLE       -- the dotted name appears only syntactically: the
                            Delphi tree references no symbol from it at all.
                            Porting because a name appears in a uses clause is
                            exactly the mistake this category exists to catch.

Nothing is written. No shim is created. This is a classifier.
"""

import argparse
import collections
import importlib.util
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location(
    "_ns", ROOT / "tools" / "f3_namespace_alias.py")
_ns = importlib.util.module_from_spec(spec)
_saved = sys.argv
sys.argv = ["f3_namespace_alias.py"]
try:
    spec.loader.exec_module(_ns)
except SystemExit:
    raise SystemExit("could not import f3_namespace_alias.py")
finally:
    sys.argv = _saved


def uses_clauses(text):
    """Yield the body of every `uses ...;` clause, comments stripped."""
    for m in re.finditer(r"(?ms)^\s*uses\b(.*?);", _ns._strip_comments(text)):
        for part in m.group(1).split(","):
            nm = part.strip().split(" in ")[0].strip()
            if re.fullmatch(r"\w+(?:\.\w+)*", nm or ""):
                yield nm


def strip_comments(text):
    """Pascal comments removed without mistaking a brace inside a LITERAL for one.

    THE BUG THIS REPLACES, because it failed in the direction this whole tool
    exists to avoid. The previous version counted every `{` character, including
    the ones inside character and string literals:

        if CurLine[col] = '{' then            -- Source/Editor.pas:2986

    That `{` opens a comment the scanner never closes, so everything after it is
    silently deleted. Measured on the real tree: 10 of the 121 Delphi-tree units
    finish with the brace depth still positive, so their tails were invisible to
    every symbol search built on this function -- including
    `Printer.Title := FDocTitle` at Editor.pas:3087, and an unknown span of
    main.pas.

    A swallowed line makes a symbol look UNUSED, and "unused" is the one category
    that authorises dropping work. So this defect was silently manufacturing
    permission to skip units, in the consumer scan that BOTH evidence sources
    share -- which is why `Vcl.Printers` came out "no symbol referenced" while
    `Printer` sat in its own .ppu as a public global variable.

    THE LESSON, because the obvious "fix" was tried first and is worse. This
    repository already owns a correct stripper: `comment_bleed.strip_lines`,
    written for f3_compile_cost.py with the note "reuses the repo's own stripper
    so this tool does not become a second implementation of a rule that already
    has one". Delegating to it was measured here and REJECTED: on this input it
    moves the verdict from 3. NOT SAFELY SHIM-ABLE / 5. INDETERMINATE to
    3. NOT SAFELY SHIM-ABLE / 16. INDETERMINATE, because its string-literal
    state persists across lines and the units fed to it here are FPC's
    per-platform variants.

    So the real lesson is not "use the shared one" but "stop hand-rolling this".
    The source-text evidence source has three independently measured defects and
    is no longer authoritative at all -- see the banner in main() and
    tools/f3_ppu_surface.py. This function survives only so the comparison that
    documents WHY is reproducible.
    """
    out = []
    i, n = 0, len(text)
    depth = 0                      # 0 = code, 1 = inside { }, 2 = inside (* *)
    while i < n:
        ch = text[i]
        if depth:
            if depth == 1 and ch == "}":
                depth = 0
                i += 1
                continue
            if depth == 2 and ch == "*" and text[i:i + 2] == "*)":
                depth = 0
                i += 2
                continue
            # Newlines survive: `uses_clauses` and the declaration patterns are
            # all ^-anchored with re.M, so collapsing lines would silently merge
            # declarations that were never on the same line.
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        two = text[i:i + 2]
        if ch == "{":
            depth = 1
            out.append(" ")
            i += 1
            continue
        if two == "(*":
            depth = 2
            out.append("  ")
            i += 2
            continue
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if ch == "'":
            # Copy a string literal verbatim, since '' is an escaped quote.
            # Bounded to one line: a quote that never closes must not be able to
            # swallow the rest of the file, which is the failure being repaired.
            j = i + 1
            while j < n and text[j] != "\n":
                if text[j] == "'":
                    if text[j:j + 2] == "''":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)



_ns._strip_comments = strip_comments


# Symbol kinds a unit can export, and whether a RE-EXPORT SHIM can reproduce
# them by a one-line alias. This table is the whole basis of category 3.
_INCLUDE_DIRS = (
    # objfpc/objpas variants first: this project builds with -Mdelphiunicode in
    # objfpc mode, and these are the ones that match.
    r"C:\lazarus\fpc\3.2.2\source\rtl\objpas\sysutils",
    r"C:\lazarus\fpc\3.2.2\source\rtl\objpas\classes",
    r"C:\lazarus\fpc\3.2.2\source\rtl\objpas\inc",
    r"C:\lazarus\fpc\3.2.2\source\rtl\objpas",
    r"C:\lazarus\fpc\3.2.2\source\rtl\inc",
    r"C:\lazarus\fpc\3.2.2\source\rtl\amicommon",
    r"C:\lazarus\fpc\3.2.2\source\rtl\win32",
    r"C:\lazarus\fpc\3.2.2\source\rtl\objpas\x86_64-win64",
    r"C:\lazarus\fpc\3.2.2\source\packages\rtl-objpas\src\inc",
    r"C:\lazarus\fpc\3.2.2\source\packages\fcl-base\src",
    r"C:\lazarus\fpc\3.2.2\source\packages\winunits-base\src",
    r"C:\lazarus\fpc\3.2.2\source\packages\winunits-jedi\src",
)

_INC_DIRECTIVE = re.compile(r"\{\$(?:I|INCLUDE)\s+(\S+?)\s*\}", re.I)


class Indeterminate(Exception):
    """Raised when a unit's surface cannot be enumerated reliably."""


def expand_includes(pas, depth=0, seen=None):
    """Unit text with `{$I file.inc}` inlined, or raise Indeterminate.

    MANDATORY, and its absence produced the most dangerous result this tool has
    produced. FPC's RTL units are thin wrappers: sysutils.pp is a `{$I
    sysutils.inc}` shell and classes.pp is `{$I classes.inc}`, so a naive scan
    reports 5 and 0 exported symbols. Every RTL name then came out as
    "QUESTIONABLE -- no symbol from this unit is referenced", which is a licence
    to drop real work. That is the one error direction a feasibility classifier
    must never make silently, and it made it on the first run.

    Ambiguity is refused rather than resolved. FPC ships per-platform copies of
    many .inc files -- execd.inc exists for morphos, amiga and others -- so
    "first match wins" would silently inject the wrong platform's declarations.
    When more than one candidate survives the ordered search, this raises
    instead, and the classifier reports the name as INDETERMINATE rather than
    guessing.
    """
    if seen is None:
        seen = set()
    if depth > 6 or pas in seen:
        return ""
    seen.add(pas)
    try:
        text = pas.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""

    def sub(m):
        name = m.group(1)
        ordered = [pas.parent / name]
        ordered += [pathlib.Path(d) / name for d in _INCLUDE_DIRS]
        hits = [c for c in ordered if c.is_file()]
        if not hits:
            return " "          # unresolved: do not pretend it does not exist
        # One ordered hit that is not a competing platform copy is fine.
        first = hits[0]
        rivals = [h for h in hits[1:]
                  if h.resolve() != first.resolve()]
        if rivals:
            raise Indeterminate(
                "%s: `{$I %s}` resolves to more than one file (%s ... %s); "
                "picking one would inject another platform's declarations"
                % (pas.name, name, first, rivals[0]))
        return expand_includes(first, depth + 1, seen)

    return _INC_DIRECTIVE.sub(sub, text)


def declared_symbols(pas):
    """{NAME: kind} for the public surface of a unit, includes followed."""
    text = expand_includes(pas)
    if not text:
        return {}
    body = re.split(r"(?mi)^\s*implementation\s*$", text)[0]
    body = strip_comments(body)

    syms = {}

    def grab(kind, pat):
        # Take the first NON-NONE group. The `var` pattern has two alternatives
        # with a capture each, so match.group(1) is None on half the hits --
        # which then reached re.escape() as None and raised
        # "decoding to str: need a bytes-like object".
        for m in re.finditer(pat, body, re.I | re.M):
            for g in m.groups():
                if g:
                    syms.setdefault(g, kind)
                    break

    # TYPES: a single-line `TFoo = class(...)`, `TFoo = record`, `TFoo = class of`
    #         `TFoo = type X`. Exclude aliases to RTL units? No -- keep them;
    #         they are still types and still alias-able.
    grab("type", r"(?m)^\s*(T\w+|[A-Z]\w*)\s*=\s*(?:class|record|object|"
                  r"interface|type|set\s+of|\(|[\w.]+\s*;)")
    # CONSTS
    grab("const", r"(?mi)^\s*(\w+)\s*(?::\s*[\w.]+\s*)?=\s*[^=]")
    # VARS
    grab("var", r"(?mi)^\s*(?:(\w+)\s*:\s*[\w.<>]+\s*;|var\s+(\w+)\s*:)")
    # ROUTINES -- a routine shim must repeat `external 'dll' name '...'` or
    # forward the body. Neither is a one-line alias.
    grab("routine", r"(?mi)^\s*(?:class\s+)?(?:function|procedure|constructor|"
                    r"destructor)\s+(\w+)")
    return syms


# ---------------------------------------------------------------------------
# THE PRINCIPLE, as an enforced rule rather than a comment
# ---------------------------------------------------------------------------
#     EVIDENCE-EXTRACTION FAILURE IS NOT "THE SYMBOL DOES NOT EXIST".
#
# The first run of this tool reported five names as "QUESTIONABLE -- no symbol
# from this unit is referenced", `System.SysUtils` among them. That was the
# EXTRACTOR failing: FPC's RTL units are include shells (`sysutils.pp` is
# `{$I sysutils.inc}`), so a scan that does not follow includes sees 5 symbols
# where there are thousands.
#
# Category 4 is the only category that authorises DROPPING work, so it is the
# only category where a wrong answer destroys value instead of merely wasting
# time. Every other misclassification is safe in the direction it errs.
#
# Two guards below enforce the principle:
#   * a suspiciously small export surface refuses the classification;
#   * an ambiguous `{$I}` raises instead of guessing.
#
# Anything that cannot be established is reported as INDETERMINATE. An
# incomplete table that says so is more useful than a complete one that lies.
# ---------------------------------------------------------------------------

# Below this, a "no symbols referenced" verdict is treated as an extractor
# failure rather than as evidence. Chosen against real measurements: `math`
# exports 120 and `controls` 1274, while a broken `sysutils` scan saw 5 and
# `classes` saw 0. 25 sits an order of magnitude above the failure mode and an
# order of magnitude below any unit worth classifying.
MIN_PLAUSIBLE_EXPORTS = 25


def consumer_usage(dotted, exported):
    """Which Delphi-tree units consume `dotted`, and which of `exported`'s
    symbols do they actually reference?

    Factored out of classify() with no change to its behaviour, because a second
    implementation of "what does the Delphi tree consume" would be the FOURTH
    copy of a quantity that this project has now computed two ways in one file
    three times already (F1-g's `uses main` count, F1-m-0's fourth item, and
    section 17.10's roll-up). The correctness argument for a comparison tool is
    that both sides measure the same thing; that argument does not survive
    re-deriving one of them.
    """
    consumers, wanted = set(), set()
    for pas in sorted((ROOT / "Source").rglob("*.pas")):
        rel = pas.relative_to(ROOT).as_posix()
        if rel.startswith("Source/Fpc/") or "VCL" in pas.parts:
            continue
        try:
            text = pas.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not any(n.lower() == dotted.lower() for n in uses_clauses(text)):
            continue
        consumers.add(rel)
        code = strip_comments(text)
        for name in exported:
            if re.search(r"\b%s\b" % re.escape(name), code):
                wanted.add(name)
    return consumers, wanted


def classify(dotted):
    """One dotted name -> (category, detail dict)."""
    tail = dotted.rsplit(".", 1)[-1]

    # Category 2 first: does the FPC side already resolve the dotted name?
    if _ns.shim_for(dotted) is not None:
        return "2. ALREADY RESOLVABLE", {"reason": "a unit declares this name"}

class _Unlocatable(Exception):
    """A unit was found but its surface cannot be enumerated."""

    def __init__(self, reason, unit):
        super().__init__(reason)
        self.reason = reason
        self.unit = unit


def source_evidence(tail):
    """(exported surface, locator detail) for `tail`, from the Pascal SOURCE.

    REFERENCE ONLY. NOT AUTHORITATIVE, and the reason is measured rather than
    suspected. Three independent defects, all of them in the direction that
    destroys value:

    1. IT READS THE WRONG COPY OF THE UNIT. `compiled_unit_paths()` builds its
       table with `setdefault` over `rglob`, so whichever per-platform variant
       the filesystem yields first wins. Measured on this machine:

           SysUtils  -> rtl\\amicommon\\sysutils.pp     (Amiga)
           Classes   -> rtl\\amicommon\\classes.pp      (Amiga)
           Messages  -> lcl\\nonwin32\\messages.pp      (the NON-WINDOWS stub)

       So the three most important names in this table were classified by reading
       code for platforms this project does not build. `Messages` is the whole
       story of how `Winapi.Messages` came out "no symbol referenced": the stub
       the reader opened declares almost nothing.

    2. IT COUNTS CLASS MEMBERS AS UNIT SYMBOLS. The declaration patterns match
       at any nesting depth, so `constructor Create;` inside `TThread = class`
       becomes a routine named `Create`, and `X : Longint;` inside a record
       becomes a variable named `X`. Measured: 177 such names across these 22
       units, and because `Create`, `Assign`, `Clear` and `Add` occur in almost
       any file, they were being matched as "used" in consumers.

    3. IT MISSES REAL SYMBOLS. 43 names the tree references that this reader
       cannot see, 40 of them in SysUtils, whose surface it refuses to enumerate
       at all.

    A reader with three measured defects in the dangerous direction is not worth
    repairing -- it is worth replacing. `f3_ppu_surface.py` replaces it with the
    compiler's own record and prints this column beside the replacement, so the
    comparison that justifies the change stays reproducible.

    `exported is None` means "this evidence source could not even locate the
    unit", which the classifier reports as category 3; it never means "the unit
    is unused". Only the small-surface guard may say that.
    """
    sources = _ns.compiled_unit_paths()
    unit = sources.get(tail.lower())
    if unit is None:
        return None, {
            "reason": "the unprefixed tail has no source under any Lazarus/FPC "
                      "root, so there is nothing to re-export"}
    try:
        return declared_symbols(unit), {"unit": str(unit)}
    except Indeterminate as exc:
        raise _Unlocatable("surface not enumerable: %s" % exc, str(unit))



def classify(dotted, evidence=source_evidence):
    """One dotted name -> (category, detail dict).

    `evidence` is the single point where "where does this unit's symbol surface
    come from" is decided, so a second evidence source can be compared against
    this one without a second copy of the category rules. Two copies of the
    RULES would be a fourth instance of the failure this project has hit three
    times: the same quantity computed two ways in one file.
    """
    tail = dotted.rsplit(".", 1)[-1]

    # Category 2 first: does the FPC side already resolve the dotted name?
    if _ns.shim_for(dotted) is not None:
        return "2. ALREADY RESOLVABLE", {"reason": "a unit declares this name"}

    try:
        exported, loc = evidence(tail)
    except _Unlocatable as exc:
        return "5. INDETERMINATE", {"reason": exc.reason, "unit": exc.unit}
    if exported is None:
        return "3. NOT SAFELY SHIM-ABLE", loc
    unit = loc["unit"]

    # Which Delphi-tree units consume this dotted name, and what do they use?
    consumers, wanted = consumer_usage(dotted, exported)
    kinds = collections.Counter(exported[n] for n in wanted)
    # The source lives under C:\lazarus, NOT under the repo, so relative_to
    # raised on the first RTL unit. Reporting an absolute path is honest and the
    # crash was better than a silently wrong location.
    detail = {
        "consumers": sorted(consumers),
        "symbols_needed": len(wanted),
        "kinds": dict(kinds),
        "unit": unit,
    }

    # Category 4: the name is syntactic only.
    #
    # Guarded, because this is the category that authorises DROPPING work, and
    # it is the one an incomplete extractor gets wrong in the dangerous
    # direction. If the tail unit exports a suspiciously small surface, that is
    # evidence the extraction failed -- not evidence the unit is unused.
    if not wanted:
        if len(exported) < MIN_PLAUSIBLE_EXPORTS:
            return "5. INDETERMINATE", {
                "reason": "tail unit exposed only %d symbol(s), below the %d "
                          "floor -- that is an EXTRACTION FAILURE, not evidence "
                          "the unit is unused"
                          % (len(exported), MIN_PLAUSIBLE_EXPORTS),
                "unit": unit,
                "consumers": sorted(consumers),
            }
        detail["reason"] = ("no symbol from this unit is referenced; the "
                            "uses entry alone would justify nothing")
        return "4. QUESTIONABLE", detail

    # Category 3: something other than a type is needed.
    #
    # sorted() is load-bearing, not cosmetic. `kinds` is built from a SET, so its
    # iteration order follows string hash randomisation and this sentence came out
    # in a different order on consecutive runs of an UNCHANGED tree -- measured:
    # three runs, two distinct texts, `System.Classes` reading "30 routine, 14
    # var" and "14 var, 30 routine". The category and every count were stable;
    # only the wording of the reason moved.
    #
    # That is a small thing, and it is recorded because it costs this tool its
    # only regression witness: "the output is byte-identical" is how section 3.1
    # proved the 137x speedup changed no answer, and it is simply not available
    # here until the text is a function of the data alone. A measurement tool that
    # cannot be compared byte-for-byte invites unnoticed drift.
    non_types = {k: v for k, v in kinds.items() if k != "type"}
    if non_types:
        detail["reason"] = ("needs %s, which a one-line type alias cannot "
                            "reproduce" % ", ".join(
                                "%d %s" % (non_types[k], k)
                                for k in sorted(non_types)))
        return "3. NOT SAFELY SHIM-ABLE", detail

    detail["reason"] = ("%d type symbol(s), each one alias line"
                        % len(wanted))
    return "1. SHIM CANDIDATE", detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    base_path = ROOT / "tools" / "f3_namespace_alias_baseline.json"
    hist = json.loads(base_path.read_text(encoding="utf-8"))
    names = list(hist.get("prefix_only", []))

    results = {n: classify(n) for n in names}

    if args.json:
        print(json.dumps({n: {"category": c, **d} for n, (c, d) in results.items()},
                         indent=2, sort_keys=True))
        return 0

    print("GROUP-A SHIM FEASIBILITY -- a classification, NOT an implementation")
    print("=" * 78)
    print()
    print("*** THE TABLE BELOW IS NOT AUTHORITATIVE. ***")
    print()
    print("It reads unit SOURCE. Measured on this tree, that reader:")
    print("  * opens the WRONG COPY of three units -- SysUtils and Classes from")
    print("    rtl\\amicommon (Amiga), Messages from lcl\\nonwin32 (the non-Windows")
    print("    stub), because the unit table is built with setdefault over rglob;")
    print("  * counts CLASS MEMBERS and RECORD FIELDS as unit symbols (177 of")
    print("    them, including Create, Assign, Clear and Add);")
    print("  * MISSES 43 real symbols the tree references.")
    print()
    print("The authoritative classification is")
    print("    python tools/f3_ppu_surface.py --detail")
    print("which runs THIS SAME classify() against the .ppu the compiler itself")
    print("produced. Run this file to reproduce the comparison that justifies the")
    print("replacement, not to plan work.")
    print()
    print("FPC has no transitive interface visibility (measured: a shim that "
          "only")
    print("`uses Forms` cannot re-export TForm). So each dotted name costs one "
          "alias line")
    print("per symbol the Delphi tree actually consumes, and only TYPEs are "
          "alias-able.")
    print()
    print("Measured over %d dotted name(s) from the frozen baseline."
          % len(names))
    print()

    by_cat = collections.defaultdict(list)
    for n in sorted(results):
        cat, detail = results[n]
        by_cat[cat].append((n, detail))

    for cat in sorted(by_cat):
        print("%s  (%d)" % (cat, len(by_cat[cat])))
        for n, d in by_cat[cat]:
            extra = ""
            if "symbols_needed" in d:
                extra = "  [%d symbol(s): %s]" % (
                    d["symbols_needed"],
                    ", ".join("%s=%d" % (k, v)
                              for k, v in sorted(d["kinds"].items())) or "-")
            print("   %-32s %s%s" % (n, d.get("reason", ""), extra))
            if len(d.get("consumers", [])) <= 3:
                for c in d.get("consumers", []):
                    print("        %s" % c)
        print()

    print("=" * 78)
    print("VERDICT")
    for cat in sorted(by_cat):
        print("  %-30s %d" % (cat.split(".")[0] + ". " + cat.split(". ", 1)[1],
                              len(by_cat[cat])))
    print()
    print("  The number to plan against is NOT '22 shims'. Read the counts above.")
    print("  No shim was created and no source file was modified by this tool.")
    return 0


if __name__ == "__main__":
    sys.exit(main())