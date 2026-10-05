unit LclSvgImageList;

// ---------------------------------------------------------------------------
// TLclSvgImageList -- an indexed image list backed by INLINE SVG sources.
//
// WHY IT IS A TCustomImageList
// =============================
// The first version was `TLclSvgImageList = class`, and that made the control
// unusable in two independent ways, both measured rather than argued:
//
//   1. Every LCL control's `Images` property is typed TCustomImageList
//      (measured across stdctrls/buttons/comctrls/extctrls). A plain class can
//      never be assigned to one, so all 70 `.Images` sites and 188 `ImageIndex`
//      sites would have had to be rewritten.
//   2. An LFM component must be a TComponent, or it cannot be streamed at all.
//
// The plan (doc section 4) proposed `class(TCustomImageList)` with a `GetImage`
// override, mirroring the VCL. That does NOT compile:
//
//     Error: There is no method in an ancestor class to be overridden: "GetImage"
//     Error: There is no method in an ancestor class to be overridden: "SetImage"
//     Error: There is no method in an ancestor class to be overridden: "GetCount"
//
// LCL's TCustomImageList has no virtual GetImage at all, and its GetCount is
// PRIVATE and NON-VIRTUAL (lcl/imglist.pp:302), so the per-index lazy hook the
// plan sketched cannot exist. `Count` reads the internal resolution list, which
// only `Add` grows.
//
// CONSEQUENCE, STATED RATHER THAN HIDDEN: the "rasterise on demand, cached by
// (index, width, height, theme)" design in section 4 is not implementable.
// This control rasterises a whole list when loaded and stores real bitmaps.
// Measured cost: all 116 icons across the five lists take 265 ms (see
// Tests/FpcCoreTests/svg/RasterProbe.lpr). Theme changes redo that. For
// 16-37 px glyphs that is the right trade against overriding a method that does
// not exist -- but it IS a change of design and it is recorded as one.
//
// WHAT RENDERS THE SVG
// ====================
// NOT `TSVGComponent` / `TSVGImage`, which doc section 2 called "built into
// FCL/LCL": fpvectorial.pas contains ZERO matches for TSVG\w*. The real path,
// verified by compiling and running it:
//
//     TvVectorialDocument.ReadFromStream(stream, vfSVG)
//     TvPage.Render(canvas, 0, 0, 1.0, 1.0)
//
// plus three registrations that live in OTHER units and fail confusingly when
// absent: `svgvectorialreader` (else "Unsupported vector graphics format"),
// `fpvectorial2canvas` (else no renderer), `Interfaces` (else EAccessViolation
// inside Render). The stream must carry UTF-8 BYTES -- a TStringStream under
// -Mdelphiunicode hands the parser UTF-16 and it reports
// "EXMLReadError ... Name starts with invalid character 0".
//
// WHAT IT STILL CANNOT DO
// ======================
//   * Theme RECOLOURING is not implemented. `ThemeChanged` re-renders with the
//     same colours.
//
// WHAT WAS FIXED HERE (2026-10-06), AND WHY THE FIX LIVES IN THE CONTROL
// =======================================================================
// 7 of the 116 icons used to raise EZeroDivide. Root cause established by
// measurement (see the note above StripDegenerateArcs): every one of them, and
// ONLY them, carries an arc segment whose two endpoints are the same point.
// The fault is in fpvectorial's endpoint-to-centre conversion, which divides
// by a denominator that is zero for exactly that case -- and it fires during
// ReadFromStream, i.e. inside the PARSE rather than the render.
//
// The normalisation is done HERE rather than in SvgData, because SvgData's
// contract is byte-for-byte identity with the DFM (`f3_svg_extract.py
// --verify`) and that is the check which caught two earlier data losses.
// Whoever hands text to the parser is the one who must make it parseable, so
// Rasterise normalises and the data stays untouched. RasterProbe still reports
// 7 -- it reads SvgData directly and deliberately bypasses this control --
// while SvgListProbe, which goes through the control, reports 0. Both are
// correct: they answer different questions.
//
// HOW IT ARRIVES FROM AN LFM (step 3)
// ===================================
// Converting `object X: TSVGIconImageList` to this class is NOT sufficient on
// its own, and the reason is worth writing down because nothing about it is
// visible in the LFM:
//
//   object SVGImageListMenuStyle: TSVGIconImageList
//     Size = 19
//     SVGIconItems = < item IconName = ... SVGText = ... end ... >
//   end
//
// becomes, after the conversion rule:
//
//   object SVGImageListMenuStyle: TLclSvgImageList
//     ListName = 'SVGImageListMenuStyle'
//   end
//
// The `SVGIconItems` payload is not "converted" into `SVGText[]`; it is DROPPED,
// because the bytes already live in SvgData and `f3_svg_extract.py --verify`
// keeps them identical to the DFM. Carrying them a second time would give the
// same fact two homes, and the extractor's round-trip gate would then only be
// checking one of them. `Size` goes with it for the same reason -- LoadFrom
// takes the edge from `AData.SizePx`.
//
// What makes that work is `ListName`. A component reader only ever calls
// Create and then assigns published properties, so a list that is only
// populated by `LoadFrom` streams as Count = 0 -- a window that opens with
// blank icons, which is the failure this entire work item exists to remove.
// `ListName`'s setter is therefore the streaming entry point: it looks the
// name up in SvgData and loads on the spot.
//
// The lookup failing is its own failure mode and is reported through
// `MissingData`, because "no such list" and "no icons" look identical from the
// outside and only one of them is a bug.
// ---------------------------------------------------------------------------

{$IFDEF FPC}

interface

uses
  Classes, SysUtils, Graphics, LCLType, ImgList, SvgData;

const
  // Used when the DFM declared no Size. Matches the vendored control's own
  // default (`property Size: Integer ... default 32`), so an undeclared list
  // renders the size it always did.
  DEFAULT_ICON_EDGE = 32;

type
  TLclSvgImageList = class(TCustomImageList)
  private
    FListName: string;
    // Sources are kept so `ThemeChanged` can re-render without going back to
    // SvgData. The DATA carries the authoritative pixel edge (19 / 18 / (none)
    // / 25 / 37); a name-matching if-chain would be a second copy of a
    // measurement that already exists and would degrade silently on rename.
    FSvg: array of string;
    FNames: array of string;
    FThemeGen: Integer;
    FRasterFailures: Integer;
    FMissingData: Boolean;
    procedure RenderAll;
    procedure SetListName(const AValue: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Populate from a SvgData record. Safe to call again (re-themes).
    procedure LoadFrom(const AData: TSvgImageList);
    // Re-render every icon. The generation counter exists so an in-flight
    // paint is never handed an image that was freed under it.
    procedure ThemeChanged;

    // Icons the renderer could not draw. Non-zero means the list is INCOMPLETE,
    // and the gap is deliberate rather than silent.
    property RasterFailures: Integer read FRasterFailures;
    property ThemeGen: Integer read FThemeGen;

    // True when ListName was set but no SvgData list carries that name. A
    // streamed list in this state is EMPTY, and an empty image list is the
    // exact failure this work item exists to remove -- so it is reported rather
    // than being indistinguishable from a list that legitimately has no icons.
    property MissingData: Boolean read FMissingData;
  published
    // MUST be published, not public.
    //
    // A component reader resolves property names through RTTI, and FPC emits
    // RTTI only for the published section. Declared public, the fragment
    // streams as far as `Error reading SVGImageListMenuStyle.ListName: Unknown
    // property: "ListName"` -- so the failure is loud rather than silent,
    // which is luck, not design: nothing about the LFM looks wrong and the
    // converter still reports success.
    property ListName: string read FListName write SetListName;
  end;

// Build the list whose data record is called AName (e.g.
// 'SVGImageListMenuStyle'), or nil when there is no such list.
//
// Matches on the LIST name because that is the handle that appears at a use
// site: the DFM assigns `dmMain.SVGImageListMenuStyle`, and no call site ever
// names an icon.
function CreateSvgImageList(const AName: string): TLclSvgImageList;

// Remove the arc segments whose endpoints coincide, from one SVG source.
//
// Exposed rather than kept private so SvgNorm can compare this FPC rewrite
// byte for byte against tools/f3_svg_zerochord.py's output: two implementations
// written from one description, checked against each other instead of against
// themselves.
function StripDegenerateArcs(const ASvg: string): string;

// How many of the extracted icons the renderer cannot draw, measured over the
// whole data set. Was 7 before the normaliser above; the smoke test asserts it
// as a CEILING so a regression is caught rather than absorbed.
function MeasureRasterFailures: Integer;

implementation

uses
  FPVectorial, svgvectorialreader, fpvectorial2canvas, Interfaces;

// ---------------------------------------------------------------------------
// StripDegenerateArcs -- why this control owes the parser valid input
// ====================================================================
// Seven of the 116 icons carried an arc segment whose start and end points are
// the SAME point, e.g. the trailing `a.06.06,0,0,1,0,0` of iconsnew-56.
// fpvectorial converts endpoint arcs with (fpvutils.pas:550)
//
//     m := (sqr(rx*ry) - sqr(rx*y1p) - sqr(ry*x1p)) / (sqr(rx*y1p) + sqr(ry*x1p));
//
// and for a zero-length chord x1p = y1p = 0, so the denominator is 0 while the
// numerator is (rx*ry)^2 > 0. The division runs BEFORE the SameValue guard one
// line below it, so the guard cannot help. EZeroDivide is raised inside
// ReadFromStream -- during the PARSE.
//
// Evidence, measured rather than reasoned:
//   tools/f3_svg_divzero.py  candidate `zero-chord-arc`: 7 in the failures,
//                            7 in all 116 -- a PERFECT SEPARATOR, where all 18
//                            text-shape candidates before it were not;
//   SvgParse.exe svg\failed  7/7 raise EZeroDivide with render removed;
//   SvgTry.exe svg\control   3/3 pass -- the judge is not blind;
//   SvgTry.exe svg\zerochord 7/7 pass after these arcs are removed.
//
// WHAT IS REMOVED, AND WHAT IT COSTS: only arcs with identical endpoints, and
// the largest removed radius renders to <= 0.142 px at its own list size, so
// nothing visible can be lost. The full-circle reading (endpoints equal AND
// large-arc set) was NOT settled against the spec -- the W3C pages came back
// truncated -- so it is recorded as unsettled rather than assumed away; every
// arc removed here has large-arc=0.
//
// The token walk mirrors tools/f3_svg_divzero.py's walk_path_groups, and SvgNorm
// diffs this function's bytes against that tool's output. Two implementations
// from one description, compared to each other -- not to themselves.
// ---------------------------------------------------------------------------
type
  TPathToken = record
    IsLetter: Boolean;
    Txt: string;
    Num: Double;
  end;
  TPathTokens = array of TPathToken;

function IsPathLetter(C: Char): Boolean;
begin
  Result := CharInSet(C, ['M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c',
    'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z']);
end;

function PathArgCount(UpCmd: Char): Integer;
begin
  case UpCmd of
    'Z': Result := 0;
    'H', 'V': Result := 1;
    'M', 'L', 'T': Result := 2;
    'Q', 'S': Result := 4;
    'C': Result := 6;
    'A': Result := 7;
  else
    Result := -1;
  end;
end;

// Split path data into command letters and numbers. Separators (whitespace,
// commas) are dropped because the output is rebuilt with spaces -- a comma
// lives in the GAP between tokens, so deleting tokens in place would leave one
// dangling in front of the next argument.
// Ok = False means the text was not fully tokenised. The caller must then
// return the path UNCHANGED: rebuilding from a truncated token list would
// silently drop the rest of the path, which is exactly the class of damage the
// byte-for-byte data contract exists to prevent.
procedure TokenizePath(const D: string; out Toks: TPathTokens; out Ok: Boolean);
var
  I, J, K, N, Code: Integer;
  S: string;
  V: Double;
  SeenDot: Boolean;
begin
  Ok := True;
  SetLength(Toks, 0);
  I := 1;
  N := Length(D);
  while I <= N do
  begin
    if IsPathLetter(D[I]) then
    begin
      SetLength(Toks, Length(Toks) + 1);
      Toks[High(Toks)].IsLetter := True;
      Toks[High(Toks)].Txt := D[I];
      Toks[High(Toks)].Num := 0;
      Inc(I);
      Continue;
    end;
    if CharInSet(D[I], ['0'..'9', '+', '-', '.']) then
    begin
      J := I;
      if CharInSet(D[J], ['+', '-']) then
        Inc(J);
      SeenDot := False;
      while (J <= N) and
        (CharInSet(D[J], ['0'..'9']) or ((D[J] = '.') and not SeenDot)) do
      begin
        if D[J] = '.' then
          SeenDot := True;
        Inc(J);
      end;
      if (J <= N) and CharInSet(D[J], ['e', 'E']) then
      begin
        K := J + 1;
        if (K <= N) and CharInSet(D[K], ['+', '-']) then
          Inc(K);
        if (K <= N) and CharInSet(D[K], ['0'..'9']) then
        begin
          J := K;
          while (J <= N) and CharInSet(D[J], ['0'..'9']) do
            Inc(J);
        end;
      end;
      S := Copy(D, I, J - I);
      Val(S, V, Code);
      if Code <> 0 then
      begin
        Ok := False; // cannot tokenise this text safely -- do not touch it
        SetLength(Toks, 0);
        Exit;
      end;
      SetLength(Toks, Length(Toks) + 1);
      Toks[High(Toks)].IsLetter := False;
      Toks[High(Toks)].Txt := S;
      Toks[High(Toks)].Num := V;
      I := J;
      Continue;
    end;
    Inc(I); // whitespace or comma
  end;
end;

function StripDPath(const D: string): string;
var
  Toks: TPathTokens;
  Drop: array of Boolean;
  Counts, Misses: array of Integer;
  I, J, K, ArgStart, ArgN, LetterIdx: Integer;
  Cmd, UpCmd: Char;
  Rel, Stop, Degenerate, AnyDrop, PrevNum, CurNum, First, Ok: Boolean;
  X, Y, SX, SY, XN, YN: Double;
  V: array[0..6] of Double;
begin
  TokenizePath(D, Toks, Ok);
  if not Ok then
    Exit(D);
  K := Length(Toks);
  SetLength(Drop, K);
  SetLength(Counts, K);
  SetLength(Misses, K);

  I := 0;
  Cmd := #0;
  LetterIdx := -1;
  X := 0; Y := 0; SX := 0; SY := 0;
  Stop := False;
  while (I < K) and not Stop do
  begin
    if Toks[I].IsLetter then
    begin
      Cmd := Toks[I].Txt[1];
      LetterIdx := I;
      Inc(I);
      if UpCase(Cmd) = 'Z' then
      begin
        X := SX;
        Y := SY;
        Cmd := #0;
        LetterIdx := -1;
      end;
      Continue;
    end;
    if Cmd = #0 then
      Break;
    Rel := CharInSet(Cmd, ['a'..'z']);
    UpCmd := UpCase(Cmd);
    ArgN := PathArgCount(UpCmd);
    if (ArgN < 0) or (I + ArgN > K) then
      Break;
    for J := 0 to ArgN - 1 do
      if Toks[I + J].IsLetter then
      begin
        Stop := True; // a command letter where an argument belongs
        Break;
      end;
    if Stop then
      Break;
    for J := 0 to ArgN - 1 do
      V[J] := Toks[I + J].Num;
    ArgStart := I;
    Inc(I, ArgN);
    Inc(Counts[LetterIdx]);
    Degenerate := False;
    if UpCmd = 'A' then
    begin
      if Rel then
      begin
        XN := X + V[5];
        YN := Y + V[6];
      end
      else
      begin
        XN := V[5];
        YN := V[6];
      end;
      Degenerate := (X = XN) and (Y = YN);
      X := XN;
      Y := YN;
    end
    else if UpCmd = 'M' then
    begin
      if Rel then
      begin
        X := X + V[0];
        Y := Y + V[1];
      end
      else
      begin
        X := V[0];
        Y := V[1];
      end;
      SX := X;
      SY := Y;
    end
    else if CharInSet(UpCmd, ['L', 'C', 'S', 'Q', 'T']) then
    begin
      if Rel then
      begin
        X := X + V[ArgN - 2];
        Y := Y + V[ArgN - 1];
      end
      else
      begin
        X := V[ArgN - 2];
        Y := V[ArgN - 1];
      end;
    end
    else if UpCmd = 'H' then
    begin
      if Rel then
        X := X + V[0]
      else
        X := V[0];
    end
    else if UpCmd = 'V' then
    begin
      if Rel then
        Y := Y + V[0]
      else
        Y := V[0];
    end;
    if Degenerate then
    begin
      Inc(Misses[LetterIdx]);
      for J := ArgStart to ArgStart + ArgN - 1 do
        Drop[J] := True;
    end;
  end;

  // The command letter is shared by every parameter set that follows it, so it
  // may only go when NOTHING under it survives.
  for I := 0 to K - 1 do
    if Toks[I].IsLetter and (Counts[I] > 0) and (Counts[I] = Misses[I]) then
      Drop[I] := True;

  AnyDrop := False;
  for I := 0 to K - 1 do
    if Drop[I] then
    begin
      AnyDrop := True;
      Break;
    end;
  if not AnyDrop then
    Exit(D); // untouched paths keep their exact bytes

  Result := '';
  First := True;
  PrevNum := False;
  for I := 0 to K - 1 do
  begin
    if Drop[I] then
      Continue;
    CurNum := not Toks[I].IsLetter;
    if (not First) and PrevNum and CurNum then
      Result := Result + ' ';
    Result := Result + Toks[I].Txt;
    PrevNum := CurNum;
    First := False;
  end;
end;

function StripDegenerateArcs(const ASvg: string): string;
var
  I, Q: Integer;
  D, NewD: string;
begin
  Result := ASvg;
  I := 1;
  while I <= Length(Result) - 3 do
  begin
    // `d="` must start an ATTRIBUTE name: in `id="..."` the same three
    // characters appear as a substring, and taking those for path data would
    // rewrite an id. The word-boundary test is what keeps them apart.
    if (Result[I] = 'd') and (Result[I + 1] = '=') and (Result[I + 2] = '"') and
      ((I = 1) or not CharInSet(Result[I - 1], ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
    begin
      Q := I + 3;
      while (Q <= Length(Result)) and (Result[Q] <> '"') do
        Inc(Q);
      if Q > Length(Result) then
        Break;
      D := Copy(Result, I + 3, Q - (I + 3));
      NewD := StripDPath(D);
      Result := Copy(Result, 1, I + 2) + NewD + Copy(Result, Q, MaxInt);
      I := I + 3 + Length(NewD); // points at the closing quote
    end;
    Inc(I);
  end;
end;

// Render one SVG into a new transparent TBitmap of AEdge x AEdge.
// Returns nil when the renderer raises, which it does for some inputs.
function Rasterise(const ASvg: string; AEdge: Integer): TBitmap;
var
  Doc: TvVectorialDocument;
  Stream: TMemoryStream;
  Utf8: TBytes;
  Bmp: TBitmap;
  Canvas: TCanvas;
begin
  Result := nil;
  Doc := nil;
  Stream := nil;
  Bmp := nil;
  try
    try
      // The ONE point where source text enters the parser, and therefore the
      // one place that owes the parser valid input -- see StripDegenerateArcs.
      Utf8 := TEncoding.UTF8.GetBytes(StripDegenerateArcs(ASvg));
      Stream := TMemoryStream.Create;
      if Length(Utf8) > 0 then
        Stream.WriteBuffer(Utf8[0], Length(Utf8));
      Stream.Position := 0;
      Doc := TvVectorialDocument.Create;
      Doc.ReadFromStream(Stream, vfSVG);
      if Doc.GetPageCount = 0 then
        Exit(nil);
      Bmp := TBitmap.Create;
      Bmp.SetSize(AEdge, AEdge);
      Canvas := Bmp.Canvas;
      // bsClear, not Brush.Color := clNone: clNone is a TFPColor here and
      // Brush.Color wants a TGraphicsColor, so that assignment is a type error.
      Canvas.Brush.Style := bsClear;
      Canvas.FillRect(0, 0, AEdge, AEdge);
      Doc.GetPageAsVectorial(0).Render(Canvas, 0, 0, 1.0, 1.0);
      Result := Bmp;
      // Ownership moves to the caller, so do not free it in the finally below.
      Bmp := nil;
    finally
      Bmp.Free;
      Doc.Free;
      Stream.Free;
    end;
  except
    // One unrenderable icon must not cost the list its other icons. Counting it
    // is what makes that loss visible instead of quiet.
    Result := nil;
  end;
end;

constructor TLclSvgImageList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRasterFailures := 0;
  FMissingData := False;
end;

destructor TLclSvgImageList.Destroy;
begin
  inherited Destroy;
end;

procedure TLclSvgImageList.RenderAll;
var
  I, Edge: Integer;
  Bmp: TBitmap;
begin
  // BeginUpdate/EndUpdate because TCustomImageList notifies the widgetset on
  // every Add; without them an 85-icon list repaints 85 times.
  BeginUpdate;
  try
    Clear;
    FRasterFailures := 0;
    Edge := Width;
    for I := 0 to High(FSvg) do
    begin
      Bmp := Rasterise(FSvg[I], Edge);
      if Bmp = nil then
      begin
        Inc(FRasterFailures);
        Continue;
      end;
      try
        // Add COPIES the pixels, so the bitmap is disposable immediately.
        Add(Bmp, nil);
      finally
        Bmp.Free;
      end;
    end;
  finally
    EndUpdate;
  end;
  Inc(FThemeGen);
end;

procedure TLclSvgImageList.LoadFrom(const AData: TSvgImageList);
var
  I, Edge: Integer;
begin
  FListName := AData.Name;
  SetLength(FSvg, Length(AData.Svg));
  SetLength(FNames, Length(AData.Names));
  for I := 0 to High(AData.Svg) do
  begin
    FSvg[I] := AData.Svg[I];
    if I <= High(AData.Names) then
      FNames[I] := AData.Names[I];
  end;

  // The edge comes from the DATA. SizePx = 0 means the DFM declared none, so
  // the control's own default applies -- as the vendored control did.
  Edge := AData.SizePx;
  if Edge <= 0 then
    Edge := DEFAULT_ICON_EDGE;
  // TCustomImageList spells it Width/Height, NOT Size. Writing `Size` here
  // compiles under neither tree.
  Width := Edge;
  Height := Edge;

  FMissingData := False;
  RenderAll;
end;

procedure TLclSvgImageList.SetListName(const AValue: string);
var
  Idx: Integer;
begin
  // Assign before the lookup so LoadFrom's own `FListName := AData.Name` lands
  // on the same value, and so re-assigning the same name is a no-op rather than
  // a 265 ms re-render.
  if FListName = AValue then
    Exit;
  FListName := AValue;
  FMissingData := False;
  if FListName = '' then
    Exit;
  Idx := FindSvgListIndex(FListName);
  if Idx < 0 then
  begin
    // No such list in SvgData. Leave Count at 0 and SAY SO -- a silent empty
    // list is indistinguishable from a working one until a user stares at a
    // blank toolbar.
    FMissingData := True;
    Exit;
  end;
  LoadFrom(SVG_IMAGE_LISTS[Idx]);
end;

procedure TLclSvgImageList.ThemeChanged;
begin
  // Re-render rather than free: a toolbar can be mid-paint, and dropping the
  // bitmaps out from under it is the crash this avoids.
  RenderAll;
end;

function CreateSvgImageList(const AName: string): TLclSvgImageList;
var
  Idx: Integer;
begin
  Result := nil;
  Idx := FindSvgListIndex(AName);
  if Idx < 0 then
    Exit(nil);
  Result := TLclSvgImageList.Create(nil);
  try
    Result.LoadFrom(SVG_IMAGE_LISTS[Idx]);
  except
    Result.Free;
    Result := nil;
  end;
end;

function MeasureRasterFailures: Integer;
var
  L: TLclSvgImageList;
  I: Integer;
begin
  Result := 0;
  for I := 0 to SvgListCount - 1 do
  begin
    L := TLclSvgImageList.Create(nil);
    try
      L.LoadFrom(SVG_IMAGE_LISTS[I]);
      Inc(Result, L.RasterFailures);
    finally
      L.Free;
    end;
  end;
end;

end.

{$ENDIF}
