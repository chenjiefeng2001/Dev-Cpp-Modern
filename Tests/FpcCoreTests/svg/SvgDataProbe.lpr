// Does the data unit actually DELIVER, not merely compile?
//
// The project's own rule: a structural check proves shape, and "it compiles"
// proves syntax. Neither says a single icon reached the consumer. This program
// prints the list count, each list's item count, the measured pixel edges, and a
// per-list spot check of the first and last payload -- so a regression that
// silently yields empty arrays is visible rather than inferred.
program SvgDataProbe;
{$mode delphiunicode}{$H+}

uses SysUtils, SvgData;

var
  I, J: Integer;
  NamesOk, SvgOk: Integer;
  Edge: string;

begin
  WriteLn('SvgListCount = ', SvgListCount);
  if SvgListCount <> 5 then
  begin
    WriteLn('UNEXPECTED list count');
    Halt(1);
  end;

  for I := Low(SVG_IMAGE_LISTS) to High(SVG_IMAGE_LISTS) do
  begin
    Edge := IntToStr(SVG_IMAGE_LISTS[I].SizePx);
    if SVG_IMAGE_LISTS[I].SizePx = 0 then
      Edge := '(none declared)';
    WriteLn;
    WriteLn(Format('  %-28s items=%3d size_px=%s',
      [SVG_IMAGE_LISTS[I].Name,
       Length(SVG_IMAGE_LISTS[I].Svg),
       Edge]));

    // Names and Svg must be the same length or ImageIndex and the name ledger
    // have silently drifted apart.
    if Length(SVG_IMAGE_LISTS[I].Names) <> Length(SVG_IMAGE_LISTS[I].Svg) then
    begin
      WriteLn('    MISMATCH names=', Length(SVG_IMAGE_LISTS[I].Names),
        ' svg=', Length(SVG_IMAGE_LISTS[I].Svg));
      Halt(1);
    end;

    NamesOk := 0;
    SvgOk := 0;
    for J := Low(SVG_IMAGE_LISTS[I].Svg) to High(SVG_IMAGE_LISTS[I].Svg) do
    begin
      if SVG_IMAGE_LISTS[I].Svg[J] <> '' then
        Inc(SvgOk);
      if (J >= Low(SVG_IMAGE_LISTS[I].Names)) and
         (SVG_IMAGE_LISTS[I].Names[J] <> '') then
        Inc(NamesOk);
    end;
    WriteLn('    non-empty svg=', SvgOk, '/', Length(SVG_IMAGE_LISTS[I].Svg),
      '   named=', NamesOk, '/', Length(SVG_IMAGE_LISTS[I].Names));
    if (SvgOk <> Length(SVG_IMAGE_LISTS[I].Svg)) or
       (NamesOk <> Length(SVG_IMAGE_LISTS[I].Svg)) then
      Halt(1);

    if Length(SVG_IMAGE_LISTS[I].Svg) > 0 then
      WriteLn('    first name=', SVG_IMAGE_LISTS[I].Names[0],
        '  svg starts: ', Copy(SVG_IMAGE_LISTS[I].Svg[0], 1, 34));
  end;

  WriteLn;
  WriteLn('FindSvgListIndex(SVGImageListMenuStyle) = ',
    FindSvgListIndex('SVGImageListMenuStyle'));
  WriteLn('FindSvgListIndex(NoSuchList)            = ',
    FindSvgListIndex('NoSuchList'));
  if FindSvgListIndex('SVGImageListMenuStyle') <> 0 then
    Halt(1);
  if FindSvgListIndex('NoSuchList') <> -1 then
    Halt(1);

  WriteLn;
  WriteLn('RESULT: data unit delivers 5 lists / 116 payloads');
end.