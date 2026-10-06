// ---------------------------------------------------------------------------
// Do the TVirtualImage conversion and the extracted PNGs actually work?
// ======================================================================
// Everything before this probe was text and arithmetic. f3_image_extract.py
// decoded 20 PNGs out of DataFrm.dfm and hashed them; f3_dfm_to_lfm.py renamed
// three `TVirtualImage` nodes to `TLclVirtualImage` and rewrote their
// `ImageCollection` references. Neither fact says an LCL reader can stream the
// result, or that the widgetset's PNG decoder accepts the bytes. This program
// is the thing that answers both.
//
// It streams the REAL generated file -- Source/Fpc/UI/Forms/ImageCollections.lfm
// -- rather than an LFM the probe writes itself. A hand-written fixture would
// agree with the control by construction and prove only that the control can be
// fed something shaped like what it expects; feeding it the converter's actual
// output is what makes a converter bug visible.
//
// WHAT IS ASSERTED, AND WHY EACH ONE
// ==================================
//   1. Every extracted PNG DECODES through LCL's own format registry
//      (TPicture.LoadFromFile -> graphics.pp's png.inc). f3_image_extract.py
//      proved the bytes are structurally a PNG; it says nothing about whether
//      the decoder agrees. A collection that fails to decode keeps a blank
//      placeholder at its index, so the failure is silent BY CONSTRUCTION and
//      only LoadFailures reports it.
//   2. Every PNG decodes to the EXACT width and height the manifest recorded.
//      The extractor read those from the IHDR chunk, the decoder reports them
//      independently: two readings of one file, compared to each other rather
//      than to themselves.
//   3. Every PNG HAS CONTENT. This is the check that matters most, and the one
//      this project has been wrong about three times -- "structurally fine,
//      draws nothing" was true of the SVG extraction (12x data loss), of the
//      SVG control's first version, and of the gate over both. A Count of 9
//      with nine blank cells passes every other assertion in this file.
//   4. Each streamed control is bound to a collection that EXISTS, is not
//      flagged CollectionMissing, and carries the ImageIndex the DFM gave it.
//   5. ImageName resolved the index. The LFM streams `ImageIndex = -1` BEFORE
//      `ImageName`, so the name is what picks the initial picture -- if
//      SetImageName did nothing, EnviroFrm's preview would sit empty.
//   6. ImageIndex = -1 paints nothing. EnviroFrm ships that value and the VCL
//      control treats it as "no image", not as an error; TCustomImage
//      .GetHasGraphic agrees. Nothing here is supposed to paint, and this
//      asserts the port did not quietly turn it into index 0.
//
// WHY THE CLASSES ARE REGISTERED BY HAND
// ======================================
// `RegisterClass` is not optional. A component reader resolves every class name
// through FindClass, and neither TLclVirtualImage nor the carrier class is one
// of the LCL's own -- LCLClasses registers the standard widgets, not ours.
//
// WHY THERE IS NO Application.Run
// ==============================
// Nothing here needs a message loop. `Interfaces` is still required because the
// PNG decoder calls into the widgetset, and Application.Initialize is still
// called so the canvas belongs to a live widgetset.
//
// WHY THE REPO ROOT IS FOUND BY WALKING UP
// =========================================
// A fixed relative path means the probe passes from one directory and fails
// from another with "file not found", which reads as missing data rather than
// as the wrong cwd. Walking up from the executable for a file that must exist
// (img_manifest.json) makes the probe runnable from anywhere, and the root it
// settled on is printed so a wrong one is visible.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

program ImgCollProbe;

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Classes, SysUtils, Types, Forms, Graphics, GraphType, LResources,
  ExtCtrls, LclVirtualImage, ImageCollectionData;

type
  // The carrier the generated fragment declares as its root. It has to exist
  // under exactly this name -- see emit_vimage_fragment() in
  // tools/f3_dfm_to_lfm.py, which is what writes `object VirtualImages:
  // TLclVirtualImages`.
  //
  // It used to be called TVirtualImageCarrier, which CONTAINS the VCL class
  // name it stands in for. tools/f3_imgcoll_check.py looks for surviving
  // `TVirtualImage` declarations, so the gate fired on this repository's own
  // probe fragment. The check was tightened; the name was changed as well,
  // because a substring collision is a trap for whoever reads this next.
  TLclVirtualImages = class(TComponent);

  // The class RESOLVER. `ReadComponentFromBinaryStream` calls
  // OnFindComponentClass unconditionally, with no nil guard, so passing nil is
  // not "use the default" -- it is a call through a nil method pointer, which
  // on this build hung instead of failing. The event is `of object`, so it
  // needs a host object; a plain function will not do.
  TClassResolver = class
    procedure Resolve(Reader: TReader; const AClassName: string;
                      var ComponentClass: TComponentClass);
  end;

procedure TClassResolver.Resolve(Reader: TReader; const AClassName: string;
  var ComponentClass: TComponentClass);
begin
  // FindClass, so a class that was never registered reports "Class
  // TLclVirtualImage not found" -- which is the truth and names the fix --
  // instead of silently resolving to something else.
  ComponentClass := TComponentClass(FindClass(AClassName));
  if ComponentClass = nil then
    raise EClassNotFound.CreateFmt('Class "%s" not found', [AClassName]);
end;

const
  // AnsiString: -Mdelphiunicode makes `string` a UnicodeString and TFileStream
  // still takes an AnsiString file name in this FPC.
  LFM_REL = 'Source\Fpc\UI\Forms\ImageCollections.lfm';
  MANIFEST_REL = 'Source\Fpc\UI\Data\img_manifest.json';

var
  Failures: Integer = 0;
  RepoRoot: string = '';
  Total: Integer = 0;

// Every line is flushed. The first run of this probe produced NO output at all
// before it was killed, and the only way to tell whether it was hung or merely
// buffered was to rebuild it -- a buffered writer makes a slow scan and a
// deadlock indistinguishable, which is the one distinction a probe exists to
// draw.
procedure Check(const What: string; Ok: Boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn('  OK   ', What, ' ', Detail)
  else
  begin
    WriteLn('  FAIL ', What, ' ', Detail);
    Inc(Failures);
  end;
  // Flushed after every check. A probe killed by a timeout reports NOTHING
  // about where it got to when stdout is a pipe, and the question "is this
  // scan slow, or is it deadlocked" is the first question every failure of this
  // program raises. Flushing thirty lines costs nothing.
  //
  // It is a Flush, not an unbuffered stream: FPC's `Output` is a text file
  // pointer here, so `Output.BufSize := 0` is an illegal qualifier, and
  // SetTextBuf(Output, nil) fails with "Can't assign values to an address".
  Flush(Output);
end;

// One level up, or '' at the root.
//
// Hand-rolled, and the reason is measured. Two things went wrong here first,
// and both are worth writing down because neither announces itself:
//
//   * `IncludeTrailingPathDelimiter('')` returns the SEPARATOR, not an empty
//     string. Feeding 'D:\' in therefore returned '\', feeding '\' in returned
//     '\' again, and the walk spun forever. The probe produced no output at all
//     for 400 seconds and looked exactly like a deadlock in the PNG decoder.
//   * Having fixed that, `LastDelimiter(S, '\/')` returned 1 for a path with
//     five separators in it -- verified in a standalone program, not guessed:
//       S = D:\Git\Dev-Cpp-Modern\Tests\FpcCoreTests\imgcoll  (len 48)
//       LastDelimiter(S, '\/') = 1   Copy(S,1,1) = 'D'
//     so the walk jumped straight to the drive root and gave up.
//
// A backwards character scan has neither problem and is five lines.
function ParentDir(const ADir: string): string;
var
  S: string;
  I: Integer;
begin
  S := ExcludeTrailingPathDelimiter(ADir);
  for I := Length(S) downto 1 do
    if (S[I] = '\') or (S[I] = '/') then
      Exit(IncludeTrailingPathDelimiter(Copy(S, 1, I)));
  Result := '';
end;

// Walk up from the executable until a file that must exist shows up.
function FindRepoRoot: string;
var
  D: string;
  Tried: string;
begin
  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Tried := '';
  while D <> '' do
  begin
    if FileExists(D + MANIFEST_REL) then
      Exit(D);
    Tried := Tried + #13#10 + '    tried: ' + D + MANIFEST_REL;
    D := ParentDir(D);
  end;
  // The candidates are reported rather than swallowed: a root walk that fails
  // looks exactly like missing data, and the one thing that tells them apart is
  // which paths were actually asked for.
  WriteLn('  walk from "', ExtractFilePath(ParamStr(0)), '" visited:', Tried);
  Result := '';
end;

// True when the image has something to show.
//
// Two tests, because the collections are not uniform: nineteen of the twenty
// PNGs are RGBA and one (EMBTWhite, PNG colour type 2) carries no alpha at
// all. For an alpha image, any non-zero alpha is content. For an opaque image
// alpha proves nothing, so the test becomes "not a single flat colour" -- a
// blank cell is blank everywhere, and these are desktop screenshots, so one
// differing pixel is already content.
//
// `Canvas.Colors` rather than `Bmp.ScanLine` was tried FIRST and abandoned: it is
// a virtual GetPixel through the interface image, and 3.4 million of them did
// not finish in 400 seconds. See the comment inside.
function HasContent(Bmp: TBitmap): Boolean;
var
  X, Y: Integer;
  P, First: PByte;
begin
  Result := False;
  // Direct ScanLine access, NOT Canvas.Colors. The first version of this
  // function used Colors[X,Y] -- a virtual GetPixel that goes through the
  // interface image -- over 3.4 million pixels, and the probe produced no
  // output at all for 400 seconds. ScanLine is a direct pointer read and the
  // same scan completes in well under a second.
  //
  // The cost is a "Symbol ScanLine is not portable" warning. This probe is
  // Windows-only for the same reason build_svg_probe.ps1 is: it drives the win32
  // widgetset, whose PNG decoder and whose 32-bit layout are what is under test.
  if Bmp.PixelFormat = pf32bit then
  begin
    for Y := 0 to Bmp.Height - 1 do
    begin
      P := Bmp.ScanLine[Y];
      for X := 0 to Bmp.Width - 1 do
        // Alpha is the fourth byte of BGRA.
        if P[X * 4 + 3] <> 0 then
          Exit(True);
    end;
    Exit(False);
  end;

  if Bmp.PixelFormat = pf24bit then
  begin
    First := Bmp.ScanLine[0];
    for Y := 0 to Bmp.Height - 1 do
    begin
      P := Bmp.ScanLine[Y];
      for X := 0 to Bmp.Width - 1 do
        if (P[X * 3] <> First[X * 3]) or (P[X * 3 + 1] <> First[X * 3 + 1]) or
           (P[X * 3 + 2] <> First[X * 3 + 2]) then
          Exit(True);
    end;
    Exit(False);
  end;

  // An unrecognised pixel format is reported rather than assumed. Failing here
  // would be a false alarm if a future decoder hands back something exotic;
  // passing silently would hide that it happened.
  WriteLn('       (unsupported pixel format ' + IntToStr(Ord(Bmp.PixelFormat)) +
      ' -- content NOT checked)');
  Result := True;
end;

procedure CheckPngs;
var
  C, It, BadDim, Blank, DecodeFail: Integer;
  Path: string;
  Pic: TPicture;
  Bmp: TBitmap;
begin
  WriteLn('PNG payload, decoded through LCL rather than through the extractor:');
  DecodeFail := 0;
  BadDim := 0;
  Blank := 0;
  Total := 0;
  for C := 0 to ImageCollectionCount - 1 do
    for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
    begin
      Path := ImageCollectionFileByIndex(IMAGE_COLLECTIONS[C].Name, It);
      Inc(Total);
      Pic := TPicture.Create;
      Bmp := nil;
      try
        try
          Pic.LoadFromFile(AnsiString(Path));
          // Drawn, not Assigned -- same reason the control draws: a PNG
          // decodes to a TFpImage and `TBitmap.Assign` rejects it with
          // "Cannot assign a TPicture to a TBitmap".
          Bmp := TBitmap.Create;
          Bmp.SetSize(Pic.Graphic.Width, Pic.Graphic.Height);
          Bmp.Canvas.Brush.Style := bsClear;
          Bmp.Canvas.FillRect(0, 0, Bmp.Width, Bmp.Height);
          Bmp.Canvas.Draw(0, 0, Pic.Graphic);
        except
          on E: Exception do
          begin
            Inc(DecodeFail);
            // Class AND message. The first version printed only E.ClassName and
            // every one of the 20 failures read "EConvertError" with no way to
            // tell a truncated file from a missing decoder from a colour
            // mismatch. A diagnosis you cannot act on is the same as no
            // diagnosis.
            WriteLn('       ', IMAGE_COLLECTIONS[C].Items[It].FileName, ': ',
                    AnsiString(E.ClassName), ': ',
                    AnsiString(E.Message));
          end;
        end;
        if Bmp <> nil then
        begin
          // Cross-check against the IHDR the extractor read: two independent
          // readings of the same file.
          if (Bmp.Width <> IMAGE_COLLECTIONS[C].Items[It].Width) or
             (Bmp.Height <> IMAGE_COLLECTIONS[C].Items[It].Height) then
          begin
            Inc(BadDim);
            WriteLn('       ', IMAGE_COLLECTIONS[C].Items[It].FileName, ': got ',
                    Bmp.Width, 'x', Bmp.Height, ', manifest says ',
                    IMAGE_COLLECTIONS[C].Items[It].Width, 'x',
                    IMAGE_COLLECTIONS[C].Items[It].Height);
          end;
          if not HasContent(Bmp) then
          begin
            Inc(Blank);
            WriteLn('       ', IMAGE_COLLECTIONS[C].Items[It].FileName, ': BLANK');
          end;
        end;
      finally
        Bmp.Free;
        Pic.Free;
      end;
    end;
  Check('every PNG decodes', DecodeFail = 0,
        Format('%d failed of %d', [DecodeFail, Total]));
  Check('every PNG matches the manifest size', BadDim = 0,
        Format('%d mismatched', [BadDim]));
  Check('every PNG has content', Blank = 0,
        Format('%d blank of %d', [Blank, Total]));
end;

procedure CheckCollection(const AName: string);
var
  L: TLclCollectionImageList;
  C, It, MaxW, MaxH: Integer;
begin
  L := CollectionImageList(AName);
  WriteLn('  ', AName, ':');
  if L = nil then
  begin
    Check('collection is known', False, 'CollectionImageList returned nil');
    Exit;
  end;
  Check('not Missing', not L.Missing);
  C := FindImageCollectionIndex(AName);
  MaxW := 0;
  MaxH := 0;
  for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
  begin
    if IMAGE_COLLECTIONS[C].Items[It].Width > MaxW then
      MaxW := IMAGE_COLLECTIONS[C].Items[It].Width;
    if IMAGE_COLLECTIONS[C].Items[It].Height > MaxH then
      MaxH := IMAGE_COLLECTIONS[C].Items[It].Height;
  end;
  Check('Count matches ImageCollectionData', L.Count = Length(IMAGE_COLLECTIONS[C].Items),
        Format('got %d, want %d', [L.Count, Length(IMAGE_COLLECTIONS[C].Items)]));
  Check('every item decoded', L.LoadFailures = 0,
        Format('got %d', [L.LoadFailures]));
  Check('cell covers the largest item', (L.Width >= MaxW) and (L.Height >= MaxH),
        Format('cell %dx%d, largest %dx%d', [L.Width, L.Height, MaxW, MaxH]));
end;

var
  Mem: TFileStream;
  Bin: TMemoryStream;
  Resolver: TClassResolver;
  Root: TComponent;
  I, C: Integer;
  V: TLclVirtualImage;
  WantColl: string;
  WantIndex: Integer;

  // Expectations are looked up BY NAME. Order in an LFM is not part of any
  // contract, and the sibling SVG probe failed once by indexing its expectation
  // array positionally -- it compared a subset against the wrong list and
  // reported failures that had nothing to do with the code under test.
  Expected: array[0..2] of record
    Name: string;
    Collection: string;
    Index: Integer;
  end;

function ExpectedFor(const AName: string; out Coll: string; out Idx: Integer): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(Expected) do
    if Expected[K].Name = AName then
    begin
      Coll := Expected[K].Collection;
      Idx := Expected[K].Index;
      Exit(True);
    end;
  Coll := '';
  Idx := 0;
  Result := False;
end;

begin
  // Unbuffered stdout. The first run of this probe produced NO output at all
  // before it was killed after 400 seconds, and the only way to tell a slow
  // scan from a deadlock was to rebuild it -- a buffered writer makes the two
  // indistinguishable, which is the one distinction a probe exists to draw.
  //
  RepoRoot := FindRepoRoot;
  if RepoRoot = '' then
  begin
    WriteLn('RESULT: could not find ', MANIFEST_REL, ' above ',
            ExtractFilePath(ParamStr(0)), ' -- FAIL');
    Halt(1);
  end;
  WriteLn('repo root: ', RepoRoot);
  SetImageCollectionRoot(RepoRoot + 'Source\Fpc\UI\Data\Images');
  WriteLn('image root: ', GetImageCollectionRoot);
  WriteLn;

  WriteLn('collections: ', ImageCollectionCount);
  for C := 0 to ImageCollectionCount - 1 do
    CheckCollection(IMAGE_COLLECTIONS[C].Name);
  WriteLn;

  CheckPngs;
  WriteLn;

  WriteLn('STREAMING ', LFM_REL);
  RegisterClass(TLclVirtualImages);
  RegisterClass(TLclVirtualImage);
  Resolver := TClassResolver.Create;
  Application.Initialize;

  Mem := TFileStream.Create(AnsiString(RepoRoot + LFM_REL),
                            fmOpenRead or fmShareDenyWrite);
  Bin := TMemoryStream.Create;
  try
    // LRSObjectTextToBinary then ReadComponentFromBinaryStream, rather than
    // ReadComponentFromTextStream. The combined helper does exactly these two,
    // and separating them is what tells a malformed fragment apart from one
    // that parses but instantiates wrongly.
    try
      LRSObjectTextToBinary(Mem, Bin);
    except
      on E: Exception do
      begin
        WriteLn('  PARSE raised ', E.ClassName, ': ', E.Message);
        Inc(Failures);
        Halt(1);
      end;
    end;
    Mem.Position := 0;
    Bin.Position := 0;
    Root := nil;
    try
      ReadComponentFromBinaryStream(Bin, Root, @Resolver.Resolve);
    except
      on E: Exception do
      begin
        WriteLn('  streaming raised ', E.ClassName, ': ', E.Message);
        Inc(Failures);
        Root := nil;
      end;
    end;
  finally
    Bin.Free;
    Mem.Free;
  end;
  if Root = nil then
  begin
    WriteLn('RESULT: the fragment streamed to a nil component -- FAIL');
    Halt(1);
  end;
  Resolver.Free;
  WriteLn('  streamed ', Root.ComponentCount, ' component(s)');
  WriteLn;

  // What the DFMs say, and one thing they say that is easy to get wrong.
  //
  // viThemePreview ships `ImageIndex = -1` with `ImageName = 'Windows
  // Classic'` -- but AppearanceThemeCollection's items are named
  // 'windows_classic', 'windows_10', 'slate_gray', ... so the name matches
  // NOTHING in the collection it is bound to. The VCL control looks the name
  // up, finds nothing, and paints no image; EnviroFrm's preview is therefore
  // blank until the user clicks a style in ListBoxStyle, which then assigns
  // ImageIndex directly.
  //
  // The first version of this expectation said 0 -- reasoning that the name
  // "should" resolve -- and the probe caught the port faithfully reproducing
  // a Delphi behaviour the expectation had not accounted for. The code was
  // right; the expectation was wrong. Recorded here because the wrong
  // expectation was the more plausible of the two.
  Expected[0].Name := 'viThemePreview';
  Expected[0].Collection := 'AppearanceThemeCollection';
  Expected[0].Index := -1;
  Expected[1].Name := 'VirtualImageTheme';
  Expected[1].Collection := 'ImageThemeColection';
  Expected[1].Index := 0;
  Expected[2].Name := 'ImageEmbarcadero';
  Expected[2].Collection := 'EMBTImageCollection';
  Expected[2].Index := 0;

  try
    Check('root is the carrier', Root is TLclVirtualImages);
    Check('three components', Root.ComponentCount = 3,
          Format('got %d', [Root.ComponentCount]));
    for I := 0 to Root.ComponentCount - 1 do
    begin
      if not (Root.Components[I] is TLclVirtualImage) then
      begin
        Check('component ' + IntToStr(I) + ' is a TLclVirtualImage', False,
              'got ' + Root.Components[I].ClassName);
        Continue;
      end;
      V := TLclVirtualImage(Root.Components[I]);
      if not ExpectedFor(V.Name, WantColl, WantIndex) then
      begin
        Check('component name is expected', False, V.Name);
        Continue;
      end;
      WriteLn('  ', V.Name, ':');
      Check('collection bound', not V.CollectionMissing);
      Check('Images attached', V.Images <> nil);
      if V.Images <> nil then
        Check('Images count matches the collection',
              V.Images.Count =
                Length(IMAGE_COLLECTIONS[FindImageCollectionIndex(WantColl)].Items),
              Format('got %d', [V.Images.Count]));
      Check('ImageIndex after streaming', V.ImageIndex = WantIndex,
            Format('got %d, want %d', [V.ImageIndex, WantIndex]));
      // viThemePreview is the one that legitimately shows nothing, because its
      // ImageName matches no item in the collection it names. The other two
      // must show their image.
      Check('HasGraphic at this index',
            V.HasGraphic = (WantIndex >= 0));

      // ImageIndex = -1 is a real state, not an error: the VCL paints nothing.
      V.ImageIndex := -1;
      Check('ImageIndex = -1 paints nothing', not V.HasGraphic);
      // Index 0 must paint for ALL THREE, including viThemePreview which
      // legitimately starts at -1. That is the assertion that separates "the
      // list works" from "the list works and this control is merely parked on
      // -1" -- restoring to WantIndex could not tell them apart when WantIndex
      // is itself -1, which is exactly the mistake the first version made.
      V.ImageIndex := 0;
      Check('index 0 paints', V.HasGraphic);
    end;
  finally
    Root.Free;
  end;

  WriteLn;
  if Failures = 0 then
    WriteLn('RESULT: the converted LFM streams and every PNG decodes with content')
  else
  begin
    WriteLn('RESULT: ', Failures, ' check(s) FAILED');
    Halt(1);
  end;
end.