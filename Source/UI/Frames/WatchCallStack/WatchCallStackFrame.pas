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

unit WatchCallStackFrame;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ComCtrls,
  Core.Events, Core.Services;

// Watch / Call Stack / Threads dockable frame.
// Owns its own UI and speaks to the debugger through the event bus / services,
// keeping MainForm free of direct debugger-window manipulation.

type
  TWatchCallStackFrame = class(TFrame)
  private
    FPageControl: TPageControl;
    FListViewWatch: TListView;
    FListViewCallStack: TListView;
    FListViewThreads: TListView;
    FOnVarChange: TNotifyEvent;
    FOnCallStackSelChanged: TNotifyEvent;
    FOnThreadSelChanged: TNotifyEvent;
    procedure InitializePages;
    procedure ListViewChange(Sender: TObject);
  public
    constructor CreateOwner(AOwner: TComponent); override;
    destructor Destroy; override;

    property ListViewWatch: TListView read FListViewWatch;
    property ListViewCallStack: TListView read FListViewCallStack;
    property ListViewThreads: TListView read FListViewThreads;

    property OnVarChange: TNotifyEvent read FOnVarChange write FOnVarChange;
    property OnCallStackSelChanged: TNotifyEvent read FOnCallStackSelChanged write FOnCallStackSelChanged;
    property OnThreadSelChanged: TNotifyEvent read FOnThreadSelChanged write FOnThreadSelChanged;
  end;

implementation

{ TWatchCallStackFrame }

constructor TWatchCallStackFrame.CreateOwner(AOwner: TComponent);
begin
  inherited CreateOwner(AOwner);
  InitializePages;
end;

destructor TWatchCallStackFrame.Destroy;
begin
  inherited;
end;

procedure TWatchCallStackFrame.InitializePages;
var
  TabWatch, TabCallStack, TabThreads: TTabSheet;
begin
  FPageControl := TPageControl.Create(Self);
  FPageControl.Parent := Self;
  FPageControl.Align := alClient;
  FPageControl.TabPosition := tpBottom;

  TabWatch := TTabSheet.Create(FPageControl);
  TabWatch.Caption := 'Watch';
  TabWatch.PageControl := FPageControl;

  FListViewWatch := TListView.Create(TabWatch);
  FListViewWatch.Parent := TabWatch;
  FListViewWatch.Align := alClient;
  FListViewWatch.ViewStyle := vsReport;
  FListViewWatch.Columns.Add.Caption := 'Variable';
  FListViewWatch.Columns.Add.Caption := 'Value';
  FListViewWatch.Columns.Add.Caption := 'Type';
  FListViewWatch.RowSelect := True;
  FListViewWatch.OnChange := ListViewChange;

  TabCallStack := TTabSheet.Create(FPageControl);
  TabCallStack.Caption := 'Call Stack';
  TabCallStack.PageControl := FPageControl;

  FListViewCallStack := TListView.Create(TabCallStack);
  FListViewCallStack.Parent := TabCallStack;
  FListViewCallStack.Align := alClient;
  FListViewCallStack.ViewStyle := vsReport;
  FListViewCallStack.Columns.Add.Caption := 'Frame';
  FListViewCallStack.Columns.Add.Caption := 'Function';
  FListViewCallStack.Columns.Add.Caption := 'Source';
  FListViewCallStack.RowSelect := True;
  FListViewCallStack.OnChange := ListViewChange;

  TabThreads := TTabSheet.Create(FPageControl);
  TabThreads.Caption := 'Threads';
  TabThreads.PageControl := FPageControl;

  FListViewThreads := TListView.Create(TabThreads);
  FListViewThreads.Parent := TabThreads;
  FListViewThreads.Align := alClient;
  FListViewThreads.ViewStyle := vsReport;
  FListViewThreads.Columns.Add.Caption := 'Thread ID';
  FListViewThreads.Columns.Add.Caption := 'State';
  FListViewThreads.Columns.Add.Caption := 'Function';
  FListViewThreads.RowSelect := True;
  FListViewThreads.OnChange := ListViewChange;
end;

procedure TWatchCallStackFrame.ListViewChange(Sender: TObject);
begin
  // Route selection changes to the appropriate event.
  if not Assigned(Sender) then
    Exit;
  if Sender = FListViewWatch then
  begin
    if Assigned(FOnVarChange) then
      FOnVarChange(Self);
  end
  else if Sender = FListViewCallStack then
  begin
    if Assigned(FOnCallStackSelChanged) then
      FOnCallStackSelChanged(Self);
  end
  else if Sender = FListViewThreads then
  begin
    if Assigned(FOnThreadSelChanged) then
      FOnThreadSelChanged(Self);
  end;
end;

end.