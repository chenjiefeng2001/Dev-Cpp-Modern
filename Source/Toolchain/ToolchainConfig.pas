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

unit ToolchainConfig;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, SyncObjs,
  // FPC has no `Winapi` tree (measured across all 8603 shipped sources: the
  // directory does not exist) and refuses to compile a unit whose NAME contains
  // a dot, so an alias shim cannot bridge it in any layout -- the same finding
  // that drove tools/fpc_uses_rewrite.py. The equivalent unit is `Windows`.
  // Every identifier this unit uses was verified present in that RTL before the
  // spelling was changed: CreatePipe, CreateProcess, GetStdHandle, SW_HIDE,
  // SetHandleInformation, THandle, WaitForSingleObject, CloseHandle.
  //
  // This branch had never been compiled before 2026-10-05: the FPC builds ran
  // the PORTABLE variant, where TEST_TOOLCHAIN is undefined, so this uses clause
  // was never handed to the parser. It surfaced as
  //     ToolchainConfig.pas(30,3) Fatal: Can't find unit Winapi.Windows
  // only once the Windows variant was actually built.
  Windows,
  {$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  Winapi.Windows,
  {$ENDIF}
  Core.Services;

// Toolchain Profile Types
type
  // Supported toolchain profiles
  TToolchainProfile = (tcpGCC14UCRT, tcpGCC14MT, tcpLLVMMinGW, tcpCustom);

// Architecture Targets
type
  TArchitecture = (arWin32, arWin64, arLinux, armac64);

// Detected Toolchain Paths
type
  TDetectedToolchainPaths = record
    GCCPath: String;
    MakePath: String;
    GDBPath: String;
    LLVMPath: String;
    Valid: Boolean;
    Version: String;
    UCRT: Boolean;
  end;

// Toolchain Configuration Record
type
  TToolchainConfig = record
    Profile: TToolchainProfile;
    Architecture: TArchitecture;
    GCCVersion: String; // e.g., "14.1.0"
    UCRT: Boolean; // Use Windows Universal C Runtime
    Prefix: String; // e.g., "x86_64-w64-mingw32"
    Sysroot: String;
    CFlags: String;
    CXXFlags: String;
    LinkerFlags: String;
  end;

// Compile/Link event types
type
  TCompilerMessageEvent = procedure(const Message: String; const ErrorLevel: Integer) of object;
  TDebuggerMessageEvent = procedure(const Message: String) of object;

// Toolchain Service Interface
// (接口内禁止 event 关键字; 进度回调走方法式属性)
type
  IToolchainService = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567896}']
    function GetCurrentProfile: TToolchainConfig;
    function SetProfile(Profile: TToolchainProfile): Boolean;
    function GetGCCPath: String;
    function GetMakePath: String;
    function GetGDBPath: String;
    function GetOnCompileProgress: TCompilerMessageEvent;
    procedure SetOnCompileProgress(const AHandler: TCompilerMessageEvent);
    function DetectToolchainPaths(out Paths: TDetectedToolchainPaths): Boolean;
    function Compile(const FileName: String; out Errors: String): Boolean;
    function Link(const Files: array of String; out Executable: String): Boolean;
    property CurrentProfile: TToolchainConfig read GetCurrentProfile;
    property OnCompileProgress: TCompilerMessageEvent
      read GetOnCompileProgress write SetOnCompileProgress;
  end;

// Toolchain Implementation
type
  TToolchainService = class(TInterfacedObject, IToolchainService)
  private
    FProfile: TToolchainConfig;
    FPaths: TDetectedToolchainPaths;
    FHasPaths: Boolean;
    FOnCompileProgress: TCompilerMessageEvent;
    function GetCurrentProfile: TToolchainConfig;
    function SetProfile(Profile: TToolchainProfile): Boolean;
    function GetGCCPath: String;
    function GetMakePath: String;
    function GetGDBPath: String;
    function GetOnCompileProgress: TCompilerMessageEvent;
    procedure SetOnCompileProgress(const AHandler: TCompilerMessageEvent);
    function DetectToolchainPaths(out Paths: TDetectedToolchainPaths): Boolean;
    function ProbeBinDir(const ABinDir: String;
      out AVersion: String; out AUCRT: Boolean): Boolean;
    function CaptureConsoleOutput(const AExe, AArgs: String;
      ATimeoutMs: Cardinal; out AOutput: String): Boolean;
    function ExtractVersionToken(const AText: String): String;
    procedure EmitProgress(const AMessage: String; ALevel: Integer);
  public
    class var Instance: IToolchainService;
    constructor Create;
    destructor Destroy; override;
    function Compile(const FileName: String; out Errors: String): Boolean;
    function Link(const Files: array of String; out Executable: String): Boolean;
  end;

implementation

uses
  // SplitString. Delphi reaches it through the implicit StrUtils in System, so
  // listing it again is redundant there but legal; FPC has no implicit unit and
  // refused the bare name outright:
  //     ToolchainConfig.pas(437,17) Error: Identifier not found "SplitString"
  // Verified present with an identical signature: rtl/objpas/strutils.pp:80.
  //
  // Deliberately NOT wrapped in {$IFDEF FPC}. An empty uses list cannot be
  // followed by a bare `;` -- FPC reports
  //     ToolchainConfig.pas(152,3) Fatal: Syntax error, "identifier" expected
  //                                    but ";" found
  // and a unit that BOTH compilers accept is simpler than a conditional one.
  // TStringDynArray (the type SplitString returns) is declared in
  // rtl/objpas/types.pp:66, not in StrUtils. Verified there rather than
  // assumed, after StrUtils alone left the name unresolved.
  Types,
  StrUtils;
// Delphi's SysUtils.GetEnvironmentVariable(const Name: string): string and FPC's
// are the SAME function (rtl/objpas/sysutils.pp:246 and siblings). The call sites
// below stopped resolving only because this unit also uses the Windows unit,
// which declares a DIFFERENT, PChar-based one in the same namespace and wins the
// unqualified lookup under Delphi's last-unit-wins rule:
//
//     ToolchainConfig.pas(419,16) Error: Wrong number of parameters specified
//                                      for call to "GetEnvironmentVariable"
//     ascdef.inc(75,10) Error: Found declaration:
//       GetEnvironmentVariable(PChar;PChar;LongWord):DWord;
//
// A unit-qualified call pins the intended overload and compiles unchanged under
// both trees, so no {$IFDEF} copy of those call sites is needed.
function EnvVar(const AName: String): String;
begin
  Result := SysUtils.GetEnvironmentVariable(AName);
end;

{ TToolchainService }

constructor TToolchainService.Create;
begin
  inherited Create;
  FProfile.Profile := tcpGCC14UCRT;
  FProfile.Architecture := arWin64;
  FProfile.GCCVersion := '14.1.0';
  FProfile.UCRT := True;
  FProfile.Prefix := 'x86_64-w64-mingw32';
  FProfile.Sysroot := '';
  FProfile.CFlags := '-std=c++20 -finput-charset=UTF-8 -fexec-charset=UTF-8';
  FProfile.CXXFlags := '-std=c++20 -finput-charset=UTF-8 -fexec-charset=UTF-8 -O2 -g';
  FProfile.LinkerFlags := '-static-libstdc++ -static-libgcc';
  FHasPaths := False;
end;

destructor TToolchainService.Destroy;
begin
  inherited;
end;

function TToolchainService.GetCurrentProfile: TToolchainConfig;
begin
  Result := FProfile;
end;

function TToolchainService.SetProfile(Profile: TToolchainProfile): Boolean;
begin
  try
    case Profile of
      tcpGCC14UCRT:
        begin
          FProfile.Profile := tcpGCC14UCRT;
          FProfile.Architecture := arWin64;
          FProfile.GCCVersion := '14.1.0';
          FProfile.UCRT := True;
          FProfile.Prefix := 'x86_64-w64-mingw32';
          FProfile.CFlags := '-std=c++20 -finput-charset=UTF-8 -fexec-charset=UTF-8';
          FProfile.CXXFlags := '-std=c++20 -finput-charset=UTF-8 -fexec-charset=UTF-8 -O2 -g';
          FProfile.LinkerFlags := '-static-libstdc++ -static-libgcc';
        end;
      tcpGCC14MT:
        begin
          FProfile.Profile := tcpGCC14MT;
          FProfile.Architecture := arWin64;
          FProfile.GCCVersion := '14.1.0';
          FProfile.UCRT := False;
          FProfile.Prefix := 'x86_64-w64-mingw32';
          FProfile.CFlags := '-std=c++20 -O2 -g';
          FProfile.CXXFlags := '-std=c++20 -O2 -g -static';
          FProfile.LinkerFlags := '-static';
        end;
      tcpLLVMMinGW:
        begin
          FProfile.Profile := tcpLLVMMinGW;
          FProfile.Architecture := arWin64;
          FProfile.GCCVersion := '16.0.6';
          FProfile.UCRT := True;
          FProfile.Prefix := 'clang64';
          FProfile.CFlags := '-std=c++20 -finput-charset=UTF-8';
          FProfile.CXXFlags := '-std=c++20 -finput-charset=UTF-8 -O2 -g';
          FProfile.LinkerFlags := '-fuse-ld=lld -stdlib=libc++';
        end;
      tcpCustom:
        begin
          // Custom profile - keep existing settings
        end;
    end;
    // 切换 Profile 后探测缓存失效
    FHasPaths := False;
    Result := True;
  except
    Result := False;
  end;
end;

function TToolchainService.GetGCCPath: String;
begin
  if not FHasPaths then
    DetectToolchainPaths(FPaths);
  Result := FPaths.GCCPath;
end;

function TToolchainService.GetMakePath: String;
begin
  if not FHasPaths then
    DetectToolchainPaths(FPaths);
  Result := FPaths.MakePath;
end;

function TToolchainService.GetGDBPath: String;
begin
  if not FHasPaths then
    DetectToolchainPaths(FPaths);
  Result := FPaths.GDBPath;
end;

function TToolchainService.GetOnCompileProgress: TCompilerMessageEvent;
begin
  Result := FOnCompileProgress;
end;

procedure TToolchainService.SetOnCompileProgress(const AHandler: TCompilerMessageEvent);
begin
  FOnCompileProgress := AHandler;
end;

procedure TToolchainService.EmitProgress(const AMessage: String; ALevel: Integer);
begin
  if Assigned(FOnCompileProgress) then
  try
    FOnCompileProgress(AMessage, ALevel);
  except
  end;
end;

// 无控制台静默执行并捕获 stdout (隐藏窗口, 超时强杀)
function TToolchainService.CaptureConsoleOutput(const AExe, AArgs: String;
  ATimeoutMs: Cardinal; out AOutput: String): Boolean;
var
  SA: TSecurityAttributes;
  ReadPipe, WritePipe: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  Buf: array[0..4095] of Byte;
  BytesRead: DWORD;
  Accum: TBytes;
  OldLen: Integer;
  WaitRes: DWORD;
begin
  Result := False;
  AOutput := '';
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then
    Exit;
  try
    // 父进程不继承读端
    SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    SI.hStdOutput := WritePipe;
    SI.hStdError := WritePipe;
    CmdLine := '"' + AExe + '" ' + AArgs;
    UniqueString(CmdLine);
    FillChar(PI, SizeOf(PI), 0);
    // The cast WIDTH is a property of the compiler, so it cannot be spelled
    // unconditionally -- an earlier attempt at `PAnsiChar` for both trees fixed
    // FPC and would have broken Delphi, whose Winapi.Windows.CreateProcess takes
    // the WIDE entry point and whose PChar is therefore the correct argument
    // (Lsp.Process.Win32.pas:124 uses exactly that and compiles today).
    //
    // FPC disagrees: its Windows unit binds the bare name to the ANSI entry
    // point (rtl/win/ascdef.inc:359 -> LPCSTR/LPSTR), while -Mdelphiunicode
    // makes PChar PWideChar, so the original cast reported
    //     Incompatible type for arg no. 2: Got "PWideChar", expected "PChar"
    // with the CALLEE's PChar being the 8-bit one. Hence the conditional.
    {$IFDEF FPC}
    if not CreateProcess(nil, PAnsiChar(CmdLine), nil, nil, True,
    {$ELSE}
    if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    {$ENDIF}
      CREATE_NO_WINDOW, nil, nil, SI, PI) then
      Exit;
    try
      WaitRes := WaitForSingleObject(PI.hProcess, ATimeoutMs);
      if WaitRes = WAIT_TIMEOUT then
      begin
        TerminateProcess(PI.hProcess, 1);
        Exit;
      end;
      // 读完管道剩余数据 (按字节累积, 最后统一 UTF-8 解码,
      // 避免 SetString 在 AnsiString/UTF8String var 形参上的类型不匹配)
      SetLength(Accum, 0);
      CloseHandle(WritePipe);
      WritePipe := 0;
      while ReadFile(ReadPipe, Buf[0], SizeOf(Buf), BytesRead, nil) and
        (BytesRead > 0) do
      begin
        OldLen := Length(Accum);
        SetLength(Accum, OldLen + BytesRead);
        Move(Buf[0], Accum[OldLen], BytesRead);
      end;
      AOutput := TEncoding.UTF8.GetString(Accum);
      Result := True;
    finally
      CloseHandle(PI.hThread);
      CloseHandle(PI.hProcess);
    end;
  finally
    if WritePipe <> 0 then
      CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

// 从 "--version" 首行提取 "14.2.0" 形 token
function TToolchainService.ExtractVersionToken(const AText: String): String;
var
  I, Start: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] in ['0'..'9']) then
    begin
      Start := I;
      while (I <= Length(AText)) and (AText[I] in ['0'..'9', '.']) do
        Inc(I);
      Result := Copy(AText, Start, I - Start);
      // 至少形如 X.Y 才算版本
      if (Pos('.', Result) > 0) and (Length(Result) >= 3) then
        Exit;
      Result := '';
    end
    else
      Inc(I);
  end;
end;

// 探测单个 bin 目录: gcc.exe 存在 + --version 可执行
function TToolchainService.ProbeBinDir(const ABinDir: String;
  out AVersion: String; out AUCRT: Boolean): Boolean;
var
  Gcc: string;
  Outp: string;
begin
  Result := False;
  AVersion := '';
  AUCRT := False;
  if Trim(ABinDir) = '' then
    Exit;
  Gcc := IncludeTrailingPathDelimiter(ABinDir) + 'gcc.exe';
  if not FileExists(Gcc) then
    Exit;
  if not CaptureConsoleOutput(Gcc, '--version', 5000, Outp) then
    Exit;
  AVersion := ExtractVersionToken(Outp);
  if AVersion = '' then
    Exit;
  AUCRT := (Pos('ucrt', LowerCase(ABinDir)) > 0) or
    (Pos('ucrt', LowerCase(Outp)) > 0);
  Result := True;
end;

// 多级探测: 程序目录 -> 环境变量 -> 系统标准路径 -> PATH
function TToolchainService.DetectToolchainPaths(out Paths: TDetectedToolchainPaths): Boolean;
var
  // SplitString returns TStringDynArray. Delphi makes that the SAME type as
  // TArray<string>; FPC keeps them distinct and reports
  //     Incompatible types: got "TStringDynArray" expected
  //     "TArray$1$crc8147D24F"
  // so the local is declared with the type SplitString actually returns.
  {$IFDEF FPC}
  // types.pp:66 declares TStringDynArray = array of AnsiString under this
  // mode, which is why the assignment is not merely a rename.
  Candidates: TStringDynArray;
  {$ELSE}
  Candidates: TArray<string>;
  {$ENDIF}
  ExeDir, Home: string;

  function TryBin(const ABinDir, AMakeName: string): Boolean;
  var
    Ver: string;
    IsUCRT: Boolean;
  begin
    Result := False;
    if not ProbeBinDir(ABinDir, Ver, IsUCRT) then
      Exit;
    Paths.GCCPath := IncludeTrailingPathDelimiter(ABinDir) + 'gcc.exe';
    if FileExists(IncludeTrailingPathDelimiter(ABinDir) + AMakeName) then
      Paths.MakePath := IncludeTrailingPathDelimiter(ABinDir) + AMakeName
    else
      Paths.MakePath := '';
    if FileExists(IncludeTrailingPathDelimiter(ABinDir) + 'gdb.exe') then
      Paths.GDBPath := IncludeTrailingPathDelimiter(ABinDir) + 'gdb.exe'
    else
      Paths.GDBPath := '';
    Paths.LLVMPath := '';
    Paths.Valid := True;
    Paths.Version := Ver;
    Paths.UCRT := IsUCRT;
    FPaths := Paths;
    FHasPaths := True;
    EmitProgress('Toolchain detected: ' + ABinDir + ' (' + Ver + ')', 0);
    Result := True;
  end;

begin
  Paths := Default(TDetectedToolchainPaths);
  Result := False;

  // Level 1: 程序自身相对路径
  ExeDir := ExtractFilePath(ParamStr(0));
  if TryBin(ExeDir + 'MinGW64\bin', 'mingw32-make.exe') then Exit(True);
  if TryBin(ExeDir + 'mingw64\bin', 'mingw32-make.exe') then Exit(True);

  // Level 2: 环境变量
  Home := Trim(EnvVar('MINGW_HOME'));
  if (Home <> '') then
    if TryBin(IncludeTrailingPathDelimiter(Home) + 'bin', 'mingw32-make.exe') then
      Exit(True);
  Home := Trim(EnvVar('LLVM_HOME'));
  if (Home <> '') then
    if TryBin(IncludeTrailingPathDelimiter(Home) + 'bin', 'mingw32-make.exe') then
      Exit(True);

  // Level 3: 系统标准路径
  if TryBin('C:\msys64\ucrt64\bin', 'mingw32-make.exe') then Exit(True);
  if TryBin('C:\msys64\mingw64\bin', 'mingw32-make.exe') then Exit(True);
  if TryBin('C:\msys64\clang64\bin', 'mingw32-make.exe') then Exit(True);
  Home := Trim(EnvVar('USERPROFILE')) +
    '\scoop\apps\mingw-w64\current\bin';
  if TryBin(Home, 'mingw32-make.exe') then Exit(True);

  // Level 4: PATH (仅取 gcc.exe; make/gdb 同目录顺带)
  Candidates := SplitString(Trim(EnvVar('PATH')), ';');
  for Home in Candidates do
  begin
    if Trim(Home) = '' then
      Continue;
    if FileExists(IncludeTrailingPathDelimiter(Trim(Home)) + 'gcc.exe') then
      if TryBin(Trim(Home), 'mingw32-make.exe') then
        Exit(True);
  end;

  EmitProgress('Toolchain not found. Use Config -> Toolchain to set up paths.', 1);
end;

function TToolchainService.Compile(const FileName: String; out Errors: String): Boolean;
begin
  // 实际编译流水线由 Compiler.pas 负责; 此处仅做可用性门禁.
  // (旧骨架曾无条件返回 True, 属误导性占位, 现如实返回.)
  Result := False;
  Errors := '';
  if not FHasPaths then
    DetectToolchainPaths(FPaths);
  if not FPaths.Valid or (FPaths.GCCPath = '') then
  begin
    Errors := 'Toolchain not found. Use Config -> Toolchain to set up paths.';
    Exit;
  end;
  Errors := 'Compile pipeline not implemented in ToolchainService; use Compiler.pas.';
end;

function TToolchainService.Link(const Files: array of String; out Executable: String): Boolean;
begin
  Result := False;
  Executable := '';
end;

initialization
  TToolchainService.Instance := TToolchainService.Create;

finalization
  TToolchainService.Instance := nil;

end.
