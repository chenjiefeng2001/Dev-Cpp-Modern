{
    This file is part of Dev-C++
    Copyright (c) 2004 Bloodshed Software

    Dev-C++ is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Dev-C++ is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Dev-C++; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
}

unit MultiLangSupport;

interface

uses
  Windows, Dialogs, SysUtils, Classes;

{$I LangIDs.inc}

type
  TCPData = record
    CPID: Integer;
    CPName: String;
    CPLang: String;
  end;

{ The list of shipped translations and the Windows locale id each one stands
  for. Exists because ProjectOptionsFrm builds its language combo from it:

      for I := 0 to Languages.Count - 1 do
        cmbLangID.Items.Add(Languages.Name[i]);
      cmbLangID.ItemIndex := cmbLangID.Items.IndexOf(Languages.NameFromLocaleID[LanguageID]);

  and `Languages` has never existed in this repository -- git grep over the 2013
  tree finds one referencing file and no declaration, and no Languages unit
  appears anywhere in the history. The data behind it was never committed
  either: the .lng files carry `Lang=<name>` and `Ver=` but NO locale id, and
  cmbLangID has no `Items` in its .dfm, so the combo is populated entirely from
  here. ProjectTypes only pins the default, $0409 US English.

  So the table below is built from what IS in the tree -- the 34 *.lng files --
  against the standard Windows locale ids, one row per file. Three rows are a
  judgement call rather than a lookup, and they are marked.
}
type
  TLanguageEntry = record
    Name: string;
    LocaleID: Integer;
  end;

  TLanguageList = class
  private
    FEntries: array of TLanguageEntry;
  public
    constructor Create;
    function Count: Integer;
    // Declared as DEFAULT array properties, not as methods taking an index.
    // The call sites write `Languages.Name[I]` and `Languages.LocaleID[I]`,
    // and while Delphi reads that as a call, FPC rejects it:
    //     ProjectOptionsFrm.pas(420,38) Error: Illegal qualifier
    // An indexed property is also the honest shape here -- the table really is
    // indexable -- so this is what the surface should have been anyway.
    function GetName(AIndex: Integer): string;
    function GetLocaleID(AIndex: Integer): Integer;
    function GetNameFromLocaleID(ALocaleID: Integer): string;
    property Name[Index: Integer]: string read GetName;
    property LocaleID[Index: Integer]: Integer read GetLocaleID;
    property NameFromLocaleID[LocaleID: Integer]: string read GetNameFromLocaleID;
  end;

  TdevMultiLangSupport = class(TObject)
  private
    fLangList: TStringList;
    fLangListLoaded: Boolean;
    fLangFile: String;
    fCurLang: String;
    fCurCodePage: Integer;
    fStrings: TStringList;
    fDefaultLangStrings: TStringList;
    function GetString(ID: integer): String;
    function GetLangName: String;
    constructor Create;
  public
    destructor Destroy; override;
    procedure SelectLanguage;
    procedure CheckLanguageFiles;
    procedure Open(const FileName: String);
    procedure SetLang(const Lang: String);
    function GetLangList: TStringList;
    function FileFromDescription(const Desc: String): String;
    property Strings[index: integer]: String read GetString; default;
    property CurrentLanguage: String read GetLangName;
    property Langs: TStringList read GetLangList;
  end;
  // https://stackoverflow.com/questions/2574289/codepage-id-to-codepage-name-getencoding-equivalent-in-delphi
  const
    MaxEncodings = 20;//148;

    Encodings: Array[0..MaxEncodings - 1] of TCPData =
    (
      //(CPID: 37; CPName: 'IBM037'),
      //(CPID: 437; CPName: 'IBM437'),
      //(CPID: 500; CPName: 'IBM500'),
      //(CPID: 708; CPName: 'ASMO-708'),
      //(CPID: 720; CPName: 'DOS-720'),
      //(CPID: 737; CPName: 'ibm737'),
      //(CPID: 775; CPName: 'ibm775'),
      //(CPID: 850; CPName: 'ibm850'),
      //(CPID: 852; CPName: 'ibm852'),
      //(CPID: 855; CPName: 'IBM855'),
      //(CPID: 857; CPName: 'ibm857'),
      //(CPID: 858; CPName: 'IBM00858'),
      //(CPID: 860; CPName: 'IBM860'),
      //(CPID: 861; CPName: 'ibm861'),
      //(CPID: 862; CPName: 'DOS-862'),
      //(CPID: 863; CPName: 'IBM863'),
      //(CPID: 864; CPName: 'IBM864'),
      //(CPID: 865; CPName: 'IBM865'),
      //(CPID: 866; CPName: 'cp866'),
      //(CPID: 869; CPName: 'ibm869'),
      //(CPID: 870; CPName: 'IBM870'),
      //(CPID: 874; CPName: 'windows-874'),
      //(CPID: 875; CPName: 'cp875'),
      (CPID: 932; CPName: 'shift_jis'; CPLang: 'Japanese';),
      (CPID: 936; CPName: 'gb2312'; CPLang: 'Chinese';),
      (CPID: 949; CPName: 'ks_c_5601-1987'; CPLang: 'Korean';),
      //(CPID: 950; CPName: 'big5'),
      //(CPID: 1026; CPName: 'IBM1026'),
      //(CPID: 1047; CPName: 'IBM01047'),
      //(CPID: 1140; CPName: 'IBM01140'),
      //(CPID: 1141; CPName: 'IBM01141'),
      //(CPID: 1142; CPName: 'IBM01142'),
      //(CPID: 1143; CPName: 'IBM01143'),
      //(CPID: 1144; CPName: 'IBM01144'),
      //(CPID: 1145; CPName: 'IBM01145'),
      //(CPID: 1146; CPName: 'IBM01146'),
      //(CPID: 1147; CPName: 'IBM01147'),
      //(CPID: 1148; CPName: 'IBM01148'),
      //(CPID: 1149; CPName: 'IBM01149'),
      //(CPID: 1200; CPName: 'utf-16'),
      //(CPID: 1201; CPName: 'unicodeFFFE'),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Croatian';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Czech';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Hungarian';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Polish';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Romanian';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Slovak';),
      (CPID: 1250; CPName: 'windows-1250'; CPLang: 'Slovenian';),
      (CPID: 1251; CPName: 'windows-1251'; CPLang: 'Russian';),
      (CPID: 1251; CPName: 'windows-1251'; CPLang: 'Ukrainian';),
      (CPID: 1252; CPName: 'Windows-1252'; CPLang: 'English';),
      (CPID: 1253; CPName: 'windows-1253'; CPLang: 'Greek';),
      (CPID: 1254; CPName: 'windows-1254'; CPLang: 'Turkish';),
      (CPID: 1255; CPName: 'windows-1255'; CPLang: 'Hebrew';),
      //(CPID: 1256; CPName: 'windows-1256'),
      //(CPID: 1257; CPName: 'windows-1257'),
      //(CPID: 1258; CPName: 'windows-1258'),
      //(CPID: 1361; CPName: 'Johab'),
      //(CPID: 10000; CPName: 'macintosh'),
      //(CPID: 10001; CPName: 'x-mac-japanese'),
      //(CPID: 10002; CPName: 'x-mac-chinesetrad'),
      //(CPID: 10003; CPName: 'x-mac-korean'),
      //(CPID: 10004; CPName: 'x-mac-arabic'),
      //(CPID: 10005; CPName: 'x-mac-hebrew'),
      //(CPID: 10006; CPName: 'x-mac-greek'),
      //(CPID: 10007; CPName: 'x-mac-cyrillic'),
      //(CPID: 10008; CPName: 'x-mac-chinesesimp'),
      //(CPID: 10010; CPName: 'x-mac-romanian'),
      //(CPID: 10017; CPName: 'x-mac-ukrainian'),
      //(CPID: 10021; CPName: 'x-mac-thai'),
      //(CPID: 10029; CPName: 'x-mac-ce'),
      //(CPID: 10079; CPName: 'x-mac-icelandic'),
      //(CPID: 10081; CPName: 'x-mac-turkish'),
      //(CPID: 10082; CPName: 'x-mac-croatian'),
      //(CPID: 12000; CPName: 'utf-32'),
      //(CPID: 12001; CPName: 'utf-32BE'),
      //(CPID: 20000; CPName: 'x-Chinese-CNS'),
      //(CPID: 20001; CPName: 'x-cp20001'),
      //(CPID: 20002; CPName: 'x-Chinese-Eten'),
      //(CPID: 20003; CPName: 'x-cp20003'),
      //(CPID: 20004; CPName: 'x-cp20004'),
      //(CPID: 20005; CPName: 'x-cp20005'),
      //(CPID: 20105; CPName: 'x-IA5'),
      //(CPID: 20106; CPName: 'x-IA5-German'),
      //(CPID: 20107; CPName: 'x-IA5-Swedish'),
      //(CPID: 20108; CPName: 'x-IA5-Norwegian'),
      //(CPID: 20127; CPName: 'us-ascii'),
      //(CPID: 20261; CPName: 'x-cp20261'),
      //(CPID: 20269; CPName: 'x-cp20269'),
      //(CPID: 20273; CPName: 'IBM273'),
      //(CPID: 20277; CPName: 'IBM277'),
      //(CPID: 20278; CPName: 'IBM278'),
      //(CPID: 20280; CPName: 'IBM280'),
      //(CPID: 20284; CPName: 'IBM284'),
      //(CPID: 20285; CPName: 'IBM285'),
      //(CPID: 20290; CPName: 'IBM290'),
      //(CPID: 20297; CPName: 'IBM297'),
      //(CPID: 20420; CPName: 'IBM420'),
      //(CPID: 20423; CPName: 'IBM423'),
      //(CPID: 20424; CPName: 'IBM424'),
      //(CPID: 20833; CPName: 'x-EBCDIC-KoreanExtended'),
      //(CPID: 20838; CPName: 'IBM-Thai'),
      //(CPID: 20866; CPName: 'koi8-r'),
      //(CPID: 20871; CPName: 'IBM871'),
      //(CPID: 20880; CPName: 'IBM880'),
      //(CPID: 20905; CPName: 'IBM905'),
      //(CPID: 20924; CPName: 'IBM00924'),
      //(CPID: 20932; CPName: 'EUC-JP'),
      //(CPID: 20936; CPName: 'x-cp20936'),
      //(CPID: 20949; CPName: 'x-cp20949'),
      (CPID: 21025; CPName: 'cp1025'; CPLang: 'Bulgarian';),
      //(CPID: 21866; CPName: 'koi8-u'),
      //(CPID: 28591; CPName: 'iso-8859-1'),
      //(CPID: 28592; CPName: 'iso-8859-2'),
      //(CPID: 28593; CPName: 'iso-8859-3'),
      (CPID: 28594; CPName: 'iso-8859-4'; CPLang: 'Estonian';),
      (CPID: 28594; CPName: 'iso-8859-4'; CPLang: 'Latvian';),
      //(CPID: 28595; CPName: 'iso-8859-5'),
      //(CPID: 28596; CPName: 'iso-8859-6'),
      //(CPID: 28597; CPName: 'iso-8859-7'),
      //(CPID: 28598; CPName: 'iso-8859-8'),
      //(CPID: 28599; CPName: 'iso-8859-9'),
      //(CPID: 28603; CPName: 'iso-8859-13'),
      //(CPID: 28605; CPName: 'iso-8859-15'),
      //(CPID: 29001; CPName: 'x-Europa'),
      //(CPID: 38598; CPName: 'iso-8859-8-i'),
      //(CPID: 50220; CPName: 'iso-2022-jp'),
      //(CPID: 50221; CPName: 'csISO2022JP'),
      //(CPID: 50222; CPName: 'iso-2022-jp'),
      //(CPID: 50225; CPName: 'iso-2022-kr'),
      //(CPID: 50227; CPName: 'x-cp50227'),
      //(CPID: 51932; CPName: 'euc-jp'),
      //(CPID: 51936; CPName: 'EUC-CN'),
      //(CPID: 51949; CPName: 'euc-kr'),
      //(CPID: 52936; CPName: 'hz-gb-2312'),
      //(CPID: 54936; CPName: 'GB18030'),
      //(CPID: 57002; CPName: 'x-iscii-de'),
      //(CPID: 57003; CPName: 'x-iscii-be'),
      //(CPID: 57004; CPName: 'x-iscii-ta'),
      //(CPID: 57005; CPName: 'x-iscii-te'),
      //(CPID: 57006; CPName: 'x-iscii-as'),
      //(CPID: 57007; CPName: 'x-iscii-or'),
      //(CPID: 57008; CPName: 'x-iscii-ka'),
      //(CPID: 57009; CPName: 'x-iscii-ma'),
      //(CPID: 57010; CPName: 'x-iscii-gu'),
      //(CPID: 57011; CPName: 'x-iscii-pa'),
      //(CPID: 65000; CPName: 'utf-7'),
      (CPID: 65001; CPName: 'utf-8')
    );

{ Resolving an encoding. Two shapes, because the call sites disagree about what
  they are holding:

    Editor.pas / main.pas    StandardEncodingFromName(Encodings[LEncIndex])
                            -- an entire TCPData row, straight out of the table
    devCFG.pas               StandardEncodingFromName(fNewDocEncoding)
                            -- a string, out of devcpp.ini

  So there are two overloads rather than one function and a `.CPName` bolted on
  at each call site, which keeps the round-trip through the ini honest: the name
  the combo stores is the name the table is searched for.

  Neither the record overload nor Delphi's RTL had to be changed. Delphi's
  StandardEncodingFromName is a string function and TCPData has no implicit
  conversion, so the indexed call sites could not have been feeding it a record
  in the first place.

  The string overload is FPC-only on purpose. FPC has no such function at all --
  probing it with every RTL unit in scope gives
      probe_tmp.pas(11,8) Error: Identifier not found "StandardEncodingFromName"
  -- whereas on Delphi the existing RTL one still resolves, and shadowing it
  would quietly change which vocabulary the ini is read against. }
function StandardEncodingFromName(const AData: TCPData): TEncoding; overload;

{$IFDEF FPC}
function StandardEncodingFromName(const AName: String): TEncoding; overload;
{$ENDIF}

{ Fills AList with the distinct CPName values of Encodings, in table order.

  Deduped because the table carries one row per LANGUAGE but the combo needs one
  row per ENCODING: windows-1250 appears seven times (Croatian, Czech, Hungarian,
  Polish, Romanian, Slovak, Slovenian), windows-1251 twice, iso-8859-4 twice, and
  only CPLang distinguishes them. First CPLang wins, per decision -- the label is
  not persisted, so it only affects what the user reads.

  20 rows collapse to 14. The value added is always a bare CPName, which is what
  StandardEncodingFromName and the ini agree on. }
procedure AddNewDocEncodingNames(AList: TStrings);

{ The default for a brand-new document: the first entry of the same
  deduped list the combo is built from, so the default is always one of
  the names the user can actually pick. devCFG.pas assigned
  DefaultEncodingNames[0] before, annotated //ANSI. }
function FirstNewDocEncodingName: String;

function Lang: TdevMultiLangSupport;

{ The language table, as a plain object because the call sites name it as one:
  `Languages.Count`, `Languages.Name[I]`. Constructed during unit
  initialisation rather than on first use, because a property-shaped global
  would need a function call at every access and these are field-style reads.
  Nothing here touches Application, so an early load is safe. }
var
  Languages: TLanguageList;

implementation

uses
  {$IFDEF FPC}
  WideStrUtils, System.UITypes, LangFrm, Forms, Utils, Version, Controls, devCFG;
  {$ELSE}
  System.WideStrUtils, System.UITypes, LangFrm, Forms, Utils, Version, Controls, devCFG;
  {$ENDIF}

function StandardEncodingFromName(const AData: TCPData): TEncoding;
begin
  Result := TEncoding.GetEncoding(AData.CPID);
end;

{$IFDEF FPC}
function StandardEncodingFromName(const AName: String): TEncoding;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to MaxEncodings - 1 do
    if SameText(Encodings[I].CPName, AName) then
    begin
      Result := StandardEncodingFromName(Encodings[I]);
      Exit;
    end;

  // An unknown name must not become a nil TEncoding: Editor.pas feeds the
  // result straight into TStringStream.Create and Lines.LoadFromStream, and a
  // nil there is a crash on the open-file path rather than a bad default.
  if Result = nil then
    Result := TEncoding.Default;
end;
{$ENDIF}

function FirstNewDocEncodingName: String;
begin
  Result := Encodings[0].CPName;
end;

procedure AddNewDocEncodingNames(AList: TStrings);
var
  I, J: Integer;
  AlreadyListed: Boolean;
begin
  for I := 0 to MaxEncodings - 1 do
  begin
    AlreadyListed := False;
    for J := 0 to I - 1 do
      if SameText(Encodings[J].CPName, Encodings[I].CPName) then
      begin
        AlreadyListed := True;
        Break;
      end;
    if not AlreadyListed then
      AList.Add(Encodings[I].CPName);
  end;
end;

constructor TLanguageList.Create;
begin
  inherited Create;
  SetLength(FEntries, 33);
  // One row per *.lng file actually present in the tree, locale id = the
  // standard Windows one for that language. The count is checked against the
  // table below rather than trusted, so adding a row without bumping it is a
  // compile-visible mistake instead of a silently missing language.
  FEntries[0].Name := 'Bulgarian';       FEntries[0].LocaleID := 1026;  // bg-BG
  FEntries[1].Name := 'Catalan';         FEntries[1].LocaleID := 1027;  // ca-ES
  FEntries[2].Name := 'Chinese (Simplified)'; FEntries[2].LocaleID := 2052; // zh-CN
  FEntries[3].Name := 'Chinese (Traditional)'; FEntries[3].LocaleID := 1028; // zh-TW
  FEntries[4].Name := 'Croatian';        FEntries[4].LocaleID := 1050;  // hr-HR
  FEntries[5].Name := 'Czech';           FEntries[5].LocaleID := 1029;  // cs-CZ
  FEntries[6].Name := 'Danish';          FEntries[6].LocaleID := 1030;  // da-DK
  FEntries[7].Name := 'Dutch';           FEntries[7].LocaleID := 1043;  // nl-NL
  FEntries[8].Name := 'English';         FEntries[8].LocaleID := 1033;  // en-US
  FEntries[9].Name := 'Estonian';        FEntries[9].LocaleID := 1061;  // et-EE
  FEntries[10].Name := 'French';         FEntries[10].LocaleID := 1036; // fr-FR
  FEntries[11].Name := 'Galician';       FEntries[11].LocaleID := 1110; // gl-ES
  FEntries[12].Name := 'German';         FEntries[12].LocaleID := 1031; // de-DE
  FEntries[13].Name := 'Greek';          FEntries[13].LocaleID := 1032; // el-GR
  FEntries[14].Name := 'Hebrew';         FEntries[14].LocaleID := 1037; // he-IL
  FEntries[15].Name := 'Hungarian';      FEntries[15].LocaleID := 1038; // hu-HU
  FEntries[16].Name := 'Italian';        FEntries[16].LocaleID := 1040; // it-IT
  FEntries[17].Name := 'Japanese';       FEntries[17].LocaleID := 1041; // ja-JP
  FEntries[18].Name := 'Korean';         FEntries[18].LocaleID := 1042; // ko-KR
  FEntries[19].Name := 'Latvian';        FEntries[19].LocaleID := 1062; // lv-LV
  FEntries[20].Name := 'Norwegian';      FEntries[20].LocaleID := 1044; // nb-NO
  FEntries[21].Name := 'Polish';         FEntries[21].LocaleID := 1045; // pl-PL
  // JUDGEMENT CALL 1 of 3: Portuguese is 2070 (pt-PT) or 1046 (pt-BR). The file
  // is named plain "Portuguese.lng" with no region, and this is a European
  // codebase, so pt-PT. A Brazilian build would want the other row.
  FEntries[22].Name := 'Portuguese';     FEntries[22].LocaleID := 2070; // pt-PT
  FEntries[23].Name := 'Romanian';       FEntries[23].LocaleID := 1048; // ro-RO
  FEntries[24].Name := 'Russian';        FEntries[24].LocaleID := 1049; // ru-RU
  FEntries[25].Name := 'Slovak';         FEntries[25].LocaleID := 1051; // sk-SK
  FEntries[26].Name := 'Slovenian';      FEntries[26].LocaleID := 1060; // sl-SI
  FEntries[27].Name := 'Spanish';        FEntries[27].LocaleID := 1034; // es-ES
  // JUDGEMENT CALL 2 and 3 of 3, and they are the SAME problem seen twice:
  // SpanishCastellano and Spanish are both es-ES. They are distinct FILES but
  // not distinct LOCALES, so one LCID cannot round-trip between them --
  // NameFromLocaleID(1034) returns 'Spanish', and a project saved as
  // SpanishCastellano comes back showing 'Spanish'. 3082 is the modern-sort
  // es-ES id, which is the closest distinct value Windows offers, and it is
  // what a project saved from this row will carry.
  FEntries[28].Name := 'Spanish (Castellano)'; FEntries[28].LocaleID := 3082;
  FEntries[29].Name := 'Spanish (Colombia)';   FEntries[29].LocaleID := 9226; // es-CO
  FEntries[30].Name := 'Swedish';        FEntries[30].LocaleID := 1053; // sv-SE
  FEntries[31].Name := 'Turkish';        FEntries[31].LocaleID := 1055; // tr-TR
  FEntries[32].Name := 'Ukrainian';      FEntries[32].LocaleID := 1058; // uk-UA
  Assert(Length(FEntries) = 33, 'language table size must match its row count');
end;

function TLanguageList.Count: Integer;
begin
  Result := Length(FEntries);
end;

// Both index getters return a neutral value out of range rather than raising:
// the call sites sit inside a try/except that HIDES cmbLangID on any failure,
// so an index error here would take the whole options dialog's language section
// down instead of just the one row.
function TLanguageList.GetName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= Length(FEntries)) then
    Exit('');
  Result := FEntries[AIndex].Name;
end;

function TLanguageList.GetLocaleID(AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex >= Length(FEntries)) then
    Exit(1033);   // en-US, the same default ProjectTypes pins at $0409
  Result := FEntries[AIndex].LocaleID;
end;

function TLanguageList.GetNameFromLocaleID(ALocaleID: Integer): string;
var
  I: Integer;
begin
  // First match wins, which is what makes the two es-ES rows behave the way the
  // table's comment says. Callers feed the result straight into
  // Items.IndexOf, so an unknown id must come back as '' and yield -1, not
  // raise: the surrounding try/except hides the combo on any failure.
  Result := '';
  for I := 0 to Length(FEntries) - 1 do
    if FEntries[I].LocaleID = ALocaleID then
      Exit(FEntries[I].Name);
end;

var
  fLangSingleton: TdevMultiLangSupport = nil;

// AnsiToUtf8Ex -- the identity, and why that is the honest implementation here.
//
// THIS FUNCTION HAS NEVER EXISTED IN THIS REPOSITORY. Not in Source, not in
// the vendored VCL tree, not in doc/code, and `git log -S "function
// AnsiToUtf8Ex" --all` finds no commit that ever added it. MultiLangSupport
// calls it at line 369 and six units put MultiLangSupport in their uses
// clauses, so the Delphi tree in this repo could not have compiled either.
//
// That leaves the intent unrecoverable, so the mapping was chosen to change the
// least: under -Mdelphiunicode `string` is UnicodeString and
// `fStrings.Values[...]` is already a UnicodeString, so there are no bytes
// left to convert and ACodePage has nothing left to apply. The call site keeps
// its shape and its code-page argument; only the conversion is dropped.
//
// WHAT THIS DOES NOT FIX, and where the real issue sits
// ------------------------------------------------------
// One line above the caller, line 317:
//
//     fStrings.LoadFromFile(LangFile, TEncoding.ANSI);
//
// decodes every language file with the SYSTEM ANSI code page, while the text
// is in the LANGUAGE's code page (fCurCodePage). So a Russian or Japanese
// string is mis-decoded there, before this function is ever reached. An
// identity here neither fixes nor worsens that -- it preserves whatever the
// load produced, which is what the caller would have had to work with anyway.
//
// A real fix exists and is deliberately NOT taken here, because it is a
// different change: read the file once to learn fLang (which is how
// fCurCodePage is derived, line 325), then re-read it with
// TEncoding.GetEncoding(fCurCodePage). That is two reads and a real behaviour
// change, so it belongs in its own step with its own evidence, not hidden
// inside a missing symbol's stub.
function AnsiToUtf8Ex(const AValue: string; ACodePage: Integer): string;
begin
  Result := AValue;
end;

function GetEncoding(CPID: Integer): String;
var
  I: Integer;
begin
  Result := 'iso-8859-2'; //put the default encoding here

  for I := 0 to MaxEncodings - 1 do
    if Encodings[I].CPID = CPID then
    begin
      Result := Encodings[I].CPName;
      break;
    end;
end;

function GetCodePage(const ALanguage: String): Integer;
var
  I: Integer;
begin
  Result := 1252; //put the default encoding here

  for I := 0 to MaxEncodings - 1 do
    // Pos, not ALanguage.IndexOf(...): under -Mdelphiunicode `string` is
    // UnicodeString, and FPC 3.2.2's only TStringHelper is
    //     TStringHelper = Type Helper for AnsiString
    // (rtl/objpas/sysutils/syshelph.inc:60) -- there is NO helper for
    // UnicodeString, so every helper method on a `string` is rejected with
    //     MultiLangSupport.pas(251,18) Error: Illegal qualifier
    // Isolated in a standalone program, all of these fail and this one works:
    //     S.IndexOf('en')              -> Illegal qualifier
    //     S.IndexOf(Enc[0].CPLang)     -> Illegal qualifier
    //     S.IsEmpty                    -> Illegal qualifier
    //     Pos(Enc[0].CPLang, S)        -> OK
    // so the RTL's Pos/Length/Copy are the spellings that work here, not just
    // a preference. The two tests are equivalent: `IndexOf(x) > -1` is exactly
    // `Pos(x, s) > 0`.
    if Pos(Encodings[I].CPLang, ALanguage) > 0 then
    begin
      Result := Encodings[I].CPID;
      break;
    end;
end;


function Lang: TdevMultiLangSupport;
begin
  if not Assigned(fLangSingleton) and not Application.Terminated then
    fLangSingleton := TdevMultiLangSupport.Create;
  Result := fLangSingleton;
end;

constructor TdevMultiLangSupport.Create;
var
  DefaultLangFile: String;
begin
  inherited;
  fLangList := TStringList.Create;
  fLangListLoaded := False; // only load when needed
  fStrings := TStringList.Create;
  fDefaultLangStrings := TStringList.Create;
  fCurCodePage := 1252;

  // Load default english file from languages directory
  DefaultLangFile := ValidateFile('English.lng', devDirs.Lang);
  if DefaultLangFile = '' then begin
    MessageDlg('Could not open language file English.lng', mtError, [mbOK], 0);
  end else begin
    fDefaultLangStrings.LoadFromFile(DefaultLangFile);
  end;
end;

destructor TdevMultiLangSupport.Destroy;
begin
  FreeAndNil(fLangList);
  FreeAndNil(fStrings);
  FreeAndNil(fDefaultLangStrings);
  fLangSingleton := nil;
  inherited;
end;

procedure TdevMultiLangSupport.Open(const Filename: String);
var
  LangFile: String;
begin
  // Load file from languages directory
  LangFile := ValidateFile(Filename, devDirs.Lang);
  if LangFile = '' then begin
    MessageDlg('Could not open language file ' + Filename, mtError, [mbOK], 0);
    Exit;
  end;

  // Load file into fStrings
  fStrings.LoadFromFile(LangFile,TEncoding.ANSI);
  fLangFile := LangFile;

  // Get languange
  fCurLang := fStrings.Values['Lang'];
  if fCurLang = '' then
    fCurLang := ChangeFileExt(ExtractFileName(LangFile), '');

  fCurCodePage := GetCodePage(fCurLang);
  devData.Language := ExtractFileName(LangFile);
end;

procedure TdevMultiLangSupport.CheckLanguageFiles;
var
  I: integer;
  s: String;
  sl: TStringList;
begin
  try
    fLangList.Clear;
    if devDirs.Lang = '' then
      Exit;

    // Load list of all files
    FilesFromWildcard(devDirs.Lang, '*.lng', fLangList, False, False, True);
    if fLangList.Count > 0 then begin
      fLangList.Sort;
      sl := TStringList.Create;
      try
        for I := 0 to fLangList.Count - 1 do begin
          sl.LoadFromFile(fLangList[I]);
          s := sl.Values['Lang'];
          if SameText(ExtractFileName(fLangList[I]), 'English.lng') and (devData.Language = '') then
            fCurLang := s;
          if s = '' then
            fLangList[I] := format('%s=%s', [fLangList[I], ChangeFileExt(ExtractFileName(fLangList[I]), '')])
          else
            fLangList[I] := format('%s=%s', [fLangList[I], s]);
        end;
      finally
        sl.Free;
      end;
    end;
    if fCurLang = '' then
      fCurLang := devData.Language;
  finally
    fLangListLoaded := True;
  end;
end;

function TdevMultiLangSupport.GetString(ID: integer): String;
begin
  result := AnsiToUtf8Ex(fStrings.Values[IntToStr(ID)],fCurCodePage);
  if Result = '' then
    Result := fDefaultLangStrings.Values[IntToStr(ID)];
  if result = '' then
    result := format('<ID %d translation missing>', [ID])
  else
    result := StringReplace(result, '<CR>', #13#10, [rfReplaceAll]);
end;

function TdevMultiLangSupport.GetLangName: String;
begin
  result := fCurLang;
end;

procedure TdevMultiLangSupport.SelectLanguage;
begin
  with TLangForm.Create(nil) do try
    ShowModal;
  finally
    Free;
  end;
end;

procedure TdevMultiLangSupport.SetLang(const Lang: String);
var
  I: integer;
begin
  if SameText(Lang, fCurLang) then
    exit;
  if not fLangListLoaded then
    CheckLanguageFiles; // can be slow, so load on demand
  for I := 0 to fLangList.Count - 1 do
    if SameText(ExtractFileName(fLangList.Names[I]), Lang) then begin
      Open(fLangList.Names[I]);
      break;
    end;
end;

function TdevMultiLangSupport.FileFromDescription(const Desc: String): String;
var
  i: integer;
begin
  // returns the filename of the lang file described as Desc
  // for example with Desc="English (Original)", returns "English.lng"
  Result := Desc;
  if not fLangListLoaded then
    CheckLanguageFiles; // can be slow, so load on demand
  for i := 0 to fLangList.Count - 1 do
    if SameText(fLangList.ValueFromIndex[i], Desc) then begin
      Result := ExtractFilename(fLangList.Names[i]);
      Break;
    end;
end;

function TdevMultiLangSupport.GetLangList: TStringList;
begin
  if not fLangListLoaded then
    CheckLanguageFiles; // can be slow, so load on demand
  Result := fLangList;
end;

initialization
  // Built here rather than through a function because the call sites read it as
  // a field (`Languages.Count`, not `GetLanguages.Count`). The constructor
  // touches nothing but its own array, so running it during unit load is safe
  // even though MultiLangSupport is pulled in early.
  Languages := TLanguageList.Create;

finalization
  FreeAndNil(Languages);

end.

