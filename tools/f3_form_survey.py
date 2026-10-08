#!/usr/bin/env python3
"""
f3_form_survey.py -- what F3 (DFM -> LFM) actually has to face.

WHY THIS TOOL EXISTS
====================
The migration plan puts F3 at 8-10 weeks and describes it in one sentence
("窗体体系重塑 DFM→LFM"). That sentence hides the question that decides the
schedule: of the 53 forms, how many can a Lazarus DFM converter even read?

A DFM that references `TPageControl`, `TToolBar` or a third-party control has a
conversion risk. A DFM made only of `TForm`/`TButton`/`TEdit` does not. Nothing
in the repository measured which is which, so the estimate rested on nothing
checkable -- the same failure mode this project has been fixing for R1 and R3.

WHAT IT MEASURES
================
For every self-authored .dfm (vendored Source/VCL excluded):
  * the root component type
  * the count and names of controls, by root type
  * a per-form verdict: CONVERTABLE (only widgetset primitives) or
    CUSTOM (something Lazarus has no equivalent for)
  * a per-type roll-up, so the handful of blockers can be enumerated instead of
    guessed at

WHY THE PRIMITIVE LIST IS EXPLICIT
==================================
Lazarus's widgetset covers a specific set. Listing the ones this project
actually uses, and calling everything else CUSTOM, means a NEW control appearing
later is reported as a blocker rather than silently counted as free. The default
has to be "unknown" for the tool to be worth running again.

Run:  python tools/f3_form_survey.py
Exit: 0 always. This is a measurement, not a gate -- see the note at the end.
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Source"

# Lazarus widgetset types this project is allowed to use without a second look.
# Derived from what Dev-C++ forms actually contain, not from the full LCL list,
# so that the set stays small enough to review by eye.
WIDGETSET = {
    # containers / core
    "TForm", "TFrame", "TPanel", "TGroupBox", "TBevel", "TScrollBox", "TSplitter",
    "TPageControl", "TTabSheet", "TCheckBox", "TRadioButton", "TPage",
    "TLabel", "TStaticText",
    # widgets the first pass of this list missed, all LCL-native. They were
    # flagged as blockers until measured: TBitBtn appears in 27 of 53 forms and
    # TListView in 10, so treating either as custom would have declared the
    # entire form layer unconvertible, which is false.
    "TBitBtn", "TListView", "THeaderControl", "TStatusBar",
    # TToolButton was missing here and accounted for FIFTY blocked fields across
    # Main.dfm and main.dfm -- the single largest reason the baseline looked
    # like 41/53. LCL ships TToolButton; it is a straight type swap.
    "TToolButton",
    # Standard VCL controls the first two passes missed. Every one of these is
    # LCL-native; counting them as blockers would have understated what F3 can
    # convert, which is the number the estimate depends on.
    "TOpenDialog", "TSaveDialog", "TOpenPictureDialog", "TSavePictureDialog",
    "TColorDialog", "TPrintDialog", "TFindDialog", "TReplaceDialog",
    "TFontDialog", "TPageControl", "TTabControl", "TRadioGroup",
    "TShape", "TTreeView", "TAction", "TShortCut", "THotKey",
    "TGlassFrame", "TScrollBar", "TTrackBar", "TCalendar",
    "TTrackBar", "TProgressBar", "TValueListEditor",
    "TWizardPage", "TNotebook", "TToolbar", "TSplitter",
    # input
    "TButton", "TSpeedButton", "TEdit", "TMemo", "TListBox", "TComboBox",
    "TUpDown", "TDateEdit", "TMonthCalendar", "TTimeEdit", "TSpinEdit", "TCheckListBox",
    "TRichEdit", "TColorBox", "TDirectoryListBox", "TFileListBox", "TFilterComboBox",
    "TImageList", "TStringGrid",
    # display
    "TImage", "TPaintBox", "TProgressBar", "TStatusBar", "TChart",
    "TToolBar", "TMainMenu", "TPopupMenu", "TMenuItem", "TActionList",
    "TApplication", "TTimer",
    # dev-c++ specific but LCL-supported
    "TSynEdit",
}

# Classes that are NOT placeable controls, yet whose presence in a DFM is not a
# conversion blocker because the LCL supplies a class of the SAME NAME.
#
# WHY THIS IS A SEPARATE SET AND NOT AN ENTRY IN WIDGETSET
# ==========================================================
# WIDGETSET answers "can this control be PLACED in a Lazarus form?". A syntax
# highlighter cannot be placed: it derives from TComponent, has no Left/Top, and
# would be meaningless as a child control. So adding TSynCppSyn there would be a
# category error -- it would assert something false about the class in order to
# make a count come out right. The question this set answers is different and
# narrower: "does the reader have a class of this name, and can it stream?".
#
# MEASURED, per entry -- not inferred from the name
# ==================================================
# `TSynCppSyn` (Sprint F3-6). The vendored Delphi copy is
# Source/VCL/SynEdit/Source/SynHighlighterCpp.pas (211 lines); the LCL ships
# SynHighlighterCpp in components/synedit/synhighlightercpp.pp -- NOTE the .pp
# extension, which is why a search for "*.pas" over the Lazarus tree finds
# nothing and the class looks absent. Both are named TSynCppSyn, both derive
# from TSynCustomHighlighter, and in BOTH trees that derives from TComponent --
# the property that lets the LCL reader own and stream a non-visual component
# inside a form. Verified against the built unit list as well as the source:
# components/synedit/units/x86_64-win64/win32/synhighlightercpp.ppu exists.
#
# WHAT IS *NOT* CLAIMED
# =====================
# The two token enums are NOT the same. The vendored TtkTokenKind carries
# tkChar, tkFloat, tkHex and tkOctal on top of the LCL's eleven values, so a
# highlighter written against the Delphi enumeration will not recompile
# unchanged. That is a property of the PASCAL UNIT (EditorOptFrm.pas), not of
# the DFM, and it belongs to the SynEdit port -- this entry claims only that
# the class NAME resolves and streams, which is what unblocks the form.
#
# `TSynRCSyn` is deliberately ABSENT. DataFrm.dfm declares it and LCL 4.4 has no
# synhighlighterrc unit at all (verified against both the source tree and the
# built .ppu list). Recording a class as LCL-supplied without checking would
# have unblocked a form whose reader then dies on "Class TSynRCSyn not found".
LCL_SUPPLIED = {
    "TSynCppSyn",
    # F3-7. NOT an LCL class -- OURS: Source/Fpc/UI/Controls/SynHighlighterRc.pas
    # writes a native highlighter against the LCL's own SynEditHighlighter,
    # because LCL 4.4 ships TSynCppSyn and TSynPASyn but NO synhighlighterrc
    # unit at all (verified against components/synedit/*.p* AND the built
    # units/x86_64-win64/win32/*.ppu list). DataFrm.pas:42 declares
    # `Res: TSynRCSyn` and GetHighlighter returns it for any .rc file, so the
    # class is used by CODE, not merely declared in a DFM.
    #
    # The name is preserved deliberately: DataFrm.dfm already says
    # `object Res: TSynRCSyn`, so retiring the vendored class needs NO
    # converter rename rule and no .dfm edit -- only the unit moves. The
    # alternative (porting the 537-line vendored unit, whose declaration is 62
    # of those lines) was measured and rejected: it is roughly twice the work
    # for the same result, against Delphi SynEdit internals LCL does not have.
    # The runtime evidence is Tests/FpcCoreTests/syn/SynRcProbe.lpr, which
    # tokenises real .rc text and asserts the token KINDS -- a highlighter that
    # loads and returns nothing is the "converted but blank" shape this project
    # has already caught twice.
    "TSynRCSyn",
}

# ---------------------------------------------------------------------------
# RETIRED: classes that used to block a form and no longer do.
# =======================================================================
# WHY THIS LIVES HERE AND NOT IN THE TOOLS THAT NEED IT
# ===================================================
# Two tools answer "what is still in the way", and they answered it differently
# because each carried its own copy of this fact:
#
#   f3_load_routes.py   had a RETIRED set, subtracted it, AND scoped the
#                       subtraction to forms that already produced an .lfm --
#                       for a reason recorded in its own comment: a blanket
#                       subtraction erases producer-side gaps such as
#                       Tools/Packman/Main, which are real.
#   f3_batch_plan.py    had NO subtraction at all, and reported LangFrm and
#                       EnviroFrm as "BATCH B, blocked by TVirtualImage" on the
#                       same tree where the route tool called them CLEARED.
#
# That is this project's recurring failure -- one fact, two hand-maintained
# copies -- and the standing rule against it is "one definition, so 'this tool
# added it and that one forgot' is impossible". So the SET moves here, next to
# WIDGETSET and LCL_SUPPLIED, and each entry carries its OWN REASON: a bare
# class name cannot be reviewed, and an unreviewable exclusion list is just a
# list of classes someone decided were inconvenient.
#
# Each value is (sprint, why), and the "why" names the evidence that made the
# retirement real -- a probe run, or a source-level fact -- rather than an
# opinion about difficulty.
#
# NOT IN HERE, DELIBERATELY
# ========================
# * `TSynRCSyn` -- LCL 4.4 has no such unit (verified against the source tree
#   AND the built .ppu list). DataFrm.dfm still declares it and is still blocked.
# * `TClassBrowser`, `TCodeCompletion`, `TCppParser`, `TCppPreprocessor`,
#   `TCppTokenizer`, `TControlBar`, `TdevFileMonitor`, `TdevShortcuts` -- the
#   eight that block main.dfm. main.dfm is excluded from near-term scheduling
#   (8 ports for 1 form), but "excluded from the schedule" is not the same
#   statement as "resolved", and putting them here would make the tools report
#   main.dfm as convertible when no replacement exists for any of them.
# * `TImageCollection` -- no LCL counterpart; blocks DataFrm and Packman/Main.
RETIRED = {
    "TSVGIconImageList": (
        "SVG work",
        "renamed to TLclSvgImageList; the substituted control is load- AND "
        "pixel-tested by Tests/FpcCoreTests/svg/SvgLfmProbe.lpr (117 payloads)"),
    "TVirtualImage": (
        "F3-3",
        "renamed to TLclVirtualImage; Source/Fpc/UI/Controls/LclVirtualImage.pas "
        "resolves the index against the 20 PNGs extracted from DataFrm.dfm, and "
        "ImgCollProbe.lpr loads the converted fragment"),
    "TCompOptionsList": (
        "F3-4",
        "RETIRED, not ported: LCL's TValueListEditor gives esPickList rows a "
        "native cbsPickList editor, so the hand-rolled pick-list has no reason "
        "to exist; f3_removed_controls.py asserts nothing re-uses the unit"),
    "TCompOptionsFrame": (
        "F3-4",
        "PORTED, not retired: own code whose every symbol is LCL-native, so the "
        "class still names itself in three LFMs but resolves at stream time "
        "(CompOptionsFrm and ProjectOptionsFrm load it as a real TFrame)"),
}


def is_retired(t: str) -> bool:
    return t in RETIRED


def retirement_note(t: str) -> str:
    """(sprint, reason) for a retired class, or '' if it is not retired."""
    return RETIRED.get(t, ("", ""))[1]

# Anything here needs a decision before a form can be converted.
KNOWN_CUSTOM = {
    "TSkinManager", "TSkinData", "TStyleManager",
    "TcxGrid", "TcxGridDBTableView", "TcxGridView",
    "TWebBrowser", "TADOQuery", "TADOConnection",
    "TVirtualStringTree", "TVirtualTreeView", "TcxTreeView",
    "TTcxGrid",
}

COMPONENT_RE = re.compile(r"^\s*(?:inherited|inline|object)\s+(\w+)\s*:\s*(\w+)", re.M)

# A form can be structurally convertible and still RUNTIME-BROKEN: a DFM that
# assigns `Images = dmMain.SVGImageListMenuStyle` converts perfectly, and then
# draws nothing, because the icon list it names is a vendored TSVGIconImageList.
#
# Measured: 15 forms draw from an SVG image list, 9 of them in batch A. So the
# batch-A count alone overstates what works without the SVG work -- which is why
# this is reported separately instead of being folded into the convertible total,
# where it would have been invisible.
#
# The FIRST version of this file did not look for it at all and reported 43/53
# convertible, which reads as "these 43 are done" and is wrong for 9 of them.
SVG_USE_RE = re.compile(r"\.(?:SVGImageList\w*|SVGImageCollection\w*)\b")


def read(p: pathlib.Path) -> str:
    return p.read_bytes().decode("utf-8-sig", errors="replace")


def survey(path: pathlib.Path):
    text = read(path)
    comps = COMPONENT_RE.findall(text)
    types = collections.Counter(t for _, t in comps)
    root = comps[0][1] if comps else "(none)"
    # Only the ROOT class is a form type; every other match is a component.
    # The first version compared EVERY type against the widgetset list, which
    # made each form's own class (TFindForm, TAboutForm, ...) look like a
    # blocker -- so all 53 forms came out unconvertible. That was a statement
    # about the tool, not about the project.
    #
    # Components declared in code and merely referenced from the DFM (TRichEdit
    # subclasses, TAction, a TTimer on a datamodule) are not DFM blockers
    # either: a custom class the converter does not recognise is a CODE problem,
    # not a form-conversion problem. What blocks conversion is a control that
    # cannot be placed in a form at all -- which is why the list is explicit.
    component_types = {t for _, t in comps[1:]} if len(comps) > 1 else set()
    custom = {t for t in component_types
              if t not in WIDGETSET and t not in LCL_SUPPLIED}
    return root, types, custom


def main() -> int:
    dfms = sorted(
        p for p in SOURCE.rglob("*.dfm") if "VCL" not in p.parts
    )
    if not dfms:
        print("no self-authored .dfm found", file=sys.stderr)
        return 0

    rollup = collections.Counter()
    blockers = collections.defaultdict(list)
    convertible = []
    # Every type that ACTUALLY blocked a form, accumulated from the per-form
    # verdict. The roll-up below used to recompute the marker from WIDGETSET,
    # which disagreed with this set in two ways at once:
    #
    #   * it ignored LCL_SUPPLIED (fixed in F3-6), so TSynCppSyn read as custom
    #     on a run that reported its forms as OK;
    #   * it marked every form's OWN ROOT CLASS as custom -- 60-odd types such
    #     as TAboutForm and TToolForm -- even though `survey()` deliberately
    #     excludes the root (`comps[1:]`), because a form class is a code
    #     problem, not a form-conversion problem. Measured before the fix: the
    #     roll-up printed 62 types as custom while the per-form verdicts named
    #     9. A reader comparing those two numbers has to discard one of them,
    #     and a survey whose own two outputs disagree is worse than no survey.
    #
    # So the marker is now read off the verdict rather than recomputed.
    blocking_types = set()

    print(f"self-authored .dfm: {len(dfms)}")
    print()
    for p in dfms:
        root, types, custom = survey(p)
        for t in types:
            rollup[t] += 1
        blocking_types |= custom
        for t in sorted(custom):
            blockers[t].append(p.name)
        if not custom:
            convertible.append(p.relative_to(SOURCE).as_posix())
        flag = "OK  " if not custom else "CUSTOM"
        print(f"  {flag} {p.name:<28} root={root:<18} controls={sum(types.values())}")

    print()
    print(f"convertible as-is : {len(convertible)} / {len(dfms)}")
    # The runtime-validity axis, kept separate from convertibility on purpose.
    #
    # A DFM that draws from an SVG image list converts cleanly and then renders
    # nothing, so "convertible" and "works after conversion" are different
    # questions. Folding them together would hide 9 forms behind a total that
    # reads as if they were finished.
    svg_forms = []
    for p in dfms:
        if SVG_USE_RE.search(read(p)):
            # Relative path, not p.name: three forms are called main.dfm /
            # Main.dfm and Windows is case-insensitive, so the short names
            # collide and two different forms get counted once.
            svg_forms.append(p.relative_to(SOURCE).as_posix())
    clean = [n for n in convertible if n not in svg_forms]
    print()
    print("RUNTIME VALIDITY (separate from convertibility)")
    print(f"  forms drawing from an SVG image list : {len(svg_forms)}")
    print(f"  convertible AND svg-independent       : {len(clean)} / {len(dfms)}")
    print("  (the remaining", len(convertible) - len(clean), "convertible forms convert but")
    print("   render nothing until the SVG icon work lands -- see F3/F4 note)")

    print()
    print("blockers (control type -> forms using it):")
    if not blockers:
        print("  none")
    for t, forms in sorted(blockers.items(), key=lambda kv: -len(kv[1])):
        note = " (known)" if t in KNOWN_CUSTOM else ""
        print(f"  {t}{note}: {len(forms)}")
        for f in sorted(forms):
            print(f"      {f}")
    # Classify each blocker by WHERE it is declared. This is the distinction
    # that decides F3's cost structure, and it was not visible until measured:
    #
    #   vendored  the class lives in Source/VCL (ClassBrowsing, devShortcuts,
    #             SynEdit highlighter, SVGIconImageList...). Those units are
    #             third-party Pascal: a converter may still read the DFM, but
    #             the class needs an LCL equivalent, which is code work.
    #   external  the class is REFERENCED (as a field type) but never declared
    #             in the repository at all -- it comes from the Delphi RTL or a
    #             binary package. TVirtualImage, TImageCollection, TAnimate,
    #             TControlBar and TToolButton are all of this kind, so naming
    #             them as "controls to convert" overstates the work: the form
    #             itself converts, and the field needs replacing.
    #   own       declared by this project outside Source/VCL (TCompOptionsFrame),
    #             which is the cheapest kind to deal with.
    sources = {}
    for p in SOURCE.rglob("*.pas"):
        sources[p] = p.read_bytes().decode("utf-8-sig", errors="replace")

    def origin(t: str) -> str:
        decl = re.compile(r"^\s*" + re.escape(t) + r"\s*=\s*class", re.M | re.I)
        for p, text in sources.items():
            if decl.search(text):
                return "vendored" if "VCL" in p.parts else "own"
        return "external"

    print()
    print("blocker origin (this is what decides F3's cost):")
    tally = collections.Counter()
    for t, forms in sorted(blockers.items(), key=lambda kv: -len(kv[1])):
        o = origin(t)
        tally[o] += len(forms)
        print(f"  {o:<9} {t}: {len(forms)} form(s)")
    print()
    print("  form-instances by origin: " + ", ".join(f"{k}={v}" for k, v in tally.most_common()))

    print()
    print("control type roll-up:")
    for t, n in rollup.most_common():
        mark = "   <-- custom" if t in blocking_types else ""
        print(f"  {n:4d}  {t}{mark}")
    print()
    print(f"  types in the roll-up        : {len(rollup)}")
    print(f"  types that blocked a form   : {len(blocking_types)}"
          "   <- the marker above is this set, not a recomputed one")

    # NOT a gate on purpose. Converting the whole form layer is the explicit
    # goal of F3, so failing the build until every form is convertible would
    # make this file useless as a survey. It reports; a decision belongs to a
    # ratchet that knows which forms F3 has actually reached.
    return 0


if __name__ == "__main__":
    sys.exit(main())
