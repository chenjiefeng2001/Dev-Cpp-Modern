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

unit Lsp.Bootstrap;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  LSP.Transport, Lsp.DocumentSync,
  LSP.Client.Completion, LSP.Client.SignatureHelp, LSP.Client.Hover,
  LSP.Client.Definition;

// LSP 生命周期引导器:
//   后台线程拉起 clangd -> Connect(含 initialize 握手) ->
//   主线程 initialized 通知 + MarkReady + 挂接双管理器/文档同步
// 找不到 clangd 时静默待命 (不阻塞启动, 不弹窗)
type
  TLspBootstrap = class
  private
    FTransport: TLspTransport;
    FWorkDir: string;
    FClangdPath: string;
    FStarting: Boolean;
    FReady: Boolean;
    FLock: TCriticalSection;
    function FindClangdExe: string;
    procedure DoStartupThread;
    procedure FinishReady;
  public
    constructor Create;
    destructor Destroy; override;
    // 幂等: 重复调用直接返回; 实际连接在后台线程完成
    procedure Startup(const AWorkDir: string);
    property Ready: Boolean read FReady;
    property Transport: TLspTransport read FTransport;
    property ClangdPath: string read FClangdPath;
  end;

var
  LspBootstrap: TLspBootstrap;

// 入口 (main.pas FormShow 调用一次即可)
procedure LspBootstrapStartup(const AWorkDir: string);

implementation

{ TLspBootstrap }

constructor TLspBootstrap.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TLspBootstrap.Destroy;
begin
  // 注意: 后台启动线程可能仍在 Connect 阻塞中; 这里只释放已移交的实例.
  // (实验阶段接受该竞态: 进程退出时 OS 回收管道/进程句柄)
  FreeAndNil(FTransport);
  FreeAndNil(FLock);
  inherited;
end;

procedure TLspBootstrap.Startup(const AWorkDir: string);
begin
  FLock.Enter;
  try
    if FReady or FStarting then
      Exit;
    FStarting := True;
    if Trim(AWorkDir) <> '' then
      FWorkDir := AWorkDir;
  finally
    FLock.Leave;
  end;
  TThread.CreateAnonymousThread(
    procedure
    begin
      DoStartupThread;
    end).Start;
end;

// clangd 探测顺序:
//   1) CLANGD_PATH 环境变量 (显式覆盖, 便于联调)
//   2) exe 同级常见布局 (llvm/bin, MinGW64/bin, mingw64/bin)
//   3) LLVM_HOME / MINGW_HOME
//   4) 常见安装路径 (msys2 各环境, Program Files\LLVM)
//   5) PATH 搜索
// 注: clangd 发现独立于 ToolchainConfig (后者负责 gcc/gdb/make 构建链探测,
// 本单元负责语言服务二进制发现; 两者候选路径有交集但职责不同, 故不耦合)
function TLspBootstrap.FindClangdExe: string;
var
  ExeDir: string;

  function TryPath(const P: string): Boolean;
  begin
    Result := (Trim(P) <> '') and FileExists(P);
    if Result then
      FClangdPath := P;
  end;

begin
  Result := '';
  FClangdPath := '';

  if TryPath(Trim(GetEnvironmentVariable('CLANGD_PATH'))) then
    Exit(FClangdPath);

  ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  if TryPath(ExeDir + 'llvm\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath(ExeDir + 'MinGW64\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath(ExeDir + 'mingw64\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath(ExeDir + 'clangd.exe') then Exit(FClangdPath);

  if TryPath(IncludeTrailingPathDelimiter(
    Trim(GetEnvironmentVariable('LLVM_HOME'))) + 'bin\clangd.exe') then
    Exit(FClangdPath);
  if TryPath(IncludeTrailingPathDelimiter(
    Trim(GetEnvironmentVariable('MINGW_HOME'))) + 'bin\clangd.exe') then
    Exit(FClangdPath);

  if TryPath('C:\msys64\ucrt64\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath('C:\msys64\mingw64\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath('C:\msys64\clang64\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath('C:\Program Files\LLVM\bin\clangd.exe') then Exit(FClangdPath);
  if TryPath('C:\Program Files (x86)\LLVM\bin\clangd.exe') then Exit(FClangdPath);

  if TryPath(FileSearch('clangd.exe', GetEnvironmentVariable('PATH'))) then
    Exit(FClangdPath);

  FClangdPath := '';
  Result := '';
end;

procedure TLspBootstrap.DoStartupThread;
var
  Path, Dir: string;
  T: TLspTransport;
  Ok: Boolean;
begin
  Path := '';
  try
    Path := FindClangdExe;
  except
    Path := '';
  end;
  if Path = '' then
  begin
    // 无 clangd: 静默待命, 允许日后手动重试
    FLock.Enter;
    try
      FStarting := False;
    finally
      FLock.Leave;
    end;
    Exit;
  end;

  Dir := Trim(FWorkDir);
  if Dir = '' then
    Dir := ExtractFilePath(ParamStr(0));

  T := nil;
  Ok := False;
  try
    T := CreateLspTransport(Path, Dir);
    Ok := T.Connect; // 阻塞: 管道 + initialize 握手
  except
    Ok := False;
  end;

  if not Ok then
  begin
    try
      T.Free;
    except
    end;
    FLock.Enter;
    try
      FStarting := False;
    finally
      FLock.Leave;
    end;
    Exit;
  end;

  FTransport := T; // 移交: 此后只读, FinishReady 在主线程继续
  TThread.Queue(nil,
    procedure
    begin
      FinishReady;
    end);
end;

procedure TLspBootstrap.FinishReady;
begin
  if not Assigned(FTransport) then
  begin
    FLock.Enter;
    try
      FStarting := False;
    finally
      FLock.Leave;
    end;
    Exit;
  end;
  try
    // 握手闭环: initialized 通知 (空 params 对象)
    FTransport.SendNotification('initialized', '{}');
    FTransport.MarkReady;
  except
    // 通知失败不致命, 继续挂接 (后续请求会自然失败并可重试)
  end;

  // 挂接消费者: 补全 / 签名 / 文档同步 (多播订阅, 互不覆盖)
  try
    EnsureLspCompletionCreated;
    LspCompletionManager.SetTransport(FTransport);
  except
  end;
  try
    EnsureLspSignatureHelpCreated;
    LspSignatureHelpManager.SetTransport(FTransport);
  except
  end;
  try
    EnsureLspHoverCreated;
    LspHoverManager.SetTransport(FTransport);
  except
  end;
  try
    EnsureLspDefinitionCreated;
    LspDefinitionManager.SetTransport(FTransport);
  except
  end;
  try
    LspDocSync.SetTransport(FTransport);
    LspDocSync.ResyncAll; // 把启动前已打开的文档补发 didOpen
  except
  end;

  FLock.Enter;
  try
    FReady := True;
    FStarting := False;
  finally
    FLock.Leave;
  end;
end;

procedure LspBootstrapStartup(const AWorkDir: string);
begin
  if not Assigned(LspBootstrap) then
    LspBootstrap := TLspBootstrap.Create;
  LspBootstrap.Startup(AWorkDir);
end;

initialization
  LspBootstrap := nil;

finalization
  if Assigned(LspBootstrap) then
    FreeAndNil(LspBootstrap);

end.
