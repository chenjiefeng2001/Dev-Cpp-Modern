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

unit LSP.Client.Hover;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections, SyncObjs, Windows,
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  {$ENDIF}
  {$IFDEF FPC}
  Controls, Forms, Graphics, Windows,
  {$ELSE}
  Vcl.Controls, Vcl.Forms, Vcl.Graphics, Winapi.Windows,
  {$ENDIF}
  {$IFDEF FPC}
  Lsp.Transport, Lsp.DocumentSync,
  {$ELSE}
  LSP.Transport, Lsp.DocumentSync,
  {$ENDIF}
  Lsp.Editor.Types, Lsp.Editor.Interfaces;

// Hover 数据模型 (textDocument/hover)
type
  TLspHoverRange = record
    HasRange: Boolean;
    StartLine: Integer; // 0-based
    StartChar: Integer; // 0-based
    EndLine: Integer;
    EndChar: Integer;
  end;

  TLspHoverResult = record
    HasContent: Boolean;
    CodeBlock: string;     // 签名/类型 (等宽高亮区)
    Documentation: string; // 解释文档 (常规字体区)
    Range: TLspHoverRange; // 目标符号范围 (移出即关闭)
  end;

// 请求上下文: 记录请求时的悬停位置, 用于丢弃过期响应
  TLspHoverRequestContext = record
    RequestId: Integer;
    FileName: string;
    Line: Integer; // 0-based (请求时的鼠标指向行)
    Char: Integer; // 0-based
  end;

// Hover 气泡: 代码区(等宽藏青/浅灰底) + 分割线 + 文档区
  TLspHoverHintWindow = class(THintWindow)
  private
    FCode: string;
    FDoc: string;
    procedure WrapText(const S: string; AMaxWidth: Integer; ALines: TStrings);
    function CalcRectFor(AMaxWidth: Integer): TRect;
  protected
    procedure Paint; override;
  public
    procedure SetData(const ACode, ADoc: string);
    procedure ShowForEditorAt(const AEditor: IEditorControlAdapter;
      const ABufferPos: TLspBufferCoord);
  end;

// Hover 管理器: 异步、无阻塞、按请求 ID 丢弃过期响应
  TLspHoverManager = class
  private
    FEditor: IEditorControlAdapter;
    FTransport: TLspTransport;
    FCurrentFile: string;
    FOnHover: TNotifyEvent;
    FNextRequestId: Integer;
    FActiveRequestId: Integer;
    FActiveContext: TLspHoverRequestContext;
    FHint: TLspHoverHintWindow;
    FHintVisible: Boolean;
    FLastRange: TLspHoverRange;
    procedure HandleTransportMessage(const AMessage: string);
    procedure ProcessResponseOnUIThread(const AMessage: string; AReqId: Integer);
    procedure FillHintAndShow(const AResult: TLspHoverResult);
    function ExtractRequestId(const AJson: string): Integer;
    function ParseHoverResponse(const AJson: string;
      out AResult: TLspHoverResult): Boolean;
    function PathToLspUri(const AFileName: string): string;
    function MouseStillOnRequest: Boolean;
  public
    constructor Create(const AEditor: IEditorControlAdapter;
      ATransport: TLspTransport);
    destructor Destroy; override;

    procedure SetEditor(const AEditor: IEditorControlAdapter);
    procedure SetTransport(ATransport: TLspTransport);
    procedure SetCurrentFile(const AFileName: string);
    // 编辑器析构前调用, 防止悬空 FEditor
    procedure EditorDestroyed(const AEditor: IEditorControlAdapter);

    // ALine/AChar 均为 0-based (调用方由 BufferCoord 换算)
    procedure RequestHover(ALine, AChar: Integer);
    // 鼠标移到新字符时调用: 移出符号 Range 则关闭
    procedure DismissIfOutside(const AEditor: IEditorControlAdapter;
      const ABufferPos: TLspBufferCoord);
    function PosInLastRange(const ABufferPos: TLspBufferCoord): Boolean;
    procedure HideHint;
    function IsHintVisible: Boolean;

    property OnHover: TNotifyEvent read FOnHover write FOnHover;
    property CurrentFile: string read FCurrentFile write SetCurrentFile;
  end;

// 全局 Hover 管理器 (延迟创建)
var
  LspHoverManager: TLspHoverManager;

procedure InitializeLspHover(const AEditor: IEditorControlAdapter; ATransport: TLspTransport);
procedure EnsureLspHoverCreated;

implementation

{ TLspPixelPoint -> TPoint, for the hint window's screen-coordinate maths.
  The hint window is VCL and stays VCL: it is shown with ActivateHint at
  absolute screen coordinates, so TRect / TPoint / Screen legitimately stay
  in this unit. Only the EDITOR dependency is being cut. }
function MakePixelPoint(const P: TPoint): TLspPixelPoint;
begin
  Result.X := P.X;
  Result.Y := P.Y;
end;

function MakeHintPoint(const APoint: TLspPixelPoint): TPoint;
begin
  Result.X := APoint.X;
  Result.Y := APoint.Y;
end;

// ---------- 独立 JSON 小工具 (与 Completion/Signature 同构) ----------

function SkipJsonSpaces(const S: string; var Idx: Integer): Boolean;
begin
  while (Idx <= Length(S)) and (S[Idx] in [' ', #9, #10, #13]) do
    Inc(Idx);
  Result := Idx <= Length(S);
end;

function FindJsonFieldColon(const AJson, AField: string; out AValuePos: Integer): Boolean;
var
  P: Integer;
begin
  Result := False;
  AValuePos := 0;
  P := Pos('"' + AField + '"', AJson);
  if P = 0 then
    Exit;
  P := P + Length(AField) + 2;
  if not SkipJsonSpaces(AJson, P) then
    Exit;
  if (P > Length(AJson)) or (AJson[P] <> ':') then
    Exit;
  Inc(P);
  if not SkipJsonSpaces(AJson, P) then
    Exit;
  AValuePos := P;
  Result := True;
end;

function UnescapeJsonString(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if (C = '\') and (I < Length(S)) then
    begin
      Inc(I);
      case S[I] of
        '"': Result := Result + '"';
        '\': Result := Result + '\';
        '/': Result := Result + '/';
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        'b': Result := Result + #8;
        'f': Result := Result + #12;
        else Result := Result + '\' + S[I];
      end;
    end
    else
      Result := Result + C;
    Inc(I);
  end;
end;

function FindJsonStringField(const AJson, AField: string; out AValue: string): Boolean;
var
  P, Start: Integer;
begin
  Result := False;
  AValue := '';
  if not FindJsonFieldColon(AJson, AField, P) then
    Exit;
  if (P > Length(AJson)) or (AJson[P] <> '"') then
    Exit;
  Inc(P);
  Start := P;
  while P <= Length(AJson) do
  begin
    if AJson[P] = '\' then
      Inc(P, 2)
    else if AJson[P] = '"' then
      Break
    else
      Inc(P);
  end;
  if P > Length(AJson) then
    Exit;
  AValue := UnescapeJsonString(Copy(AJson, Start, P - Start));
  Result := True;
end;

function FindJsonIntField(const AJson, AField: string; out AValue: Integer): Boolean;
var
  P, Start: Integer;
  Num: string;
begin
  Result := False;
  AValue := 0;
  if not FindJsonFieldColon(AJson, AField, P) then
    Exit;
  Start := P;
  if (P <= Length(AJson)) and (AJson[P] = '-') then
    Inc(P);
  while (P <= Length(AJson)) and (AJson[P] in ['0'..'9']) do
    Inc(P);
  if P = Start then
    Exit;
  Num := Copy(AJson, Start, P - Start);
  AValue := StrToIntDef(Trim(Num), 0);
  Result := True;
end;

function ExtractJsonObject(const AJson, AField: string; out AObj: string): Boolean;
var
  P, Start, Depth: Integer;
  InStr: Boolean;
begin
  Result := False;
  AObj := '';
  if not FindJsonFieldColon(AJson, AField, P) then
    Exit;
  if (P > Length(AJson)) or (AJson[P] <> '{') then
    Exit;
  Start := P;
  Depth := 0;
  InStr := False;
  while P <= Length(AJson) do
  begin
    if InStr then
    begin
      if AJson[P] = '\' then
        Inc(P)
      else if AJson[P] = '"' then
        InStr := False;
    end
    else
    begin
      if AJson[P] = '"' then
        InStr := True
      else if AJson[P] = '{' then
        Inc(Depth)
      else if AJson[P] = '}' then
      begin
        Dec(Depth);
        if Depth = 0 then
        begin
          AObj := Copy(AJson, Start, P - Start + 1);
          Result := True;
          Exit;
        end;
      end;
    end;
    Inc(P);
  end;
end;

function ExtractJsonArrayContent(const AJson, AField: string; out AContent: string): Boolean;
var
  P, Start, Depth: Integer;
  InStr: Boolean;
begin
  Result := False;
  AContent := '';
  if not FindJsonFieldColon(AJson, AField, P) then
    Exit;
  if (P > Length(AJson)) or (AJson[P] <> '[') then
    Exit;
  Start := P + 1;
  Depth := 1;
  InStr := False;
  Inc(P);
  while P <= Length(AJson) do
  begin
    if InStr then
    begin
      if AJson[P] = '\' then
        Inc(P)
      else if AJson[P] = '"' then
        InStr := False;
    end
    else
    begin
      if AJson[P] = '"' then
        InStr := True
      else if AJson[P] = '[' then
        Inc(Depth)
      else if AJson[P] = ']' then
      begin
        Dec(Depth);
        if Depth = 0 then
        begin
          AContent := Copy(AJson, Start, P - Start);
          Result := True;
          Exit;
        end;
      end;
    end;
    Inc(P);
  end;
end;

function SplitTopLevelItems(const AContent: string): TArray<string>;
var
  List: TList<string>;
  I, Start, DepthB, DepthC: Integer;
  InStr: Boolean;
  Ch: Char;
begin
  List := TList<string>.Create;
  try
    I := 1;
    while I <= Length(AContent) do
    begin
      while (I <= Length(AContent)) and
        (AContent[I] in [' ', #9, #10, #13, ',']) do
        Inc(I);
      if I > Length(AContent) then
        Break;
      Ch := AContent[I];
      if Ch = '"' then
      begin
        Start := I;
        Inc(I);
        InStr := True;
        while (I <= Length(AContent)) and InStr do
        begin
          if AContent[I] = '\' then
            Inc(I, 2)
          else
          begin
            if AContent[I] = '"' then
              InStr := False;
            Inc(I);
          end;
        end;
        List.Add(Copy(AContent, Start, I - Start));
      end
      else if (Ch = '{') or (Ch = '[') then
      begin
        Start := I;
        DepthB := 0;
        DepthC := 0;
        InStr := False;
        while I <= Length(AContent) do
        begin
          if InStr then
          begin
            if AContent[I] = '\' then
              Inc(I)
            else if AContent[I] = '"' then
              InStr := False;
          end
          else
          begin
            if AContent[I] = '"' then
              InStr := True
            else if AContent[I] = '{' then
              Inc(DepthC)
            else if AContent[I] = '[' then
              Inc(DepthB)
            else if AContent[I] = '}' then
            begin
              Dec(DepthC);
              if (DepthC = 0) and (DepthB = 0) and (Ch = '{') then
              begin
                Inc(I);
                Break;
              end;
            end
            else if AContent[I] = ']' then
            begin
              Dec(DepthB);
              if (DepthC = 0) and (DepthB = 0) and (Ch = '[') then
              begin
                Inc(I);
                Break;
              end;
            end;
          end;
          Inc(I);
        end;
        List.Add(Copy(AContent, Start, I - Start));
      end
      else
      begin
        Start := I;
        while (I <= Length(AContent)) and
          not (AContent[I] in [',', ']', '}']) do
          Inc(I);
        List.Add(Trim(Copy(AContent, Start, I - Start)));
      end;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function ParseJsonStringLiteral(const AToken: string; out AValue: string): Boolean;
var
  P, Start: Integer;
begin
  Result := False;
  AValue := '';
  P := 1;
  while (P <= Length(AToken)) and (AToken[P] in [' ', #9]) do
    Inc(P);
  if (P > Length(AToken)) or (AToken[P] <> '"') then
    Exit;
  Inc(P);
  Start := P;
  while P <= Length(AToken) do
  begin
    if AToken[P] = '\' then
      Inc(P, 2)
    else if AToken[P] = '"' then
      Break
    else
      Inc(P);
  end;
  if P > Length(AToken) then
    Exit;
  AValue := UnescapeJsonString(Copy(AToken, Start, P - Start));
  Result := True;
end;

// ---------- 极简 Markdown 规整 ----------

function UnescapeHtml(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
end;

// 去行内标记: **bold** -> bold, `code` -> code, 行首 # -> 去掉
function StripInlineMarkup(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '*') and (I < Length(S)) and (S[I + 1] = '*') then
      Inc(I, 2) // 丢弃 **
    else if S[I] = '`' then
      Inc(I) // 丢弃行内反引号 (内容保留)
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
  // 去行首 # (标题)
  I := 1;
  while (I <= Length(Result)) and (Result[I] = '#') do
    Inc(I);
  if (I > 1) and (I <= Length(Result)) and (Result[I] = ' ') then
    Inc(I);
  if I > 1 then
    Result := Copy(Result, I, MaxInt);
  Result := Trim(Result);
end;

function IsCodeIshLine(const S: string): Boolean;
begin
  Result := (Pos('(', S) > 0) or (Pos('::', S) > 0) or (Pos(';', S) > 0) or
    (Pos('#', S) = 1) or (Pos('<', S) > 0);
end;

// 输入原始 Markdown, 输出 Code(签名) 与 Doc(文档)
procedure FlattenHoverMarkdown(const AMarkdown: string;
  out ACode, ADoc: string);
var
  Norm: string;
  Lines: TStringList;
  I: Integer;
  InFence: Boolean;
  FenceBuf, BodyBuf: TStringList;
  L: string;
begin
  ACode := '';
  ADoc := '';
  Norm := StringReplace(AMarkdown, #13#10, #10, [rfReplaceAll]);
  Norm := StringReplace(Norm, #13, #10, [rfReplaceAll]);
  Lines := TStringList.Create;
  FenceBuf := TStringList.Create;
  BodyBuf := TStringList.Create;
  try
    Lines.Text := Norm;
    InFence := False;
    for I := 0 to Lines.Count - 1 do
    begin
      L := Lines[I];
      if (Length(Trim(L)) >= 3) and (Copy(Trim(L), 1, 3) = '```') then
      begin
        if not InFence then
          InFence := True
        else
        begin
          // 围栏结束: 第一个块作为签名, 后续块并入正文
          InFence := False;
          if (ACode = '') and (Trim(FenceBuf.Text) <> '') then
            ACode := Trim(FenceBuf.Text)
          else if Trim(FenceBuf.Text) <> '' then
            BodyBuf.Add(Trim(FenceBuf.Text));
          FenceBuf.Clear;
        end;
        Continue;
      end;
      if InFence then
        FenceBuf.Add(L)
      else
      begin
        L := Trim(L);
        if (L = '---') or (L = '***') or (L = '___') then
          Continue; // 分割线丢弃 (UI 自绘分割线)
        BodyBuf.Add(StripInlineMarkup(L));
      end;
    end;
    // 未闭合围栏按代码处理
    if InFence and (Trim(FenceBuf.Text) <> '') then
    begin
      if ACode = '' then
        ACode := Trim(FenceBuf.Text)
      else
        BodyBuf.Add(Trim(FenceBuf.Text));
    end;
    // 无围栏: 首个像代码的行提升为签名
    if ACode = '' then
    begin
      for I := 0 to BodyBuf.Count - 1 do
      begin
        if Trim(BodyBuf[I]) = '' then
          Continue;
        if IsCodeIshLine(BodyBuf[I]) then
        begin
          ACode := Trim(BodyBuf[I]);
          BodyBuf.Delete(I);
          Break;
        end
        else
          Break; // 首行不像代码则整体视为文档
      end;
    end;
    // 文档: 压多余空行, 截断
    ADoc := '';
    for I := 0 to BodyBuf.Count - 1 do
    begin
      L := Trim(BodyBuf[I]);
      if L = '' then
      begin
        if (ADoc <> '') and (Copy(ADoc, Length(ADoc) - 1, 2) <> #10#10) then
          ADoc := ADoc + #10;
      end
      else
      begin
        if ADoc <> '' then
          ADoc := ADoc + #10;
        ADoc := ADoc + L;
      end;
    end;
    ADoc := Trim(ADoc);
    if Length(ADoc) > 800 then
      ADoc := Copy(ADoc, 1, 800) + '...';
    ACode := Trim(UnescapeHtml(ACode));
    ADoc := UnescapeHtml(ADoc);
  finally
    BodyBuf.Free;
    FenceBuf.Free;
    Lines.Free;
  end;
end;

{ TLspHoverHintWindow }

procedure TLspHoverHintWindow.SetData(const ACode, ADoc: string);
begin
  FCode := ACode;
  FDoc := ADoc;
end;

procedure TLspHoverHintWindow.WrapText(const S: string; AMaxWidth: Integer;
  ALines: TStrings);
var
  I, LineStart, LastBreak, LastBreakEnd: Integer;
  W: string;
begin
  I := 1;
  LineStart := 1;
  LastBreak := 0;
  LastBreakEnd := 0;
  while I <= Length(S) do
  begin
    if S[I] = #10 then
    begin
      ALines.Add(Copy(S, LineStart, I - LineStart));
      LineStart := I + 1;
      LastBreak := 0;
      Inc(I);
      Continue;
    end;
    if S[I] in [' ', #9] then
    begin
      LastBreak := I;
      LastBreakEnd := I;
      while (LastBreakEnd + 1 <= Length(S)) and
        (S[LastBreakEnd + 1] in [' ', #9]) do
        Inc(LastBreakEnd);
    end;
    W := Copy(S, LineStart, I - LineStart + 1);
    if Canvas.TextWidth(W) > AMaxWidth then
    begin
      if LastBreak > LineStart then
      begin
        ALines.Add(Copy(S, LineStart, LastBreak - LineStart));
        LineStart := LastBreakEnd + 1;
        LastBreak := 0;
      end
      else
      begin
        ALines.Add(Copy(S, LineStart, I - LineStart));
        LineStart := I;
        LastBreak := 0;
      end;
    end;
    Inc(I);
  end;
  if LineStart <= Length(S) then
    ALines.Add(Copy(S, LineStart, MaxInt));
  if ALines.Count = 0 then
    ALines.Add('');
end;

function TLspHoverHintWindow.CalcRectFor(AMaxWidth: Integer): TRect;
var
  Lines: TStringList;
  I, W, H, LineH: Integer;
  Doc: string;
begin
  Lines := TStringList.Create;
  try
    LineH := Canvas.TextHeight('Ag') + 2;
    H := 8;
    W := 0;
    if Trim(FCode) <> '' then
    begin
      Lines.Clear;
      WrapText(FCode, AMaxWidth, Lines);
      for I := 0 to Lines.Count - 1 do
        if Canvas.TextWidth(Lines[I]) > W then
          W := Canvas.TextWidth(Lines[I]);
      Inc(H, Lines.Count * (LineH + 1) + 6);
    end;
    Doc := Trim(FDoc);
    if Doc <> '' then
    begin
      Lines.Clear;
      WrapText(Doc, AMaxWidth, Lines);
      if Lines.Count > 8 then
      begin
        while Lines.Count > 8 do
          Lines.Delete(Lines.Count - 1);
        Lines[7] := Lines[7] + '...';
      end;
      for I := 0 to Lines.Count - 1 do
        if Canvas.TextWidth(Lines[I]) > W then
          W := Canvas.TextWidth(Lines[I]);
      Inc(H, Lines.Count * LineH + 4);
    end;
    if W > AMaxWidth then
      W := AMaxWidth;
    if W < 120 then
      W := 120;
    Result := Rect(0, 0, W + 16, H + 6);
  finally
    Lines.Free;
  end;
end;

procedure TLspHoverHintWindow.Paint;
var
  Lines: TStringList;
  I, Y, LineH, CodeBottom: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  LineH := Canvas.TextHeight('Ag') + 2;
  Y := 4;
  // 代码区: 等宽 + 浅灰底
  if Trim(FCode) <> '' then
  begin
    Lines := TStringList.Create;
    try
      Canvas.Font.Name := 'Consolas';
      Canvas.Font.Size := 9;
      Canvas.Font.Style := [];
      Canvas.Font.Color := clNavy;
      WrapText(FCode, ClientWidth - 16, Lines);
      CodeBottom := Y + Lines.Count * (LineH + 1) + 4;
      Canvas.Brush.Color := $00F2F2F2;
      Canvas.FillRect(Rect(0, 0, ClientWidth, CodeBottom));
      for I := 0 to Lines.Count - 1 do
      begin
        Canvas.TextOut(8, Y, Lines[I]);
        Inc(Y, LineH + 1);
      end;
      Inc(Y, 2);
      // 分割线
      Canvas.Pen.Color := clGray;
      Canvas.MoveTo(0, Y);
      Canvas.LineTo(ClientWidth, Y);
      Inc(Y, 4);
    finally
      Lines.Free;
    end;
  end;
  // 文档区
  if Trim(FDoc) <> '' then
  begin
    Lines := TStringList.Create;
    try
      Canvas.Brush.Color := Color;
      Canvas.Font.Name := 'Segoe UI';
      Canvas.Font.Size := 9;
      Canvas.Font.Style := [];
      Canvas.Font.Color := clInfoText;
      WrapText(FDoc, ClientWidth - 16, Lines);
      if Lines.Count > 8 then
      begin
        while Lines.Count > 8 do
          Lines.Delete(Lines.Count - 1);
        Lines[7] := Lines[7] + '...';
      end;
      for I := 0 to Lines.Count - 1 do
      begin
        Canvas.TextOut(8, Y, Lines[I]);
        Inc(Y, LineH);
      end;
    finally
      Lines.Free;
    end;
  end;
end;

procedure TLspHoverHintWindow.ShowForEditorAt(
  const AEditor: IEditorControlAdapter;
  const ABufferPos: TLspBufferCoord);
var
  R: TRect;
  P: TPoint;
  Work: TRect;
begin
  if not Assigned(AEditor) then
    Exit;
  Color := clInfoBk;
  R := CalcRectFor(560);
  P := MakeHintPoint(AEditor.BufferToScreenPixels(ABufferPos));
  Inc(P.Y, AEditor.GetLineHeight + 6);
  Work := Screen.MonitorFromPoint(P).WorkareaRect;
  if P.Y + R.Bottom > Work.Bottom then
  begin
    // 下方放不下则翻到悬停位置上方
    P := MakeHintPoint(AEditor.BufferToScreenPixels(ABufferPos));
    P.Y := P.Y - R.Bottom - 6;
    if P.Y < Work.Top then
      P.Y := Work.Top;
  end;
  if P.X + R.Right > Work.Right then
    P.X := Work.Right - R.Right;
  if P.X < Work.Left then
    P.X := Work.Left;
  OffsetRect(R, P.X, P.Y);
  ActivateHint(R, '');
end;

{ TLspHoverManager }

constructor TLspHoverManager.Create(
  const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
begin
  inherited Create;
  FNextRequestId := 0;
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.FileName := '';
  FActiveContext.Line := 0;
  FActiveContext.Char := 0;
  FHintVisible := False;
  FLastRange.HasRange := False;
  FLastRange.StartLine := 0;
  FLastRange.StartChar := 0;
  FLastRange.EndLine := 0;
  FLastRange.EndChar := 0;
  FHint := TLspHoverHintWindow.Create(nil);
  SetEditor(AEditor);
  SetTransport(ATransport);
end;

destructor TLspHoverManager.Destroy;
begin
  HideHint;
  if Assigned(FTransport) then
  try
    FTransport.UnsubscribeMessage(HandleTransportMessage);
  except
  end;
  FreeAndNil(FHint);
  inherited;
end;

procedure TLspHoverManager.SetEditor(
  const AEditor: IEditorControlAdapter);
begin
  if FEditor = AEditor then
    Exit;
  HideHint;
  FEditor := AEditor;
end;

procedure TLspHoverManager.SetTransport(ATransport: TLspTransport);
begin
  if FTransport = ATransport then
    Exit;
  if Assigned(FTransport) then
  try
    FTransport.UnsubscribeMessage(HandleTransportMessage);
  except
  end;
  FTransport := ATransport;
  if Assigned(FTransport) then
    FTransport.SubscribeMessage(HandleTransportMessage);
end;

procedure TLspHoverManager.SetCurrentFile(const AFileName: string);
begin
  FCurrentFile := AFileName;
end;

procedure TLspHoverManager.EditorDestroyed(
  const AEditor: IEditorControlAdapter);
begin
  if FEditor = AEditor then
  begin
    HideHint;
    FEditor := nil;
  end;
end;

function TLspHoverManager.PathToLspUri(const AFileName: string): string;
var
  P: string;
begin
  P := Trim(AFileName);
  if P = '' then
    P := Trim(FCurrentFile);
  if P = '' then
    Exit('file:///untitled.cpp');
  P := StringReplace(P, '\', '/', [rfReplaceAll]);
  P := StringReplace(P, ' ', '%20', [rfReplaceAll]);
  if Pos('file://', LowerCase(P)) = 1 then
    Result := P
  else if (Length(P) > 1) and (P[1] = '/') then
    Result := 'file://' + P
  else
    Result := 'file:///' + P;
end;

procedure TLspHoverManager.RequestHover(ALine, AChar: Integer);
var
  ReqId: Integer;
  ParamsJson, Request: string;
begin
  if not Assigned(FEditor) then
    Exit;
  if not Assigned(FTransport) then
    Exit;
  if ALine < 0 then ALine := 0;
  if AChar < 0 then AChar := 0;

  // FlushOnDemand: 与补全/签名同理
  try
    LspFlushPendingDocument(FCurrentFile, FEditor.GetAllText);
  except
  end;

{$IFDEF FPC}
  ReqId := InterlockedIncrement(FNextRequestId);
{$ELSE}
  ReqId := TInterlocked.Increment(FNextRequestId);
{$ENDIF}
  FActiveRequestId := ReqId;
  FActiveContext.RequestId := ReqId;
  FActiveContext.FileName := FCurrentFile;
  FActiveContext.Line := ALine;
  FActiveContext.Char := AChar;

  ParamsJson := Format(
    '{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d}}',
    [PathToLspUri(FCurrentFile), ALine, AChar]);
  Request := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover","params":%s}',
    [ReqId, ParamsJson]);
  FTransport.SendPayload(Request);
end;

function TLspHoverManager.PosInLastRange(
  const ABufferPos: TLspBufferCoord): Boolean;
begin
  Result := False;
  if not FLastRange.HasRange then
    Exit;
  // 1-based BufferCoord vs 0-based LSP range
  if (ABufferPos.Line - 1 < FLastRange.StartLine) or
    (ABufferPos.Line - 1 > FLastRange.EndLine) then
    Exit;
  if (ABufferPos.Line - 1 = FLastRange.StartLine) and
    (ABufferPos.Char - 1 < FLastRange.StartChar) then
    Exit;
  if (ABufferPos.Line - 1 = FLastRange.EndLine) and
    (ABufferPos.Char - 1 >= FLastRange.EndChar) then
    Exit;
  Result := True;
end;

procedure TLspHoverManager.DismissIfOutside(
  const AEditor: IEditorControlAdapter;
  const ABufferPos: TLspBufferCoord);
begin
  if not FHintVisible then
    Exit;
  if not Assigned(FEditor) or (AEditor <> FEditor) then
    Exit;
  if not PosInLastRange(ABufferPos) then
    HideHint;
end;

procedure TLspHoverManager.HideHint;
begin
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.FileName := '';
  FActiveContext.Line := 0;
  FActiveContext.Char := 0;
  FHintVisible := False;
  FLastRange.HasRange := False;
  if Assigned(FHint) then
  try
    FHint.ReleaseHandle;
  except
  end;
end;

function TLspHoverManager.IsHintVisible: Boolean;
begin
  Result := FHintVisible and Assigned(FHint) and Assigned(FEditor);
end;

function TLspHoverManager.ExtractRequestId(const AJson: string): Integer;
var
  P: Integer;
  Neg: Boolean;
  Num: string;
begin
  Result := -1;
  if not FindJsonFieldColon(AJson, 'id', P) then
    Exit;
  if (P <= Length(AJson)) and (AJson[P] = '"') then
    Inc(P);
  Neg := False;
  if (P <= Length(AJson)) and (AJson[P] = '-') then
  begin
    Neg := True;
    Inc(P);
  end;
  Num := '';
  while (P <= Length(AJson)) and (AJson[P] in ['0'..'9']) do
  begin
    Num := Num + AJson[P];
    Inc(P);
  end;
  if Num = '' then
    Exit;
  Result := StrToIntDef(Num, -1);
  if Neg then
    Result := -Result;
end;

// 响应到达时鼠标是否仍在请求位置 (防"移开后弹 stale 气泡")
function TLspHoverManager.MouseStillOnRequest: Boolean;
var
  CursorPixel: TLspPixelPoint;
  BC: TLspBufferCoord;
begin
  Result := False;
  if not Assigned(FEditor) then
    Exit;
  try
    // CursorPixel is the mouse in screen pixels. The ORIGINAL code read the
    // client point first and range-checked it before converting; that order
    // is kept, because outside the viewport there is no meaningful buffer
    // coordinate and a bounds test applied after conversion would be
    // comparing against garbage.
    CursorPixel := MakePixelPoint(Mouse.CursorPos);
    if CursorPixel.X < 0 then
      Exit;
    if CursorPixel.Y < 0 then
      Exit;
    if (CursorPixel.X > FEditor.GetClientWidth) or
      (CursorPixel.Y > FEditor.GetClientHeight) then
      Exit;
    // ScreenToClient + PixelsToRowColumn + DisplayToBufferPos, collapsed.
    BC := FEditor.ScreenPixelsToBuffer(CursorPixel);
    Result := (BC.Line - 1 = FActiveContext.Line) and
      (BC.Char - 1 = FActiveContext.Char);
  except
    Result := False;
  end;
end;

procedure TLspHoverManager.HandleTransportMessage(const AMessage: string);
var
  ReqId: Integer;
  R: TLspHoverResult;
begin
  if AMessage = '' then
    Exit;
  if Pos('"method"', AMessage) > 0 then
    Exit;
  ReqId := ExtractRequestId(AMessage);
  if (ReqId < 0) or (ReqId <> FActiveRequestId) then
    Exit;
  if not ParseHoverResponse(AMessage, R) or not R.HasContent then
  begin
    // 空结果 (空白处/未知符号): 隐藏旧气泡
    TThread.Queue(nil,
      procedure
      begin
        if ReqId = FActiveRequestId then
          HideHint;
      end);
    Exit;
  end;
  TThread.Queue(nil,
    procedure
    begin
      ProcessResponseOnUIThread(AMessage, ReqId);
    end);
end;

procedure TLspHoverManager.ProcessResponseOnUIThread(const AMessage: string;
  AReqId: Integer);
var
  R: TLspHoverResult;
begin
  if AReqId <> FActiveRequestId then
    Exit;
  if not Assigned(FEditor) then
    Exit;
  if not ParseHoverResponse(AMessage, R) or not R.HasContent then
  begin
    HideHint;
    Exit;
  end;
  // 鼠标已离开请求位置则不弹 (驻留计时器会被新位置的请求超车)
  if not MouseStillOnRequest then
    Exit;
  FillHintAndShow(R);
  if Assigned(FOnHover) then
    FOnHover(Self);
end;

procedure TLspHoverManager.FillHintAndShow(const AResult: TLspHoverResult);
var
  AtPos: TLspBufferCoord;
begin
  if not Assigned(FEditor) or not Assigned(FHint) then
    Exit;
  FLastRange := AResult.Range;
  try
    FHint.SetData(AResult.CodeBlock, AResult.Documentation);
    // 气泡锚定在请求位置 (鼠标驻留点), 而非当前光标
    AtPos.Line := FActiveContext.Line + 1;
    AtPos.Char := FActiveContext.Char + 1;
    FHint.ShowForEditorAt(FEditor, AtPos);
    FHintVisible := True;
  except
    FHintVisible := False;
  end;
end;

function TLspHoverManager.ParseHoverResponse(const AJson: string;
  out AResult: TLspHoverResult): Boolean;
var
  ResultObj, ContentsObj, ArrContent: string;
  RawItems: TArray<string>;
  Raw, S, Code, Doc: string;
  I: Integer;
  Tok: string;
begin
  Result := False;
  AResult.HasContent := False;
  AResult.CodeBlock := '';
  AResult.Documentation := '';
  AResult.Range.HasRange := False;
  AResult.Range.StartLine := 0;
  AResult.Range.StartChar := 0;
  AResult.Range.EndLine := 0;
  AResult.Range.EndChar := 0;

  if Pos('"result":null', AJson) > 0 then
    Exit;
  if not ExtractJsonObject(AJson, 'result', ResultObj) then
    Exit;

  // contents 三形态: string | {kind,value} | MarkedString[]
  Raw := '';
  if FindJsonStringField(ResultObj, 'contents', S) then
    Raw := S
  else if ExtractJsonObject(ResultObj, 'contents', ContentsObj) then
  begin
    if not FindJsonStringField(ContentsObj, 'value', Raw) then
      Exit;
  end
  else if ExtractJsonArrayContent(ResultObj, 'contents', ArrContent) then
  begin
    RawItems := SplitTopLevelItems(ArrContent);
    Raw := '';
    for I := Low(RawItems) to High(RawItems) do
    begin
      Tok := Trim(RawItems[I]);
      if Tok = '' then
        Continue;
      if (Tok[1] = '"') then
      begin
        if ParseJsonStringLiteral(Tok, S) then
        begin
          if Raw <> '' then
            Raw := Raw + #10#10;
          Raw := Raw + S;
        end;
      end
      else if (Tok[1] = '{') then
      begin
        if FindJsonStringField(Tok, 'value', S) then
        begin
          if Raw <> '' then
            Raw := Raw + #10#10;
          Raw := Raw + S;
        end;
      end;
    end;
  end
  else
    Exit;

  if Trim(Raw) = '' then
    Exit;

  FlattenHoverMarkdown(Raw, Code, Doc);
  if (Trim(Code) = '') and (Trim(Doc) = '') then
    Exit;
  AResult.HasContent := True;
  AResult.CodeBlock := Code;
  AResult.Documentation := Doc;

  // range 可选
  if ExtractJsonObject(ResultObj, 'range', ContentsObj) then
  begin
    if ExtractJsonObject(ContentsObj, 'start', S) then
    begin
      FindJsonIntField(S, 'line', AResult.Range.StartLine);
      FindJsonIntField(S, 'character', AResult.Range.StartChar);
      AResult.Range.HasRange := True;
    end;
    if ExtractJsonObject(ContentsObj, 'end', S) then
    begin
      FindJsonIntField(S, 'line', AResult.Range.EndLine);
      FindJsonIntField(S, 'character', AResult.Range.EndChar);
    end;
  end;
  Result := True;
end;

// 全局初始化
procedure InitializeLspHover(const AEditor: IEditorControlAdapter; ATransport: TLspTransport);
begin
  if not Assigned(LspHoverManager) then
    LspHoverManager := TLspHoverManager.Create(AEditor, ATransport)
  else
  begin
    LspHoverManager.SetEditor(AEditor);
    LspHoverManager.SetTransport(ATransport);
  end;
end;

procedure EnsureLspHoverCreated;
begin
  if not Assigned(LspHoverManager) then
    LspHoverManager := TLspHoverManager.Create(nil, nil);
end;

initialization
  LspHoverManager := nil;

finalization
  if Assigned(LspHoverManager) then
    FreeAndNil(LspHoverManager);

end.
