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

unit LSP.Transport;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  System.Types, System.IOUtils, Winapi.Windows, Vcl.Forms;

// JSON-RPC 2.0 消息结构
type
  // JSON-RPC 请求
  TLspRequest = record
    JsonRpc: String;
    Id: Integer;
    Method: String;
    Params: String;
  end;

  // JSON-RPC 响应 (仅保存裸文本, 由上层解析)
  TLspResponse = record
    JsonRpc: String;
    Id: Integer;
    Result: String;
    Error: String;
  end;

  // JSON-RPC 通知
  TLspNotification = record
    JsonRpc: String;
    Method: String;
    Params: String;
  end;

// LSP 传输状态
type
  TLspTransportState = (tsDisconnected, tsConnecting, tsInitialized, tsReady, tsShuttingDown);

// LSP 消息事件回调
type
  TLspMessageEvent = procedure(const AMessage: String) of object;
  TLspErrorEvent = procedure(const AError: String) of object;
  TLspConnectionEvent = procedure(const AConnected: Boolean) of object;

// LSP 传输客户端
type
  TLspTransport = class
  private
    FState: TLspTransportState;
    FProcessHandle: THandle;
    FProcessInfo: TProcessInformation;
    FStdinRead, FStdinWrite: THandle;   // 子进程 stdin 管道
    FStdoutRead, FStdoutWrite: THandle; // 子进程 stdout/stderr 管道
    FReadThread: TThread;
    FLock: TCriticalSection;
    FOnMessage: TLspMessageEvent;
    FMessageSubs: TList<TLspMessageEvent>;
    FOnError: TLspErrorEvent;
    FOnConnection: TLspConnectionEvent;
    FUri: String;
    FInitialized: Boolean;
    FClangdPath: string;
    FWorkDir: string;
    FReadBuf: TBytes; // 读线程累积的裸字节
    FLastBody: String;        // 最近一条已派发的 JSON (供诊断/回读)
    FNextRequestId: Integer;
    FLastActivity: TDateTime;
    FTimeout: Integer;
    procedure DoReadThread;
    procedure HandleMessage(const AMessage: String);
    procedure HandleError(const AError: String);
    procedure SetState(const AState: TLspTransportState);
    procedure SendInternal(const AMessage: String);
    function GetConnected: Boolean;
  public
    constructor Create(const AClangdPath: String; const AWorkDir: String);
    destructor Destroy; override;

    // 连接管理
    function Connect: Boolean;
    procedure Disconnect;
    property State: TLspTransportState read FState;
    property Connected: Boolean read GetConnected;

    // 初始化握手
    function Initialize: Boolean;
    function WaitForInitialized(const ATimeoutSec: Integer = 30): Boolean;
    procedure MarkReady;

    // JSON-RPC 发送
    function SendRequest(const AMethod: String; const AParams: String; out AId: Integer; out AResult: String): Boolean;
    function SendNotification(const AMethod: String; const AParams: String): Boolean;
    procedure SendNotificationAsync(const AMethod: String; const AParams: String);
    procedure SendPayload(const AJsonPayload: String);

    // 事件
    property OnMessage: TLspMessageEvent read FOnMessage write FOnMessage;
    procedure SubscribeMessage(const AHandler: TLspMessageEvent);
    procedure UnsubscribeMessage(const AHandler: TLspMessageEvent);
    procedure BroadcastMessage(const AMessage: String);
    property OnError: TLspErrorEvent read FOnError write FOnError;
    property OnConnection: TLspConnectionEvent read FOnConnection write FOnConnection;

    procedure Shutdown;
  end;

var
  LspTransport: TLspTransport;

function CreateLspTransport(const AClangdPath: String; const AWorkDir: String): TLspTransport;

implementation

type
  // 一次性 UI 线程分发 holder: 按值持有消息文本,
  // 避免匿名方法直接捕获读线程循环局部变量的竞态.
  TLspQueuedMessage = class
  private
    FTransport: TLspTransport;
    FMsg: string;
  public
    constructor Create(ATransport: TLspTransport; const AMsg: string);
    procedure Dispatch;
  end;

{ TLspQueuedMessage }

constructor TLspQueuedMessage.Create(ATransport: TLspTransport; const AMsg: string);
begin
  inherited Create;
  FTransport := ATransport;
  FMsg := AMsg;
end;

procedure TLspQueuedMessage.Dispatch;
var
  T: TLspTransport;
begin
  T := FTransport;
  FTransport := nil;
  try
    if Assigned(T) then
      T.BroadcastMessage(FMsg);
  finally
    Free;
  end;
end;

{ TLspTransport }

constructor TLspTransport.Create(const AClangdPath: String; const AWorkDir: String);
begin
  inherited Create;
  FState := tsDisconnected;
  FLock := TCriticalSection.Create;
  FMessageSubs := TList<TLspMessageEvent>.Create;
  FClangdPath := AClangdPath;
  FWorkDir := AWorkDir;
  FReadBuf := nil;
  FLastBody := '';
  FNextRequestId := 0;
  FTimeout := 60;
  FLastActivity := Now;

  if (Trim(FWorkDir) <> '') and not DirectoryExists(FWorkDir) then
    ForceDirectories(FWorkDir);
  FUri := 'file://' + FWorkDir;
end;

destructor TLspTransport.Destroy;
begin
  try
    Disconnect;
  finally
    FreeAndNil(FMessageSubs);
    FLock.Free;
    inherited;
  end;
end;

function TLspTransport.Connect: Boolean;
var
  StartupInfo: TStartupInfo;
  Security: TSecurityAttributes;
  CmdLine: string;
begin
  Result := False;
  SetState(tsConnecting);
  FLastActivity := Now;

  try
    // 可继承句柄的安全属性 (子进程需继承 stdin/stdout 管道)
    FillChar(Security, SizeOf(Security), 0);
    Security.nLength := SizeOf(Security);
    Security.lpSecurityDescriptor := nil;
    Security.bInheritHandle := True;

    // stdin 管道: 父进程写 FStdinWrite, 子进程读 FStdinRead
    if not CreatePipe(FStdinRead, FStdinWrite, @Security, 0) then
    begin
      HandleError('Failed to create stdin pipe');
      Exit;
    end;
    // 父进程不可把写端继承给子进程
    SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);

    // stdout 管道: 子进程写 FStdoutWrite, 父进程读 FStdoutRead
    if not CreatePipe(FStdoutRead, FStdoutWrite, @Security, 0) then
    begin
      HandleError('Failed to create stdout pipe');
      Exit;
    end;
    SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);

    // 启动信息: 接管子进程 stdio
    FillChar(StartupInfo, SizeOf(StartupInfo), 0);
    StartupInfo.cb := SizeOf(StartupInfo);
    StartupInfo.hStdInput := FStdinRead;
    StartupInfo.hStdOutput := FStdoutWrite;
    StartupInfo.hStdError := FStdoutWrite;
    StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    StartupInfo.wShowWindow := SW_HIDE;

    CmdLine := Format('"%s" --background-index --clang-tidy --completion-style=detailed --header-insertion=iwyu --pch-storage=memory --compile-commands-dir="%s" --log-level=error',
      [FClangdPath, FWorkDir]);

    if not CreateProcess(nil, PChar(CmdLine), nil, nil, True, CREATE_NO_WINDOW,
      nil, PChar(FWorkDir), StartupInfo, FProcessInfo) then
    begin
      HandleError('Failed to start clangd: ' + SysErrorMessage(GetLastError));
      Disconnect;
      Exit;
    end;
    FProcessHandle := FProcessInfo.hProcess;

    // 父进程关闭子进程侧的句柄
    CloseHandle(FStdinRead);
    FStdinRead := 0;
    CloseHandle(FStdoutWrite);
    FStdoutWrite := 0;

    // 启动读线程
    FReadThread := TThread.CreateAnonymousThread(
      procedure
      begin
        DoReadThread;
      end);
    FReadThread.FreeOnTerminate := False;
    FReadThread.Start;

    // 给予 clangd 一点启动时间, 随后发送 initialize 请求
    Sleep(1000);

    FInitialized := Initialize;
    SetState(tsInitialized);

    if Assigned(FOnConnection) then
      FOnConnection(True);

    Result := True;
  except
    on E: Exception do
    begin
      HandleError(E.Message);
      Disconnect;
    end;
  end;
end;

procedure TLspTransport.Disconnect;
begin
  SetState(tsShuttingDown);

  // 先关读端, 解除读线程的 ReadFile 阻塞
  if FStdoutRead <> 0 then
  begin
    CloseHandle(FStdoutRead);
    FStdoutRead := 0;
  end;

  if Assigned(FReadThread) then
  begin
    FReadThread.Terminate;
    FReadThread.WaitFor;
    FreeAndNil(FReadThread);
  end;

  // 结束子进程
  if FProcessHandle <> 0 then
  begin
    TerminateProcess(FProcessHandle, 0);
    CloseHandle(FProcessInfo.hThread);
    CloseHandle(FProcessInfo.hProcess);
    FProcessHandle := 0;
  end;

  // 关闭残留管道句柄
  if FStdinWrite <> 0 then begin CloseHandle(FStdinWrite); FStdinWrite := 0; end;
  if FStdinRead <> 0 then begin CloseHandle(FStdinRead); FStdinRead := 0; end;
  if FStdoutWrite <> 0 then begin CloseHandle(FStdoutWrite); FStdoutWrite := 0; end;

  SetState(tsDisconnected);
  if Assigned(FOnConnection) then
    FOnConnection(False);
end;

function TLspTransport.Initialize: Boolean;
var
  Request: String;
begin
  Request := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"initialize",' +
    '"params":{"processId":null,"rootUri":"%s","capabilities":{' +
    '"textDocument":{' +
    '"synchronization":{"dynamicRegistration":false,"willSave":false,"didSave":false},' +
    '"completion":{"completionItem":{"snippetSupport":false,"documentationFormat":["plaintext"]}},' +
    '"signatureHelp":{"signatureInformation":{"documentationFormat":["plaintext"]}},' +
    '"hover":{"contentFormat":["plaintext"]}}}}}',
    [TInterlocked.Increment(FNextRequestId), FUri]);

  SendInternal(Request);
  // 握手响应异步到达并交给订阅者处理; 此处不阻塞等待.
  Result := True;
end;

procedure TLspTransport.MarkReady;
begin
  SetState(tsReady);
  if Assigned(FOnConnection) then
    FOnConnection(True);
end;

function TLspTransport.WaitForInitialized(const ATimeoutSec: Integer): Boolean;
var
  Start: TDateTime;
begin
  Result := False;
  Start := Now;
  while (Now - Start) * SecsPerDay < ATimeoutSec do
  begin
    Sleep(100);
    if FState = tsReady then
    begin
      Result := True;
      Exit;
    end;
    if FState in [tsDisconnected, tsShuttingDown] then
      Exit;
  end;
end;

function TLspTransport.SendRequest(const AMethod: String; const AParams: String;
  out AId: Integer; out AResult: String): Boolean;
var
  Request: String;
begin
  AId := TInterlocked.Increment(FNextRequestId);
  AResult := '';
  Request := Format('{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}',
    [AId, AMethod, AParams]);
  SendInternal(Request);
  Result := True;
end;

function TLspTransport.SendNotification(const AMethod: String; const AParams: String): Boolean;
var
  ParamsStr: String;
begin
  if AParams <> '' then
    ParamsStr := AParams
  else
    ParamsStr := '{}';
  SendInternal(Format('{"jsonrpc":"2.0","method":"%s","params":%s}', [AMethod, ParamsStr]));
  Result := True;
end;

procedure TLspTransport.SendNotificationAsync(const AMethod: String; const AParams: String);
var
  ParamsStr: String;
begin
  if AParams <> '' then
    ParamsStr := AParams
  else
    ParamsStr := '{}';
  TThread.Queue(nil,
    procedure
    begin
      SendInternal(Format('{"jsonrpc":"2.0","method":"%s","params":%s}', [AMethod, ParamsStr]));
    end);
end;

procedure TLspTransport.DoReadThread;
var
  Chunk: TBytes;
  BytesRead: DWORD;
  OldLen: Integer;
  HeaderEnd: Integer;
  ContentLength: Integer;
  I: Integer;
  HeaderStr: string;
  ClPos: Integer;
  ClValue: string;
  BodyStr: string;
  Remaining: Integer;
begin
  SetLength(Chunk, 8192);
  try
    while FState <> tsShuttingDown do
    begin
      BytesRead := 0;
      if not ReadFile(FStdoutRead, Chunk[0], Length(Chunk), BytesRead, nil) or (BytesRead = 0) then
      begin
        if FState = tsShuttingDown then
          Break;
        Sleep(10);
        Continue;
      end;

      // 按字节累积
      OldLen := Length(FReadBuf);
      SetLength(FReadBuf, OldLen + Integer(BytesRead));
      Move(Chunk[0], FReadBuf[OldLen], BytesRead);

      // 解析一或多条 Content-Length 帧
      repeat
        // 定位 "\r\n\r\n" (13 10 13 10)
        HeaderEnd := -1;
        for I := 0 to Length(FReadBuf) - 4 do
          if (FReadBuf[I] = 13) and (FReadBuf[I + 1] = 10) and
             (FReadBuf[I + 2] = 13) and (FReadBuf[I + 3] = 10) then
          begin
            HeaderEnd := I;
            Break;
          end;
        if HeaderEnd < 0 then
          Break;

        HeaderStr := TEncoding.UTF8.GetString(FReadBuf, 0, HeaderEnd);
        ContentLength := 0;
        ClPos := Pos('Content-Length:', HeaderStr);
        if ClPos > 0 then
        begin
          ClValue := Trim(Copy(HeaderStr, ClPos + Length('Content-Length:'), MaxInt));
          ContentLength := StrToIntDef(ClValue, 0);
        end;

        if ContentLength <= 0 then
        begin
          // 畸形头: 丢弃头部块, 继续扫描
          Remaining := Length(FReadBuf) - (HeaderEnd + 4);
          if Remaining > 0 then
            Move(FReadBuf[HeaderEnd + 4], FReadBuf[0], Remaining);
          SetLength(FReadBuf, Remaining);
          Continue;
        end;

        if Length(FReadBuf) < HeaderEnd + 4 + ContentLength then
          Break; // 正文不完整, 等待更多字节

        BodyStr := TEncoding.UTF8.GetString(FReadBuf, HeaderEnd + 4, ContentLength);
        FLastBody := BodyStr;

        Remaining := Length(FReadBuf) - (HeaderEnd + 4 + ContentLength);
        if Remaining > 0 then
          Move(FReadBuf[HeaderEnd + 4 + ContentLength], FReadBuf[0], Remaining);
        SetLength(FReadBuf, Remaining);

        TThread.Queue(nil, TLspQueuedMessage.Create(Self, BodyStr).Dispatch);
      until False;
    end;
  finally
    SetLength(Chunk, 0);
  end;
end;

function TLspTransport.GetConnected: Boolean;
begin
  Result := FState = tsReady;
end;

procedure TLspTransport.HandleMessage(const AMessage: String);
begin
  BroadcastMessage(AMessage);
end;

procedure TLspTransport.SubscribeMessage(const AHandler: TLspMessageEvent);
var
  I: Integer;
begin
  if not Assigned(AHandler) then
    Exit;
  FLock.Enter;
  try
    if not Assigned(FMessageSubs) then
      FMessageSubs := TList<TLspMessageEvent>.Create;
    for I := 0 to FMessageSubs.Count - 1 do
      if (TMethod(FMessageSubs[I]).Code = TMethod(AHandler).Code) and
        (TMethod(FMessageSubs[I]).Data = TMethod(AHandler).Data) then
        Exit;
    FMessageSubs.Add(AHandler);
  finally
    FLock.Leave;
  end;
end;

procedure TLspTransport.UnsubscribeMessage(const AHandler: TLspMessageEvent);
var
  I: Integer;
begin
  if not Assigned(FMessageSubs) then
    Exit;
  FLock.Enter;
  try
    for I := FMessageSubs.Count - 1 downto 0 do
      if (TMethod(FMessageSubs[I]).Code = TMethod(AHandler).Code) and
        (TMethod(FMessageSubs[I]).Data = TMethod(AHandler).Data) then
        FMessageSubs.Delete(I);
  finally
    FLock.Leave;
  end;
end;

procedure TLspTransport.BroadcastMessage(const AMessage: String);
var
  Handlers: TArray<TLspMessageEvent>;
  Legacy: TLspMessageEvent;
  I: Integer;
begin
  FLock.Enter;
  try
    if Assigned(FMessageSubs) then
      Handlers := FMessageSubs.ToArray
    else
      SetLength(Handlers, 0);
    Legacy := FOnMessage;
  finally
    FLock.Leave;
  end;

  if Assigned(Legacy) then
  try
    Legacy(AMessage);
  except
  end;

  for I := Low(Handlers) to High(Handlers) do
  try
    Handlers[I](AMessage);
  except
  end;
end;

procedure TLspTransport.HandleError(const AError: String);
begin
  if Assigned(FOnError) then
    FOnError(AError);
end;

procedure TLspTransport.SetState(const AState: TLspTransportState);
begin
  FLock.Enter;
  try
    FState := AState;
    FLastActivity := Now;
  finally
    FLock.Leave;
  end;
end;

procedure TLspTransport.SendPayload(const AJsonPayload: String);
begin
  if Trim(AJsonPayload) <> '' then
    SendInternal(AJsonPayload);
end;

procedure TLspTransport.SendInternal(const AMessage: String);
var
  BytesWritten: DWORD;
  Utf8Body: UTF8String;
  Header: UTF8String;
  Utf8Full: UTF8String;
begin
  if (AMessage = '') or (FStdinWrite = 0) then
    Exit;

  // LSP 帧: "Content-Length: <bytes>\r\n\r\n<json>"; 长度按 UTF-8 字节计
  Utf8Body := UTF8String(AMessage);
  Header := UTF8String(Format('Content-Length: %d'#13#10#13#10, [Length(Utf8Body)]));
  Utf8Full := Header + Utf8Body;

  if not WriteFile(FStdinWrite, Utf8Full[1], Length(Utf8Full), BytesWritten, nil) then
    HandleError('Failed to write to LSP pipe');

  FLastActivity := Now;
end;

procedure TLspTransport.Shutdown;
begin
  Disconnect;
end;

function CreateLspTransport(const AClangdPath: String; const AWorkDir: String): TLspTransport;
begin
  Result := TLspTransport.Create(AClangdPath, AWorkDir);
end;

initialization
  LspTransport := nil;

finalization
  if Assigned(LspTransport) then
    LspTransport.Free;

end.