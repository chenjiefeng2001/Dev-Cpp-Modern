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

unit LSP.Client.SignatureHelp;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections, SyncObjs, Windows, Types,
  {$ELSE}
  SysUtils, Classes, Generics.Collections, SyncObjs, Windows, System.Types,
  {$ENDIF}
  {$IFDEF FPC}
  Controls, Forms, Graphics,
  {$ELSE}
  Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  {$ENDIF}
  {$IFDEF FPC}
  Lsp.Transport, Lsp.DocumentSync,
  {$ELSE}
  LSP.Transport, Lsp.DocumentSync,
  {$ENDIF}
  Lsp.Editor.Types, Lsp.Editor.Interfaces;

// LSP 签名帮助数据模型 (textDocument/signatureHelp)
type
  TLspParameterInformation = record
    LabelText: string;    // 如 "int x"; 若服务端给 [start,end] 偏移则据此切片
    Documentation: string;
    LabelStart: Integer;  // 1-based, 在所属 signature Label 中的起始 (-1=未知)
    LabelLength: Integer; // 高亮长度 (-1=未知, 回退到逗号切分/字符串查找)
  end;

  TLspSignatureInformation = record
    LabelText: string;      // 如 "void foo(int x, double y)"
    Documentation: string;
    ActiveParameter: Integer; // 本签名的 activeParameter (-1=未指定, 用顶层值)
    Parameters: TArray<TLspParameterInformation>;
  end;

  TLspSignatureHelpResult = record
    Signatures: TArray<TLspSignatureInformation>;
    ActiveSignature: Integer;
    ActiveParameter: Integer; // 顶层 activeParameter (-1=未指定)
  end;

// 请求上下文: 记录请求发出时的光标, 用于丢弃过期响应
  TLspSignatureRequestContext = record
    RequestId: Integer;
    TriggerChar: string;
    FileName: string;
    CaretLine: Integer; // 1-based (SynEdit)
    CaretChar: Integer; // 1-based (SynEdit)
  end;

// 签名提示气泡: THintWindow 子类, 当前参数加粗高亮
  TLspSignatureHintWindow = class(THintWindow)
  private
    FSignatures: TArray<TLspSignatureInformation>;
    FActiveSignature: Integer;
    FActiveParameter: Integer; // 已归一化 (顶层回退后)
    FEditor: IEditorControlAdapter;   // 弱引用, 仅用于定位
    function EffectiveActiveParameter(const ASig: TLspSignatureInformation): Integer;
    function ActiveParamRange(const ASig: TLspSignatureInformation;
      out AStart, ALen: Integer): Boolean;
    function CalcRectFor(AMaxWidth: Integer): TRect;
    procedure WrapText(const S: string; ABaseOffset: Integer; AMaxWidth: Integer;
      ALines: TStrings; AOffsets: TList<Integer>);
    function DrawWrapped(const S: string; ABaseOffset, X, Y, AMaxWidth: Integer;
      AHiStart, AHiLen: Integer): Integer;
  protected
    procedure Paint; override;
  public
    procedure SetData(const ASigs: TArray<TLspSignatureInformation>;
      AActiveSig, AActiveParam: Integer);
    procedure ShowForEditor(const AEditor: IEditorControlAdapter);
    function CycleSignature(ADelta: Integer): Boolean;
    property ActiveSignature: Integer read FActiveSignature;
  end;

// 签名帮助管理器: 异步、无阻塞、按请求 ID 丢弃过期响应
  TLspSignatureHelpManager = class
  private
    FEditor: IEditorControlAdapter;
    FTransport: TLspTransport;
    FCurrentFile: string;
    FOnSignatureHelp: TNotifyEvent;
    FNextRequestId: Integer;
    FActiveRequestId: Integer;
    FActiveContext: TLspSignatureRequestContext;
    FHint: TLspSignatureHintWindow;
    FHintVisible: Boolean;
    FLastResult: TLspSignatureHelpResult;
    FHasResult: Boolean;
    procedure HandleTransportMessage(const AMessage: string);
    procedure ProcessResponseOnUIThread(const AMessage: string; AReqId: Integer);
    procedure FillHintAndShow(const AResult: TLspSignatureHelpResult);
    function ExtractRequestId(const AJson: string): Integer;
    function ParseSignatureHelpResponse(const AJson: string;
      out AResult: TLspSignatureHelpResult): Boolean;
    function ParseSingleSignature(const ASigJson: string;
      out ASig: TLspSignatureInformation): Boolean;
    function PathToLspUri(const AFileName: string): string;
  public
    constructor Create(const AEditor: IEditorControlAdapter;
      ATransport: TLspTransport);
    destructor Destroy; override;

    procedure SetEditor(const AEditor: IEditorControlAdapter);
    procedure SetTransport(ATransport: TLspTransport);
    procedure SetCurrentFile(const AFileName: string);

    // ATriggerChar: '(' / ',' (triggerKind=2); '' 表示 Invoked 或 ContentChange
    // AIsRetrigger: 气泡已可见时的二次触发 (context.isRetrigger=true)
    procedure RequestSignatureHelp(const ATriggerChar: string;
      AIsRetrigger: Boolean = False);
    // 光标移动时由 EditorStatusChange 调用: 仅气泡可见且位置变化才重查
    procedure EditorCaretMoved(const AEditor: IEditorControlAdapter);
    // 编辑器析构前调用: 关闭气泡、作废在途请求、摘除悬空引用
    procedure EditorDestroyed(const AEditor: IEditorControlAdapter);
    procedure CancelPendingActive;
    procedure HideHint;
    function IsHintVisible: Boolean;
    // Alt+Up/Down 切换重载, 不发网络请求
    function CycleOverload(ADelta: Integer): Boolean;

    property OnSignatureHelp: TNotifyEvent
      read FOnSignatureHelp write FOnSignatureHelp;
    property CurrentFile: string read FCurrentFile write SetCurrentFile;
  end;

// 全局签名帮助管理器 (延迟创建)
var
  LspSignatureHelpManager: TLspSignatureHelpManager;

procedure InitializeLspSignatureHelp(
  const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
procedure EnsureLspSignatureHelpCreated;

implementation

{ TLspPixelPoint -> TPoint for the hint window's screen-coordinate maths.
  The hint window is VCL and stays VCL (ActivateHint at absolute screen
  coordinates), so TRect / TPoint / Screen legitimately remain here. Only
  the EDITOR dependency is being cut. }
function MakeHintPoint(const APoint: TLspPixelPoint): TPoint;
begin
  Result.X := APoint.X;
  Result.Y := APoint.Y;
end;

// ---------- 独立 JSON 小工具 (与 Completion 同构, 不依赖 System.JSON) ----------

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

// 切分数组内层文本为顶层元素 (字符串/对象/数字均可)
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
        // 数字 / true / false / null
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

// 解析 "..." 字面量 (含转义) 为原文
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

// 在签名 label 中定位第 N 个顶层参数 (逗号切分, 感知嵌套与字符串)
function FindNthParameterRange(const ASigLabel: string; AParamIndex: Integer;
  out AStart, ALen: Integer): Boolean;
var
  OpenPos, I, DepthPar, DepthBr, DepthBrace, DepthAngle: Integer;
  InS, InD: Boolean;
  SegStarts, SegEnds: TList<Integer>;
  S, E, K: Integer;
  procedure PushSeg(ABegin, AEnd: Integer);
  begin
    // 去首尾空白
    while (ABegin <= AEnd) and (ABegin <= Length(ASigLabel)) and
      (ASigLabel[ABegin] in [' ', #9]) do
      Inc(ABegin);
    while (AEnd >= ABegin) and (ASigLabel[AEnd] in [' ', #9]) do
      Dec(AEnd);
    SegStarts.Add(ABegin);
    SegEnds.Add(AEnd);
  end;
begin
  Result := False;
  AStart := 0;
  ALen := 0;
  OpenPos := Pos('(', ASigLabel);
  if OpenPos = 0 then
    Exit;
  // 找配对的 ')'
  DepthPar := 0;
  InS := False;
  InD := False;
  I := OpenPos;
  E := 0;
  while I <= Length(ASigLabel) do
  begin
    if InS then
    begin
      if ASigLabel[I] = '\' then
        Inc(I)
      else if ASigLabel[I] = '''' then
        InS := False;
    end
    else if InD then
    begin
      if ASigLabel[I] = '\' then
        Inc(I)
      else if ASigLabel[I] = '"' then
        InD := False;
    end
    else
    begin
      if ASigLabel[I] = '''' then
        InS := True
      else if ASigLabel[I] = '"' then
        InD := True
      else if ASigLabel[I] = '(' then
        Inc(DepthPar)
      else if ASigLabel[I] = ')' then
      begin
        Dec(DepthPar);
        if DepthPar = 0 then
        begin
          E := I;
          Break;
        end;
      end;
    end;
    Inc(I);
  end;
  if E = 0 then
    Exit;
  // 切分 OpenPos+1 .. E-1
  SegStarts := TList<Integer>.Create;
  SegEnds := TList<Integer>.Create;
  try
    S := OpenPos + 1;
    DepthPar := 0;
    DepthBr := 0;
    DepthBrace := 0;
    DepthAngle := 0;
    InS := False;
    InD := False;
    I := S;
    while I < E do
    begin
      if InS then
      begin
        if ASigLabel[I] = '\' then
          Inc(I)
        else if ASigLabel[I] = '''' then
          InS := False;
      end
      else if InD then
      begin
        if ASigLabel[I] = '\' then
          Inc(I)
        else if ASigLabel[I] = '"' then
          InD := False;
      end
      else
      begin
        case ASigLabel[I] of
          '''': InS := True;
          '"': InD := True;
          '(': Inc(DepthPar);
          ')': Dec(DepthPar);
          '[': Inc(DepthBr);
          ']': Dec(DepthBr);
          '{': Inc(DepthBrace);
          '}': Dec(DepthBrace);
          '<': Inc(DepthAngle);
          '>': Dec(DepthAngle);
          ',':
            if (DepthPar = 0) and (DepthBr = 0) and (DepthBrace = 0) and
              (DepthAngle = 0) then
            begin
              PushSeg(S, I - 1);
              S := I + 1;
            end;
        end;
      end;
      Inc(I);
    end;
    PushSeg(S, E - 1);
    if SegStarts.Count = 0 then
      Exit;
    // 空参数列表 "()" 或 "(void)" 视为无参数
    if (SegStarts.Count = 1) then
    begin
      K := SegEnds[0] - SegStarts[0] + 1;
      if (K <= 0) or SameText(Copy(ASigLabel, SegStarts[0], K), 'void') then
        Exit;
    end;
    if AParamIndex < 0 then
      AParamIndex := 0;
    if AParamIndex >= SegStarts.Count then
      AParamIndex := SegStarts.Count - 1; // 超界钳位到末参 (变参/多实参)
    AStart := SegStarts[AParamIndex];
    ALen := SegEnds[AParamIndex] - SegStarts[AParamIndex] + 1;
    Result := ALen > 0;
  finally
    SegStarts.Free;
    SegEnds.Free;
  end;
end;

{ TLspSignatureHintWindow }

procedure TLspSignatureHintWindow.SetData(
  const ASigs: TArray<TLspSignatureInformation>;
  AActiveSig, AActiveParam: Integer);
begin
  FSignatures := Copy(ASigs, 0, Length(ASigs));
  FActiveSignature := AActiveSig;
  FActiveParameter := AActiveParam;
  if FActiveSignature < 0 then
    FActiveSignature := 0;
  if (Length(FSignatures) > 0) and (FActiveSignature >= Length(FSignatures)) then
    FActiveSignature := 0;
end;

function TLspSignatureHintWindow.EffectiveActiveParameter(
  const ASig: TLspSignatureInformation): Integer;
begin
  if ASig.ActiveParameter >= 0 then
    Result := ASig.ActiveParameter
  else
    Result := FActiveParameter;
end;

// 解析当前参数在签名串中的高亮区间 (1-based 起始 + 长度)
function TLspSignatureHintWindow.ActiveParamRange(
  const ASig: TLspSignatureInformation; out AStart, ALen: Integer): Boolean;
var
  P: Integer;
  FoundAt: Integer;
begin
  Result := False;
  AStart := 0;
  ALen := 0;
  P := EffectiveActiveParameter(ASig);
  if P < 0 then
    Exit;
  // 1) 服务端给的 [start,end) 偏移 (0-based UTF-16) 最精确
  if (P >= 0) and (P < Length(ASig.Parameters)) then
  begin
    if ASig.Parameters[P].LabelLength > 0 then
    begin
      AStart := ASig.Parameters[P].LabelStart;
      ALen := ASig.Parameters[P].LabelLength;
      Result := True;
      Exit;
    end;
    // 2) 参数 label 字符串回查
    if ASig.Parameters[P].LabelText <> '' then
    begin
      FoundAt := Pos(ASig.Parameters[P].LabelText, ASig.LabelText);
      if FoundAt > 0 then
      begin
        AStart := FoundAt;
        ALen := Length(ASig.Parameters[P].LabelText);
        Result := True;
        Exit;
      end;
    end;
  end;
  // 3) 逗号切分回退
  Result := FindNthParameterRange(ASig.LabelText, P, AStart, ALen);
end;

procedure TLspSignatureHintWindow.WrapText(const S: string; ABaseOffset: Integer;
  AMaxWidth: Integer; ALines: TStrings; AOffsets: TList<Integer>);
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
      if (LastBreak > LineStart) then
      begin
        ALines.Add(Copy(S, LineStart, LastBreak - LineStart));
        AOffsets.Add(ABaseOffset + LineStart - 1);
        LineStart := LastBreakEnd + 1;
        LastBreak := 0;
      end
      else
      begin
        // 单词本身超长则硬断
        ALines.Add(Copy(S, LineStart, I - LineStart));
        AOffsets.Add(ABaseOffset + LineStart - 1);
        LineStart := I;
        LastBreak := 0;
      end;
    end;
    Inc(I);
  end;
  if LineStart <= Length(S) then
  begin
    ALines.Add(Copy(S, LineStart, MaxInt));
    AOffsets.Add(ABaseOffset + LineStart - 1);
  end;
  if ALines.Count = 0 then
  begin
    ALines.Add('');
    AOffsets.Add(ABaseOffset);
  end;
end;

// 绘制可换行文本; AHiStart/AHiLen 为原文 1-based 高亮区间 (0=不高亮)
function TLspSignatureHintWindow.DrawWrapped(const S: string; ABaseOffset,
  X, Y, AMaxWidth: Integer; AHiStart, AHiLen: Integer): Integer;
var
  Lines: TStringList;
  Offsets: TList<Integer>;
  L, K: Integer;
  LineOff, HiS, HiE, SegEnd: Integer;
  Pre, Hi, Post: string;
  OldStyle: TFontStyles;
  OldColor: TColor;
  LineH: Integer;
begin
  Lines := TStringList.Create;
  Offsets := TList<Integer>.Create;
  try
    WrapText(S, ABaseOffset, AMaxWidth, Lines, Offsets);
    LineH := Canvas.TextHeight('Ag') + 2;
    OldStyle := Canvas.Font.Style;
    OldColor := Canvas.Font.Color;
    for L := 0 to Lines.Count - 1 do
    begin
      LineOff := Offsets[L];
      HiS := 0;
      if (AHiLen > 0) then
      begin
        HiE := AHiStart + AHiLen; // 开区间
        // 行区间 [LineOff, LineOff+Len)
        if (AHiStart < LineOff + Length(Lines[L])) and
          (HiE > LineOff) then
          HiS := 1;
      end;
      if HiS = 0 then
      begin
        Canvas.Font.Style := OldStyle;
        Canvas.Font.Color := OldColor;
        Canvas.TextOut(X, Y, Lines[L]);
      end
      else
      begin
        // 三段绘制: 前 / 高亮 / 后
        K := AHiStart - LineOff; // 高亮在行内的 0-based 起点
        if K < 0 then K := 0;
        SegEnd := AHiStart + AHiLen - LineOff;
        if SegEnd > Length(Lines[L]) then
          SegEnd := Length(Lines[L]);
        Pre := Copy(Lines[L], 1, K);
        Hi := Copy(Lines[L], K + 1, SegEnd - K);
        Post := Copy(Lines[L], SegEnd + 1, MaxInt);
        Canvas.Font.Style := OldStyle;
        Canvas.Font.Color := OldColor;
        Canvas.TextOut(X, Y, Pre);
        Canvas.Font.Style := OldStyle + [fsBold];
        Canvas.Font.Color := clNavy;
        Canvas.TextOut(X + Canvas.TextWidth(Pre), Y, Hi);
        Canvas.Font.Style := OldStyle;
        Canvas.Font.Color := OldColor;
        Canvas.TextOut(X + Canvas.TextWidth(Pre + Hi), Y, Post);
      end;
      Inc(Y, LineH);
    end;
    Result := Y;
  finally
    Offsets.Free;
    Lines.Free;
  end;
end;

function TLspSignatureHintWindow.CalcRectFor(AMaxWidth: Integer): TRect;
var
  Lines: TStringList;
  Offsets: TList<Integer>;
  I, W, H, LineH: Integer;
  Sig: TLspSignatureInformation;
  Doc: string;
begin
  Lines := TStringList.Create;
  Offsets := TList<Integer>.Create;
  try
    LineH := Canvas.TextHeight('Ag') + 2;
    H := 8;
    W := 0;
    if Length(FSignatures) > 1 then
      Inc(H, LineH); // 重载头行
    if (FActiveSignature >= 0) and (FActiveSignature < Length(FSignatures)) then
    begin
      Sig := FSignatures[FActiveSignature];
      Lines.Clear;
      Offsets.Clear;
      WrapText(Sig.LabelText, 1, AMaxWidth, Lines, Offsets);
      for I := 0 to Lines.Count - 1 do
        if Canvas.TextWidth(Lines[I]) > W then
          W := Canvas.TextWidth(Lines[I]);
      Inc(H, Lines.Count * LineH + 4);
      Doc := Trim(Sig.Documentation);
      if Length(Doc) > 500 then
        Doc := Copy(Doc, 1, 500) + '...';
      if Doc <> '' then
      begin
        Lines.Clear;
        Offsets.Clear;
        WrapText(Doc, 1, AMaxWidth, Lines, Offsets);
        if Lines.Count > 5 then
        begin
          while Lines.Count > 5 do
            Lines.Delete(Lines.Count - 1);
          Lines[4] := Lines[4] + '...';
        end;
        for I := 0 to Lines.Count - 1 do
          if Canvas.TextWidth(Lines[I]) > W then
            W := Canvas.TextWidth(Lines[I]);
        Inc(H, Lines.Count * LineH + 2);
      end;
    end;
    if W > AMaxWidth then
      W := AMaxWidth;
    Result := Rect(0, 0, W + 16, H + 6);
  finally
    Offsets.Free;
    Lines.Free;
  end;
end;

procedure TLspSignatureHintWindow.Paint;
var
  Y: Integer;
  Sig: TLspSignatureInformation;
  Doc: string;
  HiS, HiL: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  Canvas.Font.Assign(Font);
  Canvas.Font.Color := clInfoText;
  Y := 4;
  if Length(FSignatures) > 1 then
  begin
    Canvas.Font.Color := clGrayText;
    Canvas.TextOut(8, Y,
      Format('Overload %d of %d  (Alt+Up/Down)',
      [FActiveSignature + 1, Length(FSignatures)]));
    Canvas.Font.Color := clInfoText;
    Inc(Y, Canvas.TextHeight('Ag') + 4);
  end;
  if (FActiveSignature < 0) or (FActiveSignature >= Length(FSignatures)) then
    Exit;
  Sig := FSignatures[FActiveSignature];
  if not ActiveParamRange(Sig, HiS, HiL) then
  begin
    HiS := 0;
    HiL := 0;
  end;
  Y := DrawWrapped(Sig.LabelText, 1, 8, Y, ClientWidth - 16, HiS, HiL);
  Inc(Y, 2);
  Doc := Trim(Sig.Documentation);
  if Length(Doc) > 500 then
    Doc := Copy(Doc, 1, 500) + '...';
  if Doc <> '' then
  begin
    Canvas.Font.Style := [];
    Canvas.Font.Color := clGrayText;
    DrawWrapped(Doc, 1, 8, Y, ClientWidth - 16, 0, 0);
  end;
end;

procedure TLspSignatureHintWindow.ShowForEditor(
  const AEditor: IEditorControlAdapter);
var
  R: TRect;
  P: TPoint;
  Work: TRect;
begin
  if not Assigned(AEditor) then
    Exit;
  FEditor := AEditor;
  Color := clInfoBk;
  R := CalcRectFor(560);
  P := MakeHintPoint(AEditor.CaretToScreenPixels);
  Inc(P.Y, AEditor.GetLineHeight + 4);
  Work := Screen.MonitorFromPoint(P).WorkareaRect;
  // 底部放不下则翻到光标上方
  if P.Y + R.Bottom > Work.Bottom then
  begin
    P := MakeHintPoint(AEditor.CaretToScreenPixels);
    P.Y := P.Y - R.Bottom - 4;
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

function TLspSignatureHintWindow.CycleSignature(ADelta: Integer): Boolean;
begin
  Result := False;
  if Length(FSignatures) < 2 then
    Exit;
  FActiveSignature :=
    (FActiveSignature + ADelta + Length(FSignatures)) mod Length(FSignatures);
  if Assigned(FEditor) then
    ShowForEditor(FEditor)
  else
    Invalidate;
  Result := True;
end;

{ TLspSignatureHelpManager }

constructor TLspSignatureHelpManager.Create(
  const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
begin
  inherited Create;
  FNextRequestId := 0;
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.TriggerChar := '';
  FActiveContext.FileName := '';
  FActiveContext.CaretLine := 0;
  FActiveContext.CaretChar := 0;
  FHintVisible := False;
  FHasResult := False;
  FHint := TLspSignatureHintWindow.Create(nil);
  SetEditor(AEditor);
  SetTransport(ATransport);
end;

destructor TLspSignatureHelpManager.Destroy;
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

procedure TLspSignatureHelpManager.SetEditor(
  const AEditor: IEditorControlAdapter);
begin
  if FEditor = AEditor then
    Exit;
  HideHint;
  FEditor := AEditor;
end;

procedure TLspSignatureHelpManager.SetTransport(ATransport: TLspTransport);
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

procedure TLspSignatureHelpManager.SetCurrentFile(const AFileName: string);
begin
  FCurrentFile := AFileName;
end;

function TLspSignatureHelpManager.PathToLspUri(const AFileName: string): string;
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

procedure TLspSignatureHelpManager.RequestSignatureHelp(
  const ATriggerChar: string; AIsRetrigger: Boolean);
var
  LspLine, LspChar, ReqId, TrigKind: Integer;
  CaretPos: TLspBufferCoord;
  ParamsJson, Request: string;
begin
  if not Assigned(FEditor) then
    Exit;
  if not Assigned(FTransport) then
    Exit;

  // FlushOnDemand: 与 Completion 同理, 先同步脏文本再发签名请求
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
  FActiveContext.TriggerChar := ATriggerChar;
  FActiveContext.FileName := FCurrentFile;
  CaretPos := FEditor.GetCaretPosition;
  FActiveContext.CaretLine := CaretPos.Line;
  FActiveContext.CaretChar := CaretPos.Char;

  LspLine := CaretPos.Line - 1;
  LspChar := CaretPos.Char - 1;
  if LspLine < 0 then LspLine := 0;
  if LspChar < 0 then LspChar := 0;

  // triggerKind: 1=Invoked, 2=TriggerCharacter, 3=ContentChange(光标移动重查)
  if ATriggerChar <> '' then
    TrigKind := 2
  else if AIsRetrigger then
    TrigKind := 3
  else
    TrigKind := 1;

  if TrigKind = 2 then
    ParamsJson := Format(
      '{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d},' +
      '"context":{"triggerKind":2,"triggerCharacter":"%s","isRetrigger":%s}}',
      [PathToLspUri(FCurrentFile), LspLine, LspChar, ATriggerChar,
       LowerCase(BoolToStr(AIsRetrigger, True))])
  else
    ParamsJson := Format(
      '{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d},' +
      '"context":{"triggerKind":%d,"isRetrigger":%s}}',
      [PathToLspUri(FCurrentFile), LspLine, LspChar, TrigKind,
       LowerCase(BoolToStr(AIsRetrigger, True))]);

  Request := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"textDocument/signatureHelp","params":%s}',
    [ReqId, ParamsJson]);

  FTransport.SendPayload(Request);
end;

procedure TLspSignatureHelpManager.EditorCaretMoved(
  const AEditor: IEditorControlAdapter);
begin
  if not FHintVisible then
    Exit;
  // Interface equality compares the interface POINTER (VMT + Self), not
  // the underlying editor. Correct only because TEditor.GetAdapter hands
  // every caller the same cached value -- do not remove that cache.
  if not Assigned(FEditor) or (AEditor <> FEditor) then
    Exit;
  if (FEditor.GetCaretPosition.Line = FActiveContext.CaretLine) and
    (FEditor.GetCaretPosition.Char = FActiveContext.CaretChar) then
    Exit;
  // 光标移动 -> ContentChange 重查, stale 响应由请求 ID 丢弃
  RequestSignatureHelp('', True);
end;

procedure TLspSignatureHelpManager.EditorDestroyed(
  const AEditor: IEditorControlAdapter);
begin
  if not Assigned(AEditor) or (FEditor <> AEditor) then
    Exit;
  // SetEditor(nil) 内部先 HideHint (作废在途请求 + 关闭气泡) 再摘除引用
  SetEditor(nil);
end;

procedure TLspSignatureHelpManager.CancelPendingActive;
begin
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.TriggerChar := '';
  FActiveContext.FileName := '';
  FActiveContext.CaretLine := 0;
  FActiveContext.CaretChar := 0;
end;

procedure TLspSignatureHelpManager.HideHint;
begin
  CancelPendingActive;
  FHintVisible := False;
  if Assigned(FHint) then
  try
    FHint.ReleaseHandle;
  except
  end;
end;

function TLspSignatureHelpManager.IsHintVisible: Boolean;
begin
  Result := FHintVisible and Assigned(FHint) and Assigned(FEditor);
end;

function TLspSignatureHelpManager.CycleOverload(ADelta: Integer): Boolean;
begin
  Result := False;
  if not IsHintVisible then
    Exit;
  if not FHasResult then
    Exit;
  if Length(FLastResult.Signatures) < 2 then
    Exit;
  FLastResult.ActiveSignature :=
    (FLastResult.ActiveSignature + ADelta + Length(FLastResult.Signatures)) mod
    Length(FLastResult.Signatures);
  FHint.SetData(FLastResult.Signatures, FLastResult.ActiveSignature,
    FLastResult.ActiveParameter);
  FHint.ShowForEditor(FEditor);
  Result := True;
end;

function TLspSignatureHelpManager.ExtractRequestId(const AJson: string): Integer;
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

procedure TLspSignatureHelpManager.HandleTransportMessage(const AMessage: string);
var
  ReqId: Integer;
  R: TLspSignatureHelpResult;
begin
  if AMessage = '' then
    Exit;
  if Pos('"method"', AMessage) > 0 then
    Exit; // 通知/请求回显, 非响应
  ReqId := ExtractRequestId(AMessage);
  if (ReqId < 0) or (ReqId <> FActiveRequestId) then
    Exit; // 过期/无关响应
  if not ParseSignatureHelpResponse(AMessage, R) then
  begin
    // 无可用签名 (如光标在字符串/注释内): 在 UI 线程隐藏旧气泡
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

procedure TLspSignatureHelpManager.ProcessResponseOnUIThread(
  const AMessage: string; AReqId: Integer);
var
  R: TLspSignatureHelpResult;
begin
  if AReqId <> FActiveRequestId then
    Exit;
  if not Assigned(FEditor) then
    Exit;
  if not ParseSignatureHelpResponse(AMessage, R) then
  begin
    HideHint;
    Exit;
  end;
  if Length(R.Signatures) = 0 then
  begin
    HideHint;
    Exit;
  end;
  FillHintAndShow(R);
  if Assigned(FOnSignatureHelp) then
    FOnSignatureHelp(Self);
end;

procedure TLspSignatureHelpManager.FillHintAndShow(
  const AResult: TLspSignatureHelpResult);
var
  ActSig, ActParam: Integer;
begin
  if not Assigned(FEditor) or not Assigned(FHint) then
    Exit;
  FLastResult := AResult;
  FHasResult := True;
  ActSig := AResult.ActiveSignature;
  if (ActSig < 0) or (ActSig >= Length(AResult.Signatures)) then
    ActSig := 0;
  ActParam := AResult.ActiveParameter;
  FLastResult.ActiveSignature := ActSig;
  try
    FHint.SetData(AResult.Signatures, ActSig, ActParam);
    FHint.ShowForEditor(FEditor);
    FHintVisible := True;
  except
    FHintVisible := False;
  end;
end;

function TLspSignatureHelpManager.ParseSignatureHelpResponse(
  const AJson: string; out AResult: TLspSignatureHelpResult): Boolean;
var
  ResultObj, ArrContent: string;
  RawItems: TArray<string>;
  Sig: TLspSignatureInformation;
  List: TList<TLspSignatureInformation>;
  I, N: Integer;
begin
  Result := False;
  SetLength(AResult.Signatures, 0);
  AResult.ActiveSignature := 0;
  AResult.ActiveParameter := -1;

  if Pos('"result":null', AJson) > 0 then
    Exit;
  if not ExtractJsonObject(AJson, 'result', ResultObj) then
    Exit;
  if not ExtractJsonArrayContent(ResultObj, 'signatures', ArrContent) then
    Exit;

  List := TList<TLspSignatureInformation>.Create;
  try
    RawItems := SplitTopLevelItems(ArrContent);
    for I := Low(RawItems) to High(RawItems) do
    begin
      if (RawItems[I] <> '') and (RawItems[I][1] = '{') then
        if ParseSingleSignature(RawItems[I], Sig) then
          List.Add(Sig);
    end;
    if List.Count = 0 then
      Exit;
    AResult.Signatures := List.ToArray;
    if FindJsonIntField(ResultObj, 'activeSignature', N) then
      AResult.ActiveSignature := N;
    if FindJsonIntField(ResultObj, 'activeParameter', N) then
      AResult.ActiveParameter := N;
    Result := True;
  finally
    List.Free;
  end;
end;

function TLspSignatureHelpManager.ParseSingleSignature(
  const ASigJson: string; out ASig: TLspSignatureInformation): Boolean;
var
  S, ParamsContent, DocObj: string;
  RawParams: TArray<string>;
  P: TLspParameterInformation;
  I: Integer;
  Tok, Inner, PairContent: string;
  Nums: TArray<string>;
  A, B: Integer;
begin
  Result := False;
  ASig.LabelText := '';
  ASig.Documentation := '';
  ASig.ActiveParameter := -1;
  SetLength(ASig.Parameters, 0);

  if not FindJsonStringField(ASigJson, 'label', S) then
    Exit;
  ASig.LabelText := S;

  if FindJsonStringField(ASigJson, 'documentation', S) then
    ASig.Documentation := S
  else if ExtractJsonObject(ASigJson, 'documentation', DocObj) then
  begin
    if FindJsonStringField(DocObj, 'value', S) then
      ASig.Documentation := S;
  end;

  if FindJsonIntField(ASigJson, 'activeParameter', I) then
    ASig.ActiveParameter := I;

  if ExtractJsonArrayContent(ASigJson, 'parameters', ParamsContent) then
  begin
    RawParams := SplitTopLevelItems(ParamsContent);
    SetLength(ASig.Parameters, Length(RawParams));
    for I := Low(RawParams) to High(RawParams) do
    begin
      Tok := Trim(RawParams[I]);
      P.LabelText := '';
      P.Documentation := '';
      P.LabelStart := -1;
      P.LabelLength := -1;
      if (Tok <> '') and (Tok[1] = '"') then
      begin
        // 字符串形参数
        if ParseJsonStringLiteral(Tok, S) then
          P.LabelText := S;
      end
      else if (Tok <> '') and (Tok[1] = '{') then
      begin
        // 对象形参数: {label, documentation}
        if FindJsonStringField(Tok, 'label', S) then
          P.LabelText := S
        else if ExtractJsonArrayContent(Tok, 'label', PairContent) then
        begin
          // label 为 [start, end) 偏移 (0-based UTF-16, 相对 signature label)
          Nums := SplitTopLevelItems(PairContent);
          if Length(Nums) >= 2 then
          begin
            A := StrToIntDef(Trim(Nums[0]), -1);
            B := StrToIntDef(Trim(Nums[1]), -1);
            if (A >= 0) and (B > A) then
            begin
              P.LabelStart := A + 1; // 转 1-based
              P.LabelLength := B - A;
              P.LabelText := Copy(ASig.LabelText, A + 1, B - A);
            end;
          end;
        end;
        if FindJsonStringField(Tok, 'documentation', S) then
          P.Documentation := S
        else if ExtractJsonObject(Tok, 'documentation', Inner) then
        begin
          if FindJsonStringField(Inner, 'value', S) then
            P.Documentation := S;
        end;
      end;
      ASig.Parameters[I] := P;
    end;
  end;

  Result := ASig.LabelText <> '';
end;

// 全局初始化
procedure InitializeLspSignatureHelp(
  const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
begin
  if not Assigned(LspSignatureHelpManager) then
    LspSignatureHelpManager := TLspSignatureHelpManager.Create(AEditor, ATransport)
  else
  begin
    LspSignatureHelpManager.SetEditor(AEditor);
    LspSignatureHelpManager.SetTransport(ATransport);
  end;
end;

procedure EnsureLspSignatureHelpCreated;
begin
  if not Assigned(LspSignatureHelpManager) then
    LspSignatureHelpManager := TLspSignatureHelpManager.Create(nil, nil);
end;

initialization
  LspSignatureHelpManager := nil;

finalization
  if Assigned(LspSignatureHelpManager) then
    FreeAndNil(LspSignatureHelpManager);

end.
