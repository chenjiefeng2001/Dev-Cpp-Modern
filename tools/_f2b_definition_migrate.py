#!/usr/bin/env python3
"""F2-b step 1: wire Definition.pas onto IEditorControlAdapter.

ENCODING -- READ THIS FIRST
---------------------------
`Editor.pas` is NOT utf-8. Its Chinese comments decode as mojibake under utf-8
(the comment blocks print as "ae-~..."), because the file is latin-1 /
cp1252-family. Decoding it as utf-8 and writing it back is exactly the
corruption documented in the F1-n step 3 migration: cp1252 bytes become U+FFFD
and are permanently destroyed on the round trip.

So this script reads and writes BOTH files as latin-1, which is a byte<->code
point bijection. ASCII -- every line this migration edits -- compares
identically either way, so the patterns below stay plain ASCII strings.

The three rulings being implemented:

  A. TEditor owns the adapter, created lazily and CACHED. The cache is not a
     performance nicety: `EditorDestroyed` compares interface values, and
     Delphi compares interface pointers (VMT + Self), so two separately-built
     adapters over the same editor would compare UNEQUAL and the teardown would
     silently never fire. Every cache site carries that warning.

  B. Interface comparison replaces the TMethod dead code at Definition:466.

  C. Definition first, as the template for the other three units.

Usage:  python tools/_f2b_definition_migrate.py [--dry-run]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDITOR = ROOT / "Source" / "Editor.pas"
DEFINITION = (ROOT / "Source" / "LSP" / "Client" / "Definition" /
              "Lsp.Client.Definition.pas")
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    """latin-1 in, latin-1 out -- byte-exact for every byte this script edits."""
    return path.read_bytes().decode("latin-1")


def write_raw(path, text):
    path.write_bytes(text.encode("latin-1"))


def edit(path, rules):
    eol = eol_of(path)
    text = read_raw(path)
    plan = []
    for old, new, want in rules:
        # Normalise BOTH sides to LF first, then to the file's EOL. Without the
        # first step a literal that already contains CRLF (see DEF_USES_*) would
        # gain a second CR when the CRLF->LF step is skipped, producing \r\r\n.
        # The first draft of this script did exactly that, and the mismatch only
        # showed up as a dry-run abort -- which is the assertion doing its job.
        o = old.replace("\r\n", "\n").replace("\n", eol)
        n = new.replace("\r\n", "\n").replace("\n", eol)
        got = text.count(o)
        if got != want:
            print("  ABORT %s: pattern hit %d, expected %d\n    %r"
                  % (path.name, got, want, old.strip()[:88]))
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
# Definition.pas -- the contract-ification itself.
# --------------------------------------------------------------------------

# Rule 1: uses. `SynEdit` is dropped and the contract added. Both are needed:
# dropping SynEdit is the point of the change, and Lsp.Editor.Interfaces must be
# nameable for the field and parameter types below.
DEF_USES_OLD = (
    "  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,\r\n"
    "  SynEdit,\r\n"
    "  LSP.Transport, Lsp.DocumentSync;\r\n"
)
DEF_USES_NEW = (
    "  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,\r\n"
    "  LSP.Transport, Lsp.DocumentSync,\r\n"
    "  Lsp.Editor.Types, Lsp.Editor.Interfaces;\r\n"
)

# Rule 2: the field, and every declaration that names TCustomSynEdit.
DEF_FIELD_OLD = "    FEditor: TCustomSynEdit;\n"
DEF_FIELD_NEW = "    FEditor: IEditorControlAdapter;\n"

DEF_DECLS_OLD = (
    "    constructor Create(AEditor: TCustomSynEdit; ATransport: TLspTransport);\n"
    "    destructor Destroy; override;\n"
    "\n"
    "    procedure SetEditor(AEditor: TCustomSynEdit);\n"
)
DEF_DECLS_NEW = (
    "    constructor Create(const AEditor: IEditorControlAdapter;\n"
    "      ATransport: TLspTransport);\n"
    "    destructor Destroy; override;\n"
    "\n"
    "    procedure SetEditor(const AEditor: IEditorControlAdapter);\n"
)

DEF_DESTROY_DECL_OLD = (
    "    // 编辑器析构前调用: 作废在途请求、清除回调、摘除悬空引用\n"
)
DEF_DESTROY_DECL_NEW = (
    "    // 编辑器析构前调用: 作废在途请求、清除回调、摘除悬空引用\n"
)
DEF_DESTROY_SIG_OLD = (
    "    procedure EditorDestroyed(AEditor: TCustomSynEdit);\n"
)
DEF_DESTROY_SIG_NEW = (
    "    procedure EditorDestroyed(const AEditor: IEditorControlAdapter);\n"
)

DEF_INIT_SIG_OLD = (
    "procedure InitializeLspDefinition(AEditor: TCustomSynEdit;\n"
)
DEF_INIT_SIG_NEW = (
    "procedure InitializeLspDefinition(const AEditor: IEditorControlAdapter;\n"
)

# Rule 3: the implementation signatures.
DEF_IMPL_CREATE_OLD = (
    "constructor TLspDefinitionManager.Create(AEditor: TCustomSynEdit;\n"
)
DEF_IMPL_CREATE_NEW = (
    "constructor TLspDefinitionManager.Create(\n"
    "  const AEditor: IEditorControlAdapter;\n"
)
DEF_IMPL_SET_OLD = (
    "procedure TLspDefinitionManager.SetEditor(AEditor: TCustomSynEdit);\n"
)
DEF_IMPL_SET_NEW = (
    "procedure TLspDefinitionManager.SetEditor(\n"
    "  const AEditor: IEditorControlAdapter);\n"
)
DEF_IMPL_DESTROYED_OLD = (
    "procedure TLspDefinitionManager.EditorDestroyed(AEditor: TCustomSynEdit);\n"
)
DEF_IMPL_DESTROYED_NEW = (
    "procedure TLspDefinitionManager.EditorDestroyed(\n"
    "  const AEditor: IEditorControlAdapter);\n"
)

# Rule 4: the dead defence, replaced. The old branch compared
# TMethod(FOnNoResult).Data against the editor pointer -- but FOnNoResult is this
# manager's OWN method (invoked as FOnNoResult(Self)), so its Data is the
# manager and the comparison could never be true. It compiled only because an
# object reference is pointer-sized. Under an interface there is no pointer to
# take, so the branch is deleted rather than translated, and OnNoResult is
# cleared unconditionally on teardown: a manager that is being detached has no
# business keeping a callback either way.
DEF_BODY_OLD = (
    "  if Assigned(AEditor) then\n"
    "  begin\n"
    "    if TMethod(FOnNoResult).Data = Pointer(AEditor) then\n"
    "      FOnNoResult := nil;\n"
    "    if FEditor = AEditor then\n"
    "      FEditor := nil;\n"
    "  end;\n"
)
DEF_BODY_NEW = (
    "  // Interface equality below compares the interface POINTER (VMT + Self),\n"
    "  // not the underlying object. It is correct here only because the caller\n"
    "  // passes the very interface value TEditor cached -- see\n"
    "  // TEditor.GetAdapter. If that cache is ever removed and adapters start\n"
    "  // being built per call, this comparison silently turns False and the\n"
    "  // teardown never fires. Do not 'simplify' the caching.\n"
    "  FOnNoResult := nil;\n"
    "  if FEditor = AEditor then\n"
    "    FEditor := nil;\n"
)

# Rule 5: the single member access -- Lines.Text -> GetAllText.
DEF_LINETEXT_OLD = "    LspFlushPendingDocument(FCurrentFile, FEditor.Lines.Text);\n"
DEF_LINETEXT_NEW = "    LspFlushPendingDocument(FCurrentFile, FEditor.GetAllText);\n"

# Rule 6: the shim at the bottom, which passes the adapter straight through.
DEF_SHIM_OLD = (
    "  LspDefinitionManager := TLspDefinitionManager.Create(AEditor, ATransport);\n"
)
DEF_SHIM_NEW = (
    "  LspDefinitionManager := TLspDefinitionManager.Create(AEditor, ATransport);\n"
)


# --------------------------------------------------------------------------
# Editor.pas -- the TEditor-owned adapter.
# --------------------------------------------------------------------------

# Rule 7: the field, next to fText so the pairing is obvious on sight.
ED_FIELD_OLD = "    fText: TSynEditEx;\n"
ED_FIELD_NEW = (
    "    fText: TSynEditEx;\n"
    "    // F2: the LSP contract adapter for this tab's editor. Owned here so its\n"
    "    // lifetime is the tab's, and CACHED so every consumer receives the SAME\n"
    "    // interface value -- see TEditor.GetAdapter.\n"
    "    FEditorAdapter: IEditorControlAdapter;\n"
)

# Rule 8: the accessor, declared in the public section next to the other
# LSP-facing methods so the wiring sites find it.
ED_DECL_OLD = (
    "    function TryLspGotoDefinitionAtCaret: Boolean;\n"
)
ED_DECL_NEW = (
    "    // F2: returns this tab's IEditorControlAdapter, creating it on first use.\n"
    "    // CACHING IS LOAD-BEARING, NOT AN OPTIMISATION: Delphi compares\n"
    "    // interface values by POINTER (VMT + Self), so a freshly built adapter\n"
    "    // over the same editor compares UNEQUAL to a cached one, and every\n"
    "    // `FEditor = AEditor` teardown check would silently stop matching.\n"
    "    // Never change this to build a new adapter per call.\n"
    "    function GetAdapter: IEditorControlAdapter;\n"
    "    function TryLspGotoDefinitionAtCaret: Boolean;\n"
)

ED_IMPL_OLD = "function TEditor.TryLspGotoDefinitionAtCaret: Boolean;\n"
ED_IMPL_NEW = (
    "function TEditor.GetAdapter: IEditorControlAdapter;\n"
    "begin\n"
    "  if not Assigned(FEditorAdapter) and Assigned(fText) then\n"
    "    FEditorAdapter := TVclSynEditAdapter.Create(fText);\n"
    "  Result := FEditorAdapter;\n"
    "end;\n"
    "\n"
    "function TEditor.TryLspGotoDefinitionAtCaret: Boolean;\n"
)

# Rule 9: the two SetEditor call sites.
ED_CALL_OLD = "  LspDefinitionManager.SetEditor(fText);\n"
ED_CALL_NEW = "  LspDefinitionManager.SetEditor(GetAdapter);\n"

# Rule 10: teardown ordering. The adapter holds a raw pointer to fText, so it
# must be released while fText is still alive -- and AFTER the manager has been
# told to detach, because that notification compares against the adapter.
ED_DESTROY_OLD = (
    "  if Assigned(fText) then\n"
    "  begin\n"
    "    if Assigned(LspHoverManager) then\n"
    "      LspHoverManager.EditorDestroyed(fText);\n"
    "    if Assigned(LspCompletionManager) then\n"
    "      LspCompletionManager.EditorDestroyed(fText);\n"
    "    if Assigned(LspSignatureHelpManager) then\n"
    "      LspSignatureHelpManager.EditorDestroyed(fText);\n"
    "  end;\n"
)
ED_DESTROY_NEW = (
    "  if Assigned(fText) then\n"
    "  begin\n"
    "    if Assigned(LspHoverManager) then\n"
    "      LspHoverManager.EditorDestroyed(fText);\n"
    "    if Assigned(LspCompletionManager) then\n"
    "      LspCompletionManager.EditorDestroyed(fText);\n"
    "    if Assigned(LspSignatureHelpManager) then\n"
    "      LspSignatureHelpManager.EditorDestroyed(fText);\n"
    "  end;\n"
    "  // F2 teardown order, and it is load-bearing:\n"
    "  //   1. notify the manager while the adapter is still alive -- that call\n"
    "  //      compares against this very interface value;\n"
    "  //   2. drop the adapter while fText is STILL ALIVE, because the adapter\n"
    "  //      holds a raw pointer to it and would otherwise touch freed memory;\n"
    "  //   3. only then is fText freed below.\n"
    "  if Assigned(LspDefinitionManager) and Assigned(FEditorAdapter) then\n"
    "    LspDefinitionManager.EditorDestroyed(FEditorAdapter);\n"
    "  FEditorAdapter := nil;\n"
)


# Rule 11: Editor.pas needs the adapter unit. The interface types are also used
# by the field and the accessor, so both contract units are named.
#
# Anchored on the END of the uses clause, not on its first line. The first draft
# anchored mid-list and hit 0, because this clause wraps across four lines and
# the continuation point is an implementation detail that moves whenever anyone
# adds a unit. The tail is one line and names the two VCL units already there.
ED_USES_OLD = (
    "  CodeToolTip, CBUtils, System.UITypes, System.Contnrs, SynEditPrint, "
    "Vcl.ExtDlgs;"
)
ED_USES_NEW = (
    "  CodeToolTip, CBUtils, System.UITypes, System.Contnrs, SynEditPrint, "
    "Vcl.ExtDlgs,\r\n"
    "  // F2: the editor-adapter contract. VclAdapter is the ONLY place in this\n"
    "  // unit that may name TCustomSynEdit; everything else talks to the\n"
    "  // interface, which is what makes the LSP layer portable later.\n"
    "  Lsp.Editor.Types, Lsp.Editor.Interfaces, Lsp.Editor.VclAdapter;"
)


def main():
    print("F2-b step 1 (Definition wiring) %s" % ("(dry run)" if DRY else ""))
    ok = edit(DEFINITION, [
        (DEF_USES_OLD, DEF_USES_NEW, 1),
        (DEF_FIELD_OLD, DEF_FIELD_NEW, 1),
        (DEF_DECLS_OLD, DEF_DECLS_NEW, 1),
        (DEF_DESTROY_SIG_OLD, DEF_DESTROY_SIG_NEW, 1),
        (DEF_INIT_SIG_OLD, DEF_INIT_SIG_NEW, 2),   # decl + impl
        (DEF_IMPL_CREATE_OLD, DEF_IMPL_CREATE_NEW, 1),
        (DEF_IMPL_SET_OLD, DEF_IMPL_SET_NEW, 1),
        (DEF_IMPL_DESTROYED_OLD, DEF_IMPL_DESTROYED_NEW, 1),
        (DEF_BODY_OLD, DEF_BODY_NEW, 1),
        (DEF_LINETEXT_OLD, DEF_LINETEXT_NEW, 1),
    ])
    if not ok:
        print("BATCH ABORTED -- Definition.pas untouched.")
        return 1

    ok = edit(EDITOR, [
        (ED_USES_OLD, ED_USES_NEW, 1),
        (ED_FIELD_OLD, ED_FIELD_NEW, 1),
        (ED_DECL_OLD, ED_DECL_NEW, 1),
        (ED_IMPL_OLD, ED_IMPL_NEW, 1),
        (ED_CALL_OLD, ED_CALL_NEW, 2),             # two call sites
        (ED_DESTROY_OLD, ED_DESTROY_NEW, 1),
    ])
    if not ok:
        print("BATCH ABORTED -- Editor.pas untouched (Definition.pas already written).")
        return 1

    print("all 2 file(s) written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())


