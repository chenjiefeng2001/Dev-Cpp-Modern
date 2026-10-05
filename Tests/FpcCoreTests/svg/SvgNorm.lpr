// Cross-check the FPC normaliser against the Python one, byte for byte.
//
// Two implementations were written from one description:
//   tools/f3_svg_zerochord.py  -> Tests/FpcCoreTests/svg/zerochord/*.svg
//   LclSvgImageList.StripDegenerateArcs (this program's input is SvgData)
//
// Neither is checked against itself here. This program recomputes the
// normalisation over ALL 116 icons and compares its result with the files the
// Python tool wrote, so a divergence in either implementation shows up as a
// named icon rather than as a rendering surprise later.
//
// Expected, and asserted: exactly 7 icons change, and every changed icon
// matches its file. Anything else exits non-zero.
//
// Usage:  SvgNorm [<dir of generated variants>]   (default: zerochord)
program SvgNorm;
{$mode delphiunicode}{$H+}

uses
  SysUtils, Classes, LclSvgImageList, SvgData;

var
  VariantDir: string;
  Changed, Matched, Mismatch, Missing: Integer;

function ReadWholeFile(const AFile: string): string;
var
  FS: TFileStream;
  Bytes: TBytes;
begin
  // Bytes first, then decode -- NOT SetLength(Result, Size) + ReadBuffer into
  // Result[1]. Under -Mdelphiunicode a string is UTF-16, so writing raw bytes
  // into it fills half the buffer and leaves the rest as NULs: a file that
  // "matches nothing" for a reason that has nothing to do with its content.
  // UTF-8 decode is exact for the ASCII these files are asserted to be, and a
  // stray non-ASCII byte would show up as a DIFFER, which is the wanted answer.
  FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Bytes[0], FS.Size);
    Result := TEncoding.UTF8.GetString(Bytes);
  finally
    FS.Free;
  end;
end;

// <list>_<index>_<name>.svg -> the matching icon, or -1.
function FindIcon(const AFileName: string; out AList, AIndex: Integer): Boolean;
var
  Stem, ListName, Rest, IdxPart: string;
  P1, P2, Code: Integer;
begin
  Result := False;
  AList := -1;
  AIndex := -1;
  Stem := ChangeFileExt(AFileName, '');
  P1 := Pos('_', Stem);
  if P1 <= 0 then
    Exit;
  ListName := Copy(Stem, 1, P1 - 1);
  Rest := Copy(Stem, P1 + 1, MaxInt);
  P2 := Pos('_', Rest);
  if P2 <= 1 then
    Exit;
  IdxPart := Copy(Rest, 1, P2 - 1);
  Val(IdxPart, AIndex, Code);
  if Code <> 0 then
    Exit;
  AList := FindSvgListIndex(ListName);
  Result := (AList >= 0) and (AIndex >= 0) and
    (AIndex <= High(SVG_IMAGE_LISTS[AList].Svg));
end;

var
  SR: TSearchRec;
  I, K, L, Idx: Integer;
  Norm, FileName, OnDisk: string;
  ListName, IconName: string;
  Failed: Boolean;
begin
  if ParamCount >= 1 then
    VariantDir := ParamStr(1)
  else
    VariantDir := 'zerochord';
  Changed := 0;
  Matched := 0;
  Mismatch := 0;
  Missing := 0;
  Failed := False;

  // (1) How many icons does THIS implementation change?
  for I := 0 to SvgListCount - 1 do
    for K := 0 to High(SVG_IMAGE_LISTS[I].Svg) do
    begin
      Norm := StripDegenerateArcs(SVG_IMAGE_LISTS[I].Svg[K]);
      if Norm <> SVG_IMAGE_LISTS[I].Svg[K] then
        Inc(Changed);
    end;
  WriteLn('icons changed by StripDegenerateArcs: ', Changed);
  if Changed <> 7 then
  begin
    WriteLn('  FAIL: expected exactly 7');
    Failed := True;
  end;

  // (2) Every generated variant must equal what this implementation produces
  //     for the icon it claims to be. The file names carry list, index and name,
  //     so a mismatch is reported with all three.
  if FindFirst(VariantDir + '\*.svg', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        FileName := SR.Name;
        if not FindIcon(FileName, L, Idx) then
        begin
          WriteLn('  UNMATCHED FILE: ', FileName);
          Inc(Missing);
          Continue;
        end;
        Norm := StripDegenerateArcs(SVG_IMAGE_LISTS[L].Svg[Idx]);
        OnDisk := ReadWholeFile(VariantDir + '\' + FileName);
        ListName := SVG_IMAGE_LISTS[L].Name;
        IconName := SVG_IMAGE_LISTS[L].Names[Idx];
        if Norm = OnDisk then
        begin
          Inc(Matched);
          WriteLn(Format('  MATCH   %-27s [%3d] %s',
            [ListName, Idx, IconName]));
        end
        else
        begin
          Inc(Mismatch);
          WriteLn(Format('  DIFFER  %-27s [%3d] %s  (%d vs %d bytes)',
            [ListName, Idx, IconName, Length(Norm), Length(OnDisk)]));
          Failed := True;
        end;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  WriteLn;
  WriteLn('variants matched  : ', Matched);
  WriteLn('variants differing: ', Mismatch);
  WriteLn('unmatched files   : ', Missing);
  if (Matched = 0) or (Mismatch > 0) or (Missing > 0) then
    Failed := True;

  if Failed then
    WriteLn('RESULT: FAIL -- the two implementations disagree')
  else
    WriteLn('RESULT: PASS -- FPC and Python normalise identically');
  if Failed then
    Halt(1);
end.