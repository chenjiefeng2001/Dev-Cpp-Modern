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
    // The LCL types TListView.OnChange as
    //   TLVChangeEvent = procedure(Sender: TObject; Item: TListItem;
    //                              Change: TItemChange) of object
    // (lcl/comctrls.pp), not the Delphi TNotifyEvent (Sender only), so this
    // handler takes the item and the change kind as well. Neither is used
    // here -- the routing below is driven entirely by Sender.
    procedure ListViewChange(Sender: TObject; Item: TListItem;
      Change: TItemChange);
  public
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

// The former `constructor CreateOwner(AOwner: TComponent); override;` was
// removed rather than remapped -- see ProjectTreeFrame.pas for the
// measurement: no ancestor declares CreateOwner (neither the LCL's TFrame nor
// the vendored VCL), and there is no call site anywhere in the project. The
// InitializePages call below was already unreachable on every build.

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

procedure TWatchCallStackFrame.ListViewChange(Sender: TObject; Item: TListItem;
  Change: TItemChange);
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