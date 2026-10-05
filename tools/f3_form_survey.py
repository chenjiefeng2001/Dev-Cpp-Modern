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
    custom = {t for t in component_types if t not in WIDGETSET}
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

    print(f"self-authored .dfm: {len(dfms)}")
    print()
    for p in dfms:
        root, types, custom = survey(p)
        for t in types:
            rollup[t] += 1
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
        mark = "" if t in WIDGETSET else "   <-- custom"
        print(f"  {n:4d}  {t}{mark}")

    # NOT a gate on purpose. Converting the whole form layer is the explicit
    # goal of F3, so failing the build until every form is convertible would
    # make this file useless as a survey. It reports; a decision belongs to a
    # ratchet that knows which forms F3 has actually reached.
    return 0


if __name__ == "__main__":
    sys.exit(main())
