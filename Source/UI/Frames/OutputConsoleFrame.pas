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

unit OutputConsoleFrame;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ComCtrls,
  Core.Events, Core.Services;

// Compiler output frame - decoupled view of build messages.

type
  TCompilerMessageEvent = procedure(const Line: string; const ErrorLevel: Integer) of object;

  TOutputConsoleFrame = class(TFrame)
  private
    FCompilerOutput: TListView;
    FOnCompilerMessage: TCompilerMessageEvent;
  public
    constructor CreateOwner(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AddCompilerMessage(const Line: string; const ErrorLevel: Integer);
    procedure ClearCompilerOutput;
    procedure SetCompilerOutput(const Lines: TStrings);
    procedure SubscribeCompilerEvents;
    procedure UnsubscribeCompilerEvents;

    property CompilerOutput: TListView read FCompilerOutput;
    property OnCompilerMessage: TCompilerMessageEvent read FOnCompilerMessage write FOnCompilerMessage;
  end;

implementation

{ TOutputConsoleFrame }

constructor TOutputConsoleFrame.CreateOwner(AOwner: TComponent);
begin
  inherited CreateOwner(AOwner);

  FCompilerOutput := TListView.Create(Self);
  FCompilerOutput.Parent := Self;
  FCompilerOutput.Align := alClient;
  FCompilerOutput.ViewStyle := vsReport;
  FCompilerOutput.RowSelect := True;
  FCompilerOutput.Columns.Add.Caption := 'Line';
  FCompilerOutput.Columns.Add.Caption := 'Message';
  FCompilerOutput.Columns.Add.Caption := 'Type';

  SubscribeCompilerEvents;
end;

destructor TOutputConsoleFrame.Destroy;
begin
  UnsubscribeCompilerEvents;
  inherited;
end;

procedure TOutputConsoleFrame.AddCompilerMessage(const Line: string; const ErrorLevel: Integer);
const
  ErrorIcon = '>>>';
  InfoIcon = '-->';
var
  Item: TListItem;
begin
  if not Assigned(FCompilerOutput) then
    Exit;

  Item := FCompilerOutput.Items.Add;
  Item.Caption := IntToStr(FCompilerOutput.Items.Count + 1);
  case ErrorLevel of
    0: Item.SubItems.Add(InfoIcon + ' ' + Line);
    1: Item.SubItems.Add(ErrorIcon + ' ' + Line);
  else
    Item.SubItems.Add(Line);
  end;
  Item.SubItems.Add(IntToStr(ErrorLevel));
  Item.MakeVisible(False);
end;

procedure TOutputConsoleFrame.ClearCompilerOutput;
begin
  if Assigned(FCompilerOutput) then
    FCompilerOutput.Items.Clear;
end;

procedure TOutputConsoleFrame.SetCompilerOutput(const Lines: TStrings);
var
  I: Integer;
begin
  ClearCompilerOutput;
  if Assigned(FCompilerOutput) and Assigned(Lines) then
    for I := 0 to Lines.Count - 1 do
      AddCompilerMessage(Lines[I], 0);
end;

procedure TOutputConsoleFrame.SubscribeCompilerEvents;
begin
  TEventManager.Instance.OnCompilerProgress :=
    procedure(const ProgressEvent: TCompileProgressEvent)
    begin
      AddCompilerMessage(ProgressEvent.Message, ProgressEvent.Progress);
    end;
end;

procedure TOutputConsoleFrame.UnsubscribeCompilerEvents;
begin
  if Assigned(TEventManager.Instance) then
    TEventManager.Instance.OnCompilerProgress := nil;
end;

end.