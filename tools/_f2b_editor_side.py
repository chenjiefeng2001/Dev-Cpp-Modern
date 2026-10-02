#!/usr/bin/env python3
"""F2-b geometry wiring, part 2: the Editor.pas side of Hover + SignatureHelp.

Runs AFTER _f2b_geometry_migrate.py has migrated the client units, because the
two halves are only consistent together: once Hover.SetEditor takes an interface,
every call site passing `fText` is a type error, and until this runs the tree
does not compile. Kept as its own script so a failure in either half leaves the
other untouched and the breakage is attributable.

ENCODING: Editor.pas is latin-1. See the geometry script's header.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDITOR = ROOT / "Source" / "Editor.pas"
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    return path.read_bytes().decode("latin-1")


def write_raw(path, text):
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


# --- call sites ------------------------------------------------------------
# Hover now takes the adapter. Definition's two sites were already converted.
HV_SET_OLD = "  LspHoverManager.SetEditor(fText);\r\n"
HV_SET_NEW = "  LspHoverManager.SetEditor(GetAdapter);\r\n"

HV_DISMISS_OLD = "      LspHoverManager.DismissIfOutside(fText, HoverBC);\r\n"
HV_DISMISS_NEW = "      LspHoverManager.DismissIfOutside(GetAdapter, HoverBC);\r\n"

# fHoverCoord / HoverBC move to the contract's coordinate record. TBufferCoord
# is a SynEdit type; leaving it here would keep Editor.pas coupled to SynEdit
# coordinates purely to satisfy the hover timer.
HV_COORD_DECL_OLD = "    fHoverCoord: TBufferCoord;\r\n"
HV_COORD_DECL_NEW = "    fHoverCoord: TLspBufferCoord;\r\n"

# HoverBC is a LOCAL in the mouse-move routine, not a field. It also has to
# change: it is passed straight into DismissIfOutside, whose parameter is now
# TLspBufferCoord, so leaving it as TBufferCoord is a type error.
HV_LOCAL_DECL_OLD = "  HoverBC: TBufferCoord;\r\n"
HV_LOCAL_DECL_NEW = "  HoverBC: TLspBufferCoord;\r\n"

HV_COORD_CALC_OLD = (
    "    HoverBC := fText.DisplayToBufferPos(fText.PixelsToRowColumn(X, Y));\r\n"
)
# MakePixelPoint lives in Hover.pas's IMPLEMENTATION section, so it is NOT
# reachable from Editor.pas. An earlier draft of this rule called it and would
# have failed to compile -- a private helper in another unit is invisible to the
# compiler, no matter how obviously it "should" be shared. The record is built
# inline instead; it is two assignments.
HV_COORD_CALC_NEW = (
    "    HoverBC := GetAdapter.ScreenPixelsToBuffer(MakePixelCoord(X, Y));\r\n"
)

# A local helper in Editor.pas itself, so it can also be used by the routine that
# feeds DismissIfOutside. Declared just before TEditor.GetAdapter.
ED_HELPER_OLD = "function TEditor.GetAdapter: IEditorControlAdapter;\r\n"
ED_HELPER_NEW = (
    "function MakePixelCoord(const AX, AY: Integer): TLspPixelPoint;\r\n"
    "begin\r\n"
    "  Result.X := AX;\r\n"
    "  Result.Y := AY;\r\n"
    "end;\r\n"
    "\r\n"
    "function TEditor.GetAdapter: IEditorControlAdapter;\r\n"
)

# --- SignatureHelp call sites (added when SignatureHelp.pas was migrated) ----
# Three sites, not one: SetEditor (where the manager is attached), CaretMoved
# (fired from the editor's caret event) and EditorDestroyed (teardown). All three
# pass `fText` today and must pass the adapter, or the tree stops compiling the
# moment the manager's parameter becomes an interface.
SH_SET_OLD = "  LspSignatureHelpManager.SetEditor(fText);\r\n"
SH_SET_NEW = "  LspSignatureHelpManager.SetEditor(GetAdapter);\r\n"
SH_CTM_OLD = "      LspSignatureHelpManager.EditorCaretMoved(fText);\r\n"
SH_CTM_NEW = "      LspSignatureHelpManager.EditorCaretMoved(GetAdapter);\r\n"
SH_DESTROY_OLD = "      LspSignatureHelpManager.EditorDestroyed(fText);\r\n"
SH_DESTROY_NEW = "      LspSignatureHelpManager.EditorDestroyed(GetAdapter);\r\n"

# Teardown. The current file has BOTH a raw-`fText` block (Hover, Completion,
# SignatureHelp) and an adapter-routed block (Definition, Hover). Hover is
# therefore notified TWICE -- once with fText at :614 and once with the adapter
# at :634. That is not harmless: the first call compares `FEditor <> AEditor` as
# an interface against a raw TCustomSynEdit argument, which is a type error the
# compiler will catch, and if it ever compiled it would be a double teardown.
#
# So the raw block is reduced to Completion ONLY (not yet migrated) and every
# migrated manager moves into the adapter block. The F2 ordering note is
# rewritten at the same time because it now describes three steps rather than
# two, and the stale "1./2./3." list no longer matches the code below it.
HV_DESTROY_OLD = (
    "  if Assigned(fText) then\r\n"
    "  begin\r\n"
    "    if Assigned(LspHoverManager) then\r\n"
    "      LspHoverManager.EditorDestroyed(fText);\r\n"
    "    if Assigned(LspCompletionManager) then\r\n"
    "      LspCompletionManager.EditorDestroyed(fText);\r\n"
    "    if Assigned(LspSignatureHelpManager) then\r\n"
    "      LspSignatureHelpManager.EditorDestroyed(fText);\r\n"
    "  end;\r\n"
    "  // F2 teardown order, and it is load-bearing:\r\n"
    "  //   1. notify the manager while the adapter is still alive -- that call\r\n"
    "  //      compares against this very interface value;\r\n"
    "  //   2. drop the adapter while fText is STILL ALIVE, because the adapter\r\n"
    "  //      holds a raw pointer to it and would otherwise touch freed memory;\r\n"
    "  //   3. only then is fText freed below.\r\n"
    "  if Assigned(FEditorAdapter) then\r\n"
    "  begin\r\n"
    "    // Notify while the adapter is still alive: each of these calls compares\r\n"
    "    // against this exact interface value, and interface equality is pointer\r\n"
    "    // equality (see TEditor.GetAdapter).\r\n"
    "    if Assigned(LspDefinitionManager) then\r\n"
    "      LspDefinitionManager.EditorDestroyed(FEditorAdapter);\r\n"
    "    if Assigned(LspHoverManager) then\r\n"
    "      LspHoverManager.EditorDestroyed(FEditorAdapter);\r\n"
    "  end;\r\n"
)
HV_DESTROY_NEW = (
    "  if Assigned(fText) and Assigned(LspCompletionManager) then\r\n"
    "    // Completion is the last manager still on the raw control; it is not\r\n"
    "    // migrated yet, so it keeps its own notification here.\r\n"
    "    LspCompletionManager.EditorDestroyed(fText);\r\n"
    "  // F2 teardown order, and it is load-bearing:\r\n"
    "  //   1. notify every migrated manager while the adapter is still alive --\r\n"
    "  //      each of those calls compares against this exact interface value;\r\n"
    "  //   2. drop the adapter while fText is STILL ALIVE, because the adapter\r\n"
    "  //      holds a raw pointer to it and would otherwise touch freed memory;\r\n"
    "  //   3. only then is fText freed below.\r\n"
    "  if Assigned(FEditorAdapter) then\r\n"
    "  begin\r\n"
    "    // One notification per manager. Hover used to appear in BOTH this block\r\n"
    "    // and the raw block above, which would have notified it twice.\r\n"
    "    if Assigned(LspDefinitionManager) then\r\n"
    "      LspDefinitionManager.EditorDestroyed(FEditorAdapter);\r\n"
    "    if Assigned(LspHoverManager) then\r\n"
    "      LspHoverManager.EditorDestroyed(FEditorAdapter);\r\n"
    "    if Assigned(LspSignatureHelpManager) then\r\n"
    "      LspSignatureHelpManager.EditorDestroyed(FEditorAdapter);\r\n"
    "  end;\r\n"
)




def main():
    print("F2-b geometry wiring (Editor.pas side) %s"
          % ("(dry run)" if DRY else ""))

    # Only the rules that have NOT been applied yet are listed. Hover's
    # SetEditor, DismissIfOutside, coordinate types and MakePixelCoord were
    # converted by the previous run; re-listing them hits 0 and aborts, which is
    # exactly how the stale rules were found rather than silently ignored.
    # A migration script that must be hand-edited between runs is a smell, but
    # the count assertion makes the hand-edit LOUD, which is the part that
    # matters: a rule that quietly stopped matching would edit nothing.
    ok = edit(EDITOR, [
        # SignatureHelp: SetEditor (attach) and CaretMoved (caret event).
        (SH_SET_OLD, SH_SET_NEW, 1),
        (SH_CTM_OLD, SH_CTM_NEW, 1),
        # Teardown, rewritten as ONE rule. SignatureHelp's EditorDestroyed site
        # is consumed by it rather than by a separate rule -- two rules touching
        # the same lines would make the result depend on ordering. This is also
        # where Hover's DUPLICATE notification is removed.
        (HV_DESTROY_OLD, HV_DESTROY_NEW, 1),
    ])
    if not ok:
        print("BATCH ABORTED -- Editor.pas untouched.")
        return 1
    print("  Editor.pas done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())