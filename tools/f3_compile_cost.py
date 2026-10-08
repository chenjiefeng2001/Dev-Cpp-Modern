"""True compile cost of each CLEARED form -- transitive uses-closure over the
SELF-AUTHORED tree, with COMMENTS STRIPPED FIRST.

Why comments must be stripped: the first version of this measurement reported
319 "external units" for ParamsFrm, of which the overwhelming majority were
English words lifted out of the files' comments ("Genuinely", "because",
"belongs", "appears"). A `uses ... ;` clause is matched by regex, and in this
repo the prose that follows it is full of identifier-shaped words. Reporting
that number would have been worse than reporting nothing.

Run:  python tools/f3_compile_cost.py            # report
      python tools/f3_compile_cost.py --ratchet  # gate (the default in CI)
      python tools/f3_compile_cost.py --write-baseline
Exit: 0 = the closure floor did not grow. 1 = it grew.
      (--ratchet / --write-baseline: 0)

WHY A BASELINE, AND WHY ONLY GROWTH FAILS
=========================================
This measurement answered a question the plan had been estimating for four
sprints -- "what would it cost to compile ONE form?" -- and the answer was
"all of it, every time" (13 of 13 forms share one 64-unit / 40,838-LOC closure
reached through `devcfg -> MainUi -> main`). A number that expensive needs to be
watched, or the next innocuous `uses` clause spends it silently.

Growth is the failure: a new self-authored dependency in a form's closure means
the F2/F3 compile surface just grew without anyone deciding to pay for it.
A SHRINK is progress, and like every ratchet in this repo it is never
auto-accepted -- `--write-baseline` is a deliberate act, because the tempting
move is to re-baseline downward the first time a tool miscounts.
"""
import collections
import importlib.util
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / (name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


_bleed = _load("comment_bleed")
_survey = _load("f3_form_survey")


def strip_comments(text):
    """Delphi comments, brace-depth aware. Reuses the repo's own stripper so
    this tool does not become a second implementation of a rule that already has
    one -- the F1-m-0 lesson about two hand-maintained copies applies to text
    handling as much as to class lists.

    `strip_lines(text, track)` returns a list of `(surviving_text, started_outside)`
    pairs -- measured, not guessed, after two wrong guesses (it returns one value
    rather than two, and that value is pairs rather than strings). Each wrong
    guess crashed on the first file, which is the only reason the third attempt
    is correct; the return contract is worth writing down where the next reader
    of `comment_bleed` will see it.

    `started_outside` is dropped here: this tool wants the surviving CODE, and a
    line whose code came entirely from inside a comment has nothing to scan."""
    return "\n".join(code for code, _ in _bleed.strip_lines(text, []))


# Unit names may be DOTTED: `Core.Events`, `System.SysUtils`, `GDB.MiParser`.
#
# The first version used `[A-Za-z_]\w*` and split every one of them at the dot,
# so `Core.Events` became the two tokens `Core` and `Events`, neither of which
# resolves to anything. The symptom was not an obvious error -- it was an
# "absent: 33" column full of plausible-looking names, and a closure that did
# not grow when a unit was added to it. It was found by the INJECTION matrix
# reporting a miss, not by reading the table: the table looked reasonable, and
# the number of things it claimed were missing should have been the clue.
UNIT_TOKEN = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*")
USES_RE = re.compile(r"\buses\b(.*?);", re.S | re.I)
# `in 'x.pas'` and `{$IFDEF}` guards can appear inside a uses clause; they are
# not unit references.
IN_FILE_RE = re.compile(r"\bin\s+'[^']*'", re.I)
# Words that appear in the repo's own comment prose inside uses clauses.
NOISE = {"in", "implementation", "interface", "ifndef", "ifdef", "else",
         "endif", "unit", "uses", "windows", "linux", "mswindows", "win32",
         "delphi", "unix", "macos"}


def read_text(path):
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "cp1252", "gbk", "latin-1"):
        try:
            return raw.decode(enc), enc
        except Exception:
            continue
    return raw.decode("latin-1"), "latin-1"


def uses_of(path):
    """Unit names from every uses clause, comments removed."""
    text, _ = read_text(path)
    clean = strip_comments(text)
    out = []
    for m in USES_RE.finditer(clean):
        clause = IN_FILE_RE.sub(" ", m.group(1))
        for tok in UNIT_TOKEN.findall(clause):
            if tok.lower() in NOISE:
                continue
            out.append(tok)
    return out


# Unit name -> path for the self-authored tree, matched case-INSENSITIVELY
# because Pascal does.
#
# COLLISIONS ARE REPORTED, NOT SILENTLY RESOLVED. The first version of this
# table used setdefault over rglob order, so on a Windows box the LAST file
# found won, and `aboutfrm` resolved to
#     Source/Tools/PackMaker/Aboutfrm.pas
# instead of
#     Source/AboutFrm.pas
# -- two different units that share a name. The consequence was not a wrong
# number but a confidently wrong CHEAPEST: AboutFrm's real closure includes
# DataFrm and devCFG and is 44 units, while the measurement said 1 unit and
# 48 lines, because it had walked into PackMaker's unrelated form.
#
# Measured: 8 duplicated stems in this tree ('aboutfrm', 'bzip2', 'config',
# 'frmmain', 'libtar', 'main', 'uhighlighterprocs', 'umain'). `main` is the one
# the plan document already warns about -- Source/main.pas,
# Tools/PackMaker/main.pas and Tools/Packman/Main.dfm are three different files
# whose names collide on a case-insensitive filesystem.
#
# The tie-break below is a MEASUREMENT CHOICE, not a claim that the two files
# are interchangeable: the top-level Source/<name>.pas is taken as the main
# program's unit, and the alternative is printed so nobody has to guess which
# one a number was computed from.
stems = collections.defaultdict(list)
for p in SOURCE.rglob("*.pas"):
    if "VCL" in p.parts or "Archive" in p.parts:
        continue
    stems[p.stem.lower()].append(p)

unit_path = {}
AMBIGUOUS = {}
for key, paths in stems.items():
    if len(paths) == 1:
        unit_path[key] = paths[0]
        continue
    # Prefer the shallower path -- Source/<x>.pas over Source/Tools/<t>/<x>.pas.
    paths_sorted = sorted(paths, key=lambda p: (len(p.parts), p.as_posix()))
    unit_path[key] = paths_sorted[0]
    AMBIGUOUS[key] = [p.relative_to(SOURCE).as_posix() for p in paths_sorted]

# Units with no declaration under Source/.  Split in two, because they are not
# equally bad: LCL/RTL names resolve under FPC, Windows/VCL names do not.
LCL_RTL = {
    "Classes", "SysUtils", "Types", "TypInfo", "Math", "StrUtils", "Variants",
    "Contnrs", "DateUtils", "DateUtils", "AnsiStrings", "SysControls",
    "Dialogs", "Grids", "Menus", "Printers", "IniFiles", "IOUtils",
    "WideStrUtils", "System", "TypInfo", "FileCtrl", "SyncObjs", "ActnList",
    "ShellAPI", "Registry", "FileCtrl", "ClipBrd", "WinSock", "TlHelp32",
    "ActiveX", "ComObj", "ShlObj", "Shell", "Zip",
}
LCL_WIDGETSET = {
    "Forms", "Controls", "Graphics", "StdCtrls", "Buttons", "Dialogs",
    "ExtCtrls", "ComCtrls", "ImgList", "ValEdit", "Spin", "CheckLst",
    "ExtDlgs", "ColorBox", "LclType", "Grids", "Menus", "Controls",
    "TabCtrls", "PropertyGrid", "DbCtrls", "Grids", "Forms",
    "LCLVersion", "LCLIntf", "LCLStrConsts", "FileUtil", "LazFileUtils",
    "SynEdit", "SynHighlighterCpp", "SynHighlighterPas", "SynEditHighlighter",
    "SynEditTypes", "SynEditMiscClasses", "SynGutter", "LazUTF8",
    "LazLogger", "LazFileUtils", "LazUtils", "DefaultTranslator",
    "LclResources", "LResources", "LCLPlatformDef", "LCLType",
    "Enumeration", "System.Utils", "TypInfo", "Interfaces",
    "LclVirtualImage", "VclPropertySkips", "SvgData", "ImageCollectionData",
}

VENDORED_ONLY = {
    # SynEdit: LCL has equivalents under the same names for most of these, but
    # the repo's vendored copies are the Delphi ones -- recorded, not resolved.
    "SynEditTypes", "SynEditHighlighter", "SynEditTextBuffer", "SynExportHTML",
    "SynExportRTF", "SynExportTeX", "SynEditExport", "SynEditSearch",
    "SynEditMiscClasses", "SynHighlighterCpp", "SynHighlighterRC",
    "SynEditKeyCmds", "SynEditCodeFolding", "SynEditPrint",
    "SynEditPrintTypes", "SynEditStyles", "SynHighlighterAny",
    # Vendored project code
    "ClassBrowser", "CodeCompletion", "CppParser", "CppTokenizer",
    "CppPreprocessor", "CBUtils", "devShortcuts", "devFileMonitor",
    "CodeCompletionForm", "TClassBrowser", "TCppParser",
    # VCL-only
    "Windows", "Messages", "Registry", "ShellAPI", "ShlObj", "ActiveX",
    "ComObj", "Themes", "ToolWin", "CommCtrl", "SysListView32",
    "SysTreeView32", "BaseImageCollection", "ImageCollection",
    "VirtualImageList", "SVGIconImageList", "SVGIconImageCollection",
    "SVGIconVirtualImageList", "SVGIconImageListBase", "SVGColor",
    "SVGIconImageListBase",
}


def closure(start):
    seen, externals, stack = set(), {}, [start]
    while stack:
        u = stack.pop()
        key = u.lower()
        if key in seen:
            continue
        seen.add(key)
        p = unit_path.get(key)
        if p is None:
            externals[u] = start
            continue
        for dep in uses_of(p):
            if dep.lower() not in seen:
                stack.append(dep)
    return seen, externals


def classify(u):
    """Three kinds of "not self-authored", and they are not equally bad.

    MEASURED, and the first cut of this column was useless: it lumped every
    external into one list and printed the first 27 characters of it. The list
    began `AbArcTyp, AbUnzper, Actions, ...`, which reads like comment noise --
    and chasing it down was worth it, because those two names are REAL
    (Source/VCL/Abbrevia/Abbrevia/source/AbArcTyp.pas) and the noise suspicion
    was wrong. A column that looks like garbage costs more time to disprove than
    a column that was right to begin with.
    """
    if u in LCL_WIDGETSET or u in LCL_RTL:
        return "lcl"
    key = u.lower()
    if key in vendored_index:
        return "vendored"     # present in Source/VCL, no LCL counterpart
    if u in WINDOWS_ONLY:
        return "win"          # Win32 or VCL, absent under FPC
    return "absent"          # nothing in the repo declares it


# Present in the vendored tree, so the unit EXISTS but is Delphi code that FPC
# cannot compile. Built once rather than globbed per query.
vendored_index = {}
for p in (SOURCE / "VCL").rglob("*.pas"):
    vendored_index.setdefault(p.stem.lower(), p)

# Units that resolve under neither tree, or only under Delphi.
WINDOWS_ONLY = {
    "Windows", "Messages", "Registry", "ShellAPI", "ShlObj", "ActiveX",
    "ComObj", "Themes", "ToolWin", "CommCtrl", "SysListView32",
    "SysTreeView32", "BaseImageCollection", "ImageCollection", "ScreenTips",
    "System.Win", "Winapi.Windows", "Vcl.Forms", "Vcl.Graphics", "Vcl",
    "WindowsXP", "UxTheme", "Shfolder", "ComCtrls",
}


def main() -> int:
    routes = _load("f3_load_routes")
    conv = routes.converted_forms()
    survey = _survey

    args = set(sys.argv[1:])
    ratchet_mode = "--ratchet" in args or "--write-baseline" in args

    forms = []
    for src in sorted(conv):
        if not src.endswith(".dfm"):
            continue
        dfm = SOURCE / src
        if not dfm.is_file():
            continue
        if not survey.SVG_USE_RE.search(survey.read(dfm)):
            continue
        if routes.blockers_of(survey, dfm):
            continue
        forms.append(src)

    print("TRUE COMPILE COST OF EACH CLEARED FORM")
    print("=" * 100)
    print("Component count is NOT compile cost. What matters is the transitive")
    print("uses-closure over self-authored units, which is why the cheapest form")
    print("by components is one of the most expensive by dependencies.")
    print()
    if AMBIGUOUS:
        print("!! %d unit name(s) are AMBIGUOUS in this tree -- two files declare the"
              % len(AMBIGUOUS))
        print("   same unit name, which a case-insensitive filesystem happily hides:")
        for key in sorted(AMBIGUOUS):
            print("      %-20s %s   <- this one was walked" % (key, AMBIGUOUS[key][0]))
            for other in AMBIGUOUS[key][1:]:
                print("      %-20s %s" % ("", other))
        print("   The walk takes the shallowest path; the numbers below are only as")
        print("   good as that choice, which is why both files are printed.")
        print()

    rows = []
    for src in forms:
        name = src[:-4]
        lfm = ROOT / "Source" / "Fpc" / "UI" / "Forms" / (name + ".lfm")
        comps = 0
        if lfm.is_file():
            comps = len(re.findall(
                r"(?m)^\s*(?:object|inherited|inline)\s+\w+",
                lfm.read_bytes().decode("utf-8")))
        seen, externals = closure(name)
        own = {u for u in seen if u.lower() in unit_path}
        loc = 0
        for u in own:
            try:
                loc += len(read_text(unit_path[u.lower()])[0].splitlines())
            except Exception:
                pass
        kinds = collections.Counter(classify(u) for u in externals)
        pas = (SOURCE / (name + ".pas")).is_file()
        # `own_keys` is kept on the row so the ratchet can ask "does this form's
        # closure contain main.pas?" without walking the graph a second time.
        rows.append((len(own), name, comps, len(own), loc, kinds, pas,
                     {u.lower() for u in own}))

    rows.sort()
    print("%-26s %5s %5s %8s %6s %8s %6s  %s"
          % ("form", "comp", "own", "own LOC", "vend", "win", "absent",
             "live .pas?"))
    print("-" * 100)
    for _, name, comps, nown, loc, kinds, pas, _keys in rows:
        print("%-26s %5d %5d %8d %6d %8d %6d  %s"
              % (name, comps, nown, loc, kinds["vendored"], kinds["win"],
                 kinds["absent"], "yes" if pas else "NO -- ARCHIVED"))

    print()
    print("vend = present in Source/VCL, no LCL counterpart (Delphi code, FPC cannot take it)")
    print("win  = Win32/VCL unit, absent under FPC")
    print("absent= nothing in the repo declares that name")
    print()
    print("cheapest by dependency closure:")
    for _, name, comps, nown, loc, kinds, pas, _k in rows[:3]:
        print("  %-26s %2d self-authored unit(s), %5d LOC, %d vendored, %d win, "
              "%d absent%s"
              % (name, nown, loc, kinds["vendored"], kinds["win"],
                 kinds["absent"], "" if pas else "   [NO LIVE UNIT]"))
    print()
    print("This measurement is the F2/F3 schedule input: it is a bill for what")
    print("compiling ONE form costs, in place of an estimate. doc F3-SVG 18.")
    if ratchet_mode:
        print()
        return ratchet(rows, write=("--write-baseline" in args))
    return 0


BASELINE_FILE = ROOT / "tools" / "f3_compile_cost_baseline.json"


def baseline_payload(rows):
    """Only the numbers the ratchet compares. `ambiguous` is carried because it
    changes what the numbers MEAN -- if a colliding unit name is added or
    removed, every closure on the tree may move without a single uses clause
    changing, and a ratchet that reported that as drift would be lying."""
    live = [r for r in rows if r[6]]          # r[6] is "has a live .pas"
    return {
        "note": "closure floor of the CLEARED forms; see doc/F3-SVG section 18",
        "forms": len(live),
        "max_own_units": max((r[3] for r in live), default=0),
        "max_own_loc": max((r[4] for r in live), default=0),
        "forms_reaching_main": sum(1 for r in live if "main" in r[7]),
        "ambiguous_unit_names": sorted(AMBIGUOUS),
    }


def ratchet(rows, write=False):
    payload = baseline_payload(rows)
    if write:
        BASELINE_FILE.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
        print("[WRITE] compile-cost baseline =", json.dumps(payload, sort_keys=True))
        return 0

    if not BASELINE_FILE.is_file():
        print("RESULT: %s is missing -- record it with --write-baseline"
              % BASELINE_FILE.name)
        return 1
    try:
        base = json.loads(BASELINE_FILE.read_text(encoding="utf-8"))
    except ValueError as exc:
        print("RESULT: %s is unreadable (%s)" % (BASELINE_FILE.name, exc))
        return 1

    print("COMPILE-COST RATCHET -- the closure floor must not grow")
    print("=" * 78)
    fails = []
    for key in ("forms", "max_own_units", "max_own_loc", "forms_reaching_main"):
        now, was = payload[key], base.get(key)
        grew = now > was
        print("  %-22s baseline %-6s now %-6s %s"
              % (key, was, now, "GROWN" if grew else "ok"))
        if grew:
            fails.append("%s grew %s -> %s" % (key, was, now))

    base_amb = sorted(base.get("ambiguous_unit_names", []))
    now_amb = sorted(AMBIGUOUS)
    print("  %-22s baseline %-6d now %-6d %s"
          % ("ambiguous unit names", len(base_amb), len(now_amb),
             "CHANGED" if base_amb != now_amb else "ok"))
    if base_amb != now_amb:
        # Not a failure by itself: a new collision changes what the numbers mean
        # but does not make the tree worse. It IS a failure to review, because
        # every closure on the tree may have moved with no uses clause edited.
        print()
        print("  NOTE: the ambiguous unit names changed. Every closure on this")
        print("        tree may have moved without a single uses clause being")
        print("        edited, because the walk resolves collisions by taking")
        print("        the shallowest path. Re-read the table before trusting")
        print("        the comparison above.")
        print("        baseline had: %s" % (base_amb or "none"))
        print("        now has    : %s" % (now_amb or "none"))

    print()
    if fails:
        print("RESULT: %d metric(s) grew -- the F2/F3 compile surface expanded"
              % len(fails))
        for f in fails:
            print("  - %s" % f)
        print()
        print("A form's closure growing is not a style question. It means a unit")
        print("now has to compile that did not have to before.")
        return 1
    print("RESULT: the closure floor held (forms=%d, <=%d self-authored units, "
          "<=%d LOC, %d reach main.pas)"
          % (payload["forms"], payload["max_own_units"], payload["max_own_loc"],
             payload["forms_reaching_main"]))
    if payload["max_own_units"] < base.get("max_own_units", 0):
        print()
        print("NOTE: the floor DROPPED. That is progress -- record it deliberately")
        print("      with --write-baseline; do not let it happen by accident.")
    return 0


if __name__ == "__main__":
    sys.exit(main())