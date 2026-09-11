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

unit Debugger.VariableManager;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  GDB.MiParser, GDB.MiTypes, Debugger.Scheduler;

// GDB Variable Objects manager (-var-create / -var-update / -var-delete).
// Tracks watch expressions by token and dispatches updates to a change event.

type
  TVariableNode = record
    Name: string;
    TypeName: string;
    Value: string;
    NumChildren: Integer;
    Address: string;
    HasChildren: Boolean;
    IsConstant: Boolean;
    ParentToken: string;
    ChildTokens: TArray<string>;
  end;

  TVariableChangeType = (vctAdded, vctRemoved, vctUpdated, vctCleared);

  TVariableChangeEvent = procedure(Sender: TObject; const AName: string;
    AChangeType: TVariableChangeType; const ANewValue: string) of object;

  TGdbVariableManager = class
  private
    FScheduler: TDebuggerScheduler;
    FOnVariableChange: TVariableChangeEvent;
    FVariableTable: TDictionary<string, TVariableNode>;
    FVarPrefixCounter: Integer;
    procedure HandleVariableResponse(const ARecord: TMiRecord);
    procedure ParseVariableRecord(const ARecord: TMiRecord; out ANode: TVariableNode);
    procedure UpdateVariableTable(const AToken: string; const ANode: TVariableNode;
      AChangeType: TVariableChangeType);
  public
    constructor Create(AScheduler: TDebuggerScheduler);
    destructor Destroy; override;

    function CreateVariable(const AExpr: string; out AToken: string): Boolean;
    procedure UpdateAllVariables;
    function ListVariableChildren(const AParentToken: string): TArray<string>;
    procedure DeleteVariable(const AToken: string);
    procedure ClearAll;

    property OnVariableChange: TVariableChangeEvent read FOnVariableChange write FOnVariableChange;
  end;

var
  GdbVariableManager: TGdbVariableManager;

procedure InitializeGdbVariableManager(AScheduler: TDebuggerScheduler);

implementation

{ TGdbVariableManager }

constructor TGdbVariableManager.Create(AScheduler: TDebuggerScheduler);
begin
  inherited Create;
  FScheduler := AScheduler;
  FVariableTable := TDictionary<string, TVariableNode>.Create;
  FVarPrefixCounter := 0;
end;

destructor TGdbVariableManager.Destroy;
begin
  ClearAll;
  FVariableTable.Free;
  inherited;
end;

function TGdbVariableManager.CreateVariable(const AExpr: string; out AToken: string): Boolean;
var
  TokenPrefix: string;
  Cmd: string;
  CapturedToken: string;
begin
  Result := False;
  AToken := '';
  CapturedToken := '';

  Inc(FVarPrefixCounter);
  TokenPrefix := 'var' + IntToStr(FVarPrefixCounter);
  Cmd := Format('-var-create %s', [AExpr]);

  // Send through the scheduler; the response resolves the real GDB handle.
  FScheduler.SendCommand(Cmd,
    procedure(const ARecord: TMiRecord)
    begin
      CapturedToken := TokenPrefix;
      HandleVariableResponse(ARecord);
    end);

  // Simplified: adopt the generated token until the response refines it.
  if CapturedToken <> '' then
  begin
    AToken := CapturedToken;
    Result := True;
  end
  else
    AToken := TokenPrefix;
end;

procedure TGdbVariableManager.UpdateAllVariables;
begin
  FScheduler.SendCommand('-var-update *',
    procedure(const ARecord: TMiRecord)
    begin
      HandleVariableResponse(ARecord);
    end);
end;

function TGdbVariableManager.ListVariableChildren(const AParentToken: string): TArray<string>;
var
  Cmd: string;
begin
  SetLength(Result, 0);
  Cmd := Format('-var-list-children %s', [AParentToken]);
  FScheduler.SendCommand(Cmd,
    procedure(const ARecord: TMiRecord)
    begin
      HandleVariableResponse(ARecord);
    end);
  // TODO: populates Result from parsed child tokens once MI parsing lands.
end;

procedure TGdbVariableManager.DeleteVariable(const AToken: string);
var
  Cmd: string;
begin
  Cmd := Format('-var-delete %s', [AToken]);
  FScheduler.SendCommand(Cmd,
    procedure(const ARecord: TMiRecord)
    begin
      FVariableTable.Remove(AToken);
    end);
end;

procedure TGdbVariableManager.ClearAll;
var
  Token: string;
begin
  for Token in FVariableTable.Keys do
    DeleteVariable(Token);
  FVariableTable.Clear;
  FVarPrefixCounter := 0;
end;

procedure TGdbVariableManager.HandleVariableResponse(const ARecord: TMiRecord);
var
  Node: TVariableNode;
begin
  ParseVariableRecord(ARecord, Node);
  if Node.Name <> '' then
    UpdateVariableTable(ARecord.Variable.Name, Node, vctUpdated);
end;

procedure TGdbVariableManager.ParseVariableRecord(const ARecord: TMiRecord;
  out ANode: TVariableNode);
begin
  FillChar(ANode, SizeOf(ANode), 0);
  ANode.Name := ARecord.Variable.Name;
  ANode.TypeName := ARecord.Variable.TypeName;
  ANode.Value := ARecord.Variable.Value;
  ANode.NumChildren := ARecord.Variable.NumberOfChildren;
  ANode.HasChildren := ANode.NumChildren > 0;
  ANode.IsConstant := ARecord.Variable.IsConstant;
end;

procedure TGdbVariableManager.UpdateVariableTable(const AToken: string;
  const ANode: TVariableNode; AChangeType: TVariableChangeType);
begin
  case AChangeType of
    vctAdded:
      if not FVariableTable.ContainsKey(AToken) then
        FVariableTable.Add(AToken, ANode);
    vctUpdated:
      begin
        FVariableTable.AddOrSetValue(AToken, ANode);
      end;
    vctRemoved:
      FVariableTable.Remove(AToken);
    vctCleared:
      FVariableTable.Clear;
  end;

  if Assigned(FOnVariableChange) then
    FOnVariableChange(Self, ANode.Name, AChangeType, ANode.Value);
end;

procedure InitializeGdbVariableManager(AScheduler: TDebuggerScheduler);
begin
  if not Assigned(GdbVariableManager) then
    GdbVariableManager := TGdbVariableManager.Create(AScheduler);
end;

initialization
  GdbVariableManager := nil;

finalization
  if Assigned(GdbVariableManager) then
    FreeAndNil(GdbVariableManager);

end.