unit LSP.Process.Win32;

interface

uses
  {$IFDEF FPC}
  Classes, SysUtils, Winapi.Windows, Lsp.Process;
  {$ELSE}
  System.Classes, System.SysUtils, Winapi.Windows, LSP.Process;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Delphi/Windows implementation of ILspProcess.
//
// This is the pre-abstraction code from LSP.Transport moved verbatim:
// CreateProcess + two anonymous pipes (stdin/stdout, stderr folded into
// stdout), ReadFile/WriteFile streaming, TerminateProcess on shutdown.
//
// It must never be compiled by Free Pascal -- LSP.Process.Factory selects
// LSP.Process.Fpc there, and tools/fpc_artifact_check.py enforces that this
// unit stays out of the portable FPC project.
// ---------------------------------------------------------------------------

{$IFDEF FPC}
  {$WARNING LSP.Process.Win32 must not be compiled by Free Pascal}
{$ENDIF}

type
  TWin32LspProcess = class(TInterfacedObject, ILspProcess)
  private
    FProcess: THandle;
    FThreadHandle: THandle;
    FStdinWrite: THandle;
    FStdoutRead: THandle;
    FLastError: string;
    function Read(out ABuf: TBytes): Integer;
    function Write(const ABuf: TBytes): Boolean;
    function WriteText(const AText: string): Boolean;
    procedure Terminate;
    function Running: Boolean;
    function LastError: string;
    function DoStart(const AExe, AParams, AWorkDir: string): Boolean;
  public
    constructor Create(const AExe, AParams, AWorkDir: string);
    destructor Destroy; override;
  end;

  TWin32LspProcessFactory = class(TInterfacedObject, ILspProcessFactory)
  public
    function Start(const AExe, AParams, AWorkDir: string): ILspProcess;
  end;

implementation

{ TWin32LspProcess }

constructor TWin32LspProcess.Create(const AExe, AParams, AWorkDir: string);
begin
  inherited Create;
  FProcess := 0;
  FThreadHandle := 0;
  FStdinWrite := 0;
  FStdoutRead := 0;
  FLastError := '';
  if not DoStart(AExe, AParams, AWorkDir) then
    raise Exception.Create(FLastError);
end;

destructor TWin32LspProcess.Destroy;
begin
  Terminate;
  inherited;
end;

function TWin32LspProcess.DoStart(const AExe, AParams,
  AWorkDir: string): Boolean;
var
  StartupInfo: TStartupInfo;
  Security: TSecurityAttributes;
  StdinRead: THandle;
  StdoutWrite: THandle;
  Info: TProcessInformation;
  CmdLine: string;
begin
  Result := False;

  // inheritable handles so the child inherits the stdin/stdout pipes
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.lpSecurityDescriptor := nil;
  Security.bInheritHandle := True;

  // stdin pipe: parent writes FStdinWrite, child reads StdinRead
  if not CreatePipe(StdinRead, FStdinWrite, @Security, 0) then
  begin
    FLastError := 'Failed to create stdin pipe';
    Exit;
  end;
  // the parent must not leak the write end into the child
  SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);

  // stdout pipe: child writes StdoutWrite, parent reads FStdoutRead
  if not CreatePipe(FStdoutRead, StdoutWrite, @Security, 0) then
  begin
    FLastError := 'Failed to create stdout pipe';
    CloseHandle(StdinRead);
    CloseHandle(FStdinWrite);
    FStdinWrite := 0;
    Exit;
  end;
  SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);

  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.hStdInput := StdinRead;
  StartupInfo.hStdOutput := StdoutWrite;
  StartupInfo.hStdError := StdoutWrite;
  StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;

  CmdLine := AExe + ' ' + AParams;
  UniqueString(CmdLine);
  FillChar(Info, SizeOf(Info), 0);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True, CREATE_NO_WINDOW,
    nil, PChar(AWorkDir), StartupInfo, Info) then
  begin
    FLastError := 'Failed to start process: ' + SysErrorMessage(GetLastError);
    CloseHandle(StdinRead);
    CloseHandle(FStdinWrite);
    CloseHandle(FStdoutRead);
    CloseHandle(StdoutWrite);
    FStdinWrite := 0;
    FStdoutRead := 0;
    Exit;
  end;

  FProcess := Info.hProcess;
  FThreadHandle := Info.hThread;

  // the parent drops its copies of the child-side handles
  CloseHandle(StdinRead);
  CloseHandle(StdoutWrite);
  Result := True;
end;

function TWin32LspProcess.Read(out ABuf: TBytes): Integer;
var
  Chunk: array[0..8191] of Byte;
  BytesRead: DWORD;
begin
  Result := -1;
  ABuf := nil;
  if FStdoutRead = 0 then
    Exit;
  BytesRead := 0;
  if not ReadFile(FStdoutRead, Chunk[0], SizeOf(Chunk), BytesRead, nil) then
  begin
    FLastError := SysErrorMessage(GetLastError);
    Exit;
  end;
  if BytesRead = 0 then
  begin
    Result := 0; // EOF: child exited or the pipe was closed
    Exit;
  end;
  SetLength(ABuf, Integer(BytesRead));
  Move(Chunk[0], ABuf[0], BytesRead);
  Result := Integer(BytesRead);
end;

function TWin32LspProcess.Write(const ABuf: TBytes): Boolean;
var
  BytesWritten: DWORD;
  Off: Integer;
  Remaining: Integer;
begin
  Result := False;
  if FStdinWrite = 0 then
    Exit;
  if Length(ABuf) = 0 then
  begin
    Result := True;
    Exit;
  end;
  Off := 0;
  Remaining := Length(ABuf);
  while Remaining > 0 do
  begin
    if not WriteFile(FStdinWrite, ABuf[Off], Remaining, BytesWritten, nil) then
    begin
      FLastError := SysErrorMessage(GetLastError);
      Exit;
    end;
    if BytesWritten = 0 then
      Exit; // no progress: treat as a broken pipe
    Inc(Off, Integer(BytesWritten));
    Dec(Remaining, Integer(BytesWritten));
  end;
  Result := True;
end;

function TWin32LspProcess.WriteText(const AText: string): Boolean;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, TEncoding.UTF8.GetByteCount(AText));
  if Length(Bytes) > 0 then
    TEncoding.UTF8.GetBytes(AText, 0, Length(AText), Bytes, 0);
  Result := Write(Bytes);
end;

procedure TWin32LspProcess.Terminate;
var
  WaitRes: DWORD;
begin
  // Closing the read end first unblocks a pending ReadFile.
  if FStdoutRead <> 0 then
  begin
    CloseHandle(FStdoutRead);
    FStdoutRead := 0;
  end;
  if FStdinWrite <> 0 then
  begin
    CloseHandle(FStdinWrite);
    FStdinWrite := 0;
  end;
  if FProcess <> 0 then
  begin
    TerminateProcess(FProcess, 0);
    WaitRes := WaitForSingleObject(FProcess, 2000);
    if WaitRes <> WAIT_OBJECT_0 then
      FLastError := 'Process did not exit within 2s';
    CloseHandle(FThreadHandle);
    CloseHandle(FProcess);
    FProcess := 0;
    FThreadHandle := 0;
  end;
end;

function TWin32LspProcess.Running: Boolean;
var
  Code: DWORD;
begin
  Result := False;
  if FProcess = 0 then
    Exit;
  if GetExitCodeProcess(FProcess, Code) then
    Result := Code = STILL_ACTIVE;
end;

function TWin32LspProcess.LastError: string;
begin
  Result := FLastError;
end;

function TWin32LspProcessFactory.Start(const AExe, AParams,
  AWorkDir: string): ILspProcess;
begin
  Result := nil;
  try
    Result := TWin32LspProcess.Create(AExe, AParams, AWorkDir);
  except
    on E: Exception do
      Result := nil;
  end;
end;

end.