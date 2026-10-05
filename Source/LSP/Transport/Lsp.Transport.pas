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
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections, SyncObjs,
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  {$ENDIF}
  {$IFDEF FPC}
  Types, Lsp.JsonRpc, Lsp.Process, Lsp.Process.Factory;
  {$ELSE}
  System.Types, System.IOUtils, LSP.JsonRpc, LSP.Process, LSP.Process.Factory;
  {$ENDIF}

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
{$IFDEF FPC}
  // Carries the read loop as a real thread body. Declared here, ahead of
  // TLspTransport, so no forward declaration is needed; the owner is held
  // as TObject and cast at the single use site.
  //
  // Needed because TThread.CreateAnonymousThread accepts only a TProcedure
  // (a routine with no Self) and FPC cannot express one inline:
  //     Got "...procedure of object...", expected "...procedure..."
  TLspReadThread = class(TThread)
  private
    FOwner: TObject;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TObject);
  end;
{$ENDIF}

  TLspTransport = class
  private
    FState: TLspTransportState;
    FProcess: ILspProcess;         // 子进程（clangd）句柄, 抽象见 LSP.Process
    FProcessFactory: ILspProcessFactory;
    FReadThread: TThread;
    FLock: TCriticalSection;
    FOnMessage: TLspMessageEvent;
    FMessageSubs: TList<TLspMessageEvent>;
{$IFDEF FPC}
    // Pending notification payloads for the queued sender. A LIST, not a
    // single field pair: two posts before the queue drains would
    // otherwise overwrite each other and send the first message twice.
    FPendingSends: TList<string>;
{$ENDIF}
    FOnError: TLspErrorEvent;
    FOnConnection: TLspConnectionEvent;
    FUri: String;
    FInitialized: Boolean;
    FClangdPath: string;
    FWorkDir: string;
    FDecoder: TLspFrameDecoder;   // LSP 帧解码器（纯 Pascal, 见 LSP.JsonRpc）
    FLastBody: String;        // 最近一条已派发的 JSON (供诊断/回读)
    FNextRequestId: Integer;
    FLastActivity: TDateTime;
    FTimeout: Integer;
{$IFDEF FPC}
    // TInterlocked has no FPC equivalent. The increment happens under FLock,
    // the lock this class already takes for counter access.
    //
    // Declared AFTER every field, not at the top of `private`: Pascal rejects
    // a field that follows a method
    //     Error: Fields cannot appear after a method or property definition
    // and under an IFDEF so the Delphi build gains no member that cannot be
    // compile-checked on a machine with no Delphi compiler.
    function NextRequestId: Integer;
{$ENDIF}
{$IFDEF FPC}
    procedure SendNotificationQueued;
{$ENDIF}
{$IFDEF FPC}
    procedure DoReadThread;
{$ENDIF}
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
{$IFDEF FPC}
  FPendingSends := TList<string>.Create;
{$ENDIF}
  FClangdPath := AClangdPath;
  FWorkDir := AWorkDir;
  FProcess := nil;
  FProcessFactory := CreateDefaultLspProcessFactory;
  FDecoder := TLspFrameDecoder.Create;
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
    FProcess := nil;
    FProcessFactory := nil;
    FreeAndNil(FDecoder);
    FreeAndNil(FMessageSubs);
{$IFDEF FPC}
  FreeAndNil(FPendingSends);
{$ENDIF}
    FLock.Free;
    inherited;
  end;
end;

function TLspTransport.Connect: Boolean;
begin
  Result := False;
  SetState(tsConnecting);
  FLastActivity := Now;

  try
    // 启动 clangd 子进程。进程/管道实现按编译器选择:
    // Delphi -> Win32 管道, FPC -> RTL TProcess（见 LSP.Process.Factory）。
    FProcess := FProcessFactory.Start(FClangdPath,
      '--background-index --clang-tidy --completion-style=detailed ' +
      '--header-insertion=iwyu --pch-storage=memory ' +
      '--compile-commands-dir="' + FWorkDir + '" --log-level=error',
      FWorkDir);
    if FProcess = nil then
    begin
      HandleError('Failed to start clangd: ' + FClangdPath);
      Disconnect;
      Exit;
    end;

    // 启动读线程
{$IFDEF FPC}
    // A real TThread, not CreateAnonymousThread: that takes a TProcedure --
    // a routine with NO Self -- and a class method is `procedure of
    // object`, which the compiler rejects outright:
    //     Got "...procedure of object...", expected "...procedure..."
    // FPC has no nested procedures, so a plain one cannot be produced from
    // a method, and a forwarder class method has the same shape. The long
    // form is the way: the subclass supplies Execute.
    FReadThread := TLspReadThread.Create(Self);
{$ELSE}
    FReadThread := TThread.CreateAnonymousThread(
      procedure
      begin
        DoReadThread;
      end);
{$ENDIF}
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

  // 先结束子进程：实现会先关闭读端, 从而解除读线程的阻塞读
  // (Win32: CloseHandle 读端; FPC: 子进程退出后管道到达 EOF)
  if Assigned(FProcess) then
  begin
    FProcess.Terminate;
    FProcess := nil;
  end;

  if Assigned(FReadThread) then
  begin
    FReadThread.Terminate;
    FReadThread.WaitFor;
    FreeAndNil(FReadThread);
  end;

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
{$IFDEF FPC}
    [NextRequestId, FUri]);
{$ELSE}
    [TInterlocked.Increment(FNextRequestId), FUri]);
{$ENDIF}

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
{$IFDEF FPC}
  AId := NextRequestId;
{$ELSE}
  AId := TInterlocked.Increment(FNextRequestId);
{$ENDIF}
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
{$IFDEF FPC}
  // FPC has no nested procedures, and this one captured two values. Both are
  // parameters of this method, not locals of its body, so they can simply be
  // passed on. ParamsStr is computed once here and the queued call formats the
  // identical string it did before -- the closure became an argument list, not a
  // behaviour change.
  // FPC has no nested procedures, and the inline procedure in the Delphi
  // branch captured two values. The payload therefore travels in
  // FPendingSends rather than in a closure: the queued call runs after this
  // frame is gone, so a captured reference would dangle by then.
  if not Assigned(FPendingSends) then
    FPendingSends := TList<string>.Create;
  FPendingSends.Add(Format('{"jsonrpc":"2.0","method":"%s","params":%s}',
    [AMethod, ParamsStr]));
  // See the receiver note above: nil is rejected, and in this
  // project's -Mdelphiunicode mode the bound form is `O.P` with NO @.
  // @Method is the objfpc spelling and is an error here.
  TThread.Queue(TThread.CurrentThread, SendNotificationQueued);
{$ELSE}
  TThread.Queue(nil,
    procedure
    begin
      SendInternal(Format('{"jsonrpc":"2.0","method":"%s","params":%s}', [AMethod, ParamsStr]));
    end);
{$ENDIF}
end;

{$IFDEF FPC}
procedure TLspTransport.SendNotificationQueued;
var
  Payload: string;
begin
  if not Assigned(FPendingSends) or (FPendingSends.Count = 0) then
    Exit;
  Payload := FPendingSends[0];
  FPendingSends.Delete(0);
  SendInternal(Payload);
end;
{$ENDIF}

{$IFDEF FPC}
function TLspTransport.NextRequestId: Integer;
begin
  FLock.Enter;
  try
    Inc(FNextRequestId);
    Result := FNextRequestId;
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

{$IFDEF FPC}
constructor TLspReadThread.Create(AOwner: TObject);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TLspReadThread.Execute;
begin
  TLspTransport(FOwner).DoReadThread;
end;
{$ENDIF}

procedure TLspTransport.DoReadThread;
var
  Chunk: TBytes;
  N: Integer;
  BodyStr: string;
begin
  try
    while FState <> tsShuttingDown do
    begin
      if not Assigned(FProcess) then
        Break;
      // 阻塞读: 有数据即返回, 0 = EOF, -1 = 硬错误
      N := FProcess.Read(Chunk);
      if N <= 0 then
      begin
        if FState = tsShuttingDown then
          Break;
        Sleep(10);
        Continue;
      end;

      // 交给纯 Pascal 的帧解码器 (LSP.JsonRpc, 已被 FPC headless 单测覆盖)
      FDecoder.Feed(Chunk);

      // 解析出所有已完整的 Content-Length 帧
      while FDecoder.TryPopBody(BodyStr) do
      begin
        FLastBody := BodyStr;
        TThread.Queue(nil, TLspQueuedMessage.Create(Self, BodyStr).Dispatch);
      end;
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
  Frame: TBytes;
begin
  if (AMessage = '') or (not Assigned(FProcess)) then
    Exit;

  // LSP 帧: "Content-Length: <bytes>\r\n\r\n<json>", 长度按 UTF-8 字节计
  // (组帧逻辑已抽到 LSP.JsonRpc, 与 FPC 侧单测共用同一实现)
  Frame := BuildLspFrameBytes(AMessage);

  if not FProcess.Write(Frame) then
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