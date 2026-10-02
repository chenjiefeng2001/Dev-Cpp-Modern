unit Lsp.Editor.Interfaces;

{ ---------------------------------------------------------------------------
  Lsp.Editor.Interfaces -- the contract between the LSP client layer and any
  concrete editor control (VCL SynEdit today, LCL TSynEdit tomorrow).

  DERIVED FROM MEASUREMENT, NOT FROM A PLAN
  -----------------------------------------
  Every member below corresponds to something the four client units actually
  call. tools/lsp_editor_deps.py enumerates the 22 distinct members those units
  touch; this interface covers all 22 and adds nothing speculative. Members a
  plan proposed that had no measured caller were CUT -- they are listed in the
  omissions note at the bottom so the decision stays reviewable.

  Design rules, each forced by a measured fact:

  1. WRITES ARE ATOMIC. The real code performs
        BeginUndoBlock -> BlockBegin := S; BlockEnd := E; SelText := T;
        CaretXY := C; BlockBegin := C; BlockEnd := C; EndUndoBlock
     as ONE operation inside try/except + try/finally. Exposing those seven
     steps separately would let a caller reorder them into something SynEdit
     rejects, and would leak the "collapse the selection afterwards"
     implementation detail (Completion:846-857, where the comment explains the
     collapse is mandatory or the outer Validate handler double-applies).
     Hence ReplaceRange.

  2. THE MARKER COLLECTION IS A COLLABORATOR. Markers is a list with
     Count/Add/Delete (Lsp.Client.pas:139-182), not a property returning one
     thing. A collaborator keeps SynEdit's marker class out of the signature.

  3. NOTIFICATION IS A REGISTRATION, NOT A FIELD. MarkersChanged is ASSIGNED
     an anonymous method (Lsp.Client.pas:84). An interface cannot express an
     event FIELD, so it becomes a registration method. The callback type is
     declared HERE rather than taken from Vcl.Controls, which is what would
     otherwise drag the VCL into a supposedly toolkit-free contract.

  4. COORDINATES ARE PLAIN RECORDS. See Lsp.Editor.Types.

  5. NOTHING HERE RETURNS A VCL TYPE. No TPoint, TRect, TColor, TNotifyEvent
     or TBufferCoord. That property is what makes an LCL implementation
     possible at all, so tools/f2_contract_check.py verifies it mechanically
     instead of leaving it to review.
  --------------------------------------------------------------------------- }

interface

uses
  Lsp.Editor.Types;

type
  { Callback shape for marker-change notification.

    Declared locally instead of using Vcl.Controls.TNotifyEvent: that is a VCL
    symbol, and a contract mentioning it cannot be implemented under LCL
    without an LCL.Controls dependency -- exactly the coupling this unit
    exists to remove. Same shape, defined by us. }
  TLspNotifyEvent = procedure(Sender: TObject) of object;

  { The editor's diagnostic-marker collection.

    Identity note: the client layer never reads a marker back. Clear deletes
    by index and RecalculateMarkers rebuilds everything from its own
    FDiagnostics list (Lsp.Client.pas:188-200), so no caller needs a marker
    handle. That is why there is no GetMarker here -- adding one would be an
    untested member. }
  IEditorMarkerList = interface
    ['{8F3D1C2A-4B5E-4D6F-9A8B-7C6D5E4F3A2B}']
    function GetCount: Integer;
    { Add one marker. Taken by const because it carries a string. }
    procedure Add(const AMarker: TLspMarkerSpec);
    { Delete the marker at AIndex. Callers re-read indices each step:
      Lsp.Client.pas:139-144 deletes while decrementing, so indices shift. }
    procedure Delete(AIndex: Integer);
    { Delete every marker. Covers Clear()'s loop in one call; an adapter may
      still implement it as an index loop internally. }
    procedure Clear;
  end;

  IEditorControlAdapter = interface
    ['{5A6B7C8D-9E0F-4A1B-8C2D-3E4F5A6B7C8D}']

    // ---- text and line metadata (read-only) ------------------------------
    { 1-based. Covers FEditor.Lines[i] (Completion:550) and FEditor.LineText
      (Completion:573). }
    function GetLineText(const ALine: Integer): string;
    { Covers FEditor.Lines.Count -- 12 call sites, the most-used member. }
    function GetTotalLines: Integer;
    { Covers FEditor.Lines.Text, which feeds LSP document sync
      (LspFlushPendingDocument at Completion:609 and two siblings). NOT a line
      accessor: this is the whole document as one string. }
    function GetAllText: string;

    // ---- caret -----------------------------------------------------------
    { Covers FEditor.CaretX / CaretY, always read together (11 places). They
      are consumed as a pair, so the contract pairs them; splitting them would
      invite reading an inconsistent mix if the caret moves in between. }
    function GetCaretPosition: TLspBufferCoord;

    // ---- atomic write ----------------------------------------------------
    { Replace [AStart, AEnd) with ANewText as one undoable operation, leaving
      the caret at the end of the inserted text and the selection collapsed.

      The caret placement is not an implementation detail: it is required for
      correctness (Completion:846-858). }
    procedure ReplaceRange(const AStart, AEnd: TLspBufferCoord;
      const ANewText: string);

    // ---- geometry --------------------------------------------------------
    { Buffer position -> screen pixels. Collapses the 3-step chain
      BufferToDisplayPos -> RowColumnToPixels -> ClientToScreen that both
      Hover:781-783 and SignatureHelp:910-912 spell out. One method, because
      no caller ever uses an intermediate step. }
    function BufferToScreenPixels(const ACoord: TLspBufferCoord): TLspPixelPoint;
    { Caret -> screen pixels, for popups hanging off the caret.
      SignatureHelp:911 uses exactly DisplayXY here. }
    function CaretToScreenPixels: TLspPixelPoint;
    { Screen pixels -> buffer position. Collapses ScreenToClient ->
      PixelsToRowColumn -> DisplayToBufferPos (Hover:1015-1022).
      MouseStillOnRequest additionally bounds-checks against ClientWidth /
      ClientHeight and rejects negatives; that stays in the caller because it
      is a policy decision ("is the mouse still on the request?"), not a
      coordinate conversion. }
    function ScreenPixelsToBuffer(const APoint: TLspPixelPoint): TLspBufferCoord;
    { Line height in pixels, to offset popups below the anchor
      (Hover:783, SignatureHelp:912). }
    function GetLineHeight: Integer;
    { Viewport width/height, for the same bounds check (Hover:1020). }
    function GetClientWidth: Integer;
    function GetClientHeight: Integer;

    // ---- markers and notification ----------------------------------------
    function GetMarkers: IEditorMarkerList;
    { Register the marker-change callback (Lsp.Client.pas:84). Pass nil to
      unregister -- needed on teardown; the real code has no destructor that
      unsubscribes today, so the VCL adapter should. }
    procedure SetOnMarkersChanged(const AHandler: TLspNotifyEvent);
  end;

implementation

end.

{ ---------------------------------------------------------------------------
  DELIBERATE OMISSIONS -- planned members that had NO measured caller.

  Each was in the F2 contract draft and is cut here because
  tools/lsp_editor_deps.py found zero call sites. Recorded rather than
  silently dropped, so re-adding one later is a deliberate act:

    SetCaretPosition      0 callers. CaretXY is only ever assigned as part of
                          the write protocol, now folded into ReplaceRange.
    GetWordAtPosition     0 callers. Completion derives the word inline from
                          LineText + CaretX (573-577); extracting it would be
                          a refactor, not a port.
    SetSelection          0 callers. Selection is only written through the
                          BlockBegin/BlockEnd protocol.
    InvalidateView        0 callers. No direct redraw is requested.
    IsFocused             0 callers. Nothing asks about keyboard focus.
    GetWindowHandle       0 callers. No popup is parented to the editor: both
                          hint windows are TCustomHintWindows shown via
                          ActivateHint at absolute screen coordinates.
    ScrollToCaret         0 callers.
    SetOnDiagnosticChange exists on TLspDiagnosticsManager, not on the
                          editor, so it stays in the client layer.

  Two draft members were not merely unused but WRONG, and are the reason this
  contract reads differently from the draft:

  * `SetSelection` + `ReplaceSelection` as separate methods. The real code
    treats selection-write, text-write, caret placement and undo bracketing as
    ONE operation (Completion:841-859), and the caret/selection-collapse step
    is mandatory: without it the outer Validate handler double-applies the
    edit. Splitting them would let a future caller produce that bug.
  * A marker signature of (Line, Char, MarkerId). Lsp.Client.pas:169-179 sets
    Style, Color, TopLine, BottomLine, EndColumn and ToolDescription on each
    marker. A triple cannot carry a style, a colour, a tooltip or an end
    column, so that shape would have forced the client layer back to a
    concrete marker class -- reopening exactly the SynEdit dependency the
    contract exists to close.
  --------------------------------------------------------------------------- }
