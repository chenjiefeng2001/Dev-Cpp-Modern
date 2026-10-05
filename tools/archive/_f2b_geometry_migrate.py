#!/usr/bin/env python3
"""F2-b steps 2+3: wire Hover.pas and SignatureHelp.pas onto the contract.

Same shape as the Definition wiring, and the same two disciplines carry over:

  * ENCODING. Editor.pas is latin-1 (see the Definition script); the two client
    units are utf-8 with BOM. Each file is therefore read with the encoding it
    actually has, and written back the same way. Reading Editor.pas as utf-8
    destroys its Chinese comments irrecoverably.

  * LINE ENDINGS. Patterns are normalised to LF and then to the file's EOL, so a
    literal that already contains CRLF cannot end up as \r\r\n.

Two corrections to the wiring instructions, both found by reading the code
rather than following the brief:

  1. The brief wrote `fText.PixelsToRowColumn(Point(X, Y))`. The real code is
     `FEditor.ScreenToClient(Mouse.CursorPos)` at Hover:1015 -- it starts from a
     SCREEN point, so the adapter's ScreenPixelsToBuffer is the right entry, but
     the call shape is not what the brief described.

  2. The brief wrote `fText.RowColToPixels(...)`. The real member is
     `RowColumnToPixels` (capital C). Using the brief's spelling compiles
     nowhere.

Neither unit needs `TRect`, `TPoint` or `Screen` removed from its uses: those
belong to the HINT WINDOW, which stays VCL by design -- it is positioned in
screen coordinates and shown with ActivateHint. Only the EDITOR dependency is
being cut. Putting the popup geometry through the contract would be the
adapter's job, not the client's.

Usage:  python tools/_f2b_geometry_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDITOR = ROOT / "Source" / "Editor.pas"
HOVER = (ROOT / "Source" / "LSP" / "Client" / "Hover" / "Lsp.Client.Hover.pas")
SIGHELP = (ROOT / "Source" / "LSP" / "Client" / "SignatureHelp" /
           "Lsp.Client.SignatureHelp.pas")
DRY = "--dry-run" in sys.argv

# utf-8-with-BOM for the client units, latin-1 for Editor.pas.
UTF8_UNITS = (HOVER, SIGHELP)


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    if path in UTF8_UNITS:
        raw = path.read_bytes()
        return raw.decode("utf-8-sig" if raw[:3] == b"\xef\xbb\xbf" else "utf-8")
    return path.read_bytes().decode("latin-1")


def write_raw(path, text):
    if path in UTF8_UNITS:
        raw = path.read_bytes()
        bom = b"\xef\xbb\xbf" if raw[:3] == b"\xef\xbb\xbf" else b""
        path.write_bytes(bom + text.encode("utf-8"))
    else:
        path.write_bytes(text.encode("latin-1"))


def edit(path, rules):
    eol = eol_of(path)
    text = read_raw(path)
    plan = []
    for old, new, want in rules:
        o = old.replace("\r\n", "\n").replace("\n", eol)
        n = new.replace("\r\n", "\n").replace("\n", eol)
        got = text.count(o)
        if got != want:
            print("  ABORT %s: pattern hit %d, expected %d\n    %r"
                  % (path.name, got, want, old.strip()[:86]))
            return False
        plan.append((o, n))
    for o, n in plan:
        text = text.replace(o, n)
    if DRY:
        print("  DRY  %s: %d rule(s) ok" % (path.name, len(plan)))
        return True
    write_raw(path, text)
    print("  OK   %s: %d rule(s) applied" % (path.name, len(plan)))
    return True


# --------------------------------------------------------------------------
# Hover.pas
# --------------------------------------------------------------------------

# uses: drop SynEditTypes/SynEdit, add the contract. Vcl.* stays -- the hint
# window is genuinely VCL and stays that way.
HV_USES_OLD = (
    "  Vcl.Controls, Vcl.Forms, Vcl.Graphics, Winapi.Windows,\r\n"
    "  SynEditTypes, SynEdit,\r\n"
    "  LSP.Transport, Lsp.DocumentSync;"
)
HV_USES_NEW = (
    "  Vcl.Controls, Vcl.Forms, Vcl.Graphics, Winapi.Windows,\r\n"
    "  LSP.Transport, Lsp.DocumentSync,\r\n"
    "  Lsp.Editor.Types, Lsp.Editor.Interfaces;"
)

HV_FIELD_OLD = "    FEditor: TCustomSynEdit;\n"
HV_FIELD_NEW = "    FEditor: IEditorControlAdapter;\n"

# Declarations. The DismissIfOutside and ShowForEditorAt parameter types are
# handled by the merged rules further down (HV_DIO_COORD_*), which change the
# AEditor and ABufferPos types together -- splitting them would edit the same two
# lines twice and risk one form matching while the other did not.
HV_DECLS_OLD = (
    "procedure ShowForEditorAt(AEditor: TCustomSynEdit;\n"
    "      const ABufferPos: TBufferCoord);\n"
)
HV_DECLS_NEW = (
    "procedure ShowForEditorAt(const AEditor: IEditorControlAdapter;\n"
    "      const ABufferPos: TLspBufferCoord);\n"
)

HV_IMPL_OLD = (
    "procedure TLspHoverHintWindow.ShowForEditorAt(AEditor: TCustomSynEdit;\n"
    "  const ABufferPos: TBufferCoord);\n"
)
HV_IMPL_NEW = (
    "procedure TLspHoverHintWindow.ShowForEditorAt(\n"
    "  const AEditor: IEditorControlAdapter;\n"
    "  const ABufferPos: TLspBufferCoord);\n"
)
HV_DIO_IMPL_OLD = (
    "procedure TLspHoverManager.DismissIfOutside(AEditor: TCustomSynEdit;\n"
)
HV_DIO_IMPL_NEW = (
    "procedure TLspHoverManager.DismissIfOutside(\n"
    "  const AEditor: IEditorControlAdapter;\n"
)

# The popup positioning block. Three calls collapse into one contract call.
# `Disp` goes away entirely: BufferToDisplayPos existed only to feed
# RowColumnToPixels, and nothing else in the routine reads it.
HV_VAR_OLD = (
    "var\r\n"
    "  R: TRect;\r\n"
    "  P: TPoint;\r\n"
    "  Work: TRect;\r\n"
    "  Disp: TDisplayCoord;\r\n"
    "begin\r\n"
    "  if not Assigned(AEditor) then\r\n"
    "    Exit;\r\n"
    "  Color := clInfoBk;\r\n"
    "  R := CalcRectFor(560);\r\n"
)
HV_VAR_NEW = (
    "var\r\n"
    "  R: TRect;\r\n"
    "  P: TPoint;\r\n"
    "  Work: TRect;\r\n"
    "begin\r\n"
    "  if not Assigned(AEditor) then\r\n"
    "    Exit;\r\n"
    "  Color := clInfoBk;\r\n"
    "  R := CalcRectFor(560);\r\n"
)
HV_POS_OLD = (
    "  Disp := AEditor.BufferToDisplayPos(ABufferPos);\r\n"
    "  P := AEditor.ClientToScreen(AEditor.RowColumnToPixels(Disp));\r\n"
)
HV_POS_NEW = (
    "  P := MakeHintPoint(AEditor.BufferToScreenPixels(ABufferPos));\r\n"
)
HV_POS2_OLD = (
    "    P := AEditor.ClientToScreen(AEditor.RowColumnToPixels(Disp));\r\n"
)
HV_POS2_NEW = (
    "    P := MakeHintPoint(AEditor.BufferToScreenPixels(ABufferPos));\r\n"
)
HV_LINEHEIGHT_OLD = "  Inc(P.Y, AEditor.LineHeight + 6);\r\n"
HV_LINEHEIGHT_NEW = "  Inc(P.Y, AEditor.GetLineHeight + 6);\r\n"

# MouseStillOnRequest (1006-1028). The ORDER of the original matters and is kept:
# it converts the screen point to CLIENT coordinates first, rejects negatives and
# anything past ClientWidth/ClientHeight, and only then converts to a buffer
# position. Collapsing that into a single ScreenPixelsToBuffer call would change
# the semantics -- outside the editor there is no meaningful buffer coordinate,
# and the caller's own bounds test would then be applied to garbage.
#
# So the bounds test is expressed against the contract's pixel accessors (which
# is all it ever used them for) and the conversion happens afterwards, in one
# contract call.
HV_MOUSE_OLD = (
    "  Pt: TPoint;\r\n"
    "  BC: TBufferCoord;\r\n"
)
HV_MOUSE_NEW = (
    "  Pt: TLspPixelPoint;\r\n"
    "  BC: TLspBufferCoord;\r\n"
)
HV_MOUSE_CALL_OLD = (
    "    Pt := FEditor.ScreenToClient(Mouse.CursorPos);\r\n"
)
HV_MOUSE_CALL_NEW = (
    "    // ScreenToClient + PixelsToRowColumn + DisplayToBufferPos collapse to one\r\n"
    "    // contract call; see the note in the migration script for why the\r\n"
    "    // bounds test below still runs BEFORE it.\r\n"
    "    BC := FEditor.ScreenPixelsToBuffer(CursorPixel);\r\n"
)
HV_MOUSE_BOUNDS_OLD = (
    "    if Pt.X < 0 then\r\n"
    "      Exit;\r\n"
    "    if Pt.Y < 0 then\r\n"
    "      Exit;\r\n"
    "    if (Pt.X > FEditor.ClientWidth) or (Pt.Y > FEditor.ClientHeight) then\r\n"
    "      Exit;\r\n"
    "    BC := FEditor.DisplayToBufferPos(FEditor.PixelsToRowColumn(Pt.X, Pt.Y));\r\n"
)
HV_MOUSE_BOUNDS_NEW = (
    "    if CursorPixel.X < 0 then\r\n"
    "      Exit;\r\n"
    "    if CursorPixel.Y < 0 then\r\n"
    "      Exit;\r\n"
    "    if (CursorPixel.X > FEditor.GetClientWidth) or\r\n"
    "      (CursorPixel.Y > FEditor.GetClientHeight) then\r\n"
    "      Exit;\r\n"
)

# The whole try-block, rewritten in one piece so the declaration, the cursor
# read, the bounds test and the conversion are guaranteed to stay in the right
# ORDER. Editing them as four independent patterns would have let the order slip
# without any assertion noticing -- and order is the whole point here.
HV_TRY_OLD = (
    "  try\r\n"
    "    Pt := FEditor.ScreenToClient(Mouse.CursorPos);\r\n"
    "    if Pt.X < 0 then\r\n"
    "      Exit;\r\n"
    "    if Pt.Y < 0 then\r\n"
    "      Exit;\r\n"
    "    if (Pt.X > FEditor.ClientWidth) or (Pt.Y > FEditor.ClientHeight) then\r\n"
    "      Exit;\r\n"
    "    BC := FEditor.DisplayToBufferPos(FEditor.PixelsToRowColumn(Pt.X, Pt.Y));\r\n"
)
HV_TRY_NEW = (
    "  try\r\n"
    "    // CursorPixel is the mouse in screen pixels. The ORIGINAL code read the\r\n"
    "    // client point first and range-checked it before converting; that order\r\n"
    "    // is kept, because outside the viewport there is no meaningful buffer\r\n"
    "    // coordinate and a bounds test applied after conversion would be\r\n"
    "    // comparing against garbage.\r\n"
    "    CursorPixel := MakePixelPoint(Mouse.CursorPos);\r\n"
    "    if CursorPixel.X < 0 then\r\n"
    "      Exit;\r\n"
    "    if CursorPixel.Y < 0 then\r\n"
    "      Exit;\r\n"
    "    if (CursorPixel.X > FEditor.GetClientWidth) or\r\n"
    "      (CursorPixel.Y > FEditor.GetClientHeight) then\r\n"
    "      Exit;\r\n"
    "    // ScreenToClient + PixelsToRowColumn + DisplayToBufferPos, collapsed.\r\n"
    "    BC := FEditor.ScreenPixelsToBuffer(CursorPixel);\r\n"
)
HV_VAR2_OLD = (
    "  Pt: TPoint;\r\n"
    "  BC: TBufferCoord;\r\n"
    "begin\r\n"
    "  Result := False;\r\n"
)
HV_VAR2_NEW = (
    "  CursorPixel: TLspPixelPoint;\r\n"
    "  BC: TLspBufferCoord;\r\n"
    "begin\r\n"
    "  Result := False;\r\n"
)
HV_LINETEXT_OLD = "    LspFlushPendingDocument(FCurrentFile, FEditor.Lines.Text);\r\n"
HV_LINETEXT_NEW = "    LspFlushPendingDocument(FCurrentFile, FEditor.GetAllText);\r\n"

# --------------------------------------------------------------------------
# Second pass, added after the first migration verified.
#
# The first pass converted the FIELD and the two routines that Editor.pas calls,
# and the post-check showed `SynEdit x0` in the uses clause -- which looked like
# the job was finished. It was not: four INTERNAL signatures still spelled
# TBufferCoord (PosInLastRange's declaration and implementation, ShowAt's
# parameter, and a local variable in the request path).
#
# Those are the more interesting half of the finding. A unit can stop naming a
# toolkit in its uses clause and still name its types everywhere else, because
# Delphi only resolves names when they are USED -- a leftover TBufferCoord in a
# private signature is exactly the kind of thing that compiles until the day the
# adapter is swapped for the LCL one, at which point the unit stops compiling
# with an error pointing at a line nobody remembers editing. Removing SynEdit
# from uses was necessary; it was not sufficient.
# --------------------------------------------------------------------------
# The four internal signatures, located by reading the file rather than by
# assuming a routine name. An earlier draft of this script invented
# `ShowAt(const ABufferPos: TBufferCoord)`; no such routine exists, and the
# count assertion caught it before anything was written. The real four are:
#   PosInLastRange  -- interface decl :106 and impl :943
#   DismissIfOutside-- parameter on both sides (:105 and :944)
#   AtPos           -- a local in FillHintAndShow (:1084)
HV_COORD_DECL2_OLD = "function PosInLastRange(const ABufferPos: TBufferCoord): Boolean;\r\n"
HV_COORD_DECL2_NEW = "function PosInLastRange(const ABufferPos: TLspBufferCoord): Boolean;\r\n"
HV_COORD_IMPL2_OLD = (
    "function TLspHoverManager.PosInLastRange(const ABufferPos: TBufferCoord): Boolean;\r\n"
)
HV_COORD_IMPL2_NEW = (
    "function TLspHoverManager.PosInLastRange(\r\n"
    "  const ABufferPos: TLspBufferCoord): Boolean;\r\n"
)
# The DismissIfOutside parameter, merged so AEditor and ABufferPos change
# together. The two forms differ in INDENTATION: inside the class body the
# parameter sits at six spaces, in the implementation at two. That difference
# cost this script one abort -- a first attempt used two spaces for both and the
# count assertion reported the interface declaration as absent, which is exactly
# what it is for.
HV_DIO_COORD_DECL_OLD = (
    "    procedure DismissIfOutside(AEditor: TCustomSynEdit;\r\n"
    "      const ABufferPos: TBufferCoord);\r\n"
)
HV_DIO_COORD_DECL_NEW = (
    "    procedure DismissIfOutside(const AEditor: IEditorControlAdapter;\r\n"
    "      const ABufferPos: TLspBufferCoord);\r\n"
)
HV_DIO_COORD_IMPL_OLD = (
    "procedure TLspHoverManager.DismissIfOutside(AEditor: TCustomSynEdit;\r\n"
    "  const ABufferPos: TBufferCoord);\r\n"
)
HV_DIO_COORD_IMPL_NEW = (
    "procedure TLspHoverManager.DismissIfOutside(\r\n"
    "  const AEditor: IEditorControlAdapter;\r\n"
    "  const ABufferPos: TLspBufferCoord);\r\n"
)
HV_LOCAL_OLD = "  AtPos: TBufferCoord;\r\n"
HV_LOCAL_NEW = "  AtPos: TLspBufferCoord;\r\n"


# Remaining signatures that still name TCustomSynEdit in Hover.
def sig(old, new, want=1):
    return (old, new, want)


def sig2(old, new, want):
    return sig(old, new, want)


HV_SIGS = [
    sig("constructor Create(AEditor: TCustomSynEdit; ATransport: TLspTransport);",
        "constructor Create(const AEditor: IEditorControlAdapter;\r\n"
        "      ATransport: TLspTransport);"),
    sig("procedure SetEditor(AEditor: TCustomSynEdit);",
        "procedure SetEditor(const AEditor: IEditorControlAdapter);"),
    sig("procedure EditorDestroyed(AEditor: TCustomSynEdit);",
        "procedure EditorDestroyed(const AEditor: IEditorControlAdapter);"),
    # InitializeLspHover appears twice -- interface declaration and implementation.
    # Expected count 2, not 1: the Definition wiring had the same shape and the
    # count-1 assertion caught it there too. Two is correct here and asserting it
    # explicitly means a third occurrence would be reported rather than silently
    # left half-converted.
    sig2("procedure InitializeLspHover(AEditor: TCustomSynEdit;",
         "procedure InitializeLspHover(const AEditor: IEditorControlAdapter;", 2),
    sig("constructor TLspHoverManager.Create(AEditor: TCustomSynEdit;",
        "constructor TLspHoverManager.Create(\r\n  const AEditor: IEditorControlAdapter;"),
    sig("procedure TLspHoverManager.SetEditor(AEditor: TCustomSynEdit);",
        "procedure TLspHoverManager.SetEditor(\r\n  const AEditor: IEditorControlAdapter);"),
    sig("procedure TLspHoverManager.EditorDestroyed(AEditor: TCustomSynEdit);",
        "procedure TLspHoverManager.EditorDestroyed(\r\n  const AEditor: IEditorControlAdapter);"),
]

# MakePixelPoint / MakeHintPoint: the two VCL-shaped bridges the contract forces
# on us. Both are trivial and both are confined to this unit's own popup code.
HV_HELPERS_OLD = "implementation\r\n"
HV_HELPERS_NEW = (
    "implementation\r\n"
    "\r\n"
    "{ TLspPixelPoint -> TPoint, for the hint window's screen-coordinate maths.\r\n"
    "  The hint window is VCL and stays VCL: it is shown with ActivateHint at\r\n"
    "  absolute screen coordinates, so TRect / TPoint / Screen legitimately stay\r\n"
    "  in this unit. Only the EDITOR dependency is being cut. }\r\n"
    "function MakePixelPoint(const P: TPoint): TLspPixelPoint;\r\n"
    "begin\r\n"
    "  Result.X := P.X;\r\n"
    "  Result.Y := P.Y;\r\n"
    "end;\r\n"
    "\r\n"
    "function MakeHintPoint(const APoint: TLspPixelPoint): TPoint;\r\n"
    "begin\r\n"
    "  Result.X := APoint.X;\r\n"
    "  Result.Y := APoint.Y;\r\n"
    "end;\r\n"
)


def main():
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    want = only[0] if only else "all"

    print("F2-b geometry wiring %s"
          % ("(dry run)" if DRY else "(target: %s)" % want))

    if want in ("all", "hover"):
        ok = edit(HOVER, [
            (HV_USES_OLD, HV_USES_NEW, 1),
            (HV_FIELD_OLD, HV_FIELD_NEW, 1),
            (HV_DECLS_OLD, HV_DECLS_NEW, 1),
            (HV_IMPL_OLD, HV_IMPL_NEW, 1),
            (HV_VAR_OLD, HV_VAR_NEW, 1),
            (HV_POS_OLD, HV_POS_NEW, 1),
            (HV_POS2_OLD, HV_POS2_NEW, 1),
            (HV_LINEHEIGHT_OLD, HV_LINEHEIGHT_NEW, 1),
            (HV_VAR2_OLD, HV_VAR2_NEW, 1),
            (HV_TRY_OLD, HV_TRY_NEW, 1),
            (HV_LINETEXT_OLD, HV_LINETEXT_NEW, 1),
            (HV_HELPERS_OLD, HV_HELPERS_NEW, 1),
            (HV_COORD_DECL2_OLD, HV_COORD_DECL2_NEW, 1),
            (HV_COORD_IMPL2_OLD, HV_COORD_IMPL2_NEW, 1),
            (HV_DIO_COORD_DECL_OLD, HV_DIO_COORD_DECL_NEW, 1),
            (HV_DIO_COORD_IMPL_OLD, HV_DIO_COORD_IMPL_NEW, 1),
            (HV_LOCAL_OLD, HV_LOCAL_NEW, 1),
        ] + HV_SIGS)
        if not ok:
            print("BATCH ABORTED -- Hover.pas untouched.")
            return 1
        print("  Hover.pas done.")

        if DRY:
            print("  (post-check skipped: --dry-run leaves the file unchanged,")
            print("   so of course the toolkit types are still there.)")
            return 0

        # Post-condition, asserted rather than assumed. The first pass DID report
        # "SynEdit x0" in the uses clause while four TBufferCoord signatures were
        # still standing, so a clean uses clause is not evidence of a finished
        # migration. This asserts the property that actually matters.
        import re as _re
        now = read_raw(HOVER)
        # Strip comments first. Hover keeps two legitimate prose mentions of
        # "BufferCoord" (":102 callers convert via BufferCoord", ":950 1-based
        # BufferCoord vs 0-based LSP range") and the first version of this check
        # reported them as leftovers -- i.e. it failed the migration for text a
        # reader can see is a comment. Comments are exactly what a name-based
        # scan must ignore; the contract check learned that lesson already.
        code = _re.sub(r"\{[^}]*\}", " ", now)
        code = _re.sub(r"//[^\n]*", " ", code)
        left = [s for s in ("TCustomSynEdit", "TBufferCoord", "TDisplayCoord",
                            "TSynEdit", "BufferCoord", "SynEdit,")
                if _re.search(r"\b%s\b" % _re.escape(s.rstrip(",")), code)]
        if left:
            print("  POST-CHECK FAILED, leftover toolkit types: %s" % left)
            print("  (the file HAS been written -- restore from backup)")
            return 1
        print("  post-check: no SynEdit types remain in Hover.pas")

    if want == "all":
        print("  (SignatureHelp + Editor.pas rules land in the next script;")
        print("   keeping them separate means a failure here cannot leave two")
        print("   half-migrated units on disk.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())





