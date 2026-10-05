#!/usr/bin/env python3
"""F2-b step 4: wire SignatureHelp.pas onto IEditorControlAdapter.

Third unit through the same pattern as Definition and Hover. The shape here is
the easiest of the three: no TBufferCoord anywhere (only TCustomSynEdit in 14
signatures), and every member access is geometry or caret reading -- exactly what
the contract already provides.

One thing worth naming explicitly, because it is the same trap twice over:
EditorCaretMoved (:1085) and EditorDestroyed (:1096) compare `AEditor <> FEditor`.
After the migration that is an INTERFACE comparison, which Delphi resolves by
POINTER (VMT + Self), not by underlying object. It stays correct only because
TEditor.GetAdapter hands every caller the same cached interface value. The
comment at each site says so, in the same words used for Definition.

ENCODING: utf-8 with BOM, like the other client units. Line endings are
normalised to LF and then to the file's EOL, per the rule established earlier.

Usage:  python tools/_f2b_signature_migrate.py [--dry-run]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIGHELP = (ROOT / "Source" / "LSP" / "Client" / "SignatureHelp" /
           "Lsp.Client.SignatureHelp.pas")
DRY = "--dry-run" in sys.argv


def eol_of(path):
    return "\r\n" if b"\r\n" in path.read_bytes() else "\n"


def read_raw(path):
    raw = path.read_bytes()
    return raw.decode("utf-8-sig" if raw[:3] == b"\xef\xbb\xbf" else "utf-8")


def write_raw(path, text):
    raw = path.read_bytes()
    bom = b"\xef\xbb\xbf" if raw[:3] == b"\xef\xbb\xbf" else b""
    path.write_bytes(bom + text.encode("utf-8"))


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


ADAPTER_IFACE = "IEditorControlAdapter"

SH_USES_OLD = (
    "  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,\r\n"
    "  Vcl.Controls, Vcl.Forms, Vcl.Graphics,\r\n"
    "  SynEditTypes, SynEdit,\r\n"
    "  LSP.Transport, Lsp.DocumentSync;\r\n"
)
SH_USES_NEW = (
    "  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,\r\n"
    "  Vcl.Controls, Vcl.Forms, Vcl.Graphics,\r\n"
    "  LSP.Transport, Lsp.DocumentSync,\r\n"
    "  Lsp.Editor.Types, Lsp.Editor.Interfaces;\r\n"
)

# The two FEditor fields (hint window :89, manager :67). Counted 2.
SH_FIELD_OLD = "FEditor: TCustomSynEdit;"
SH_FIELD_NEW = "FEditor: IEditorControlAdapter;"

# Declarations. ShowForEditor takes the adapter and only for positioning; the
# window stores it as FEditor like before.
SH_SHOW_DECL_OLD = (
    "procedure ShowForEditor(AEditor: TCustomSynEdit);\r\n"
)
SH_SHOW_DECL_NEW = (
    "procedure ShowForEditor(const AEditor: IEditorControlAdapter);\r\n"
)
SH_CTM_OLD = "procedure EditorCaretMoved(AEditor: TCustomSynEdit);\r\n"
SH_CTM_NEW = "procedure EditorCaretMoved(const AEditor: IEditorControlAdapter);\r\n"

# Signatures that name TCustomSynEdit, one form each.
SH_SIGS = [
    ("constructor Create(AEditor: TCustomSynEdit; ATransport: TLspTransport);",
     "constructor Create(const AEditor: IEditorControlAdapter;\r\n"
     "      ATransport: TLspTransport);", 1),
    ("procedure SetEditor(AEditor: TCustomSynEdit);",
     "procedure SetEditor(const AEditor: IEditorControlAdapter);", 1),
    ("procedure EditorDestroyed(AEditor: TCustomSynEdit);",
     "procedure EditorDestroyed(const AEditor: IEditorControlAdapter);", 1),
    ("procedure InitializeLspSignatureHelp(AEditor: TCustomSynEdit;",
     "procedure InitializeLspSignatureHelp(\r\n  const AEditor: IEditorControlAdapter;", 2),
    ("procedure TLspSignatureHintWindow.ShowForEditor(AEditor: TCustomSynEdit);",
     "procedure TLspSignatureHintWindow.ShowForEditor(\r\n"
     "  const AEditor: IEditorControlAdapter);", 1),
    ("constructor TLspSignatureHelpManager.Create(AEditor: TCustomSynEdit;",
     "constructor TLspSignatureHelpManager.Create(\r\n"
     "  const AEditor: IEditorControlAdapter;", 1),
    ("procedure TLspSignatureHelpManager.SetEditor(AEditor: TCustomSynEdit);",
     "procedure TLspSignatureHelpManager.SetEditor(\r\n"
     "  const AEditor: IEditorControlAdapter);", 1),
    ("procedure TLspSignatureHelpManager.EditorCaretMoved(AEditor: TCustomSynEdit);",
     "procedure TLspSignatureHelpManager.EditorCaretMoved(\r\n"
     "  const AEditor: IEditorControlAdapter);", 1),
    ("procedure TLspSignatureHelpManager.EditorDestroyed(AEditor: TCustomSynEdit);",
     "procedure TLspSignatureHelpManager.EditorDestroyed(\r\n"
     "  const AEditor: IEditorControlAdapter);", 1),
]

# --- member access -> contract -------------------------------------------

# Popup positioning. Three calls collapse into CaretToScreenPixels, which is the
# contract member for exactly "where is the caret on screen" -- SignatureHelp
# positions off DisplayXY, not off an arbitrary buffer position like Hover does.
SH_POS_OLD = (
    "  P := AEditor.ClientToScreen(\r\n"
    "    AEditor.RowColumnToPixels(AEditor.DisplayXY));\r\n"
)
SH_POS_NEW = (
    "  P := MakeHintPoint(AEditor.CaretToScreenPixels);\r\n"
)
SH_POS2_OLD = (
    "    P := AEditor.ClientToScreen(\r\n"
    "      AEditor.RowColumnToPixels(AEditor.DisplayXY));\r\n"
)
SH_POS2_NEW = (
    "    P := MakeHintPoint(AEditor.CaretToScreenPixels);\r\n"
)
SH_LINEHEIGHT_OLD = "  Inc(P.Y, AEditor.LineHeight + 4);\r\n"
SH_LINEHEIGHT_NEW = "  Inc(P.Y, AEditor.GetLineHeight + 4);\r\n"

SH_LINETEXT_OLD = "    LspFlushPendingDocument(FCurrentFile, FEditor.Lines.Text);\r\n"
SH_LINETEXT_NEW = "    LspFlushPendingDocument(FCurrentFile, FEditor.GetAllText);\r\n"

# Caret reads. Read ONCE into the contract record rather than calling
# GetCaretPosition twice: the original read CaretY and CaretX as two separate
# property accesses, and pairing them is exactly what the contract is for.
SH_CARET_OLD = (
    "  FActiveContext.CaretLine := FEditor.CaretY;\r\n"
    "  FActiveContext.CaretChar := FEditor.CaretX;\r\n"
)
SH_CARET_NEW = (
    "  CaretPos := FEditor.GetCaretPosition;\r\n"
    "  FActiveContext.CaretLine := CaretPos.Line;\r\n"
    "  FActiveContext.CaretChar := CaretPos.Char;\r\n"
)
SH_LSPPOS_OLD = (
    "  LspLine := FEditor.CaretY - 1;\r\n"
    "  LspChar := FEditor.CaretX - 1;\r\n"
)
SH_LSPPOS_NEW = (
    "  LspLine := CaretPos.Line - 1;\r\n"
    "  LspChar := CaretPos.Char - 1;\r\n"
)

# The var section of RequestSignatureHelp needs the new local. Located by
# reading the routine: the Integer block is a single comma-separated declaration
# (`LspLine, LspChar, ReqId, TrigKind: Integer;`), not one line per name, so a
# per-name pattern hits nothing. Adding CaretPos on its own line avoids
# rewriting that list.
SH_VARS_OLD = "  LspLine, LspChar, ReqId, TrigKind: Integer;\r\n"
SH_VARS_NEW = ("  LspLine, LspChar, ReqId, TrigKind: Integer;\r\n"
               "  CaretPos: TLspBufferCoord;\r\n")

# EditorCaretMoved: the interface-equality caveat, stated at the comparison.
SH_CTM_BODY_OLD = (
    "  if not Assigned(FEditor) or (AEditor <> FEditor) then\r\n"
    "    Exit;\r\n"
)
SH_CTM_BODY_NEW = (
    "  // Interface equality compares the interface POINTER (VMT + Self), not\r\n"
    "  // the underlying editor. Correct only because TEditor.GetAdapter hands\r\n"
    "  // every caller the same cached value -- do not remove that cache.\r\n"
    "  if not Assigned(FEditor) or (AEditor <> FEditor) then\r\n"
    "    Exit;\r\n"
)

# EditorCaretMoved's caret comparison.
SH_CTM_CARET_OLD = (
    "  if (FEditor.CaretY = FActiveContext.CaretLine) and\r\n"
    "    (FEditor.CaretX = FActiveContext.CaretChar) then\r\n"
    "    Exit;\r\n"
)
SH_CTM_CARET_NEW = (
    "  if (FEditor.GetCaretPosition.Line = FActiveContext.CaretLine) and\r\n"
    "    (FEditor.GetCaretPosition.Char = FActiveContext.CaretChar) then\r\n"
    "    Exit;\r\n"
)

# MakeHintPoint, the single bridge this unit needs.
SH_HELPER_OLD = "implementation\r\n"
SH_HELPER_NEW = (
    "implementation\r\n"
    "\r\n"
    "{ TLspPixelPoint -> TPoint for the hint window's screen-coordinate maths.\r\n"
    "  The hint window is VCL and stays VCL (ActivateHint at absolute screen\r\n"
    "  coordinates), so TRect / TPoint / Screen legitimately remain here. Only\r\n"
    "  the EDITOR dependency is being cut. }\r\n"
    "function MakeHintPoint(const APoint: TLspPixelPoint): TPoint;\r\n"
    "begin\r\n"
    "  Result.X := APoint.X;\r\n"
    "  Result.Y := APoint.Y;\r\n"
    "end;\r\n"
)


def main():
    print("F2-b step 4 (SignatureHelp wiring) %s"
          % ("(dry run)" if DRY else ""))
    rules = [
        (SH_USES_OLD, SH_USES_NEW, 1),
        (SH_SHOW_DECL_OLD, SH_SHOW_DECL_NEW, 1),
        (SH_CTM_OLD, SH_CTM_NEW, 1),
        (SH_POS_OLD, SH_POS_NEW, 1),
        (SH_POS2_OLD, SH_POS2_NEW, 1),
        (SH_LINEHEIGHT_OLD, SH_LINEHEIGHT_NEW, 1),
        (SH_LINETEXT_OLD, SH_LINETEXT_NEW, 1),
        (SH_VARS_OLD, SH_VARS_NEW, 1),
        (SH_CARET_OLD, SH_CARET_NEW, 1),
        (SH_LSPPOS_OLD, SH_LSPPOS_NEW, 1),
        (SH_CTM_BODY_OLD, SH_CTM_BODY_NEW, 1),
        (SH_CTM_CARET_OLD, SH_CTM_CARET_NEW, 1),
        (SH_HELPER_OLD, SH_HELPER_NEW, 1),
    ] + SH_SIGS
    # The two FEditor fields are changed AFTER the signatures, because the
    # signature patterns still contain the literal TCustomSynEdit and the field
    # pattern is a substring of some of them ("FEditor: TCustomSynEdit;" is
    # inside the field line only, but doing fields first would leave the
    # signature patterns matching one occurrence fewer).
    rules.append((SH_FIELD_OLD, SH_FIELD_NEW, 2))

    if not edit(SIGHELP, rules):
        print("BATCH ABORTED -- SignatureHelp.pas untouched.")
        return 1
    print("  SignatureHelp.pas done.")

    if DRY:
        return 0

    now = read_raw(SIGHELP)
    code = re.sub(r"\{[^}]*\}", " ", now)
    code = re.sub(r"//[^\n]*", " ", code)
    left = [s for s in ("TCustomSynEdit", "TBufferCoord", "TDisplayCoord",
                        "TSynEdit", "SynEdit,")
            if re.search(r"\b%s\b" % re.escape(s.rstrip(",")), code)]
    if left:
        print("  POST-CHECK FAILED, leftover toolkit types: %s" % left)
        print("  (file HAS been written -- restore from backup)")
        return 1
    print("  post-check: no SynEdit types remain in SignatureHelp.pas")
    return 0


if __name__ == "__main__":
    sys.exit(main())


