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

unit Tests;

interface

uses
  Windows, Classes, Sysutils, Dateutils, Forms, ShellAPI, Dialogs, NewProjectFrm, Project,
  Menus, Registry, Controls, ComCtrls, Math, ActnList, CompOptionsFrm, SynEditKeyCmds, SynEditTypes;

type
  TTestClass = class
  private
    procedure ShowUpdate(Delay: Integer);
  public
    constructor Create;
    function TestEditor: Boolean;
    function TestEditorList: Boolean;
    function TestActions: Boolean;
    function TestCompilerOptions: Boolean;
    function TestAll: Boolean;
  end;

implementation

uses
  MainUi, Editor, Version;

// Migration note: the five `GetEditor` call sites needed five distinct rewrites
// (i/PageControl, no-args, -1/PageControl, -1/inline-PageControl, and the one
// nested inside SwapEditor). An earlier pass covered only four and left the
// -1/inline form holding a live `MainForm.*` reference. The hit-count asserts
// could not catch it -- no pattern had been written for that shape at all --
// so it was tools/main_symbols.py (the leak detector) that reported it.

procedure TTestClass.ShowUpdate(Delay: Integer);
begin
  Application.ProcessMessages;
  Sleep(Delay);
end;

function TTestClass.TestEditorList: Boolean;
var
  EditorCount, CloseEditorCount: integer;
  e: TEditor;

  procedure OpenEditors(Count: Integer; PageControl: TPageControl);
  var
    I, StartCount: integer;
  begin
    if Assigned(PageControl) then
      StartCount := PageControl.PageCount
    else
      StartCount := 0;
    for I := 1 to Count do begin
      MainUi.CreateEditorInPage('', False, True, PageControl);
      if Assigned(PageControl) then
        // make sure property PageCount is correct
        Assert(PageControl.PageCount = StartCount + I);
      ShowUpdate(0);
    end;
  end;
  procedure CloseEditors(PageControl: TPageControl);
  var
    I: integer;
    e: TEditor;
  begin
    for I := PageControl.PageCount - 1 downto 0 do begin
      e := TEditor(MainUi.EditorByIndex(i, PageControl));
      // if this fails the deleted editor will be acivated after
      // closing
      Assert(e <> TEditor(MainUi.PreviousEditor(e)));
      MainUi.TryCloseEditor(e);
      // make sure property PageCount is correct
      Assert(PageControl.PageCount = I);
      ShowUpdate(0);
    end;
  end;
  procedure CloseAllEditors;
  begin
    CloseEditors(TPageControl(MainUi.LeftPageControl));
    CloseEditors(TPageControl(MainUi.RightPageControl));
  end;
  procedure SwapEditors(PageControl: TPageControl);
  begin
    while PageControl.PageCount > 0 do begin
      MainUi.SwapEditor(TEditor(MainUi.EditorByIndex(-1, PageControl)));
      ShowUpdate(0);
    end;
  end;
  procedure ActivateEditors(PageControl: TPageControl);
  var
    I: integer;
    e: TEditor;
  begin
    for I := 0 to PageControl.PageCount - 1 do begin
      e := TEditor(MainUi.EditorByIndex(i, PageControl));
      e.Activate;
      // Make sure property FocusedPageControl is correct
      Assert(TPageControl(MainUi.FocusedPageControl) = e.PageControl);
      ShowUpdate(0);
    end;
  end;
  procedure ZapEditors(GoForward: Boolean);
  var
    I: integer;
    FocusedPageControl: TPageControl;
  begin
    FocusedPageControl := TPageControl(MainUi.FocusedPageControl);
    for I := 0 to TPageControl(MainUi.FocusedPageControl).PageCount - 1 do begin
      if GoForward then
        MainUi.SelectNextEditorPage
      else
        MainUi.SelectPrevEditorPage;
      // Make sure PageControl focus does not change
      Assert(FocusedPageControl = TPageControl(MainUi.FocusedPageControl));
      ShowUpdate(0);
    end;
  end;
  procedure CloseEditorsRandom;
  var
    I: Integer;
    e: TEditor;
  begin
    while MainUi.EditorPageCount > 0 do begin
      I := RandomRange(0, MainUi.EditorPageCount - 1);
      e := TEditor(MainUi.EditorAt(I));
      if RandomRange(1, 5) = 1 then // test closing active editors too in 1/5 on cases
        e.Activate;
      // if this fails the deleted editor will be acivated after closing
      Assert(e <> TEditor(MainUi.PreviousEditor(e)));
      MainUi.TryCloseEditor(e);
      ShowUpdate(0);
    end;
  end;
begin
  EditorCount := 10;
  CloseEditorCount := 50;
  try
    MainUi.SetStatusbarMessage('Open editors in the default page control (left)');
    OpenEditors(EditorCount, nil);
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.LeftPageControl));

    MainUi.SetStatusbarMessage('Open explicitly in the left page control');
    OpenEditors(EditorCount, TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorPageCount = 2 * EditorCount);
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.LeftPageControl));

    MainUi.SetStatusbarMessage('Open explicitly in the right page control');
    OpenEditors(EditorCount, TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorPageCount = 3 * EditorCount);
    Assert(MainUi.EditorLayoutIsBoth);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.RightPageControl));

    MainUi.SetStatusbarMessage('Close left editors');
    CloseEditors(TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    Assert(MainUi.EditorLayoutIsRight);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.RightPageControl));

    MainUi.SetStatusbarMessage('Close right editors');
    CloseEditors(TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorPageCount = 0);
    Assert(MainUi.EditorLayoutIsNone);
    Assert(TPageControl(MainUi.FocusedPageControl) = nil);

    MainUi.SetStatusbarMessage('Open lots of editors');
    OpenEditors(5 * EditorCount, nil);
    Assert(MainUi.EditorPageCount = 5 * EditorCount);
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.LeftPageControl));

    MainUi.SetStatusbarMessage('Close all');
    CloseEditors(TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorPageCount = 0);
    Assert(MainUi.EditorLayoutIsNone);
    Assert(TPageControl(MainUi.FocusedPageControl) = nil);

    MainUi.SetStatusbarMessage('Editor activating');
    OpenEditors(EditorCount, TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(TPageControl(MainUi.FocusedPageControl) = TPageControl(MainUi.LeftPageControl));
    ActivateEditors(TPageControl(MainUi.LeftPageControl));
    CloseAllEditors;
    Assert(MainUi.EditorPageCount = 0);
    Assert(MainUi.EditorLayoutIsNone);
    Assert(TPageControl(MainUi.FocusedPageControl) = nil);

    MainUi.SetStatusbarMessage('Editor swapping');
    OpenEditors(EditorCount, TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    SwapEditors(TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorLayoutIsRight);
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    SwapEditors(TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(MainUi.EditorPageCount = 1 * EditorCount);
    CloseEditors(TPageControl(MainUi.LeftPageControl));
    CloseEditors(TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorLayoutIsNone);
    Assert(MainUi.EditorPageCount = 0);

    MainUi.SetStatusbarMessage('Editor zapping');
    OpenEditors(EditorCount, TPageControl(MainUi.LeftPageControl));
    OpenEditors(EditorCount, TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorLayoutIsBoth);
    ZapEditors(True); // zap right page control
    ZapEditors(False); // idem
    e := TEditor(MainUi.EditorByIndex(-1, TPageControl(MainUi.LeftPageControl)));
    e.Activate; // should work
    ZapEditors(True); // zap left page control
    ZapEditors(False); // idem
    CloseAllEditors;

    MainUi.SetStatusbarMessage('Close random editors in the left page control');
    OpenEditors(CloseEditorCount, TPageControl(MainUi.LeftPageControl));
    Assert(MainUi.EditorLayoutIsLeft);
    Assert(MainUi.EditorPageCount = CloseEditorCount);
    CloseEditorsRandom;
    Assert(MainUi.EditorLayoutIsNone);
    Assert(MainUi.EditorPageCount = 0);

    MainUi.SetStatusbarMessage('Close random editors in the right page control');
    OpenEditors(CloseEditorCount, TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorLayoutIsRight);
    Assert(MainUi.EditorPageCount = CloseEditorCount);
    CloseEditorsRandom;
    Assert(MainUi.EditorLayoutIsNone);
    Assert(MainUi.EditorPageCount = 0);

    MainUi.SetStatusbarMessage('Close random editors in both page controls');
    OpenEditors(CloseEditorCount, TPageControl(MainUi.LeftPageControl));
    OpenEditors(CloseEditorCount, TPageControl(MainUi.RightPageControl));
    Assert(MainUi.EditorLayoutIsBoth);
    Assert(MainUi.EditorPageCount = 2 * CloseEditorCount);
    CloseEditorsRandom;
    Assert(MainUi.EditorLayoutIsNone);
    Assert(MainUi.EditorPageCount = 0);

    Result := True;
  except
    Result := False;
    //raise Exception.Create('TTestClass.TestEditorList');
  end;
end;

function TTestClass.TestActions: Boolean;
var
  I: integer;
  Action: TCustomAction;
begin
  try
    // Super annoying
    for I := 0 to MainUi.ActionCount - 1 do begin
      Action := TCustomAction(MainUi.ActionAt(i));
      if Action.Enabled and (Action.Name <> 'actRunTests') and (Action.Name <> 'actExit') then
        Action.Execute;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function TTestClass.TestCompilerOptions;
var
  I, SetCount: integer;
begin
  SetCount := 1;
  try
    MainUi.SetStatusbarMessage('Open compiler options');
    with TCompOptForm.Create(nil) do try // copy from actCompOptions
      Show;

      MainUi.SetStatusbarMessage('Delete all compiler sets');
      while cmbCompilerSetComp.Items.Count > 0 do
        btnDelCompilerSet.Click;

      MainUi.SetStatusbarMessage('Add automagically');
      btnFindCompilers.Click;

      MainUi.SetStatusbarMessage('Rename all compiler sets');
      for I := 0 to cmbCompilerSetComp.Items.Count - 1 do begin
        cmbCompilerSetComp.ItemIndex := I;
        btnRenameCompilerSet.Click;
      end;

      MainUi.SetStatusbarMessage('Add blank compiler set');
      for I := 1 to SetCount do
        btnAddBlankCompilerSet.Click;

      MainUi.SetStatusbarMessage('Add filled compiler set');
      for I := 1 to SetCount do
        btnAddFilledCompilerSet.Click;

      MainUi.SetStatusbarMessage('Set current compiler set');
      cmbCompilerSetComp.ItemIndex := 0;

      MainUi.SetStatusbarMessage('Save compiler options');
      btnOk.Click;
      //  MainForm.CheckForDLLProfiling; TODO: private
      MainUi.UpdateCompilerList;
    finally;
      Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function TTestClass.TestEditor: Boolean;
var
  I, FoldCount, LineCount, LineLength, CommentCount, DupeCount, IndentCount: Integer;
  e: TEditor;

  procedure TypeText(const Text: String);
  var
    I: Integer;
  begin
    for I := 1 to Length(Text) do
      e.Text.CommandProcessor(ecChar, Text[i], nil);
    ShowUpdate(0);
  end;
begin
  FoldCount := 20;
  LineCount := 20;
  LineLength := 10;
  CommentCount := 20;
  DupeCount := 20;
  IndentCount := 3;
  try
    MainUi.SetStatusbarMessage('Create new file');
    MainUi.ExecuteNewSource;
    e := TEditor(MainUi.EditorByIndex(-1, nil));
    //  e := MainUi.CreateEditorInPage('main.cpp', False, True, nil);
    e.Activate;

    MainUi.SetStatusbarMessage('Add foldable code');
    for I := 1 to FoldCount do begin
      TypeText('{'); // + #13#10;
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
    end;
    for I := 1 to FoldCount do begin
      TypeText('}'); // + #13#10;
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
    end;
    Assert(e.Text.Lines.Count = 2 * FoldCount + 1);

    MainUi.SetStatusbarMessage('Move folds down');
    e.Text.CaretXY := BufferCoord(1, 1);
    for I := 1 to LineCount do begin
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
      ShowUpdate(0);
    end;
    Assert(e.Text.Lines.Count = 2 * FoldCount + 1 + LineCount);

    MainUi.SetStatusbarMessage('Move folds up');
    e.Text.CaretXY := BufferCoord(1, 1);
    for I := 1 to LineCount do begin
      e.Text.CommandProcessor(ecDeleteLine, #0, nil);
      ShowUpdate(0);
    end;
    Assert(e.Text.Lines.Count = 2 * FoldCount + 1);

    MainUi.SetStatusbarMessage('Test fold collapsing and uncollapsing');
    e.Text.CollapseAll;
    ShowUpdate(50);
    e.Text.UncollapseAll;
    ShowUpdate(50);

    MainUi.SetStatusbarMessage('Undo all previous actions to end up with empty editor');
    while e.Text.UndoList.CanUndo do begin
      e.Text.Undo;
      ShowUpdate(0);
    end;
    Assert(e.Text.Text.IsEmpty);

    MainUi.SetStatusbarMessage('Type wall of text');
    for I := Ord('a') to Ord('z') do begin
      TypeText(StringOfChar(Chr(I), LineLength));
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Move lines down');
    for I := 0 to e.Text.Lines.Count - 1 do begin
      e.Text.CaretXY := BufferCoord(1, 1);
      for var J := 0 to e.Text.Lines.Count - 3 - I do
        e.Text.CommandProcessor(TSynEditEx.ecMoveSelDown, #0, nil);
      ShowUpdate(0);
    end;

    MainUi.SetStatusbarMessage('Move lines up');
    for I := 0 to e.Text.Lines.Count - 1 do begin
      e.Text.CaretXY := BufferCoord(1, e.Text.Lines.Count);
      for var J := 0 to e.Text.Lines.Count - 1 - I do
        e.Text.CommandProcessor(TSynEditEx.ecMoveSelUp, #0, nil);
      ShowUpdate(0);
    end;

    MainUi.SetStatusbarMessage('Comment');
    e.Text.SelectAll;
    for I := 1 to CommentCount do begin
      e.Text.CommandProcessor(TSynEditEx.ecComment, #0, nil);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Uncomment');
    e.Text.SelectAll;
    for I := 1 to CommentCount do begin
      e.Text.CommandProcessor(TSynEditEx.ecUncomment, #0, nil);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Toggle comment');
    e.Text.SelectAll;
    for I := 1 to CommentCount do begin
      e.Text.CommandProcessor(TSynEditEx.ecToggleComment, #0, nil);
      ShowUpdate(0);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Undo all previous actions to end up with empty editor');
    while e.Text.UndoList.CanUndo do begin
      e.Text.Undo;
      ShowUpdate(0);
    end;
    Assert(e.Text.Text.IsEmpty);

    MainUi.SetStatusbarMessage('Type line of text');
    for I := Ord('a') to Ord('z') do begin
      TypeText(Chr(I));
    end;
    Assert(e.Text.Lines.Count = 1);

    MainUi.SetStatusbarMessage('Duplicate lines');
    for I := 1 to DupeCount do begin
      e.Text.CommandProcessor(TSynEditEx.ecDuplicateLine, #0, nil);
      ShowUpdate(50);
    end;
    Assert(e.Text.Lines.Count = 1 + DupeCount);

    MainUi.SetStatusbarMessage('Delete lines');
    for I := 1 to DupeCount do begin
      e.Text.CommandProcessor(ecDeleteLine, #0, nil);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 1);

    MainUi.SetStatusbarMessage('Undo all previous actions to end up with empty editor');
    while e.Text.UndoList.CanUndo do begin
      e.Text.Undo;
      ShowUpdate(0);
    end;

    Assert(e.Text.Text.IsEmpty);

    MainUi.SetStatusbarMessage('Type wall of text');
    for I := Ord('a') to Ord('z') do begin
      TypeText(StringOfChar(Chr(I), LineLength));
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Indent');
    e.Text.SelectAll;
    for I := 1 to IndentCount do begin
      e.Text.CommandProcessor(ecBlockIndent, #0, nil);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Unindent');
    e.Text.SelectAll;
    for I := 1 to IndentCount do begin
      e.Text.CommandProcessor(ecBlockUnindent, #0, nil);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 26 + 1);

    MainUi.SetStatusbarMessage('Undo all previous actions to end up with empty editor');
    while e.Text.UndoList.CanUndo do begin
      e.Text.Undo;
      ShowUpdate(0);
    end;
    Assert(e.Text.Text.IsEmpty);

    MainUi.SetStatusbarMessage('Type wall of text');
    for I := Ord('a') to Ord('a') + 9 do begin
      TypeText(StringOfChar(Chr(I), LineLength));
      e.Text.CommandProcessor(ecLineBreak, #0, nil);
    end;
    Assert(e.Text.Lines.Count = 11);

    MainUi.SetStatusbarMessage('Enable bookmarks');
    for I := 1 to 9 do begin
      e.Text.CaretXY := BufferCoord(1, I);
      MainUi.ClickToggleBookmark(i);
      Assert(MainUi.ToggleBookmarkChecked(i));
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 11);

    MainUi.SetStatusbarMessage('Goto bookmarks');
    for I := 9 downto 1 do begin
      MainUi.ClickGotoBookmark(i);
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 11);

    MainUi.SetStatusbarMessage('Disable bookmarks');
    for I := 1 to 9 do begin
      MainUi.ClickToggleBookmark(i);
      Assert(not MainUi.ToggleBookmarkChecked(i));
      ShowUpdate(20);
    end;
    Assert(e.Text.Lines.Count = 11);

    MainUi.SetStatusbarMessage('Undo all previous actions to end up with empty editor');
    while e.Text.UndoList.CanUndo do begin
      e.Text.Undo;
      ShowUpdate(0);
    end;

    Assert(e.Text.Text.IsEmpty);

    MainUi.SetStatusbarMessage('Close editor without saving');
    MainUi.TryCloseEditor(e);

    Result := True;
  except
    Result := False;
  end;
end;

function TTestClass.TestAll: Boolean;
begin
  // TODO: further automate other tests
  Result := {TestEditorList and }TestEditor;
end;

constructor TTestClass.Create;
begin
end;

end.

