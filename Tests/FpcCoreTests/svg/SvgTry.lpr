// Judge a directory of SVG files: print PASS/FAIL per file.
//
// Python cannot render, so the experiment is split: Python GENERATES variants,
// this program JUDGES them. That keeps every rendering fact on the side that can
// actually measure it.
//
// Usage:  SvgTry <dir>   (prints "<verdict>\t<filename>" per *.svg)
program SvgTry;
{$mode delphiunicode}{$H+}

uses
  SysUtils, Classes, Graphics, Interfaces,
  FPVectorial, svgvectorialreader, fpvectorial2canvas;

var
  Dir: string;

function TryOne(const AFile: string): Boolean;
var
  Doc: TvVectorialDocument;
  Stream: TFileStream;
  Bmp: TBitmap;
  Canvas: TCanvas;
  X, Y, Ink: Integer;
begin
  Result := False;
  Doc := nil;
  Stream := nil;
  Bmp := nil;
  try
    try
      // Read the FILE's bytes. This judge fed the PATH STRING to the parser
      // (TEncoding.UTF8.GetBytes(AFile)), so it parsed the file name as if it
      // were an SVG and returned 0 for EVERY input -- a judge that cannot pass
      // a correct file reports a broken file, which is how a fix gets thrown
      // away as "did not work". Caught by SvgParse reporting EXMLReadError
      // "Illegal at document level" for all seven files: that message is about
      // the argument, not about the SVG. An all-zero verdict is indistinguish-
      // able from a broken judge, so it was checked rather than believed.
      Stream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
      Doc := TvVectorialDocument.Create;
      Doc.ReadFromStream(Stream, vfSVG);
      if Doc.GetPageCount = 0 then
        Exit(False);
      Bmp := TBitmap.Create;
      Bmp.SetSize(32, 32);
      Canvas := Bmp.Canvas;
      Canvas.Brush.Style := bsClear;
      Canvas.FillRect(0, 0, 32, 32);
      Doc.GetPageAsVectorial(0).Render(Canvas, 0, 0, 1.0, 1.0);
      Ink := 0;
      for Y := 0 to 31 do
        for X := 0 to 31 do
          if Canvas.Colors[X, Y].Alpha <> 0 then
            Inc(Ink);
      // PASS requires the render to complete AND leave ink. A variant that
      // renders nothing is not a fix, it is a different failure.
      Result := Ink > 0;
    finally
      Bmp.Free;
      Doc.Free;
      Stream.Free;
    end;
  except
    on E: Exception do
      Result := False;
  end;
end;

var
  SR: TSearchRec;
  N, Pass: Integer;
  Ok: Boolean;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: SvgTry <dir>');
    Halt(2);
  end;
  Dir := ParamStr(1);
  N := 0;
  Pass := 0;
  if FindFirst(Dir + '\*.svg', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        Inc(N);
        // Render ONCE and reuse the verdict. An earlier version called TryOne
        // twice per file -- once for the counter, once for the line -- so every
        // icon was rasterised twice.
        Ok := TryOne(Dir + '\' + SR.Name);
        if Ok then
          Inc(Pass);
        WriteLn(Ord(Ok), #9, SR.Name);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  WriteLn('# total=', N, ' pass=', Pass);
end.