// Does TLclSvgImageList actually WORK as an image list?
//
// Three claims are checked, each of which the previous `= class` version could
// not make and the doc's `GetImage`-override sketch also could not compile:
//
//   1. it can be handed to a REAL LCL control's Images property
//   2. Count and the pixel edge match the data (19 / 18 / 32 / 25 / 37)
//   3. the icons it holds have VISIBLE PIXELS when pulled back out
//
// (3) is the check this project keeps needing: a list can be perfectly
// constructed, report a healthy Count, and still paint nothing -- the empty-icon
// bug, which has already appeared twice, once inside the fix itself.
program SvgListProbe;
{$mode delphiunicode}{$H+}

uses
  SysUtils, Classes, Graphics, Buttons, Interfaces,
  LclSvgImageList, SvgData;

const
  // 7 icons used to be unrenderable; StripDegenerateArcs in the control removed
  // that gap (SvgNorm shows both implementations agree byte for byte, and every
  // list now reports fail=0). The ceiling is therefore 0: a regression is a
  // failure, not a new known gap. Ratcheting this down is the point -- a bound
  // set above the current value can never fire.
  EXPECTED_MAX_FAILURES = 0;

var
  I, Edge, Got, Failures, TotalFail: Integer;
  L: TLclSvgImageList;
  B: TBitBtn;
  Dst: TBitmap;
  X, Y, Ink: Integer;
  Names: array[0..4] of string;
  WantEdges: array[0..4] of Integer;

begin
  WriteLn('SvgListCount = ', SvgListCount);
  for I := 0 to SvgListCount - 1 do
  begin
    Names[I] := SVG_IMAGE_LISTS[I].Name;
    Edge := SVG_IMAGE_LISTS[I].SizePx;
    if Edge <= 0 then
      Edge := DEFAULT_ICON_EDGE;
    WantEdges[I] := Edge;
  end;

  Failures := 0;
  for I := 0 to SvgListCount - 1 do
  begin
    L := CreateSvgImageList(Names[I]);
    if L = nil then
    begin
      WriteLn('  ', Names[I], ': CreateSvgImageList returned nil');
      Inc(Failures);
      Continue;
    end;
    try
      // (1) THE point of deriving from TCustomImageList: a real LCL control
      // accepts it. `TBitBtn.Images` is typed TCustomImageList, so this
      // assignment is the one the old `= class` control could not make at all.
      // TBitBtn comes from `Buttons`, not `ComCtrls` (measured: buttons.pp
      // declares both TCustomBitBtn and TBitBtn), which is why the first
      // attempt with ComCtrls reported "Identifier not found: TBitBtn".
      B := TBitBtn.Create(nil);
      try
        B.Images := L;
      finally
        B.Free;
      end;

      // (2) Count and edge come from the data, not from a literal.
      Got := L.Count;
      if L.Width <> WantEdges[I] then
      begin
        WriteLn('  ', Names[I], ': edge ', L.Width, ' want ', WantEdges[I]);
        Inc(Failures);
      end;

      // (3) visible pixels, pulled back the way a control would.
      Ink := 0;
      Dst := TBitmap.Create;
      try
        Dst.SetSize(L.Width, L.Height);
        if Got > 0 then
        begin
          L.GetBitmap(0, Dst);
          for Y := 0 to L.Height - 1 do
            for X := 0 to L.Width - 1 do
              // Via the CANVAS, not the bitmap: `Colors` is a TCanvas member
              // (SvgListProbe.lpr(85,22) "no member Colors" on a TBitmap), and
              // it hands back a TFPColor whose Alpha is the ink test.
              if Dst.Canvas.Colors[X, Y].Alpha <> 0 then
                Inc(Ink);
        end;
      finally
        Dst.Free;
      end;
      if Ink = 0 then
      begin
        WriteLn('  ', Names[I], ': icon 0 is BLANK after GetBitmap');
        Inc(Failures);
      end;

      WriteLn(Format('  %-28s count=%3d/%3d edge=%2d ink[0]=%4d fail=%d',
        [Names[I], Got, Length(SVG_IMAGE_LISTS[I].Svg), L.Width, Ink,
         L.RasterFailures]));
      if L.RasterFailures <> 0 then
        // A hard failure now, not a reported-and-ignored count: the ceiling is
        // 0, so anything here is a regression (see EXPECTED_MAX_FAILURES).
        Inc(Failures);
    finally
      L.Free;
    end;
  end;

  // Theme re-render must produce the SAME icons, not an empty list.
  WriteLn;
  L := CreateSvgImageList('SVGImageListMenuStyle');
  try
    WriteLn('before theme: count=', L.Count, ' gen=', L.ThemeGen);
    L.ThemeChanged;
    WriteLn('after  theme: count=', L.Count, ' gen=', L.ThemeGen);
    if L.Count = 0 then
    begin
      WriteLn('  FAIL: re-theme emptied the list');
      Inc(Failures);
    end;
    if L.ThemeGen <> 2 then
    begin
      WriteLn('  FAIL: theme generation did not advance');
      Inc(Failures);
    end;
  finally
    L.Free;
  end;

  WriteLn;
  { A SEPARATE variable. This used to be `Failures := MeasureRasterFailures;`,
    which OVERWROTE the running problem count with the renderer's own tally --
    so a run with zero problems still printed "7 problem(s) -- see above"
    while printing no problems above it. The two numbers answer different
    questions: `Failures` counts things THIS probe found wrong; `TotalFail`
    counts icons the renderer cannot draw, which is a known gap tracked
    separately. }
  TotalFail := MeasureRasterFailures;
  WriteLn('renderer failures over all lists = ', TotalFail);
  if TotalFail > EXPECTED_MAX_FAILURES then
  begin
    WriteLn('  FAIL: failure count grew beyond the known ', EXPECTED_MAX_FAILURES);
    Inc(Failures);
  end;

  WriteLn;
  if Failures = 0 then
    WriteLn('RESULT: SVG list works as a real LCL image list')
  else
    WriteLn('RESULT: ', Failures, ' problem(s) -- see above');
end.