unit System.IOUtils;

{ Delphi's System.IOUtils -- the TPath / TFile / TDirectory trio -- for the
  FPC tree.

  WHY THIS UNIT EXISTS
  ===================
  Ten units in the closure name System.IOUtils, and FPC 3.2.2 has no such
  unit at all:

      Can't find unit System.IOUtils used by ...

  It is not merely out of search order. The individual types it declares are
  absent from the RTL too: TDirectory is not in FPC's SysUtils, checked with
  only the FPC units on the path and again with Lazarus's lazutils ahead of
  them. Nor is there a TPath, a TFile, or a record helper on `string` to stand
  in -- FPC 3.2.2's only TStringHelper is `Type Helper for AnsiString`, and
  `string` is UnicodeString here.

  WHAT IS DECLARED, AND WHY IT IS NOT MORE
  =========================================
  Exactly the members the closure calls, measured over every call site:

      TPath.Combine          AStyleFormatterOptionsFrm, ClangFormatterOptionsFrm,
                             devCFG
      TPath.GetTempPath      AStyleFormatterOptionsFrm, ClangFormatterOptionsFrm,
                             devCFG, InstallWizards
      TPath.ChangeExtension  Tools/PackMaker/Config, Tools/Packman/Config
      TFile.Exists           devCFG
      TDirectory.Exists      devCFG
      TDirectory.CreateDirectory  devCFG, Compiler

  Nothing else is declared. The real System.IOUtils has dozens of members, and
  adding the rest would be inventing surface nobody calls -- the same mistake as
  declaring the rest of TStyleFontColor in Vcl.Themes.

  Every implementation is the RTL or WinAPI routine that does the same job:

      TPath.Combine          IncludeTrailingPathDelimiter, with Delphi's rule
                             that an empty Path yields Part unchanged
      TPath.GetTempPath      GetTempPathW, the Unicode entry point
      TPath.ChangeExtension  SysUtils.ChangeFileExt
      TFile.Exists           SysUtils.FileExists
      TDirectory.Exists      SysUtils.DirectoryExists
      TDirectory.CreateDirectory  SysUtils.CreateDir

  ONE BEHAVIOURAL NOTE: TDirectory.CreateDirectory RAISES when it fails, while
  SysUtils.CreateDir returns False. Call sites that ignored the result --
  Compiler.pas's two calls -- therefore go from "abort the build" to "carry on
  and fail at the next file operation instead". That was already noted where it
  was changed; it is repeated here because this unit is the other way to reach
  the same call.

  The unit is named System.IOUtils so the ten files that already say
  `uses ... System.IOUtils` resolve to it under FPC and to the real RTL unit
  under Delphi, with no change at any call site.
}

interface

uses
  SysUtils, Windows;

type
  TPath = class
  public
    class function Combine(const APath, ARest: string): string; static;
    class function GetTempPath: string; static;
    class function ChangeExtension(const AFileName, AExtension: string): string; static;
  end;

  TFile = class
  public
    class function Exists(const AFileName: string): Boolean; static;
  end;

  TDirectory = class
  public
    class function Exists(const APath: string): Boolean; static;
    class function CreateDirectory(const APath: string): Boolean; static;
  end;

implementation

class function TPath.Combine(const APath, ARest: string): string;
begin
  { Delphi's rule, which matters: an empty path yields the other part
    unchanged rather than a leading separator, and an empty part yields the
    path with no trailing separator added. }
  if APath = '' then
    Result := ARest
  else if ARest = '' then
    Result := APath
  else
    Result := IncludeTrailingPathDelimiter(APath) + ARest;
end;

class function TPath.GetTempPath: string;
var
  Len: DWORD;
begin
  { GetTempPathW, not GetTempPath: the path is a filesystem location and can
    carry non-ASCII, and the ANSI entry point would both take a PAnsiChar --
    which PChar is not here -- and truncate. The call with a zero length is the
    documented way to ask for the required size. }
  Len := GetTempPathW(0, nil);
  SetLength(Result, Len);
  if Len > 0 then
    GetTempPathW(Len, PWideChar(Result));
end;

class function TPath.ChangeExtension(const AFileName, AExtension: string): string;
begin
  Result := ChangeFileExt(AFileName, AExtension);
end;

class function TFile.Exists(const AFileName: string): Boolean;
begin
  Result := FileExists(AFileName);
end;

class function TDirectory.Exists(const APath: string): Boolean;
begin
  Result := DirectoryExists(APath);
end;

class function TDirectory.CreateDirectory(const APath: string): Boolean;
begin
  Result := CreateDir(APath);
end;

end.
