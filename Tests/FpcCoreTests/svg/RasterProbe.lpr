// Rasterise ALL 116 extracted icons through fpvectorial and report what the
// renderer actually produced.
//
// This closes doc/F3-SVG图标方案.md section 7 item 1, open since 2026-10-04:
// "whether LCL can render this SVG subset is NOT yet verified".
//
// Two corrections this program encodes, both measured rather than assumed:
//  * fpvectorial has NO TSVGComponent/TSVGImage (zero TSVG\w* matches in
//    fpvectorial.pas). The real entry points are
//    TvVectorialDocument.ReadFromStream(AStream, vfSVG) and
//    TvPage.Render(ADest: TFPCustomCanvas; ADestX, ADestY; AMulX, AMulY).
//  * LCL 4.x TBitmap.Create takes NO arguments; size is set by SetSize.
//
// A parse that "succeeds" is NOT the answer this project needs: the empty-icon
// bug has already appeared twice, once inside the fix itself. So every icon is
// additionally checked for NON-BLANK pixels.
program RasterProbe;
{$mode delphiunicode}{$H+}

uses
  SysUtils, Classes, Graphics, FPVectorial,
  // These two are NOT optional and their absence is silent-ish: without the
  // first, every ReadFromStream(vfSVG) raises
  //     Exception: Unsupported vector graphics format.
  // and without the second there is no default renderer to draw with.
  // Both register themselves in their own `initialization`, so the
  // registration only happens if the unit is in the uses clause.
  svgvectorialreader,   // -> RegisterVectorialReader(TvSVGVectorialReader)
  fpvectorial2canvas,   // -> RegisterDefaultRenderer(TFPVCanvasRenderer)
  // The LCL widgetset. Without it the LCL graphics backend has no driver
  // behind TCanvas, and TvPage.Render dies with a bare
  //     EAccessViolation: Access violation
  // which names no unit and no line -- the reader had already succeeded by
  // then, so the fault is in the paint path, not the parse.
  Interfaces,
  SvgData;

var
  TotalIcons, OkCount, BlankCount, ParseFail: Integer;
  ListIdx, IconIdx, NonBlank: Integer;
  T0: QWord;
  FailNames: string;
  Edge, ListTotal, ListOk, ListBlank: Integer;
  Doc: TvVectorialDocument;
  S: TMemoryStream;
  Bmp: TBitmap;
  Canvas: TCanvas;
  Page: TvVectorialPage;
  Utf8: TBytes;
  // Collects the failing SVG payloads so the report can name WHICH icons broke,
  // not just how many. A set keyed on the text itself, because the same icon
  // legitimately appears in more than one list (20 names repeat across the set).
  BadIcons: TStringList;
  FailDir: string;
  BadCount: Integer;
  OutFile: string;
  F: TextFile;

// 1 = rendered with visible pixels, 0 = rendered blank, -1 = failed.
function RenderSvg(const ASvg: string; AEdge: Integer): Integer;
var
  X, Y: Integer;
begin
  Result := -1;
  NonBlank := 0;
  Doc := nil;
  S := nil;
  Bmp := nil;
  try
    try
      // UTF-8 BYTES on a byte stream, not TStringStream. An SVG on the wire is
      // UTF-8, and under -Mdelphiunicode a string stream hands the parser UTF-16,
      // which it reports as
      //     EXMLReadError: In 'stream:' (line 1 pos 2):
      //                   Name starts with invalid character 0
      // -- the "0" being a NUL byte out of the first UTF-16 code unit. So this
      // is an encoding fault reading as a parse fault.
      Utf8 := TEncoding.UTF8.GetBytes(ASvg);
      S := TMemoryStream.Create;
      if Length(Utf8) > 0 then
        S.WriteBuffer(Utf8[0], Length(Utf8));
      S.Position := 0;
      Doc := TvVectorialDocument.Create;
      // Real entry points, measured from fpvectorial.pas: there is NO
      // TSVGComponent/TSVGImage anywhere in that unit.
      Doc.ReadFromStream(S, vfSVG);
      if Doc.GetPageCount = 0 then
        Exit;
      Page := Doc.GetPageAsVectorial(0);
      Bmp := TBitmap.Create;
      Bmp.SetSize(AEdge, AEdge);
      Canvas := Bmp.Canvas;
      // bsClear rather than Brush.Color := clNone: clNone is a TFPColor while
      // Brush.Color wants a TGraphicsColor, so the assignment is a type error.
      Canvas.Brush.Style := bsClear;
      Canvas.FillRect(0, 0, AEdge, AEdge);
      Page.Render(Canvas, 0, 0, 1.0, 1.0);
      for Y := 0 to AEdge - 1 do
        for X := 0 to AEdge - 1 do
          // Canvas.Colors[] returns TFPColor here, not TColor, so it cannot be
          // masked with $FFFFFF, and it cannot be compared to clNone either:
          // in the LCL scope clNone is a TGraphicsColor. Reading the alpha
          // channel asks the only question that matters -- did the renderer put
          // ink on this pixel? -- with no conversion in between.
          if Canvas.Colors[X, Y].Alpha <> 0 then
            Inc(NonBlank);
      if NonBlank = 0 then
        Result := 0
      else
        Result := 1;
    finally
      Bmp.Free;
      Doc.Free;
      S.Free;
    end;
  except
    on E: Exception do
    begin
      if ParseFail < 6 then
        FailNames := FailNames + #13#10 + '    ' + E.ClassName + ': ' + E.Message;
      Inc(ParseFail);
      BadIcons.Add(ASvg);
      Result := -1;
    end;
  end;
end;

begin
  T0 := GetTickCount64;
  BadIcons := TStringList.Create;
  BadIcons.Sorted := True;
  BadIcons.Duplicates := dupIgnore;
  FailDir := 'failed/';
  try
  for ListIdx := Low(SVG_IMAGE_LISTS) to High(SVG_IMAGE_LISTS) do
  begin
    Edge := SVG_IMAGE_LISTS[ListIdx].SizePx;
    if Edge <= 0 then
      Edge := 32;
    ListTotal := 0;
    ListOk := 0;
    ListBlank := 0;
    for IconIdx := 0 to High(SVG_IMAGE_LISTS[ListIdx].Svg) do
    begin
      Inc(ListTotal);
      Inc(TotalIcons);
      case RenderSvg(SVG_IMAGE_LISTS[ListIdx].Svg[IconIdx], Edge) of
        1:
          begin
            Inc(ListOk);
            Inc(OkCount);
          end;
        0:
          begin
            Inc(ListOk);
            Inc(OkCount);
            Inc(ListBlank);
            Inc(BlankCount);
            if ListBlank <= 3 then
              WriteLn('    BLANK: ', SVG_IMAGE_LISTS[ListIdx].Name, '[',
                IconIdx, '] ', SVG_IMAGE_LISTS[ListIdx].Names[IconIdx],
                ' edge=', Edge);
          end;
      else
        Inc(BlankCount);
      end;
    end;
    WriteLn(Format('  %-28s edge=%2d  %3d/%3d ok  (%d blank)',
      [SVG_IMAGE_LISTS[ListIdx].Name, Edge, ListOk, ListTotal, ListBlank]));
  end;

  WriteLn;
  WriteLn('icons total      : ', TotalIcons);
  WriteLn('rendered ok      : ', OkCount);
  WriteLn('parse/raise fail : ', ParseFail);
  WriteLn('blank (0 px)     : ', BlankCount);
  WriteLn('elapsed ms       : ', GetTickCount64 - T0);
  if FailNames <> '' then
    WriteLn('first failures:', FailNames);

  // Which icons failed, by list and index. "7 of 116 fail" is a number to
  // act on only if you know WHICH 7 -- a per-icon list is what turns it into a
  // work item, and it is the only form that can be re-checked after a fix
  // without re-reading this program's source.
  if ParseFail > 0 then
  begin
    WriteLn;
    WriteLn('FAILED ICONS:');
    for ListIdx := Low(SVG_IMAGE_LISTS) to High(SVG_IMAGE_LISTS) do
      for IconIdx := 0 to High(SVG_IMAGE_LISTS[ListIdx].Svg) do
        if BadIcons.IndexOf(SVG_IMAGE_LISTS[ListIdx].Svg[IconIdx]) >= 0 then
          WriteLn(Format('  %-28s [%3d] %s',
            [SVG_IMAGE_LISTS[ListIdx].Name, IconIdx,
             SVG_IMAGE_LISTS[ListIdx].Names[IconIdx]]));
  end;

  // Dump every failing payload to disk.
  //
  // The seven failures were previously analysed by re-parsing SvgData.pas in
  // Python -- and that re-implementation was WRONG (it reported 696 icons for
  // an 85-icon list), so its conclusions were discarded. This program already
  // knows exactly which payloads fail, so it writes them out instead. The
  // analysis then reads FILES rather than re-deriving the data.
  //
  // FailDir is created if missing so the dump never silently disappears.
  if ParseFail > 0 then
  begin
    ForceDirectories(FailDir);
    for ListIdx := Low(SVG_IMAGE_LISTS) to High(SVG_IMAGE_LISTS) do
      for IconIdx := 0 to High(SVG_IMAGE_LISTS[ListIdx].Svg) do
        if BadIcons.IndexOf(SVG_IMAGE_LISTS[ListIdx].Svg[IconIdx]) >= 0 then
        begin
          OutFile := FailDir + IntToStr(BadCount) + '_' +
            SVG_IMAGE_LISTS[ListIdx].Name + '_' + IntToStr(IconIdx) + '_' +
            SVG_IMAGE_LISTS[ListIdx].Names[IconIdx] + '.svg';
          try
            AssignFile(F, OutFile);
            Rewrite(F);
            WriteLn(F, SVG_IMAGE_LISTS[ListIdx].Svg[IconIdx]);
          finally
            CloseFile(F);
          end;
          Inc(BadCount);
        end;
    WriteLn;
    WriteLn('dumped ', BadCount, ' failing payload(s) to ', FailDir);
  end;

  if (ParseFail = 0) and (BlankCount = 0) and (OkCount = TotalIcons) then
    WriteLn('RESULT: ALL ICONS RENDERED WITH VISIBLE PIXELS')
  else
    WriteLn('RESULT: INCOMPLETE -- see counts above');
  finally
    BadIcons.Free;
  end;
end.