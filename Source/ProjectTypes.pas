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

unit ProjectTypes;

interface

uses
  Classes, editor, ComCtrls, Windows;

const
  dptGUI = 0;
  dptCon = 1;
  dptStat = 2;
  dptDyn = 3;

type
  TProjType = byte;
  TProjTypeSet = set of TProjType;

  TProjVersionInfo = class(TPersistent) // allow deep copies
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
  public
    Major: integer;
    Minor: integer;
    Release: integer;
    Build: integer;
    LanguageID: integer;
    CharsetID: integer;
    CompanyName: String;
    FileVersion: String;
    FileDescription: String;
    InternalName: String;
    LegalCopyright: String;
    LegalTrademarks: String;
    OriginalFilename: String;
    ProductName: String;
    ProductVersion: String;
    AutoIncBuildNr: boolean;
    SyncProduct: boolean;
  end;

  TCompilerOptionsValues = TArray<Integer>;



  TProjOptions = class(TPersistent) // allow deep copies
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
  public
    typ: TProjType;
    Ver: integer;
    Objfiles: TStrings;
    CompilerCmd: String;
    CppCompilerCmd: String;
    LinkerCmd: String;
    Includes: TStrings;
    Libs: TStrings;
    PrivateResource: String; // Dev-C++ will overwrite this file
    ResourceIncludes: TStrings;
    MakeIncludes: TStrings;
    useGPP: boolean;
    Icon: String;
    ExeOutput: String;
    ObjectOutput: String;
    LogOutput: String;
    LogOutputEnabled: boolean;
    UseCustomMakefile: boolean;
    CustomMakefile: String;
    OverrideOutput: boolean;
    OverridenOutput: String;
    HostApplication: String;
    IncludeVersionInfo: boolean;
    SupportXPThemes: boolean;
    CompilerSet: integer;
    CompilerOptions: TCompilerOptionsValues;
    VersionInfo: TProjVersionInfo;
    CmdLineArgs: String;
  end;


  TCompilerOptionsValuesHelper = record helper for TCompilerOptionsValues
  private
    function GetOptionValue(const Index: Integer): Integer;
  public
    function ToString: string;
    property OptionValue[const Index: Integer]: Integer read GetOptionValue;
    // FPC: a record helper's methods are static, and the compiler says so
    // ("Class methods must be static in records"). Delphi allows the class
    // function here because a Delphi record method has no implicit Self.
    class function FromString(const AStr: string): TArray<Integer>; static;
  end;


{ Read and write the project's compiler-option settings.
  FPC 3.2.2 has neither `TArray<T>.FromString` nor `TArray<T>.ToString` -- not
  in the RTL, not in Generics.Collections -- and the tree uses both in five
  places (Project.pas:772 and :848, devCFG.pas:2045 and :2118,
  NewTemplateFrm.pas:318). They are free functions here because
  TCompilerOptionsValues is a type ALIAS of TArray<Integer>, so there is no
  class to hang a method on.

  WHY THIS FORMAT, MEASURED
  =========================
  Every shipped .dev file in the tree writes the settings as one CHARACTER per
  option, with no separators. All eight are 25 characters long:

      ConsolePauser.dev       0000000100111000000001001
      devcppPortable.dev      0000000100111000000011001
      KeywordHighlighter.dev  00000001g0111000000001001

  and Templates/Project3.template holds a single `0`, i.e. one option -- so the
  width follows the option count rather than being a fixed constant.

  Delphi's own `TArray<Integer>.ToString` emits COMMAS, so it cannot be what
  wrote these. The on-disk shape is the authority here: a comma-separated
  reader would parse every existing project as "no options" and silently reset
  all 25 of them to zero.

  READING is deliberately lenient and accepts BOTH shapes. A comma means the
  comma-separated form (each field a full integer); no comma means one
  character per option. Accepting the second shape costs nothing and rescues
  any file a Delphi build wrote.

  WRITING emits the legacy character-per-option form, matching every file in the
  tree. ONE RECORDED LIMITATION: three option lists carry more than ten choices
  (12, 39 and 85 -- measured over every AddOption call in devCFG.pas), so a
  value above 9 has no room in one character. Out-of-range values are written as
  0 rather than as decimal digits, because emitting the digits would shift every
  following field and corrupt all the options after it. No shipped file carries
  such a value -- all of them are 0 or 1 -- so this is a latent limit rather
  than an observed one, and it is why the alternative (comma-separated writing)
  was not taken: it would make the FPC build disagree with the Delphi build on
  every project save.
}
function CompilerOptionsFromString(const AValue: string): TCompilerOptionsValues;
function CompilerOptionsToString(const AValue: TCompilerOptionsValues): string;

implementation

uses
  devcfg, SysUtils;

function CompilerOptionsFromString(const AValue: string): TCompilerOptionsValues;
var
  I: Integer;
  SL: TStringList;
begin
  SetLength(Result, 0);
  if AValue = '' then
    Exit;

  if Pos(',', AValue) > 0 then
  begin
    // The comma-separated shape -- what Delphi's TArray<Integer>.ToString
    // writes. Each field is a full integer, not a digit.
    SL := TStringList.Create;
    try
      SL.Delimiter := ',';
      SL.StrictDelimiter := True;
      SL.DelimitedText := AValue;
      SetLength(Result, SL.Count);
      for I := 0 to SL.Count - 1 do
        Result[I] := StrToIntDef(Trim(SL[I]), 0);
    finally
      SL.Free;
    end;
    Exit;
  end;

  // The shape every shipped .dev file uses: one character per option. A
  // character that is not a digit is read as 0 rather than raising --
  // KeywordHighlighter.dev really does carry a 'g' in that field, and a parser
  // that refused it would take the whole project down over one stray keystroke.
  SetLength(Result, Length(AValue));
  for I := 1 to Length(AValue) do
    if (AValue[I] >= '0') and (AValue[I] <= '9') then
      Result[I - 1] := Ord(AValue[I]) - Ord('0')
    else
      Result[I - 1] := 0;
end;

function CompilerOptionsToString(const AValue: TCompilerOptionsValues): string;
var
  I: Integer;
begin
  SetLength(Result, Length(AValue));
  for I := 0 to High(AValue) do
    // 0..9 is a digit; anything else has no single-character encoding. See the
    // interface comment: writing the decimal digits would shift every field
    // after it, so out-of-range values are pinned to 0 instead.
    if (AValue[I] >= 0) and (AValue[I] <= 9) then
      Result[I + 1] := Chr(Ord('0') + AValue[I])
    else
      Result[I + 1] := '0';
end;

constructor TProjVersionInfo.Create;
begin
  inherited Create;

  Major := 1;
  Minor := 0;
  Release := 0;
  Build := 0;
  LanguageID := $0409; // US English
  CharsetID := $04E4; // Windows multilingual
  CompanyName := '';
  FileVersion := '';
  FileDescription := 'Developed using the Dev-C++ IDE';
  InternalName := '';
  LegalCopyright := '';
  LegalTrademarks := '';
  OriginalFilename := '';
  ProductName := '';
  ProductVersion := '';
  AutoIncBuildNr := False;
  SyncProduct := True;
end;

procedure TProjVersionInfo.Assign(Source: TPersistent);
var
  input: TProjVersionInfo;
begin
  input := TProjVersionInfo(Source);

  Major := input.Major;
  Minor := input.Minor;
  Release := input.Release;
  Build := input.Build;
  LanguageID := input.LanguageID;
  CharsetID := input.CharsetID;
  CompanyName := input.CompanyName;
  FileVersion := input.FileVersion;
  FileDescription := input.FileDescription;
  InternalName := input.InternalName;
  LegalCopyright := input.LegalCopyright;
  LegalTrademarks := input.LegalTrademarks;
  OriginalFilename := input.OriginalFilename;
  ProductName := input.ProductName;
  ProductVersion := input.ProductVersion;
  AutoIncBuildNr := input.AutoIncBuildNr;
  SyncProduct := input.SyncProduct;
end;

constructor TProjOptions.Create;
begin
  inherited Create;

  Ver := 2; // 2 since 5.2.0.3
  Includes := TStringList.Create;
  Libs := TStringList.Create;
  ResourceIncludes := TStringList.Create;
  MakeIncludes := TStringList.Create;
  ObjFiles := TStringList.Create;
  Includes.Delimiter := ';';
  Libs.Delimiter := ';';
  PrivateResource := '';
  ResourceIncludes.Delimiter := ';';
  MakeIncludes.Delimiter := ';';
  ObjFiles.Delimiter := ';';
  Icon := '';
  ExeOutput := '';
  ObjectOutput := '';
  HostApplication := '';
  SupportXPThemes := False;
  CompilerSet := devCompilerSets.DefaultSetIndex;
  if (CompilerSet < devCompilerSets.Count) and (CompilerSet >= 0) then
    CompilerOptions := devCompilerSets[CompilerSet].INIOptions
  else
    CompilerOptions := [];
  VersionInfo := TProjVersionInfo.Create;
  IncludeVersionInfo := False;
end;

destructor TProjOptions.Destroy;
begin
  Includes.Free;
  Libs.Free;
  ResourceIncludes.Free;
  MakeIncludes.Free;
  ObjFiles.Free;
  VersionInfo.Free;

  inherited;
end;

procedure TProjOptions.Assign(Source: TPersistent);
var
  input: TProjOptions;
begin
  input := TProjOptions(Source);

  typ := input.typ;
  Ver := input.Ver;
  Objfiles.Assign(input.Objfiles);
  CompilerCmd := input.CompilerCmd;
  CppCompilerCmd := input.CppCompilerCmd;
  LinkerCmd := input.LinkerCmd;
  Includes.Assign(input.Includes);
  Libs.Assign(input.Libs);
  PrivateResource := input.PrivateResource;
  ResourceIncludes.Assign(input.ResourceIncludes);
  MakeIncludes.Assign(input.MakeIncludes);
  useGPP := input.useGPP;
  Icon := input.Icon;
  ExeOutput := input.ExeOutput;
  ObjectOutput := input.ObjectOutput;
  LogOutput := input.LogOutput;
  LogOutputEnabled := input.LogOutputEnabled;
  UseCustomMakefile := input.UseCustomMakefile;
  CustomMakefile := input.CustomMakefile;
  OverrideOutput := input.OverrideOutput;
  OverridenOutput := input.OverridenOutput;
  HostApplication := input.HostApplication;
  IncludeVersionInfo := input.IncludeVersionInfo;
  SupportXPThemes := input.SupportXPThemes;
  CompilerSet := input.CompilerSet;
  CompilerOptions := input.CompilerOptions;
  VersionInfo.Assign(input.VersionInfo);
  CmdLineArgs := input.CmdLineArgs;
end;

{ TCompilerOptionsHelper }

class function TCompilerOptionsValuesHelper.FromString(const AStr: string): TArray<Integer>;
begin
  Result := [];
  if AStr.IndexOf(';')>-1 then
  begin
    // read compiler options with a ; delimiter
    for var OV in AStr.Split([';']) do
      Result := Result + [StrToIntDef(OV.Trim, 0)];
  end
  else
  begin
    // read compiler options that have no delimiter
    for var OV in AStr do
      Result := Result + [StrToIntDef(OV, 0)];
  end;
end;

function TCompilerOptionsValuesHelper.GetOptionValue(const Index: Integer): Integer;
begin
  if (Index > High(Self)) or (Index < Low(Self)) then
    Result := 0
  else
    Result := Self[Index];
end;

function TCompilerOptionsValuesHelper.ToString: string;
begin
  Result := '';
  for var OV in Self do
    if Result = '' then
      Result := OV.ToString
    else
      Result := Result + ';' + OV.ToString;
end;

end.

