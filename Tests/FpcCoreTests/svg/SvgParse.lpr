// Parse-only judge: read each SVG in a directory and report whether
// ReadFromStream succeeded -- NO rendering.
//
// WHY THIS EXISTS
// ===============
// doc/F3-SVG图标方案.md section 11.4 records the seven EZeroDivide failures
// with the note "happens during render, not parse". That was an INFERENCE: the
// only probe in circulation (RasterProbe) wraps parse and render in a single
// try/except, so it cannot tell the two apart. This program removes the render
// half, so a failure here proves the parse raised, while a pass here combined
// with RasterProbe's failure would prove the opposite.
//
// The claim decides WHERE a fix belongs: data that cannot be parsed must be
// normalised before ReadFromStream, whereas a render-time fault would be a
// canvas/transform problem instead.
//
// Usage:  SvgParse <dir>   (prints "<verdict>\t<filename>" per *.svg)
// Verdict 1 = parsed and produced a page; 0 = raised, with the class and
// message printed as the third field -- EZeroDivide here names the reader.
program SvgParse;
{$mode delphiunicode}{$H+}

uses
  SysUtils, Classes, Graphics, Interfaces,
  FPVectorial, svgvectorialreader, fpvectorial2canvas;

var
  Dir: string;

function TryOne(const AFile: string; out AWhy: string): Boolean;
var
  Doc: TvVectorialDocument;
  Stream: TFileStream;
begin
  Result := False;
  AWhy := '';
  Doc := nil;
  Stream := nil;
  try
    try
      // Read the FILE's bytes. The first version of this probe built a stream
      // from the PATH STRING (TEncoding.UTF8.GetBytes(AFile)), so it handed the
      // parser "<svg path under failed/>" as if it were document content and
      // every file failed with EXMLReadError "Illegal at document level" --
      // an error about the argument, not about the SVG.
      Stream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
      Doc := TvVectorialDocument.Create;
      Doc.ReadFromStream(Stream, vfSVG);
      if Doc.GetPageCount = 0 then
      begin
        AWhy := 'parsed but produced no page';
        Exit;
      end;
      Result := True;
    finally
      Doc.Free;
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      AWhy := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

var
  SR: TSearchRec;
  N, Pass: Integer;
  Why: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: SvgParse <dir>');
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
        if TryOne(Dir + '\' + SR.Name, Why) then
        begin
          Inc(Pass);
          WriteLn(1, #9, SR.Name);
        end
        else
          WriteLn(0, #9, SR.Name, #9, Why);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  WriteLn('# total=', N, ' parsed=', Pass, ' raised=', N - Pass);
end.
