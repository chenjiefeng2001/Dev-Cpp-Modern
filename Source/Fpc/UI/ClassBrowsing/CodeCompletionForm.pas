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

unit CodeCompletionForm;{$mode objfpc}{$H+}

interface

uses
{$IFDEF WINDOWS}
  Windows, Classes, Graphics, Forms, StdCtrls, Controls,
  CodeCompletion, CppParser, CBUtils, Messages, ExtCtrls, LCLType;
{$ENDIF}
{$IFDEF LINUX}
Xlib, SysUtils, Classes, QGraphics, QForms, QStdCtrls, QControls,
CodeCompletion, CppParser, QGrids, QDialogs, Types;
{$ENDIF}

type
  // Same shape as Controls.TKeyPressEvent; see lbCompletionDblClick.
  TLclKeyPressEvent = procedure(Sender: TObject; var Key: Char) of object;

  TCodeComplForm = class(TForm)
    lbCompletion: TListBox;
    Bevel1: TBevel;
    procedure FormShow(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure lbCompletionDblClick(Sender: TObject);
    procedure lbCompletionDrawItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure lbCompletionKeyPress(Sender: TObject; var Key: Char);
  private
    { Private declarations }
    fOwner: TCodeCompletion;

  protected
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
  public
    constructor Create(AOwner: TComponent); override;
    procedure CreateParams(var Params: TCreateParams); override;
  end;

var
  CodeComplForm: TCodeComplForm;

implementation

{$R *.lfm}

procedure TCodeComplForm.FormShow(Sender: TObject);
begin
  Width := fOwner.Width;
  Height := fOwner.Height;
  Color := fOwner.Color;
  lbCompletion.Color := fOwner.Color;
  lbCompletion.DoubleBuffered := true; // performance hit, but reduces flicker a lit
end;

procedure TCodeComplForm.FormDeactivate(Sender: TObject);
begin
  fOwner.Hide;
end;

procedure TCodeComplForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);

//  Params.Style := Params.Style or WS_SIZEBOX;
end;

constructor TCodeComplForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  fOwner := TCodeCompletion(AOwner);
end;

procedure TCodeComplForm.lbCompletionDblClick(Sender: TObject);
var
  Key: Char;
  KeyEvent: TKeyPressEvent;
begin
  // Send command to TEditor.
  // The local copy is not style: FPC 3.2.2 refuses a var argument when the
  // call goes through a Controls-typed event property directly, and through
  // a local of an identically shaped type it compiles.
  KeyEvent := TLclKeyPressEvent(fOwner.OnKeyPress);
  if Assigned(KeyEvent) then begin
    Key := Char(VK_RETURN);
    KeyEvent(self, Key);
  end;
end;

procedure TCodeComplForm.lbCompletionDrawItem(Control: TWinControl; Index: Integer; Rect: TRect; State:
  TOwnerDrawState);
var
  Offset: integer;
  statement: PStatement;
begin
  Offset := 4;

  with lbCompletion do begin
    statement := PStatement(Items.Objects[Index]);

    // Draw statement kind string, like 'Preprocessor'
    if odSelected in State then begin
      Canvas.Brush.Color := clHighlight;
      Canvas.FillRect(Rect);
      Canvas.Font.Color := clHighlightText;
    end else begin
      Canvas.Brush.Color := fOwner.Color;
      Canvas.FillRect(Rect);
      case statement^._Kind of
        skFunction: Canvas.Font.Color := clGreen;
        skClass: Canvas.Font.Color := clMaroon;
        skVariable: Canvas.Font.Color := clBlue;
        skTypedef: Canvas.Font.Color := clOlive;
        skPreprocessor: Canvas.Font.Color := clPurple;
        skEnum: Canvas.Font.Color := clNavy;
      else
        Canvas.Font.Color := clGray;
      end;
    end;
    Canvas.TextOut(Offset, Rect.Top, fOwner.Parser.StatementKindStr(statement^._Kind));
    Offset := Offset + Canvas.TextWidth('preprocessor '); // worst case width + spacing
    if not (odSelected in State) then
      Canvas.Font.Color := clWindowText;

    // Draw data type string, like 'int', hide for defines/others that don't have this property
    if Length(statement^._Type) > 0 then begin
      Canvas.TextOut(Offset, Rect.Top, statement^._Type);
      Offset := Offset + Canvas.TextWidth(statement^._Type + ' ');
    end;

    // draw statement name, like 'foo'
    Canvas.Font.Style := [fsBold];
    Canvas.TextOut(Offset, Rect.Top, statement^._Command);
    Offset := Offset + Canvas.TextWidth(statement^._Command + ' ');

    // if applicable, draw arguments
    if statement^._Kind in [skFunction, skConstructor, skDestructor] then begin
      Canvas.Font.Style := [];
      Canvas.TextOut(Offset, Rect.Top, statement^._Args);
    end;
  end;
end;

procedure TCodeComplForm.lbCompletionKeyPress(Sender: TObject; var Key: Char);
var
  KeyEvent: TKeyPressEvent;
begin
  KeyEvent := TLclKeyPressEvent(fOwner.OnKeyPress);
  if Assigned(KeyEvent) then
    KeyEvent(self, Key);
end;

procedure TCodeComplForm.WMNCHitTest(var Message: TWMNCHitTest);
var
  D: Integer;
  P: TPoint;
begin

  D := GetSystemMetrics(SM_CXSIZEFRAME);

  P := Self.ScreenToClient(Message.Pos);

  if P.Y < D then
  begin
    if P.X < D then
      Message.Result := HTTOPLEFT
    else if P.X > ClientWidth - D then
      Message.Result := HTTOPRIGHT
    else
      Message.Result := HTTOP;
  end
  else if P.Y > ClientHeight - D then
  begin
    if P.X < D then
      Message.Result := HTBOTTOMLEFT
    else if P.X > ClientWidth - D then
      Message.Result := HTBOTTOMRIGHT
    else
      Message.Result := HTBOTTOM;
  end
  else
  begin
    if P.X < D then
      Message.Result := HTLEFT
    else if P.X > ClientWidth - D then
      Message.Result := HTRIGHT
  end;

end;

end.


{ FPC-side port of the vendored CodeCompletionForm.pas.
  The Delphi file is left byte-identical; the FPC search
  path resolves THIS unit under the same name (the
  TSynRCSyn / devFileMonitor precedent).
  Measured accommodations, one per line:
//  * // the same shape as Controls.TKeyPressEvent is declared locally (TLclKeyPressEvent) and the event is called through it: calling a Controls-typed event property with a var argument is refused by FPC 3.2.2, and the local shape compiles (both were measured).
//  * Messages -> Messages, ExtCtrls -> ExtCtrls, + LCLType for TCreateParams (FPC's TCreateParams lives in LCLType with a PChar Caption).
//  * The .dfm ships as .lfm with the Delphi-only PixelsPerInch, TextHeight and OldCreateOrder dropped.
  Additional general ones:
  * every unit carries {$mode objfpc}{$H+} so Char is the
    WideChar the LCL's own types expect.
}
