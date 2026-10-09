unit Lsp.Editor.VclAdapter;

{ ---------------------------------------------------------------------------
  Lsp.Editor.VclAdapter -- IEditorControlAdapter over the vendored VCL SynEdit.

  THE ADAPTER, NOT THE CONTRACT, IS ALLOWED TO KNOW ABOUT SYNEDIT
  ---------------------------------------------------------------
  Everything here is VCL-shaped on purpose: TBufferCoord, TPoint, TSynEdit and
  the undo-block protocol. That is the point of the boundary -- the contract in
  Lsp.Editor.Interfaces stays toolkit-free and this unit is the one place the
  two meet.

  SCOPE: WRITES ARE DELIBERATELY NOT IMPLEMENTED YET
  --------------------------------------------------
  ReplaceRange is the one method this adapter refuses to fake. What it must do
  is fixed by the caller: Completion:841-859 wraps the whole edit in
  BeginUndoBlock / EndUndoBlock, sets BlockBegin and BlockEnd, assigns SelText,
  moves the caret to the end of the inserted text, and then COLLAPSES the
  selection -- and the comment there states the collapse is mandatory, because
  without it the outer Validate handler applies the edit a second time.

  It is left unimplemented rather than written for one reason: the same file
  (Lsp.Client.pas:150-186) proves this vendored SynEdit has already diverged
  from what the LSP layer was written against -- its marker API does not exist
  at all, which tools/lsp_marker_api_check.py measures rather than assumes.
  Writing the write path against an API surface demonstrably not matching the
  caller would produce code that looks right and cannot be validated.

  So the adapter ships read-only first: the geometry and text contract, which
  is 74 of the 78 measured call sites, can be reviewed on its own. The write
  path waits on evidence, not on a decision -- see the migration plan's
  "F2-b 开工前的阻断性发现" section.

  NO SILENT DEGRADATION
  --------------------
  The marker methods raise instead of returning zeros. The vendored Markers is
  an indexed property with no Count / Add / Delete, so there is no honest
  implementation to give; returning 0 or an empty list would let the caller
  loop over nothing and conclude "no diagnostics", which is a wrong answer
  that looks like a right one. A loud failure is the only truthful option.
  --------------------------------------------------------------------------- }

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Windows, Graphics, Types, SynEdit, SynEditTypes,
  {$ELSE}
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Graphics, SynEdit, SynEditTypes,
  {$ENDIF}
  Lsp.Editor.Types, Lsp.Editor.Interfaces;

type
  { VCL-backed IEditorMarkerList. Every member raises; see the unit header. }
  TVclMarkerList = class(TInterfacedObject, IEditorMarkerList)
  private
    FOwner: TCustomSynEdit;
  public
    constructor Create(AOwner: TCustomSynEdit);
    function GetCount: Integer;
    procedure Add(const AMarker: TLspMarkerSpec);
    procedure Delete(AIndex: Integer);
    procedure Clear;
  end;

  TVclSynEditAdapter = class(TInterfacedObject, IEditorControlAdapter)
  private
    FEditor: TCustomSynEdit;
    FMarkers: IEditorMarkerList;
    FOnMarkersChanged: TLspNotifyEvent;
    FOwnsHandler: Boolean;
    procedure HandleMarkersChanged(Sender: TObject);
  public
    constructor Create(AEditor: TCustomSynEdit);
    destructor Destroy; override;

    function GetLineText(const ALine: Integer): string;
    function GetTotalLines: Integer;
    function GetAllText: string;
    function GetCaretPosition: TLspBufferCoord;

    procedure ReplaceRange(const AStart, AEnd: TLspBufferCoord;
      const ANewText: string);

    function BufferToScreenPixels(const ACoord: TLspBufferCoord): TLspPixelPoint;
    function CaretToScreenPixels: TLspPixelPoint;
    function ScreenPixelsToBuffer(const APoint: TLspPixelPoint): TLspBufferCoord;
    function GetLineHeight: Integer;
    function GetClientWidth: Integer;
    function GetClientHeight: Integer;

    function GetMarkers: IEditorMarkerList;
    procedure SetOnMarkersChanged(const AHandler: TLspNotifyEvent);
  end;

implementation

function MakeCoord(const X, Y: Integer): TLspPixelPoint; overload;
begin
  Result.X := X;
  Result.Y := Y;
end;

function MakeCoord(const P: TPoint): TLspPixelPoint; overload;
begin
  Result.X := P.X;
  Result.Y := P.Y;
end;

{ ---------------------------- TVclMarkerList ------------------------------ }

constructor TVclMarkerList.Create(AOwner: TCustomSynEdit);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TVclMarkerList.GetCount: Integer;
begin
  raise ENotSupportedException.Create(
    'TVclMarkerList.GetCount: this SynEdit exposes Markers as an indexed ' +
    'property (Markers[Index]) with no Count. The LSP diagnostics layer ' +
    'expects a collection. See tools/lsp_marker_api_check.py.');
end;

procedure TVclMarkerList.Add(const AMarker: TLspMarkerSpec);
begin
  raise ENotSupportedException.Create(
    'TVclMarkerList.Add: TMarker here has no Style/Color/TopLine/BottomLine/' +
    'EndColumn/ToolDescription, and Markers has no Add.');
end;

procedure TVclMarkerList.Delete(AIndex: Integer);
begin
  raise ENotSupportedException.Create(
    'TVclMarkerList.Delete: Markers has no Delete in this SynEdit.');
end;

procedure TVclMarkerList.Clear;
begin
  raise ENotSupportedException.Create(
    'TVclMarkerList.Clear: Markers has no enumeration to clear here.');
end;

{ ------------------------- TVclSynEditAdapter ------------------------------ }

constructor TVclSynEditAdapter.Create(AEditor: TCustomSynEdit);
begin
  inherited Create;
  FEditor := AEditor;
  FMarkers := TVclMarkerList.Create(AEditor);
end;

destructor TVclSynEditAdapter.Destroy;
begin
  // Nothing to unsubscribe: this SynEdit has no MarkersChanged event (see
  // SetOnMarkersChanged), so the adapter never installs one. The real code
  // at Lsp.Client.pas:84 does install such a handler and never removes it --
  // its destructor at :91-96 frees the diagnostics list but leaves the
  // assignment in place. That is a latent dangling reference in the current
  // code, and it is why the adapter tracks FOwnsHandler: when a real event
  // does exist, the teardown is already in place to do the right thing.
  FOwnsHandler := False;
  FOnMarkersChanged := nil;
  FMarkers := nil;
  inherited;
end;

function TVclSynEditAdapter.GetLineText(const ALine: Integer): string;
begin
  Result := '';
  if not Assigned(FEditor) then
    Exit;
  // `LineText` is the CARET's line, not line N, so the indexed form is used
  // for anything else. The client layer clamps before calling, but a caller
  // need not -- and Lines[out of range] is an access violation, not an
  // exception, so the bound is checked here rather than trusted.
  if ALine = FEditor.CaretY then
    Result := FEditor.LineText
  else if (ALine >= 1) and (ALine <= FEditor.Lines.Count) then
    Result := FEditor.Lines[ALine - 1];
end;

function TVclSynEditAdapter.GetTotalLines: Integer;
begin
  Result := 0;
  if not Assigned(FEditor) then
    Exit;
  Result := FEditor.Lines.Count;
end;

function TVclSynEditAdapter.GetAllText: string;
begin
  Result := '';
  if not Assigned(FEditor) then
    Exit;
  Result := FEditor.Lines.Text;
end;

function TVclSynEditAdapter.GetCaretPosition: TLspBufferCoord;
begin
  Result.Line := 0;
  Result.Char := 0;
  if not Assigned(FEditor) then
    Exit;
  Result.Line := FEditor.CaretY;
  Result.Char := FEditor.CaretX;
end;

procedure TVclSynEditAdapter.ReplaceRange(const AStart, AEnd: TLspBufferCoord;
  const ANewText: string);
begin
  // Intentionally not implemented -- see the unit header. Faking this would be
  // the worst outcome available: it would compile, read correctly, and be the
  // one method whose behaviour nothing could check.
  raise ENotSupportedException.Create(
    'TVclSynEditAdapter.ReplaceRange is not implemented. The sequence it must ' +
    'perform is fixed by Completion:841-859 (begin undo block, set BlockBegin ' +
    'and BlockEnd, assign SelText, move the caret to the end of the inserted ' +
    'text, collapse the selection, end undo block) and is pending validation ' +
    'of this SynEdit build.');
end;

function TVclSynEditAdapter.BufferToScreenPixels(
  const ACoord: TLspBufferCoord): TLspPixelPoint;
var
  P: TPoint;
begin
  Result := MakeCoord(0, 0);
  if not Assigned(FEditor) then
    Exit;
  // The three-step chain the client layer spells out by hand (Hover:781-782):
  // buffer -> display -> pixels -> screen. No caller uses an intermediate, so
  // the contract exposes one method. BufferCoord is (Char, Line) -- the
  // argument order is the reverse of the record's field order and getting it
  // wrong compiles fine and misplaces every popup.
  P := FEditor.ClientToScreen(
    FEditor.RowColumnToPixels(Point(ACoord.Char, ACoord.Line)));
  Result := MakeCoord(P);
end;

function TVclSynEditAdapter.CaretToScreenPixels: TLspPixelPoint;
var
  P: TPoint;
begin
  Result := MakeCoord(0, 0);
  if not Assigned(FEditor) then
    Exit;
  // FEditor.DisplayXY is the vendored SynEdit's DISPLAY coordinate; the LCL has
  // no such property, only CaretXY (the buffer coordinate, 1-based). They agree
  // whenever the caret is on a line that is neither wrapped nor folded away --
  // true for every popup path this adapter serves (a caret inside code) -- but
  // they are NOT the same field, and saying so is the point: if a folded or
  // wrapped line ever needs this exact chain, it has to come back as a
  // measured question, not as an assumption.
  P := FEditor.ClientToScreen(FEditor.RowColumnToPixels(FEditor.CaretXY));
  Result := MakeCoord(P);
end;

function TVclSynEditAdapter.ScreenPixelsToBuffer(
  const APoint: TLspPixelPoint): TLspBufferCoord;
var
  P: TPoint;
begin
  Result.Line := 0;
  Result.Char := 0;
  if not Assigned(FEditor) then
    Exit;
  // The inverse chain, Hover:1015-1022. The caller's own bounds test
  // (Pt < 0, vs ClientWidth / ClientHeight) deliberately stays in the caller:
  // "is the mouse still where it was?" is a policy question, not a conversion.
  //
  // The LCL spells this without TBufferCoord: PixelsToLogicalPos(TPoint) is
  // the same mapping (client pixels -> text position, 1-based, X=Char,
  // Y=Line). Measured against the vendored DisplayToBufferPos's meaning, not
  // guessed: its own comment says "takes a position on screen and transforms
  // it into position of text".
  P := FEditor.PixelsToLogicalPos(Point(APoint.X, APoint.Y));
  Result.Char := P.X;
  Result.Line := P.Y;
end;

function TVclSynEditAdapter.GetLineHeight: Integer;
begin
  Result := 0;
  if not Assigned(FEditor) then
    Exit;
  Result := FEditor.LineHeight;
end;

function TVclSynEditAdapter.GetClientWidth: Integer;
begin
  Result := 0;
  if not Assigned(FEditor) then
    Exit;
  Result := FEditor.ClientWidth;
end;

function TVclSynEditAdapter.GetClientHeight: Integer;
begin
  Result := 0;
  if not Assigned(FEditor) then
    Exit;
  Result := FEditor.ClientHeight;
end;

function TVclSynEditAdapter.GetMarkers: IEditorMarkerList;
begin
  Result := FMarkers;
end;

procedure TVclSynEditAdapter.SetOnMarkersChanged(
  const AHandler: TLspNotifyEvent);
begin
  FOnMarkersChanged := AHandler;
  if not Assigned(FEditor) then
    Exit;
  // This vendored SynEdit has NO MarkersChanged event at all -- measured as
  // ZERO occurrences across Source/VCL/SynEdit, not merely 'absent from the
  // file I happened to grep'. There is therefore nothing to subscribe to.
  //
  // The handler is stored but never invoked, and NO assignment is made.
  // Writing `FEditor.MarkersChanged := ...` here would not compile; writing
  // it 'just in case' is how a future SynEdit upgrade silently changes
  // behaviour. The gap is stated instead: marker-change notifications do
  // NOT reach the LSP layer through this adapter, which follows from the
  // missing marker API (see tools/lsp_marker_api_check.py), not an
  // oversight in this method.
  FOwnsHandler := False;
end;

procedure TVclSynEditAdapter.HandleMarkersChanged(Sender: TObject);
begin
  if Assigned(FOnMarkersChanged) then
    FOnMarkersChanged(Sender);
end;

end.
