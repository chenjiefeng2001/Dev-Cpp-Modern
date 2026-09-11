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

unit Core.Services;

interface

uses
  Core.Events, SysUtils, Classes, SyncObjs, System.TypInfo;

// 说明: 接口内禁止 `event` 关键字与字段式 property (Object Pascal 非法语法,
// 本文件曾因此无法编译). 事件一律收敛到 Core.Events 的 TEventManager,
// 接口只保留方法与方法式属性.

// ========== IProjectService 接口 ==========
type
  IProjectService = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567891}']
    function LoadProject(const FileName: String): Boolean;
    function SaveProject: Boolean;
    function GetCurrentProject: String;
    function GetProjectModified: Boolean;
    function AddUnit(const FileName: String): Integer;
    function RemoveUnit(Index: Integer): Boolean;
    property CurrentProject: String read GetCurrentProject;
    property ProjectModified: Boolean read GetProjectModified;
  end;

// ========== ICompilerService 接口 ==========
type
  ICompilerService = interface
    ['{B2C3D4E5-F6A7-8901-BCDE-FE1234567892}']
    function Compile(const FileName: String): Boolean;
    function CheckSyntax(const FileName: String): Boolean;
    function Abort: Boolean;
    function GetCompiling: Boolean;
    function GetErrorCount: Integer;
    function GetWarningCount: Integer;
    // 进度经由 TEventManager(TCompileProgressEvent) 广播, 不在此挂事件
    property Compiling: Boolean read GetCompiling;
    property ErrorCount: Integer read GetErrorCount;
    property WarningCount: Integer read GetWarningCount;
  end;

// ========== IDebuggerService 接口 ==========
// 调试领域操作唯一入口 (Frame/上帝类禁止直调 Debugger 实例)
type
  IDebuggerService = interface
    ['{C3D4E5F6-A7B8-9012-CDEF-FE1234567893}']
    procedure StartDebugging(const AExecutable, AParams, AWorkingDir: string);
    procedure StopDebugging;
    function IsDebugging: Boolean;
    procedure StepOver;
    procedure StepInto;
    procedure StepOut;
    procedure ContinueExecution;
    procedure ToggleBreakpoint(const AFileName: string; ALine: Integer);
    // GDB Variable Objects 变量树 (懒加载)
    procedure AddWatch(const AExpression: string);
    procedure RemoveWatch(const AVarHandle: string);
    procedure ExpandVariable(const AVarHandle: string);
    procedure RefreshWatches;
  end;

// ========== IEditorService 接口 ==========
type
  IEditorService = interface
    ['{D4E5F6A7-B8C9-0123-DEF0-EF1234567894}']
    function OpenFile(const FileName: String; NewFile: Boolean = False): Integer;
    function CloseFile(Index: Integer): Boolean;
    function GetActiveEditor: String;
    property ActiveEditor: String read GetActiveEditor;
  end;

// ========== ISettingsService 接口 ==========
type
  ISettingsService = interface
    ['{E5F6A7B8-C9D0-1234-5678-FE1234567895}']
    function LoadSettings: Boolean;
    function SaveSettings: Boolean;
    function GetSetting(const Key: String): String;
    procedure SetSetting(const Key, Value: String);
    function GetAppVersion: String;
    property AppVersion: String read GetAppVersion;
  end;

// 服务定位器 - 全局服务访问点 (接口引用, 无需手动释放)
type
  TServiceLocator = class
  private
    FLock: TCriticalSection;
    FProjectService: IProjectService;
    FCompilerService: ICompilerService;
    FDebuggerService: IDebuggerService;
    FEditorService: IEditorService;
    FSettingsService: ISettingsService;
    constructor Create;
    destructor Destroy; override;
    function QueryService(const AGuid: TGUID; out AService: IInterface): Boolean;
  public
    class var Instance: TServiceLocator;
    // 泛型安全获取, 失败返回 False 且输出 nil (不抛异常)
    class function TryGetService<T: IInterface>(out Svc: T): Boolean; static;
    property ProjectService: IProjectService read FProjectService write FProjectService;
    property CompilerService: ICompilerService read FCompilerService write FCompilerService;
    property DebuggerService: IDebuggerService read FDebuggerService write FDebuggerService;
    property EditorService: IEditorService read FEditorService write FEditorService;
    property SettingsService: ISettingsService read FSettingsService write FSettingsService;
  end;

implementation

{ TServiceLocator }

constructor TServiceLocator.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TServiceLocator.Destroy;
begin
  FProjectService := nil;
  FCompilerService := nil;
  FDebuggerService := nil;
  FEditorService := nil;
  FSettingsService := nil;
  FreeAndNil(FLock);
  inherited;
end;

function TServiceLocator.QueryService(const AGuid: TGUID;
  out AService: IInterface): Boolean;
begin
  Result := False;
  AService := nil;
  FLock.Enter;
  try
    if IsEqualGUID(AGuid, IDebuggerService) then
      AService := FDebuggerService
    else if IsEqualGUID(AGuid, IProjectService) then
      AService := FProjectService
    else if IsEqualGUID(AGuid, ICompilerService) then
      AService := FCompilerService
    else if IsEqualGUID(AGuid, IEditorService) then
      AService := FEditorService
    else if IsEqualGUID(AGuid, ISettingsService) then
      AService := FSettingsService
    else
      Exit;
    Result := Assigned(AService);
    if not Result then
      AService := nil;
  finally
    FLock.Leave;
  end;
end;

class function TServiceLocator.TryGetService<T>(out Svc: T): Boolean;
var
  Unknown: IInterface;
  G: TGUID;
begin
  Result := False;
  Svc := Default(T);
  if not Assigned(Instance) then
    Exit;
  G := GetTypeData(TypeInfo(T))^.Guid;
  if not Instance.QueryService(G, Unknown) then
    Exit;
  // 经由 QueryInterface 做类型安全转换 (引用计数由编译器管理)
  Result := Supports(Unknown, G, Svc);
end;

initialization
  TServiceLocator.Instance := TServiceLocator.Create;

finalization
  FreeAndNil(TServiceLocator.Instance);

end.
