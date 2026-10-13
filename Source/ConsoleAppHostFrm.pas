unit ConsoleAppHostFrm;

interface

uses
  {$IFDEF FPC}
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  {$ELSE}
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  {$ENDIF}
  {$IFDEF FPC}
  Controls, Forms, Dialogs, ComCtrls, ExtCtrls;
  {$ELSE}
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ComCtrls, Vcl.ExtCtrls;
  {$ENDIF}

type
// The host's completion callback.
//
// Delphi has TProc<T1,T2> = reference to procedure and uses it here, but FPC
// 3.2.2 has no anonymous functions at all. Probed directly, with
// $modeswitch anonymousfunctions in effect:
//
//     generic TProc<TA, TB> = reference to procedure(A: TA; B: TB);
// -> probe_anon.pas(6,20) Error: Identifier not found "reference"
//
// so a `generic ... = reference to procedure` shim cannot be made to work; the
// feature simply is not in this compiler. The alternative is a method pointer,
// which every FPC procedure-of-object supports. All three call sites in
// main.pas supply the same body, so the `of object` form costs nothing there.
//
// Delphi keeps TProc: the branch exists so the Delphi build is untouched and no
// caller has to care which compiler it is on.
//
// TObject rather than TConsoleAppHost, and not only because FPC will not accept
// a forward class declaration so the alias could precede the class. Naming the
// host here would drag every caller that wants this type into using this unit's
// class. TObject matches the facade already used for
// MainUi.SuggestMemberInsertionLine, whose interface comment says the concrete
// type "must not be named here".

  {$IFDEF FPC}
  TConsoleAppHostCallback = procedure(Host: TObject; Success: Boolean) of object;
  {$ELSE}
  TConsoleAppHostCallback = TProc<TObject, Boolean>;
  {$ENDIF}

  TConsoleAppHost = class(TForm)
  private
  protected
    { Private declarations }
    FCommand: string;
    FCallBack: TConsoleAppHostCallback;
    FStartSucceeded: Boolean; // payload for NotifyStartResult
    FProcess: THandle;
    FProcessWindow: THandle;
    FWaitInitialization: Integer;

    procedure Resize; override;
    procedure ApplyHost; virtual;

    function StartCommand: Boolean;
    procedure ShowAppEmbedded(WindowHandle: THandle; Container: TWinControl);
    procedure AssignTo(Dest: TPersistent); override;
    procedure DoTabShow(Sender: TObject);
    procedure NotifyStartResult;

    // The VCL names its form handle hooks Create/DestroyWindowHandle and
    // passes a TCreateParams. The LCL's TWinControl instead declares
    // (controls.pp:2289-2292) `CreateHandle; virtual;` and
    // `DestroyHandle; virtual;` with no parameters, and TForm inherits both.
    // Same hook point -- the handle exists / is about to go away -- so only
    // the names differ.
    {$IFDEF FPC}
    procedure DestroyHandle; override;
    procedure CreateHandle; override;
    {$ELSE}
    procedure DestroyWindowHandle; override;
    procedure CreateWindowHandle(const Params: TCreateParams); override;
    {$ENDIF}
  public
    { Public declarations }

    class procedure NewHost(const ACommand, ACaption: string; const ACallBack: TConsoleAppHostCallback; const AWaitInitialization: Integer = 0);
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  {$IFDEF FPC}
  Generics.Collections, DateUtils,
  {$ELSE}
  System.Generics.Collections, System.DateUtils,
  {$ENDIF}

  {$IFDEF FPC}
  ShellAPI;

// LCL's TCustomForm has its own SetParent(TWinControl) -- customform.inc:1197 --
// which shadows the Win32 entry point inside a form method, so the calls below
// are wrapped rather than qualified: the unit name differs per compiler
// (`Windows` here, `Winapi.Windows` on Delphi), and a conditional at each call
// site would be noisier than two tiny wrappers.
function W32_SetParent(hWndChild, hWndNewParent: HWND): HWND;
{$IFDEF FPC}
begin
  Result := Windows.SetParent(hWndChild, hWndNewParent);
end;
{$ELSE}
begin
  Result := Winapi.Windows.SetParent(hWndChild, hWndNewParent);
end;
{$ENDIF}

procedure W32_RedrawWindow(hWnd: HWND; lprcUpdate: PRect; hrgnUpdate: HRGN;
  flags: UINT);
{$IFDEF FPC}
begin
  Windows.RedrawWindow(hWnd, lprcUpdate, hrgnUpdate, flags);
end;
{$ELSE}
begin
  Winapi.Windows.RedrawWindow(hWnd, lprcUpdate, hrgnUpdate, flags);
end;
{$ENDIF}

  {$ELSE}
  Winapi.ShellAPI;
  {$ENDIF}

{$R *.dfm}

{ TfmConsoleHost }
 class procedure TConsoleAppHost.NewHost(const ACommand, ACaption: string; const ACallBack: TConsoleAppHostCallback; const AWaitInitialization: Integer = 0);
var
  // Hoisted out of the body: FPC 3.2.2 rejects a mid-body
  // `var NewHost := ...` with
  //     ConsoleAppHostFrm.pas(110,3) Error: Illegal expression
  NewHost: TConsoleAppHost;
begin
  if not Assigned(ACallBack) then Exit;
  if ACommand = '' then Exit;

  NewHost := TConsoleAppHost.Create(Application);
  NewHost.FCommand := ACommand;

  NewHost.Caption := ACaption;
  if ACaption = '' then
    NewHost.Caption := ACommand;
  NewHost.FWaitInitialization := AWaitInitialization;
  NewHost.FCallBack := ACallBack;
  NewHost.ApplyHost;
end;

constructor TConsoleAppHost.Create(AOwner: TComponent);
begin
  FCommand := '';
  FCallBack := nil;
  FProcess := INVALID_HANDLE_VALUE;
  FProcessWindow := INVALID_HANDLE_VALUE;
  FWaitInitialization := 0;

  inherited;
end;

destructor TConsoleAppHost.Destroy;
var
  TmpProcess: Integer;
begin
  FProcessWindow := INVALID_HANDLE_VALUE;
  if FProcess <> INVALID_HANDLE_VALUE then
  begin
    TmpProcess := FProcess;
    FProcess := INVALID_HANDLE_VALUE;
    TerminateProcess(TmpProcess, 0);
  end;

  inherited;
end;

{$IFDEF FPC}
procedure TConsoleAppHost.CreateHandle;
{$ELSE}
procedure TConsoleAppHost.CreateWindowHandle(const Params: TCreateParams);
{$ENDIF}
begin
  inherited;

  ShowAppEmbedded(FProcessWindow, Self);
end;

{$IFDEF FPC}
procedure TConsoleAppHost.DestroyHandle;
{$ELSE}
procedure TConsoleAppHost.DestroyWindowHandle;
{$ENDIF}
begin
  if FProcessWindow <> INVALID_HANDLE_VALUE then
  begin
    ShowWindow(FProcessWindow, SW_HIDE);
    W32_SetParent(FProcessWindow, 0);
  end;

  inherited;
end;

procedure TConsoleAppHost.DoTabShow(Sender: TObject);
begin
  Resize;

  if FProcessWindow <> INVALID_HANDLE_VALUE then
    W32_RedrawWindow(FProcessWindow, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
end;

{$IFDEF FPC}
// GetProcessIdOfThread is a real kernel32 export -- confirmed by resolving it
// against kernel32.dll -- but FPC 3.2.2's Windows unit does not declare it, and
// it is not a Delphi RTL function either, so there is nothing to shadow: it has
// to be bound here, the same way Instances.pas binds GetModuleFileNameEx.
type
  PSearchPair = ^TPair<THandle, THandle>;

function GetProcessIdOfThread(hThread: THandle): DWORD; stdcall;
  external 'kernel32' name 'GetProcessIdOfThread';

// Same story: FPC's only GetProcessID is the zero-argument one that returns
// the ProcessID global (syswin.inc:553). The handle-taking kernel32 export
// is not declared anywhere in the RTL.
function GetProcessId(hProcess: THandle): DWORD; stdcall;
  external 'kernel32' name 'GetProcessId';
{$ENDIF}

function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwThreadId: DWORD): DWORD; stdcall; external 'kernel32.dll';

function EnumWindowsProc(AWnd: THandle; ASearchRec: Pointer): Bool; stdcall;
var
  // Hoisted out of the body: FPC 3.2.2 rejects mid-body
  // `var X: T := ...` with "Illegal expression".
  WindowPlacement: PWindowPlacement;
  ThreadHandle: DWORD;
  ThreadProcessID: Cardinal;
  IgnoredProcessID: DWORD;
  SearchPair: PSearchPair;
begin
  IgnoredProcessID := 0;
  WindowPlacement := nil;
  ThreadHandle := 0;
  ThreadProcessID := 0;
  try
    // Two arguments under FPC: Delphi's System.Windows has a one-argument
    // GetWindowThreadProcessId(hWnd) that discards the process id. The pid is
    // not wanted here -- GetProcessIdOfThread below reads it off the thread
    // handle -- so a dummy out-parameter is enough.
    GetWindowThreadProcessId(AWnd, IgnoredProcessID);
    ThreadHandle := OpenThread($0800, FALSE, IgnoredProcessID);
    try
      ThreadProcessID := GetProcessIdOfThread(ThreadHandle);
    finally
      CloseHandle(ThreadHandle);
    end;
  except
    ThreadProcessID := 0;
  end;

  // A typed pointer rather than the generic typecast
  // `TPair<THandle, THandle>(ASearchRec^)`, which FPC 3.2.2 parses as a
  // less-than and reports as
  //     ConsoleAppHostFrm.pas(255,46) Syntax error, ")" expected but "," found
  SearchPair := PSearchPair(ASearchRec);
  Result := (ThreadProcessID <> SearchPair^.Key);
  if not Result then
    SearchPair^.Value := AWnd;
end;


// The two worker threads ApplyHost used to build with
// TThread.CreateAnonymousThread(procedure ... end). FPC 3.2.2 has no anonymous
// functions, so these are real classes; same two threads, same order of work.
type
  TConsoleHostStartThread = class(TThread)
  protected
    FHost: TConsoleAppHost;
    procedure Execute; override;
  public
    constructor Create(AHost: TConsoleAppHost);
  end;

  TConsoleHostMonitorThread = class(TThread)
  protected
    FHost: TConsoleAppHost;
    procedure Execute; override;
  public
    constructor Create(AHost: TConsoleAppHost);
  end;

constructor TConsoleHostStartThread.Create(AHost: TConsoleAppHost);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FHost := AHost;
end;

procedure TConsoleHostStartThread.Execute;
var
  IsSuccess: Boolean;
begin
  IsSuccess := FHost.StartCommand;

  // The payload the closure used to capture. FCallBack is a method pointer, so
  // the result travels in a field instead of in a captured local, and
  // Synchronize runs NotifyStartResult on the UI thread.
  FHost.FStartSucceeded := IsSuccess;
  // Synchronize's first argument is the *calling* thread, so it is this thread,
  // not the host -- the host is what supplies the callback method.
  TThread.Synchronize(TThread.CurrentThread, FHost.NotifyStartResult);

  if not IsSuccess then Exit;

  TConsoleHostMonitorThread.Create(FHost).Start;
end;

constructor TConsoleHostMonitorThread.Create(AHost: TConsoleAppHost);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FHost := AHost;
end;

procedure TConsoleHostMonitorThread.Execute;
var
  H: TConsoleAppHost;
begin
  H := FHost;
  while True do
  begin
    // NB: the original was missing its closing parenthesis here, which is a
    // syntax error on any compiler -- the inner while never closed.
    while (H.FProcess <> INVALID_HANDLE_VALUE) and
          (WaitForSingleObject(H.FProcess, 10) = WAIT_TIMEOUT) do
      Sleep(10);

    if H.FProcess = INVALID_HANDLE_VALUE then Break;

    if H.StartCommand then
      H.ShowAppEmbedded(H.FProcessWindow, H);
  end;
end;

procedure TConsoleAppHost.NotifyStartResult;
begin
  if Assigned(FCallBack) then
    FCallBack(Self, FStartSucceeded);
end;
procedure TConsoleAppHost.ApplyHost;
begin
  if FCommand = '' then Exit;
  if FProcess <> INVALID_HANDLE_VALUE then Exit;

  TConsoleHostStartThread.Create(Self).Start;
end;

procedure TConsoleAppHost.AssignTo(Dest: TPersistent);
begin
  if Dest is TTabSheet then
  begin
    TTabSheet(Dest).Caption := Caption;
    TTabSheet(Dest).OnShow := DoTabShow;
    Parent := TTabSheet(Dest);
    TTabSheet(Dest).Tag := NativeInt(Self);
    Visible := True;
  end
  else
    inherited;
end;

procedure TConsoleAppHost.Resize;
begin
  inherited;

  if FProcessWindow <> INVALID_HANDLE_VALUE then
    MoveWindow(FProcessWindow, 0, 0, ClientWidth, ClientHeight, True);
end;

procedure TConsoleAppHost.ShowAppEmbedded(WindowHandle: THandle; Container: TWinControl);
var
  WindowStyle : Integer;
begin
  if WindowHandle = INVALID_HANDLE_VALUE then Exit;

  FProcessWindow := WindowHandle;
  WindowStyle := GetWindowLong(WindowHandle, GWL_STYLE);
  WindowStyle := WindowStyle
                 and (not WS_CAPTION)
                 and (not WS_BORDER)
                 and (not WS_OVERLAPPED)
                 and (not WS_THICKFRAME)
                 and (not WS_SYSMENU)
                 and (not WS_MINIMIZE)
                 and (not WS_MAXIMIZEBOX)
                 or WS_DLGFRAME;

  SetWindowLong(WindowHandle, GWL_STYLE, WindowStyle);
  SetWindowLong(WindowHandle, GWL_EXSTYLE, GetWindowLong(WindowHandle, GWL_EXSTYLE) or WS_EX_DLGMODALFRAME);

  AttachThreadInput(MainThreadID, GetWindowThreadProcessId(WindowHandle, nil), True);

  Container.HandleNeeded;
  W32_SetParent(WindowHandle, Container.Handle);
  ShowWindow(WindowHandle, SW_SHOWMAXIMIZED);
  SetWindowPos(WindowHandle, 0, 0, 0, Container.ClientWidth, Container.ClientHeight, SWP_NOMOVE or SWP_NOSIZE or SWP_FRAMECHANGED or SWP_NOZORDER);

  SendMessage(Container.Handle, WM_UPDATEUISTATE, UIS_INITIALIZE, 0);
  W32_RedrawWindow(FProcessWindow, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);

  SetWindowLong(Container.Handle, GWL_STYLE, GetWindowLong(Container.Handle,GWL_STYLE) or WS_CLIPCHILDREN);

  SetForegroundWindow(WindowHandle);

  keybd_event(VK_HOME, $24, 0, 0);
  keybd_event(VK_HOME, $24, KEYEVENTF_KEYUP, 0);
end;

function TConsoleAppHost.StartCommand: Boolean;
var
  StartWait: TDateTime;
  // Hoisted out of the body: FPC 3.2.2 rejects a mid-body `var X: T;` with
  //     ConsoleAppHostFrm.pas(424,3) Error: Illegal expression
  SEI: TShellExecuteInfoW;
  // Hoisted out of the body: FPC 3.2.2 rejects a mid-body `var X: T;`.
  SearchRec: TPair<THandle, THandle>;
begin
  FProcess := INVALID_HANDLE_VALUE;
  FillChar(SEI, SizeOf(SEI), 0);
  SEI.cbSize := SizeOf(SEI);
  SEI.wnd := Self.Handle;
  SEI.fMask := SEE_MASK_FLAG_NO_UI or SEE_MASK_NOCLOSEPROCESS or SEE_MASK_DOENVSUBST or SEE_MASK_WAITFORINPUTIDLE;
  SEI.nShow := SW_HIDE;
  SEI.lpFile := PWideChar(FCommand);

  Result := ShellExecuteExW(@SEI);
  if Result then
  begin
    FProcess := SEI.hProcess;
    WaitForInputIdle(FProcess, INFINITE);

    SearchRec.Key := GetProcessId(FProcess);
    SearchRec.Value := 0;

    TThread.Sleep(FWaitInitialization);

    StartWait := Now;
    while SearchRec.Value = 0 do
    begin
      EnumWindows(@EnumWindowsProc, LPARAM(@SearchRec));
      TThread.Sleep(100);
      if SecondsBetween(StartWait, Now) > 10 then
        Exit(False);
    end;

    if SearchRec.Value <> 0 then
    begin
      ShowWindow(SearchRec.Value, SW_HIDE);
      FProcessWindow := SearchRec.Value;
    end;
  end;
end;

end.
