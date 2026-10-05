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

unit Core.Events;

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, SyncObjs, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections;
{$ENDIF}

// Event types for decoupling main forms from business logic.
// 约定: Publish 取得事件对象所有权, 分发完毕后释放. 发布方一律 fire-and-forget,
// 禁止复用已 Publish 的对象, 订阅方禁止释放收到的事件.

// 事件基类
type
  TEvent = class(TObject)
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

// Breakpoint actions
type
  TBreakpointAction = (baAdded, baRemoved, baToggled, baHit, baClearedAll);

// Breakpoint event with full context
type
  TBreakpointEvent = class(TEvent)
  private
    FFileName: string;
    FLineNumber: Integer;
    FAction: TBreakpointAction;
    FActive: Boolean;
  public
    constructor Create(const AFileName: string; ALine: Integer;
      AAction: TBreakpointAction; AActive: Boolean = True); overload;
    // 兼容旧调用点 Debugger.pas 的 Create(Line, FileName) 形状
    constructor Create(ALine: Integer; const AFileName: string;
      AAction: TBreakpointAction = baToggled); overload;
    property FileName: string read FFileName;
    property LineNumber: Integer read FLineNumber;
    property Action: TBreakpointAction read FAction;
    property Active: Boolean read FActive;
  end;

// Compiler events
type
  TCompileProgressEvent = class(TEvent)
  private
    FProgress: Integer;
    FMessage: String;
  public
    constructor Create(Progress: Integer; const Message: String);
    property Progress: Integer read FProgress write FProgress;
    property Message: String read FMessage write FMessage;
  end;

  TCompileSuccessEvent = class(TEvent)
  private
    FAction: Integer; // 0=none, 1=run, 2=debug, 3=profile
  public
    constructor Create(Action: Integer);
    property Action: Integer read FAction write FAction;
  end;

  TCompileErrorEvent = class(TEvent)
  private
    FLine: Integer;
    FMessage: String;
    FUnit: String;
  public
    constructor Create(Line: Integer; const Message, UnitName: String);
    property Line: Integer read FLine write FLine;
    property Message: String read FMessage write FMessage;
    property UnitName: String read FUnit write FUnit;
  end;

// Debugger events
type
  TWatchVarEvent = class(TEvent)
  private
    FName: String;
    FValue: String;
  public
    constructor Create(const Name, Value: String);
    property Name: String read FName write FName;
    property Value: String read FValue write FValue;
  end;

// GDB Variable Objects 变量树节点模型 (懒加载)
type
  TGdbVarNode = class
  public
    Handle: string;       // GDB 内部句柄, 如 "var1", "var1.0"
    Expression: string;   // 显示名, 如 "vec", "[0]", "size"
    Value: string;
    TypeName: string;
    NumChildren: Integer;
    HasChildren: Boolean;
    Expanded: Boolean;    // UI 展开状态
    Changed: Boolean;     // 本轮 -var-update 是否变动 (UI 标红用)
    Children: TObjectList<TGdbVarNode>;
    constructor Create;
    destructor Destroy; override;
  end;

// 变量树刷新通知 (拥有 RootNodes, 随事件释放)
  TWatchUpdateEvent = class(TEvent)
  private
    FRootNodes: TObjectList<TGdbVarNode>;
  public
    constructor Create(ARoots: TObjectList<TGdbVarNode>);
    destructor Destroy; override;
    property RootNodes: TObjectList<TGdbVarNode> read FRootNodes;
  end;

// 调用栈帧模型
  TCallStackFrameItem = record
    Level: Integer;
    Address: string;
    FunctionName: string;
    FileName: string;
    Line: Integer;
  end;

// 调用栈刷新事件
  TCallStackUpdateEvent = class(TEvent)
  private
    FFrames: TArray<TCallStackFrameItem>;
  public
    constructor Create(const AFrames: TArray<TCallStackFrameItem>);
    property Frames: TArray<TCallStackFrameItem> read FFrames;
  end;

// 工程结构变更事件 (ProjectTreeFrame 订阅)
  TProjectChangedEvent = class(TEvent)
  private
    FFileName: string;
    FChangeKind: Integer; // 0=刷新, 1=增, 2=删, 3=改名
  public
    constructor Create(const AFileName: string; AChangeKind: Integer = 0);
    property FileName: string read FFileName;
    property ChangeKind: Integer read FChangeKind;
  end;

// Application events
type
  TFormTitleEvent = class(TEvent)
  private
    FTitle: String;
  public
    constructor Create(const Title: String);
    property Title: String read FTitle write FTitle;
  end;

// Event handler type for event manager.
// 刻意使用经典 of object (而非 reference to): 订阅/退订需按 Code+Data
// 比对方法指针, 匿名闭包无法可靠比对; 现有调用方均为方法指针, 无损.
type
  TEventHandler = procedure(const Event: TEvent) of object;

// 专用单播钩子 (与通用订阅并存; 发布时按类型路由)
type
  // A plain METHOD POINTER, not a Delphi anonymous method.
  //
  // Measured 2026-10-05 with the first real FPC 3.2.2 compile: the
  // `reference to` spelling is rejected in every mode --
  // -Mdelphi, -Mdelphiunicode, -Mfpc, -Mobjfpc, each also with
  // {$modeswitch anonymousfunctions} -- all reporting
  //     Error: Identifier not found "reference"
  // and the string `reference to` appears in NONE of the 84 shipped RTL
  // units, while `TProcedure` does exist in system.ppu. So procedural
  // TYPES exist and the Delphi ANONYMOUS-METHOD spelling does not.
  //
  // This is the fallback the port plan named for dialect risk #3:
  // "if FPC's delphi mode does not support it, disable the switch and move
  // to explicit class-level subscription in F1".
  //
  // BEHAVIOUR DIFFERENCE, stated rather than assumed: a method pointer
  // cannot close over local state the way an anonymous method can. A
  // subscriber must therefore be a real method, and any per-subscription
  // payload has to travel as a parameter. The existing subscribers pass
  // their payload through the event itself, so nothing breaks today -- but
  // a future caller relying on closure would silently not compile.
  TCompilerProgressHandler = procedure(const ProgressEvent: TCompileProgressEvent) of object;

// Event manager - thread-safe event publishing.
// 分发时先快照后调用 (不持锁执行订阅者代码, 防重入死锁);
// 单个订阅者异常被隔离, 不影响其他订阅者与事件释放.
type
  TEventManager = class
  private
    FLock: TCriticalSection;
    FHandlers: TList<TEventHandler>;
    FOnCompilerProgress: TCompilerProgressHandler;
    FOnProjectChanged: TEventHandler;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Subscribe(const Handler: TEventHandler);
    procedure Unsubscribe(const Handler: TEventHandler);
    procedure Publish(const Event: TEvent);
    property OnCompilerProgress: TCompilerProgressHandler
      read FOnCompilerProgress write FOnCompilerProgress;
    property OnProjectChanged: TEventHandler
      read FOnProjectChanged write FOnProjectChanged;
    class var Instance: TEventManager;
  end;

implementation

{ TEvent }

constructor TEvent.Create;
begin
  inherited Create;
end;

destructor TEvent.Destroy;
begin
  inherited;
end;

{ TEventManager }

constructor TEventManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHandlers := TList<TEventHandler>.Create;
end;

destructor TEventManager.Destroy;
begin
  FreeAndNil(FHandlers);
  FreeAndNil(FLock);
  inherited;
end;

procedure TEventManager.Subscribe(const Handler: TEventHandler);
var
  I: Integer;
begin
  if not Assigned(Handler) then
    Exit;
  FLock.Enter;
  try
    // 去重: 同一 Code+Data 只订阅一次
    for I := 0 to FHandlers.Count - 1 do
      if (TMethod(FHandlers[I]).Code = TMethod(Handler).Code) and
        (TMethod(FHandlers[I]).Data = TMethod(Handler).Data) then
        Exit;
    FHandlers.Add(Handler);
  finally
    FLock.Leave;
  end;
end;

procedure TEventManager.Unsubscribe(const Handler: TEventHandler);
var
  I: Integer;
begin
  if not Assigned(Handler) then
    Exit;
  FLock.Enter;
  try
    for I := FHandlers.Count - 1 downto 0 do
      if (TMethod(FHandlers[I]).Code = TMethod(Handler).Code) and
        (TMethod(FHandlers[I]).Data = TMethod(Handler).Data) then
        FHandlers.Delete(I);
  finally
    FLock.Leave;
  end;
end;

procedure TEventManager.Publish(const Event: TEvent);
var
  Snapshot: TArray<TEventHandler>;
  ProgressHook: TCompilerProgressHandler;
  ProjectHook: TEventHandler;
  I: Integer;
begin
  if not Assigned(Event) then
    Exit;
  FLock.Enter;
  try
    Snapshot := FHandlers.ToArray;
    ProgressHook := FOnCompilerProgress;
    ProjectHook := FOnProjectChanged;
  finally
    FLock.Leave;
  end;
  try
    for I := Low(Snapshot) to High(Snapshot) do
    try
      if Assigned(Snapshot[I]) then
        Snapshot[I](Event);
    except
      // 隔离单个订阅者异常
    end;
    // 类型路由单播钩子
    if (Event is TCompileProgressEvent) and Assigned(ProgressHook) then
    try
      ProgressHook(TCompileProgressEvent(Event));
    except
    end;
    if (Event is TProjectChangedEvent) and Assigned(ProjectHook) then
    try
      ProjectHook(Event);
    except
    end;
  finally
    Event.Free;
  end;
end;

{ TBreakpointEvent }

constructor TBreakpointEvent.Create(const AFileName: string; ALine: Integer;
  AAction: TBreakpointAction; AActive: Boolean);
begin
  inherited Create;
  FFileName := AFileName;
  FLineNumber := ALine;
  FAction := AAction;
  FActive := AActive;
end;

constructor TBreakpointEvent.Create(ALine: Integer; const AFileName: string;
  AAction: TBreakpointAction);
begin
  inherited Create;
  FFileName := AFileName;
  FLineNumber := ALine;
  FAction := AAction;
  FActive := True;
end;

{ TCompileProgressEvent }

constructor TCompileProgressEvent.Create(Progress: Integer; const Message: String);
begin
  inherited Create;
  FProgress := Progress;
  FMessage := Message;
end;

{ TCompileSuccessEvent }

constructor TCompileSuccessEvent.Create(Action: Integer);
begin
  inherited Create;
  FAction := Action;
end;

{ TCompileErrorEvent }

constructor TCompileErrorEvent.Create(Line: Integer; const Message, UnitName: String);
begin
  inherited Create;
  FLine := Line;
  FMessage := Message;
  FUnit := UnitName;
end;

{ TWatchVarEvent }

constructor TWatchVarEvent.Create(const Name, Value: String);
begin
  inherited Create;
  FName := Name;
  FValue := Value;
end;

{ TGdbVarNode }

constructor TGdbVarNode.Create;
begin
  inherited Create;
  Children := TObjectList<TGdbVarNode>.Create(True);
end;

destructor TGdbVarNode.Destroy;
begin
  FreeAndNil(Children);
  inherited;
end;

{ TWatchUpdateEvent }

constructor TWatchUpdateEvent.Create(ARoots: TObjectList<TGdbVarNode>);
begin
  inherited Create;
  FRootNodes := ARoots;
end;

destructor TWatchUpdateEvent.Destroy;
begin
  FreeAndNil(FRootNodes);
  inherited;
end;

{ TCallStackUpdateEvent }

constructor TCallStackUpdateEvent.Create(const AFrames: TArray<TCallStackFrameItem>);
begin
  inherited Create;
  FFrames := Copy(AFrames, 0, Length(AFrames));
end;

{ TProjectChangedEvent }

constructor TProjectChangedEvent.Create(const AFileName: string; AChangeKind: Integer);
begin
  inherited Create;
  FFileName := AFileName;
  FChangeKind := AChangeKind;
end;

{ TFormTitleEvent }

constructor TFormTitleEvent.Create(const Title: String);
begin
  inherited Create;
  FTitle := Title;
end;

initialization
  TEventManager.Instance := TEventManager.Create;

finalization
  FreeAndNil(TEventManager.Instance);

end.
