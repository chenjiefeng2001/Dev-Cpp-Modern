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

unit ProjectTreeFrame;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ComCtrls,
  Core.Events, Core.Services;

// Project explorer frame - decoupled view of the project file tree.

type
  TProjectNodeSelectEvent = procedure(Sender: TObject; Node: TTreeNode) of object;

  TProjectNodeData = record
    Name: string;
    Path: string;
    IsFolder: Boolean;
    Children: Integer;
  end;

  TProjectTreeFrame = class(TFrame)
  private
    FTreeView: TTreeView;
    FOnNodeSelect: TProjectNodeSelectEvent;
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
  public
    constructor CreateOwner(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure LoadProjectStructure(const AProjectPath: string);
    procedure ClearProjectStructure;
    procedure SubscribeProjectEvents;
    procedure UnsubscribeProjectEvents;

    property TreeView: TTreeView read FTreeView;
    property OnNodeSelect: TProjectNodeSelectEvent read FOnNodeSelect write FOnNodeSelect;
  end;

implementation

{ TProjectTreeFrame }

constructor TProjectTreeFrame.CreateOwner(AOwner: TComponent);
begin
  inherited CreateOwner(AOwner);

  FTreeView := TTreeView.Create(Self);
  FTreeView.Parent := Self;
  FTreeView.Align := alClient;
  FTreeView.RowSelect := True;
  FTreeView.OnChange := TreeChange;

  SubscribeProjectEvents;
end;

destructor TProjectTreeFrame.Destroy;
begin
  UnsubscribeProjectEvents;
  inherited;
end;

procedure TProjectTreeFrame.TreeChange(Sender: TObject; Node: TTreeNode);
begin
  if Assigned(FOnNodeSelect) then
    FOnNodeSelect(Self, Node);
end;

procedure TProjectTreeFrame.LoadProjectStructure(const AProjectPath: string);
var
  RootNode: TTreeNode;

  procedure AddNodes(ParentNode: TTreeNode; const Path: string);
  var
    SearchRec: TSearchRec;
    FindResult: Integer;
    Node: TTreeNode;
    SearchPath: string;
  begin
    SearchPath := IncludeTrailingPathDelimiter(Path) + '*.*';
    FindResult := FindFirst(SearchPath, faAnyFile, SearchRec);
    try
      while FindResult = 0 do
      begin
        if (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then
        begin
          Node := FTreeView.Items.AddChild(ParentNode,
            IncludeTrailingPathDelimiter(Path) + SearchRec.Name);
          if (SearchRec.Attr and faDirectory) <> 0 then
          begin
            Node.ImageIndex := 0;
            Node.Data := Pointer(1); // folder marker
            AddNodes(Node, IncludeTrailingPathDelimiter(Path) + SearchRec.Name);
          end
          else
            Node.Data := Pointer(0); // file marker
        end;
        FindResult := FindNext(SearchRec);
      end;
    finally
      FindClose(SearchRec);
    end;
  end;

begin
  FTreeView.Items.BeginUpdate;
  try
    FTreeView.Items.Clear;
    RootNode := FTreeView.Items.Add(nil, ExtractFileName(ExcludeTrailingPathDelimiter(AProjectPath)));
    RootNode.Data := Pointer(1);
    if DirectoryExists(AProjectPath) then
      AddNodes(RootNode, AProjectPath);
    RootNode.Expand(False);
  finally
    FTreeView.Items.EndUpdate;
  end;
end;

procedure TProjectTreeFrame.ClearProjectStructure;
begin
  FTreeView.Items.Clear;
end;

procedure TProjectTreeFrame.SubscribeProjectEvents;
begin
  TEventManager.Instance.OnProjectChanged :=
    procedure(const Event: TEvent)
    begin
      if Assigned(FOnNodeSelect) then
        FOnNodeSelect(Self, FTreeView.Selected);
    end;
end;

procedure TProjectTreeFrame.UnsubscribeProjectEvents;
begin
  if Assigned(TEventManager.Instance) then
    TEventManager.Instance.OnProjectChanged := nil;
end;

end.