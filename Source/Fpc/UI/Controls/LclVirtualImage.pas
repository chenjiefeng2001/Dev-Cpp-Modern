unit LclVirtualImage;

// ---------------------------------------------------------------------------
// TLclVirtualImage -- LCL stand-in for Vcl.VirtualImage.TVirtualImage.
//
// WHY A NEW CONTROL AT ALL
// ========================
// The roadmap called this "external, LCL has an equivalent, field-level
// rename". Reading the three use sites says otherwise, and the reason is the
// PAYLOAD, not the class:
//
//   EnviroFrm.viThemePreview   ImageCollection = dmMain.AppearanceThemeCollection
//   LangFrm.VirtualImageTheme  ImageCollection = dmMain.ImageThemeColection
//   main.ImageEmbarcadero      ImageCollection = dmMain.EMBTImageCollection
//
// All three are named-image FETCHERS over a Vcl.ImageCollection.TImageCollection
// whose 20 inline PNGs (458,644 bytes) live in DataFrm.dfm. LCL's TImage has
// Picture and nothing named -- so the rename does not compile, and renaming it
// to something that does compile would compile and then draw nothing.
//
// WHY IT ADDS ALMOST NO CODE
// ==========================
// Measured against c:/lazarus/lcl/include/customimage.inc before writing this,
// and the result changed the design:
//
//   TCustomImage already publishes `Images: TCustomImageList`, `ImageIndex`,
//   `ImageWidth` and `Proportional`. TCustomImage.GetHasGraphic reads
//
//       Result := Assigned(Picture.Graphic) or (Assigned(Images) and (ImageIndex >= 0));
//
//   so LCL ALREADY treats ImageIndex = -1 as "paint nothing" -- which is
//   exactly what EnviroFrm ships and what the VCL does. And EnviroFrm.pas:245,
//   LangFrm.pas:157, LangFrm.pas:235 and main.pas:7404 all drive these controls
//   by assigning ImageIndex.
//
//   So the whole replacement is: put the extracted PNGs into a
//   TCustomImageList, attach it to the inherited `Images`, and add two
//   properties the VCL control had that TImage does not (ImageCollection,
//   ImageName). The .pas call sites need NO EDITS AT ALL.
//
// THE ONE LCL/VCL DEFAULT THAT DIFFERS
// =====================================
// TCustomImage.Create sets `FProportional := False`; TVirtualImage letterboxes.
// LangFrm.VirtualImageTheme is 383x103 on screen over a 671x250 source, so with
// Proportional off it would be squashed. Set in Create rather than in the LFM
// because that is a property of the class, not of a site.
//
// `ImageHeight` HAS NO LCL COUNTERPART and the converter drops it. All three
// sites set it to 0, which in the VCL means "use the source size" -- and the
// probe asserts the dropped value was 0 on every site, so the day a site sets a
// real height the gate fails rather than the preview resizing wrongly.
//
// WHERE THE PNGs COME FROM
// ========================
// Source/Fpc/UI/Data/Images/, extracted byte-for-byte from DataFrm.dfm by
// tools/f3_image_extract.py. The images are FILES, not a generated unit,
// because FPC cannot express them as constants:
//
//     BigData.pas(6,3) Error: Incompatible types: got "Constant String" expected "Byte"
//
// STREAMING ORDER, WHICH IS NOT OBVIOUS
// ======================================
// A component reader assigns properties in FILE order, and the DFM writes
//
//     ImageCollection = dmMain.AppearanceThemeCollection
//     ImageWidth = 0
//     ImageHeight = 0
//     ImageIndex = -1
//     ImageName = 'Windows Classic'
//
// with ImageName LAST. So ImageName is not decorative -- it is what resolves
// the initial picture, because ImageIndex arrives as -1 first. In the VCL
// setting an item's name moves the index with it; SetImageName does the same
// here, which is why LangFrm (index 0, name 'Windows Classic') and main
// (index 0, name 'EMBTBlack') agree, and why EnviroFrm still shows its classic
// preview before the user clicks the list.
// ---------------------------------------------------------------------------

{$IFDEF FPC}

interface

uses
  Classes, SysUtils, Graphics, ImgList, ExtCtrls, ImageCollectionData;

type
  // One TImageCollection's PNGs as an indexed image list.
  //
  // A TCustomImageList gives every image in it the SAME cell size, and these
  // collections are not uniform: ImageThemeColection measures 671x250 six times,
  // 670x250 twice and 672x250 once. The cell is therefore sized to the largest
  // image in the collection and each bitmap is placed into it, so index N
  // always means item N no matter which size that item happens to be.
  TLclCollectionImageList = class(TCustomImageList)
  private
    FCollectionName: string;
    FFailures: Integer;
    FMissing: Boolean;
    procedure LoadAll;
  public
    constructor CreateForCollection(AOwner: TComponent; const AName: string);
    // Items that failed to load. Non-zero means the list is INCOMPLETE and the
    // count is reported rather than the gap being absorbed.
    property LoadFailures: Integer read FFailures;
    // No such collection in ImageCollectionData. Distinct from an empty list.
    property Missing: Boolean read FMissing;
  end;

  TLclVirtualImage = class(TImage)
  private
    FImageCollection: string;
    FImageName: string;
    FCollectionMissing: Boolean;
    procedure SetImageCollection(const AValue: string);
    procedure SetImageName(const AValue: string);
  public
    constructor Create(AOwner: TComponent); override;
    // True when ImageCollection names a collection ImageCollectionData does
    // not have. Distinct from "the list is empty": one is a typo in the LFM or
    // in code, the other is a collection nobody has opened yet.
    property CollectionMissing: Boolean read FCollectionMissing;
  published
    // MUST be published: a reader resolves property names through RTTI, and a
    // public declaration streams as "Unknown property".
    property ImageCollection: string read FImageCollection write SetImageCollection;
    property ImageName: string read FImageName write SetImageName;
  end;

// The cached list for a collection, built on first use. Callers get a shared
// instance and must NOT free it; the lists live until finalization so that a
// control freed during form teardown never leaves a dangling `Images`.
function CollectionImageList(const AName: string): TLclCollectionImageList;

// Where the extracted PNGs live, as a directory without a trailing separator.
// Unset means <exe dir>/images. Exists because the probes run from their own
// directory and a portable install needs to point elsewhere.
procedure SetImageCollectionRoot(const ADir: string);
function GetImageCollectionRoot: string;

// Absolute path of one item's PNG, or '' when the collection or index is
// unknown. Exposed so a probe can check the path without decoding pixels.
function ImageCollectionFileByIndex(const ACollection: string; AIndex: Integer): string;
function ImageCollectionFile(const ACollection, AItemName: string): string;

// Free every cached list. Only for tests that want a clean slate.
procedure FlushCollectionImageLists;

implementation

// Turn a forward-slash relative path into the platform's separator.
//
// Written as a character walk rather than
// `StringReplace(S, '/', PathDelim, [rfReplaceAll])` because PathDelim is a
// Char while '/' is an AnsiString literal, so the StringReplace call resolves
// to the AnsiString overload and the compiler reports a lossy implicit
// conversion at every call site (measured: three warnings, one per use).
function NativePath(const AFwd: string): string;
var
  I: Integer;
begin
  Result := AFwd;
  for I := 1 to Length(Result) do
    if Result[I] = '/' then
      Result[I] := PathDelim;
end;

var
  FImageRoot: string = '';
  FLists: array of TLclCollectionImageList;
  FListsBuilt: Boolean = False;

procedure SetImageCollectionRoot(const ADir: string);
begin
  if FImageRoot = IncludeTrailingPathDelimiter(ADir) then
    Exit;
  FImageRoot := IncludeTrailingPathDelimiter(ADir);
  // The lists already decoded their PNGs from the old root, so they are now
  // stale. Dropping them here is what stops a second root from silently
  // showing the first one's images.
  FlushCollectionImageLists;
end;

function GetImageCollectionRoot: string;
begin
  if FImageRoot <> '' then
    Exit(FImageRoot);
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'images';
end;

function ImageCollectionFileByIndex(const ACollection: string; AIndex: Integer): string;
var
  C: Integer;
begin
  Result := '';
  C := FindImageCollectionIndex(ACollection);
  if C < 0 then
    Exit;
  if (AIndex < 0) or (AIndex > High(IMAGE_COLLECTIONS[C].Items)) then
    Exit;
  Result := GetImageCollectionRoot +
    NativePath(IMAGE_COLLECTIONS[C].Items[AIndex].FileName);
end;

function ImageCollectionFile(const ACollection, AItemName: string): string;
var
  C, It: Integer;
begin
  Result := '';
  C := FindImageCollectionIndex(ACollection);
  if C < 0 then
    Exit;
  for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
    if IMAGE_COLLECTIONS[C].Items[It].Name = AItemName then
      Exit(ImageCollectionFileByIndex(ACollection, It));
end;

procedure LargestIn(const C: Integer; out AWidth, AHeight: Integer);
var
  It: Integer;
begin
  AWidth := 0;
  AHeight := 0;
  for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
  begin
    if IMAGE_COLLECTIONS[C].Items[It].Width > AWidth then
      AWidth := IMAGE_COLLECTIONS[C].Items[It].Width;
    if IMAGE_COLLECTIONS[C].Items[It].Height > AHeight then
      AHeight := IMAGE_COLLECTIONS[C].Items[It].Height;
  end;
end;

procedure TLclCollectionImageList.LoadAll;
var
  C, It, CellW, CellH: Integer;
  Path: string;
  Bmp, Padded: TBitmap;
  Pic: TPicture;
begin
  FFailures := 0;
  FMissing := False;
  C := FindImageCollectionIndex(FCollectionName);
  if C < 0 then
  begin
    FMissing := True;
    Exit;
  end;

  LargestIn(C, CellW, CellH);
  Width := CellW;
  Height := CellH;

  // BeginUpdate/EndUpdate because Add notifies the widgetset on every call;
  // without it an N-image list repaints N times.
  BeginUpdate;
  try
    Clear;
    for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
    begin
      Path := GetImageCollectionRoot +
        NativePath(IMAGE_COLLECTIONS[C].Items[It].FileName);
      Bmp := nil;
      // Decode through TPicture.LoadFromFile rather than reading the bytes and
      // wrapping them here. That dispatches through LCL's OWN format registry
      // (TPicture.LoadFromFile picks the reader from the extension, and
      // graphics.pp includes png.inc unconditionally), which is the same path
      // the application takes. A local fcl-image decode would be a different
      // code path, so a PNG this accepted could still be one the app rejects.
      Pic := TPicture.Create;
      try
        try
          // AnsiString(...) at the LCL boundary, deliberately. The LCL units on
          // this machine were built by lazbuild with `{$H+}`, so the `string`
          // inside their .ppu is AnsiString, while every unit of THIS project
          // is compiled with -Mdelphiunicode and so spells `string` as
          // UnicodeString. FPC therefore reports a lossy implicit conversion at
          // every crossing. It is written out rather than silenced: these are
          // ASCII file paths, and an explicit cast says so where a reader can
          // check it.
          Pic.LoadFromFile(AnsiString(Path));
          if Pic.Graphic = nil then
          begin
            // Fixed text, deliberately. This exception is caught three lines
            // below and turned into a LoadFailures count, and the probe names
            // the offending file from the manifest. Interpolating Path here
            // only buys a UnicodeString<->AnsiString round trip at the SysUtils
            // boundary -- measured as two compiler warnings for no runtime
            // gain, because the string is discarded unread.
            Raise Exception.Create('LclVirtualImage: PNG decoded to no graphic');
          end;
          // Drawn onto a fresh bitmap, NOT `Bmp.Assign(Pic)`. A PNG decodes to
          // a TFpImage, and TBitmap.Assign refuses it outright:
          //
          //     EConvertError: Cannot assign a TPicture to a TBitmap.
          //
          // Measured on all 20 images. TCustomImageList.Add takes a
          // TCustomBitmap, so a bitmap has to be produced either way.
          Bmp := TBitmap.Create;
          Bmp.SetSize(Pic.Graphic.Width, Pic.Graphic.Height);
          // bsClear first, so the area outside the image stays transparent
          // instead of becoming black.
          Bmp.Canvas.Brush.Style := bsClear;
          Bmp.Canvas.FillRect(0, 0, Bmp.Width, Bmp.Height);
          Bmp.Canvas.Draw(0, 0, Pic.Graphic);
        except
          Bmp.Free;
          Bmp := nil;
          // Counted, not swallowed. An item that fails to decode must still
          // OCCUPY its index: skipping it would shift every later image left,
          // so a theme would show the wrong preview with nothing to show for
          // the error.
          Inc(FFailures);
        end;
      finally
        Pic.Free;
      end;

      if Bmp = nil then
        Bmp := TBitmap.Create;  // blank placeholder, keeps the indices aligned

      try
        // Pad into the shared cell rather than resampling: these are pixel
        // previews, and squeezing a 671-wide bitmap to 670 loses a column of
        // UI chrome that the user can see.
        if (Bmp.Width <> CellW) or (Bmp.Height <> CellH) then
        begin
          Padded := TBitmap.Create;
          try
            Padded.SetSize(CellW, CellH);
            // bsClear leaves the padding transparent rather than black.
            Padded.Canvas.Brush.Style := bsClear;
            Padded.Canvas.FillRect(0, 0, CellW, CellH);
            Padded.Canvas.Draw(0, 0, Bmp);
          finally
            Bmp.Free;
            Bmp := Padded;
          end;
        end;
        // Add COPIES the pixels, so Bmp is disposable immediately.
        Add(Bmp, nil);
      finally
        Bmp.Free;
      end;
    end;
  finally
    EndUpdate;
  end;
end;

constructor TLclCollectionImageList.CreateForCollection(AOwner: TComponent;
  const AName: string);
begin
  inherited Create(AOwner);
  FCollectionName := AName;
  LoadAll;
end;

function CollectionImageList(const AName: string): TLclCollectionImageList;
var
  I: Integer;
begin
  Result := nil;
  if not FListsBuilt then
  begin
    SetLength(FLists, ImageCollectionCount);
    for I := 0 to High(FLists) do
      FLists[I] := nil;
    FListsBuilt := True;
  end;
  I := FindImageCollectionIndex(AName);
  if I < 0 then
    Exit(nil);
  if FLists[I] = nil then
    FLists[I] := TLclCollectionImageList.CreateForCollection(nil, IMAGE_COLLECTIONS[I].Name);
  Result := FLists[I];
end;

procedure FlushCollectionImageLists;
var
  I: Integer;
begin
  if not FListsBuilt then
    Exit;
  for I := 0 to High(FLists) do
  begin
    FLists[I].Free;
    FLists[I] := nil;
  end;
end;

constructor TLclVirtualImage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // TCustomImage.Create sets Proportional := False; TVirtualImage letterboxes.
  // See the note above -- this is the one default that genuinely differs.
  Proportional := True;
  FCollectionMissing := False;
end;

procedure TLclVirtualImage.SetImageCollection(const AValue: string);
var
  L: TLclCollectionImageList;
begin
  if FImageCollection = AValue then
    Exit;
  FImageCollection := AValue;
  if AValue = '' then
  begin
    Images := nil;
    Exit;
  end;
  L := CollectionImageList(AValue);
  // A nil list leaves `Images` unset, and TCustomImage.GetHasGraphic then
  // reports False -- so a misspelled collection renders as empty rather than
  // crashing a form load. The reason is reported instead of being absorbed.
  FCollectionMissing := L = nil;
  Images := L;
end;

procedure TLclVirtualImage.SetImageName(const AValue: string);
var
  C, It: Integer;
begin
  if FImageName = AValue then
    Exit;
  FImageName := AValue;
  if AValue = '' then
    Exit;
  C := FindImageCollectionIndex(FImageCollection);
  if C < 0 then
    Exit;
  for It := 0 to High(IMAGE_COLLECTIONS[C].Items) do
    if IMAGE_COLLECTIONS[C].Items[It].Name = AValue then
    begin
      // Setting ImageName moves ImageIndex with it, as the VCL control does.
      // Without this the initial image would never resolve, because the LFM
      // streams ImageIndex = -1 first and ImageName last.
      ImageIndex := It;
      Exit;
    end;
end;

finalization
  FlushCollectionImageLists;

end.

{$ENDIF}