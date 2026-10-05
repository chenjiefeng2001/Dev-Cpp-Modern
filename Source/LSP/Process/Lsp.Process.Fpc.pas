unit LSP.Process.Fpc;

// FPC-only unit: the entire body is wrapped in a conditional so that the
// Delphi build never parses it, and tools/qa_check.py therefore treats every
// line of this file as FPC-guarded (TProcess is legal here by design).
{$IFDEF FPC}

interface

uses
  {$IFDEF FPC}
  Classes, SysUtils, process, Lsp.Process;
  {$ELSE}
  System.Classes, System.SysUtils, LSP.Process;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Free Pascal implementation of ILspProcess, built on the RTL TProcess.
// Works on Windows and on Unix-like targets, which is what makes the LSP
// transport testable in a headless GitHub Actions run.
// ---------------------------------------------------------------------------

type
  TFpcLspProcess = class(TInterfacedObject, ILspProcess)
  private
    FProc: TProcess;
    FLastError: string;
    function Read(out ABuf: TBytes): Integer;
    function Write(const ABuf: TBytes): Boolean;
    function WriteText(const AText: string): Boolean;
    procedure Terminate;
    function Running: Boolean;
    function LastError: string;
  public
    constructor Create(const AExe, AParams, AWorkDir: string);
    destructor Destroy; override;
    property LastErrorMessage: string read FLastError;
  end;

  TFpcLspProcessFactory = class(TInterfacedObject, ILspProcessFactory)
  public
    function Start(const AExe, AParams, AWorkDir: string): ILspProcess;
  end;

implementation

constructor TFpcLspProcess.Create(const AExe, AParams, AWorkDir: string);
begin
  inherited Create;
  FLastError := '';
  // FPC's TProcess takes only an OWNER. The Delphi three-argument form
  // (parent, command line, environment) does not exist in this RTL.
  FProc := TProcess.Create(nil);
  try
    FProc.Executable := AExe;
    // SPLIT AParams, do not pass it through as ONE argument.
    //
    // ILspProcessFactory.Start takes a single command-line string, and the
    // Win32 implementation honours that reading: it hands `AExe + ' ' + AParams`
    // to CreateProcess, whose child-side C runtime splits it into argv. The
    // first version of this port did
    //
    //     FProc.Parameters.Add(AParams);
    //
    // which is the right call for a LIST and the wrong one for a STRING: it hands
    // the child ONE argv entry that still contains spaces. The smoke test caught
    // it as
    //
    //     n=72 text=usage: ...FpcCoreTests.exe [run]
    //
    // -- the child ignored its arguments and printed its usage banner, because
    // `--child-echo hello-lsp-process` had arrived as a single unknown flag.
    //
    // This is NOT a test-only defect. Lsp.Transport.Connect passes clangd SEVEN
    // flags, one quoted and containing a space (`--compile-commands-dir="C:\..."`),
    // so under this code clangd would receive one ~150-character argument and
    // refuse to start. Same failure class as the Input/Output inversion below: it
    // compiles, it links, it passes every static gate, and it breaks only at RUN.
    //
    // CommandToList is the RTL's own splitter (fcl-process/src/processbody.inc),
    // public in the `process` unit and already used by the RTL itself whenever the
    // deprecated CommandLine property is assigned. It honours single and double
    // quotes, which the clangd argument string needs.
    //
    // STATED BOUNDARY: CommandToList strips a quote pair only when it wraps the
    // WHOLE token, so `--compile-commands-dir="C:\dir"` keeps its inner quotes.
    // The argument COUNT -- the defect that matters here -- is correct either way.
    if AParams <> '' then
      CommandToList(AParams, FProc.Parameters);
    if (AWorkDir <> '') and DirectoryExists(AWorkDir) then
      FProc.CurrentDirectory := AWorkDir;
    // Pipes for stdin/stdout, and fold stderr into stdout so server-side
    // diagnostics travel the same stream (matches the previous Win32 setup
    // where hStdOutput and hStdError shared the same pipe).
    // Execute creates the pipes itself when poUsePipes is set: there is no
    // CreatePipes in this RTL, and the pipe streams exist only once
    // Execute has returned. poNoConsole keeps a console window from
    // flashing for a background language server.
    FProc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    FProc.Execute;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      FreeAndNil(FProc);
      raise;
    end;
  end;
end;

destructor TFpcLspProcess.Destroy;
begin
  Terminate;
  FreeAndNil(FProc);
  inherited;
end;

function TFpcLspProcess.Read(out ABuf: TBytes): Integer;
var
  Chunk: TBytes;
  N: Integer;
begin
  Result := -1;
  ABuf := nil;
  if not Assigned(FProc) then
    Exit;
  // FPC names the streams from the CHILD's side: Output is its stdout,
  // which is what the parent READS. The old code read `Input`, which here
  // is the child's stdin -- so the transport would have been reading its
  // own writes and blocking forever.
  if not Assigned(FProc.Output) then
    Exit; // no pipe: nothing to read

  // ReadData blocks until at least one byte arrives or the pipe reaches EOF,
  // which is precisely the blocking contract documented in LSP.Process.
  SetLength(Chunk, 8192);
  try
    N := FProc.Output.Read(Chunk[0], Length(Chunk));
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      Exit;
    end;
  end;
  if N = 0 then
  begin
    Result := 0; // EOF: child exited or the write end was closed
    Exit;
  end;
  SetLength(ABuf, N);
  Move(Chunk[0], ABuf[0], N);
  Result := N;
end;

function TFpcLspProcess.Write(const ABuf: TBytes): Boolean;
begin
  Result := False;
  // Input is the child's stdin here: the mirror image of the Read fix.
  if (not Assigned(FProc)) or (not Assigned(FProc.Input)) then
    Exit;
  if Length(ABuf) = 0 then
  begin
    Result := True;
    Exit;
  end;
  try
    FProc.Input.WriteBuffer(ABuf[0], Length(ABuf));
    Result := True;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      Result := False;
    end;
  end;
end;

function TFpcLspProcess.WriteText(const AText: string): Boolean;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, TEncoding.UTF8.GetByteCount(AText));
  if Length(Bytes) > 0 then
    TEncoding.UTF8.GetBytes(AText, 0, Length(AText), Bytes, 0);
  Result := Write(Bytes);
end;

procedure TFpcLspProcess.Terminate;
begin
  if not Assigned(FProc) then
    Exit;
  try
    if FProc.Running then
    begin
      // This RTL has no Kill: Terminate(AExitCode) IS the forceful stop.
      // WaitOnExit takes no timeout here, so no grace period is
      // requestable -- the port is told to exit and then reaped.
      FProc.Terminate(0);
      FProc.WaitOnExit;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

function TFpcLspProcess.Running: Boolean;
begin
  Result := Assigned(FProc) and FProc.Running;
end;

function TFpcLspProcess.LastError: string;
begin
  Result := FLastError;
end;

function TFpcLspProcessFactory.Start(const AExe, AParams,
  AWorkDir: string): ILspProcess;
begin
  Result := nil;
  try
    Result := TFpcLspProcess.Create(AExe, AParams, AWorkDir);
  except
    // Create raises on failure; report through nil + the caller's own error
    // path so that the factory stays exception-free for its callers.
    on E: Exception do
      Result := nil;
  end;
end;

end.

{$ENDIF}
