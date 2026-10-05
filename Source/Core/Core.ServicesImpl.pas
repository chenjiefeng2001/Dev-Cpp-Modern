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

unit Core.ServicesImpl;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes,
  {$ELSE}
  System.SysUtils, System.Classes,
  {$ENDIF}
  Core.Services, Compiler, Debugger, EditorList, Project, editor, Version;

// Concrete backends for the Core.Services interfaces.
// These adapters depend on the *subsystem* units (Compiler / Debugger /
// EditorList / Project), never on MainForm, so they can be unit-tested and
// swapped independently. Operations whose logic still lives in MainForm
// (e.g. project load/save) are injected as delegates by the host.

type
  TProjectLoadDelegate = reference to function(const AFileName: string): Boolean;
  TProjectSaveDelegate = reference to function: Boolean;
  TEditorLookupDelegate = reference to function(const AFileName: string): TObject;

  TProjectServiceImpl = class(TInterfacedObject, IProjectService)
  private
    FProject: TProject;
    FOnLoad: TProjectLoadDelegate;
    FOnSave: TProjectSaveDelegate;
  public
    constructor Create(AProject: TProject; AOnLoad: TProjectLoadDelegate;
      AOnSave: TProjectSaveDelegate);
    function LoadProject(const FileName: String): Boolean;
    function SaveProject: Boolean;
    function GetCurrentProject: String;
    function GetProjectModified: Boolean;
    function AddUnit(const FileName: String): Integer;
    function RemoveUnit(Index: Integer): Boolean;
  end;

  TCompilerServiceImpl = class(TInterfacedObject, ICompilerService)
  private
    FCompiler: TCompiler;
  public
    constructor Create(ACompiler: TCompiler);
    function Compile(const FileName: String): Boolean;
    function CheckSyntax(const FileName: String): Boolean;
    function Abort: Boolean;
    function GetCompiling: Boolean;
    function GetErrorCount: Integer;
    function GetWarningCount: Integer;
  end;

  TDebuggerServiceImpl = class(TInterfacedObject, IDebuggerService)
  private
    FDebugger: TDebugger;
  public
    constructor Create(ADebugger: TDebugger);
    procedure StartDebugging(const AExecutable, AParams, AWorkingDir: string);
    procedure StopDebugging;
    function IsDebugging: Boolean;
    procedure StepOver;
    procedure StepInto;
    procedure StepOut;
    procedure ContinueExecution;
    procedure ToggleBreakpoint(const AFileName: string; ALine: Integer);
    procedure AddWatch(const AExpression: string);
    procedure RemoveWatch(const AVarHandle: string);
    procedure ExpandVariable(const AVarHandle: string);
    procedure RefreshWatches;
  end;

  TEditorServiceImpl = class(TInterfacedObject, IEditorService)
  private
    FEditorList: TEditorList;
  public
    constructor Create(AEditorList: TEditorList);
    function OpenFile(const FileName: String; NewFile: Boolean = False): Integer;
    function CloseFile(Index: Integer): Boolean;
    function GetActiveEditor: String;
  end;

  TSettingsServiceImpl = class(TInterfacedObject, ISettingsService)
  private
    FSettings: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadSettings: Boolean;
    function SaveSettings: Boolean;
    function GetSetting(const Key: String): String;
    procedure SetSetting(const Key, Value: String);
    function GetAppVersion: String;
  end;

// Registers all service backends into the TServiceLocator singleton.
// Call once from the host (MainForm.FormCreate) after the concrete objects
// (compiler / debugger / editor list / project) have been created.
procedure RegisterCoreServices(ACompiler: TCompiler; ADebugger: TDebugger;
  AEditorList: TEditorList; AProject: TProject;
  AOnProjectLoad: TProjectLoadDelegate; AOnProjectSave: TProjectSaveDelegate);

implementation

{ TProjectServiceImpl }

constructor TProjectServiceImpl.Create(AProject: TProject;
  AOnLoad: TProjectLoadDelegate; AOnSave: TProjectSaveDelegate);
begin
  inherited Create;
  FProject := AProject;
  FOnLoad := AOnLoad;
  FOnSave := AOnSave;
end;

function TProjectServiceImpl.LoadProject(const FileName: String): Boolean;
begin
  if Assigned(FOnLoad) then
    Result := FOnLoad(FileName)
  else
    Result := False;
end;

function TProjectServiceImpl.SaveProject: Boolean;
begin
  if Assigned(FOnSave) then
    Result := FOnSave()
  else
    Result := False;
end;

function TProjectServiceImpl.GetCurrentProject: String;
begin
  if Assigned(FProject) then
    Result := FProject.FileName
  else
    Result := '';
end;

function TProjectServiceImpl.GetProjectModified: Boolean;
begin
  if Assigned(FProject) then
    Result := FProject.Modified
  else
    Result := False;
end;

function TProjectServiceImpl.AddUnit(const FileName: String): Integer;
begin
  // Adding a unit historically requires a tree node; delegated to the host later.
  Result := -1;
end;

function TProjectServiceImpl.RemoveUnit(Index: Integer): Boolean;
begin
  Result := False;
  if Assigned(FProject) and (Index >= 0) and (Index < FProject.Units.Count) then
  begin
    FProject.Units.Remove(Index);
    Result := True;
  end;
end;

{ TCompilerServiceImpl }

constructor TCompilerServiceImpl.Create(ACompiler: TCompiler);
begin
  inherited Create;
  FCompiler := ACompiler;
end;

function TCompilerServiceImpl.Compile(const FileName: String): Boolean;
begin
  Result := False;
  if not Assigned(FCompiler) then
    Exit;
  if Trim(FileName) <> '' then
    FCompiler.SourceFile := FileName;
  FCompiler.Target := ctFile;
  FCompiler.Compile;
  Result := True;
end;

function TCompilerServiceImpl.CheckSyntax(const FileName: String): Boolean;
begin
  Result := False;
  if not Assigned(FCompiler) then
    Exit;
  if Trim(FileName) <> '' then
    FCompiler.SourceFile := FileName;
  FCompiler.CheckSyntax;
  Result := True;
end;

function TCompilerServiceImpl.Abort: Boolean;
begin
  Result := Assigned(FCompiler);
  if Result then
    FCompiler.AbortThread;
end;

function TCompilerServiceImpl.GetCompiling: Boolean;
begin
  Result := Assigned(FCompiler) and FCompiler.Compiling;
end;

function TCompilerServiceImpl.GetErrorCount: Integer;
begin
  if Assigned(FCompiler) then
    Result := FCompiler.ErrorCount
  else
    Result := 0;
end;

function TCompilerServiceImpl.GetWarningCount: Integer;
begin
  if Assigned(FCompiler) then
    Result := FCompiler.WarningCount
  else
    Result := 0;
end;

{ TDebuggerServiceImpl }

constructor TDebuggerServiceImpl.Create(ADebugger: TDebugger);
begin
  inherited Create;
  FDebugger := ADebugger;
end;

procedure TDebuggerServiceImpl.StartDebugging(const AExecutable, AParams, AWorkingDir: string);
begin
  // TODO: honor AExecutable/AParams/AWorkingDir once startup is refactored
  // out of the annotation-based TDebugger.Start (currently reads project state).
  if Assigned(FDebugger) then
    FDebugger.Start;
end;

procedure TDebuggerServiceImpl.StopDebugging;
begin
  if Assigned(FDebugger) then
    FDebugger.Stop;
end;

function TDebuggerServiceImpl.IsDebugging: Boolean;
begin
  Result := Assigned(FDebugger) and FDebugger.Executing;
end;

procedure TDebuggerServiceImpl.StepOver;
begin
  if Assigned(FDebugger) then
    FDebugger.SendCommand('next', '', True);
end;

procedure TDebuggerServiceImpl.StepInto;
begin
  if Assigned(FDebugger) then
    FDebugger.SendCommand('step', '', True);
end;

procedure TDebuggerServiceImpl.StepOut;
begin
  if Assigned(FDebugger) then
    FDebugger.SendCommand('finish', '', True);
end;

procedure TDebuggerServiceImpl.ContinueExecution;
begin
  if Assigned(FDebugger) then
    FDebugger.SendCommand('continue', '', True);
end;

procedure TDebuggerServiceImpl.ToggleBreakpoint(const AFileName: string; ALine: Integer);
begin
  // Breakpoint toggling requires the editor instance (breakpoints are keyed by
  // editor + line). Wired through TEditor.ToggleBreakpoint by the host for now.
end;

procedure TDebuggerServiceImpl.AddWatch(const AExpression: string);
begin
  if Assigned(FDebugger) then
    FDebugger.AddWatchVar(AExpression);
end;

procedure TDebuggerServiceImpl.RemoveWatch(const AVarHandle: string);
begin
  // Requires the watch tree node; wired by the host for now.
end;

procedure TDebuggerServiceImpl.ExpandVariable(const AVarHandle: string);
begin
  // GDB MI variable-object expansion (-var-list-children) pending.
end;

procedure TDebuggerServiceImpl.RefreshWatches;
begin
  if Assigned(FDebugger) then
    FDebugger.RefreshWatchVars;
end;

{ TEditorServiceImpl }

constructor TEditorServiceImpl.Create(AEditorList: TEditorList);
begin
  inherited Create;
  FEditorList := AEditorList;
end;

function TEditorServiceImpl.OpenFile(const FileName: String; NewFile: Boolean): Integer;
var
  E: TEditor;
begin
  Result := 0;
  if not Assigned(FEditorList) then
    Exit;
  E := FEditorList.NewEditor(FileName, False, NewFile);
  if Assigned(E) then
    Result := 1;
end;

function TEditorServiceImpl.CloseFile(Index: Integer): Boolean;
begin
  Result := False;
  if Assigned(FEditorList) and (Index >= 0) and (Index < FEditorList.PageCount) then
    Result := FEditorList.CloseEditor(FEditorList[Index]);
end;

function TEditorServiceImpl.GetActiveEditor: String;
var
  E: TEditor;
begin
  Result := '';
  if Assigned(FEditorList) then
  begin
    E := FEditorList.GetEditor;
    if Assigned(E) then
      Result := E.FileName;
  end;
end;

{ TSettingsServiceImpl }

constructor TSettingsServiceImpl.Create;
begin
  inherited Create;
  FSettings := TStringList.Create;
  FSettings.Sorted := True;
  FSettings.Duplicates := dupIgnore;
end;

destructor TSettingsServiceImpl.Destroy;
begin
  FSettings.Free;
  inherited;
end;

function TSettingsServiceImpl.LoadSettings: Boolean;
begin
  // Persistence via devCFG JSON profile migration is pending; in-memory store.
  Result := True;
end;

function TSettingsServiceImpl.SaveSettings: Boolean;
begin
  // In-memory until the JSON toolchain/config profile lands.
  Result := True;
end;

function TSettingsServiceImpl.GetSetting(const Key: String): String;
begin
  Result := FSettings.Values[Key];
end;

procedure TSettingsServiceImpl.SetSetting(const Key, Value: String);
begin
  FSettings.Values[Key] := Value;
end;

function TSettingsServiceImpl.GetAppVersion: String;
begin
  Result := DEVCPP_VERSION;
end;

{ RegisterCoreServices }

procedure RegisterCoreServices(ACompiler: TCompiler; ADebugger: TDebugger;
  AEditorList: TEditorList; AProject: TProject;
  AOnProjectLoad: TProjectLoadDelegate; AOnProjectSave: TProjectSaveDelegate);
begin
  if not Assigned(TServiceLocator.Instance) then
    Exit;

  TServiceLocator.Instance.CompilerService := TCompilerServiceImpl.Create(ACompiler);
  TServiceLocator.Instance.DebuggerService := TDebuggerServiceImpl.Create(ADebugger);
  TServiceLocator.Instance.EditorService := TEditorServiceImpl.Create(AEditorList);
  TServiceLocator.Instance.ProjectService :=
    TProjectServiceImpl.Create(AProject, AOnProjectLoad, AOnProjectSave);
  TServiceLocator.Instance.SettingsService := TSettingsServiceImpl.Create;
end;

end.