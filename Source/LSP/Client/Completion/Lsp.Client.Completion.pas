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

unit LSP.Client.Completion;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections, SyncObjs, Windows,
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  {$ENDIF}
  {$IFDEF FPC}
  Forms,
  {$ELSE}
  Vcl.Forms,
  {$ENDIF}
  SynEditTypes, SynEdit, SynCompletionProposal,
  {$IFDEF FPC}
  Lsp.Transport, Lsp.DocumentSync;
  {$ELSE}
  LSP.Transport, Lsp.DocumentSync;
  {$ENDIF}

// LSP 文本编辑范围 (0-based, UTF-16 code units, 与 LSP 规范一致)
type
  TLspTextEdit = record
    HasEdit: Boolean;
    StartLine: Integer;
    StartChar: Integer;
    EndLine: Integer;
    EndChar: Integer;
    NewText: string;
  end;

// LSP 完成项 (record + 方法, 避免手动内存管理)
  TLspCompletionItem = record
    DisplayLabel: string;
    Kind: Integer;
    Detail: string;
    Documentation: string;
    InsertText: string;
    SortText: string;
    FilterText: string;
    TextEdit: TLspTextEdit;
    function GetEffectiveText: string;
  end;

// 完成列表
  TLspCompletionList = record
    IsIncomplete: Boolean;
    Items: TArray<TLspCompletionItem>;
  end;

// 请求上下文: 记录请求发出时的光标/文件, 用于丢弃过期响应
  TLspCompletionRequestContext = record
    RequestId: Integer;
    TriggerChar: string;
    FileName: string;
    CaretLine: Integer; // 1-based (SynEdit)
    CaretChar: Integer; // 1-based (SynEdit)
  end;

// LSP 完成管理器: 异步、无阻塞、按请求 ID 丢弃过期响应
  TLspCompletionManager = class
  private
    FEditor: TCustomSynEdit;
    FTransport: TLspTransport;
    FItems: TList<TLspCompletionItem>;
    FCurrentFile: string;
    FOnCompletion: TNotifyEvent;
    FNextRequestId: Integer;
    FActiveRequestId: Integer;
    FActiveContext: TLspCompletionRequestContext;
    FIsIncomplete: Boolean;
    FProposal: TSynCompletionProposal;
    procedure HandleTransportMessage(const AMessage: string);
    procedure ProcessResponseOnUIThread(const AMessage: string; AReqId: Integer);
    procedure FillProposalAndShow(const AItems: TArray<TLspCompletionItem>;
      AIsIncomplete: Boolean);
    procedure ProposalExecute(Kind: SynCompletionType; Sender: TObject;
      var CurrentInput: string; var x, y: Integer; var CanExecute: Boolean);
    procedure ProposalCodeCompletion(Sender: TObject; var Value: string;
      Shift: TShiftState; Index: Integer; EndToken: WideChar);
    function ExtractRequestId(const AJson: string): Integer;
    function ParseCompletionResponse(const AJson: string;
      out AItems: TLspCompletionList): Boolean;
    function ParseSingleItem(const AItemJson: string;
      out AItem: TLspCompletionItem): Boolean;
    function GetCurrentWord: string;
    function PathToLspUri(const AFileName: string): string;
  public
    constructor Create(AEditor: TCustomSynEdit; ATransport: TLspTransport);
    destructor Destroy; override;

    procedure SetEditor(AEditor: TCustomSynEdit);
    procedure SetTransport(ATransport: TLspTransport);
    procedure SetCurrentFile(const AFileName: string);

    // 触发补全: 无参版本检测光标前是否为触发字符; 有参版本强制请求
    function TriggerCompletion: Boolean; overload;
    function TriggerCompletion(const ATriggerChar: string): Boolean; overload;
    // 强制发起一次补全请求 (ATriggerChar='' 表示 Invoked/Ctrl+Space)
    procedure RequestCompletion(const ATriggerChar: string = '');
    procedure CancelPending;
    // 编辑器析构前调用: 关闭弹窗、作废在途请求、摘除悬空引用
    procedure EditorDestroyed(AEditor: TCustomSynEdit);

    function GetItems: TArray<TLspCompletionItem>;
    procedure ApplyItemWithRange(const AItem: TLspCompletionItem);

    property IsIncomplete: Boolean read FIsIncomplete;
    property OnCompletion: TNotifyEvent read FOnCompletion write FOnCompletion;
    property CurrentFile: string read FCurrentFile write SetCurrentFile;
  end;

// 全局完成管理器 (延迟创建)
var
  LspCompletionManager: TLspCompletionManager;

// 初始化完成管理器 (兼容旧调用; 可传入 nil, 后续用 SetEditor/SetTransport 补齐)
procedure InitializeLspCompletion(AEditor: TCustomSynEdit; ATransport: TLspTransport);
procedure EnsureLspCompletionCreated;

implementation

// ---------- 独立 JSON 小工具 (不依赖 System.JSON, 兼容旧版 Delphi) ----------

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
        // \uXXXX: 暂保留原样, 避免引入宽字符转换复杂度
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
    Exit; // 非字符串 (可能是对象/数字), 交给调用方处理
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
  // 允许解析形如 12 后跟 } ] , 空白
  Num := Copy(AJson, Start, P - Start);
  AValue := StrToIntDef(Trim(Num), 0);
  Result := True;
end;

function FindJsonBoolField(const AJson, AField: string; out AValue: Boolean): Boolean;
var
  P: Integer;
  Rest: string;
begin
  Result := False;
  if not FindJsonFieldColon(AJson, AField, P) then
    Exit;
  Rest := Copy(AJson, P, 5);
  if Pos('true', Rest) = 1 then
  begin
    AValue := True;
    Result := True;
  end
  else if Pos('false', Rest) = 1 then
  begin
    AValue := False;
    Result := True;
  end;
end;

// 提取 "field": { ... } 平衡大括号对象 (含括号本身)
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
        Inc(P) // 跳过转义
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

// 提取 "field": [ ... ] 平衡方括号数组内容 (不含外层括号, 返回内层文本)
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

// 去除 LSP snippet 占位符: $0 $1 ${1} ${1:text} -> text
function StripSnippetPlaceholders(const S: string): string;
var
  I, J, K: Integer;
  Num: string;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '$') and (I < Length(S)) then
    begin
      if S[I + 1] = '{' then
      begin
        // ${n} 或 ${n:text}
        J := I + 2;
        Num := '';
        while (J <= Length(S)) and (S[J] in ['0'..'9']) do
        begin
          Num := Num + S[J];
          Inc(J);
        end;
        if (J <= Length(S)) and (S[J] = '}') then
          I := J + 1 // ${n} 直接丢弃
        else if (J <= Length(S)) and (S[J] = ':') then
        begin
          // ${n:text} 取 text
          Inc(J);
          K := J;
          while (K <= Length(S)) and (S[K] <> '}') do
            Inc(K);
          Result := Result + Copy(S, J, K - J);
          if K <= Length(S) then
            I := K + 1
          else
            I := K;
        end
        else
          Inc(I); // 非法格式, 原样跳过 $
      end
      else if S[I + 1] in ['0'..'9'] then
      begin
        // $n 直接丢弃
        J := I + 1;
        while (J <= Length(S)) and (S[J] in ['0'..'9']) do
          Inc(J);
        I := J;
      end
      else
      begin
        Result := Result + S[I];
        Inc(I);
      end;
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

{ TLspCompletionItem }

function TLspCompletionItem.GetEffectiveText: string;
begin
  if (TextEdit.HasEdit) and (TextEdit.NewText <> '') then
    Result := StripSnippetPlaceholders(TextEdit.NewText)
  else if InsertText <> '' then
    Result := StripSnippetPlaceholders(InsertText)
  else
    Result := DisplayLabel;
end;

{ TLspCompletionManager }

constructor TLspCompletionManager.Create(AEditor: TCustomSynEdit;
  ATransport: TLspTransport);
begin
  inherited Create;
  FItems := TList<TLspCompletionItem>.Create;
  FNextRequestId := 0;
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.TriggerChar := '';
  FActiveContext.FileName := '';
  FActiveContext.CaretLine := 0;
  FActiveContext.CaretChar := 0;
  FIsIncomplete := False;

  // 常驻补全提案组件 (不可每次临时创建/释放, 否则弹窗会被立即销毁)
  FProposal := TSynCompletionProposal.Create(nil);
  FProposal.Options := [scoLimitToMatchedText, scoUseInsertList,
    scoCompleteWithTab, scoCompleteWithEnter];
  FProposal.TriggerChars := '';
  FProposal.OnExecute := ProposalExecute;
  FProposal.OnCodeCompletion := ProposalCodeCompletion;

  SetEditor(AEditor);
  SetTransport(ATransport);
end;

destructor TLspCompletionManager.Destroy;
begin
  CancelPending;
  if Assigned(FTransport) then
  try
    FTransport.UnsubscribeMessage(HandleTransportMessage);
  except
    // 传输层可能已在析构, 忽略
  end;
  if Assigned(FProposal) then
  begin
    try
      if Assigned(FEditor) then
        FProposal.RemoveEditor(FEditor);
    except
    end;
    FProposal.OnExecute := nil;
    FProposal.OnCodeCompletion := nil;
    FreeAndNil(FProposal);
  end;
  FreeAndNil(FItems);
  inherited;
end;

procedure TLspCompletionManager.SetEditor(AEditor: TCustomSynEdit);
begin
  if FEditor = AEditor then
    Exit;
  if Assigned(FProposal) and Assigned(FEditor) then
  try
    FProposal.RemoveEditor(FEditor);
  except
  end;
  FEditor := AEditor;
  if Assigned(FProposal) and Assigned(FEditor) then
  begin
    FProposal.Editor := FEditor;
    try
      if FProposal.EditorsCount = 0 then
        FProposal.AddEditor(FEditor);
    except
    end;
  end;
end;

procedure TLspCompletionManager.SetTransport(ATransport: TLspTransport);
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

procedure TLspCompletionManager.SetCurrentFile(const AFileName: string);
begin
  FCurrentFile := AFileName;
end;

function TLspCompletionManager.PathToLspUri(const AFileName: string): string;
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

function TLspCompletionManager.GetCurrentWord: string;
var
  LineText: string;
  I, EndPos: Integer;
begin
  Result := '';
  if not Assigned(FEditor) then
    Exit;
  if (FEditor.CaretY < 1) or (FEditor.CaretY > FEditor.Lines.Count) then
    Exit;
  LineText := FEditor.Lines[FEditor.CaretY - 1];
  EndPos := FEditor.CaretX - 1;
  if EndPos < 1 then
    Exit;
  if EndPos > Length(LineText) + 1 then
    EndPos := Length(LineText) + 1;
  I := EndPos - 1;
  while (I >= 1) and (I <= Length(LineText)) and
    not (LineText[I] in [' ', #9, '(', ')', '[', ']', '{', '}', ';', ',', '.', ':', '>', '-', '+', '*', '/', '=', '!', '&', '|', '<']) do
    Dec(I);
  Result := Copy(LineText, I + 1, EndPos - I - 1);
end;

function TLspCompletionManager.TriggerCompletion: Boolean;
var
  LineText: string;
  Ch: Char;
begin
  Result := False;
  if not Assigned(FEditor) then
    Exit;
  if (FEditor.CaretY < 1) or (FEditor.CaretY > FEditor.Lines.Count) then
    Exit;
  LineText := FEditor.LineText;
  // 取光标前一个字符 (刚键入的字符), 而非光标处字符
  if (FEditor.CaretX > 1) and (FEditor.CaretX - 1 <= Length(LineText) + 1) and
    (FEditor.CaretX - 1 >= 1) and (FEditor.CaretX - 1 <= Length(LineText)) then
    Ch := LineText[FEditor.CaretX - 1]
  else
    Ch := #0;
  case Ch of
    '.', '>', ':':
      Result := TriggerCompletion(string(Ch));
  else
    Result := False;
  end;
end;

function TLspCompletionManager.TriggerCompletion(const ATriggerChar: string): Boolean;
begin
  // 显式触发字符一律放行; 空字符串表示 Ctrl+Space 强制触发, 由调用方决定
  RequestCompletion(ATriggerChar);
  Result := True;
end;

procedure TLspCompletionManager.RequestCompletion(const ATriggerChar: string);
var
  LspLine, LspChar, ReqId: Integer;
  ParamsJson, Request: string;
begin
  if not Assigned(FEditor) then
    Exit;
  if not Assigned(FTransport) then
    Exit;

  // FlushOnDemand: 先把编辑器脏文本同步给 clangd, 再发补全请求.
  // 否则用户刚敲的 `.` / 标识符还在防抖窗口内, 服务端拿旧文本补全会错位.
  // (try/except 隔离: 同步失败不阻塞补全请求本身)
  try
    LspFlushPendingDocument(FCurrentFile, FEditor.Lines.Text);
  except
  end;

  // 单调递增请求 ID (线程安全)
{$IFDEF FPC}
  ReqId := InterlockedIncrement(FNextRequestId);
{$ELSE}
  ReqId := TInterlocked.Increment(FNextRequestId);
{$ENDIF}

  FActiveRequestId := ReqId;
  FActiveContext.RequestId := ReqId;
  FActiveContext.TriggerChar := ATriggerChar;
  FActiveContext.FileName := FCurrentFile;
  FActiveContext.CaretLine := FEditor.CaretY;
  FActiveContext.CaretChar := FEditor.CaretX;

  // SynEdit 1-based -> LSP 0-based (UTF-16 code units)
  LspLine := FEditor.CaretY - 1;
  LspChar := FEditor.CaretX - 1;
  if LspLine < 0 then LspLine := 0;
  if LspChar < 0 then LspChar := 0;

  if ATriggerChar <> '' then
    ParamsJson := Format(
      '{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d},' +
      '"context":{"triggerKind":2,"triggerCharacter":"%s"}}',
      [PathToLspUri(FCurrentFile), LspLine, LspChar, ATriggerChar])
  else
    ParamsJson := Format(
      '{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d},' +
      '"context":{"triggerKind":1}}',
      [PathToLspUri(FCurrentFile), LspLine, LspChar]);

  Request := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"textDocument/completion","params":%s}',
    [ReqId, ParamsJson]);

  // 异步发送, 不阻塞 UI (Transport 内部负责 Content-Length 帧与写管道)
  FTransport.SendPayload(Request);
end;

procedure TLspCompletionManager.CancelPending;
begin
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.TriggerChar := '';
  FActiveContext.FileName := '';
  FActiveContext.CaretLine := 0;
  FActiveContext.CaretChar := 0;
end;

procedure TLspCompletionManager.EditorDestroyed(AEditor: TCustomSynEdit);
begin
  if not Assigned(AEditor) or (FEditor <> AEditor) then
    Exit;
  CancelPending;
  if Assigned(FProposal) then
  try
    FProposal.CancelCompletion;
  except
  end;
  SetEditor(nil);
end;

function TLspCompletionManager.ExtractRequestId(const AJson: string): Integer;
var
  P: Integer;
  Neg: Boolean;
  Num: string;
begin
  Result := -1;
  if not FindJsonFieldColon(AJson, 'id', P) then
    Exit;
  // id 可能是数字或字符串形式的数字
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

procedure TLspCompletionManager.HandleTransportMessage(const AMessage: string);
var
  ReqId: Integer;
  List: TLspCompletionList;
begin
  if AMessage = '' then
    Exit;
  // 仅处理 completion 响应: 必须带 id, 且与当前活跃请求一致
  ReqId := ExtractRequestId(AMessage);
  if (ReqId < 0) or (ReqId <> FActiveRequestId) then
    Exit; // 过期/无关响应, 直接丢弃 (防乱序覆盖)
  if Pos('textDocument/completion', AMessage) > 0 then
    Exit; // 这是请求回显而非响应, 忽略

  if not ParseCompletionResponse(AMessage, List) then
  begin
    // 空结果也属有效响应: 若之前弹窗开着, 让 UI 线程关闭? 这里仅记录
    FIsIncomplete := List.IsIncomplete;
    Exit;
  end;
  FIsIncomplete := List.IsIncomplete;

  // 切到 UI 线程再碰编辑器/弹窗 (Transport 读线程回调禁止直接操作 VCL)
  TThread.Queue(nil,
    procedure
    begin
      ProcessResponseOnUIThread(AMessage, ReqId);
    end);
end;

procedure TLspCompletionManager.ProcessResponseOnUIThread(const AMessage: string;
  AReqId: Integer);
var
  List: TLspCompletionList;
  I: Integer;
begin
  // 双重检查: 排队期间可能已有更新的请求发出
  if AReqId <> FActiveRequestId then
    Exit;
  if not Assigned(FEditor) then
    Exit;
  // 光标已离开触发行则不再弹窗 (用户已继续输入/移动)
  if (FEditor.CaretY <> FActiveContext.CaretLine) and (FActiveContext.CaretLine > 0) then
    Exit;
  if not ParseCompletionResponse(AMessage, List) then
    Exit;
  FIsIncomplete := List.IsIncomplete;

  FItems.Clear;
  for I := Low(List.Items) to High(List.Items) do
    FItems.Add(List.Items[I]);

  if FItems.Count = 0 then
    Exit;
  FillProposalAndShow(FItems.ToArray, List.IsIncomplete);

  if Assigned(FOnCompletion) then
    FOnCompletion(Self);
end;

procedure TLspCompletionManager.FillProposalAndShow(
  const AItems: TArray<TLspCompletionItem>; AIsIncomplete: Boolean);
var
  I: Integer;
  Disp: string;
begin
  if not Assigned(FProposal) or not Assigned(FEditor) then
    Exit;
  FProposal.ItemList.BeginUpdate;
  FProposal.InsertList.BeginUpdate;
  try
    FProposal.ItemList.Clear;
    FProposal.InsertList.Clear;
    for I := Low(AItems) to High(AItems) do
    begin
      Disp := AItems[I].DisplayLabel;
      if AItems[I].Detail <> '' then
        Disp := Disp + '  --  ' + AItems[I].Detail;
      FProposal.ItemList.Add(Disp);
      // InsertList 供默认插入路径使用; textEdit 精确替换走 OnCodeCompletion
      FProposal.InsertList.Add(AItems[I].GetEffectiveText);
    end;
  finally
    FProposal.InsertList.EndUpdate;
    FProposal.ItemList.EndUpdate;
  end;
  // isIncomplete=true: 保持弹窗的客户端过滤, 用户继续输入时由调用方
  // 用 30-50ms 防抖重新 RequestCompletion (Editor 侧实现)
  FIsIncomplete := AIsIncomplete;
  try
    FProposal.ActivateCompletion;
  except
    // 弹窗失败不应抛到 LSP 线程
  end;
end;

// OnExecute: 弹窗前最后把关; 若列表为空则取消弹窗
procedure TLspCompletionManager.ProposalExecute(Kind: SynCompletionType;
  Sender: TObject; var CurrentInput: string; var x, y: Integer;
  var CanExecute: Boolean);
begin
  CanExecute := Assigned(FItems) and (FItems.Count > 0) and Assigned(FEditor);
end;

// OnCodeCompletion: 用户确认选项 (Enter/Tab/双击) 时触发.
// Index 已是物理索引 (原始 Items 下标), 可直接取 FItems[Index].
// textEdit 优先做精确范围替换, 并把 Value 置空以抑制默认的二次插入.
procedure TLspCompletionManager.ProposalCodeCompletion(Sender: TObject;
  var Value: string; Shift: TShiftState; Index: Integer; EndToken: WideChar);
var
  Item: TLspCompletionItem;
  Ed: TCustomSynEdit;
  StartB, EndB: TBufferCoord;
  NewText: string;
begin
  if not Assigned(FItems) then
    Exit;
  if (Index < 0) or (Index >= FItems.Count) then
    Exit;
  Ed := FEditor;
  if not Assigned(Ed) then
    Exit;
  Item := FItems[Index];

  if Item.TextEdit.HasEdit then
  begin
    NewText := StripSnippetPlaceholders(Item.TextEdit.NewText);
    StartB.Line := Item.TextEdit.StartLine + 1;
    StartB.Char := Item.TextEdit.StartChar + 1;
    EndB.Line := Item.TextEdit.EndLine + 1;
    EndB.Char := Item.TextEdit.EndChar + 1;
    // 钳位到合法范围
    if StartB.Line < 1 then StartB.Line := 1;
    if EndB.Line < 1 then EndB.Line := 1;
    if StartB.Line > Ed.Lines.Count then StartB.Line := Ed.Lines.Count;
    if EndB.Line > Ed.Lines.Count then EndB.Line := Ed.Lines.Count;
    if StartB.Char < 1 then StartB.Char := 1;
    if EndB.Char < 1 then EndB.Char := 1;

    Ed.BeginUndoBlock;
    try
      Ed.BlockBegin := StartB;
      Ed.BlockEnd := EndB;
      Ed.SelText := NewText;
      // 替换后显式坍缩选区, 把光标放到插入末尾.
      // 必须同时收拢 BlockBegin/BlockEnd, 否则外层 HandleOnValidate
      // 的 `if SelText <> Value then SelText := Value` 会二次插入/删除.
      try
        Ed.CaretXY := BufferCoord(StartB.Char + Length(NewText), StartB.Line);
      except
      end;
      try
        Ed.BlockBegin := Ed.CaretXY;
        Ed.BlockEnd := Ed.CaretXY;
      except
      end;
    finally
      Ed.EndUndoBlock;
    end;
    // 已手动落子: 置空 Value 让外层 HandleOnValidate 不再二次插入
    // (此时选区已坍缩, SelText='' , Value='' 使条件为 False)
    Value := '';
  end
  else
  begin
    // 无 textEdit: 用有效文本走默认单词替换路径
    Value := Item.GetEffectiveText;
  end;
end;

function TLspCompletionManager.GetItems: TArray<TLspCompletionItem>;
begin
  if Assigned(FItems) then
    Result := FItems.ToArray
  else
    SetLength(Result, 0);
end;

procedure TLspCompletionManager.ApplyItemWithRange(const AItem: TLspCompletionItem);
var
  Ed: TCustomSynEdit;
  StartB, EndB: TBufferCoord;
  NewText: string;
begin
  Ed := FEditor;
  if not Assigned(Ed) then
    Exit;
  NewText := AItem.GetEffectiveText;
  Ed.BeginUndoBlock;
  try
    if AItem.TextEdit.HasEdit then
    begin
      StartB.Line := AItem.TextEdit.StartLine + 1;
      StartB.Char := AItem.TextEdit.StartChar + 1;
      EndB.Line := AItem.TextEdit.EndLine + 1;
      EndB.Char := AItem.TextEdit.EndChar + 1;
      if StartB.Line < 1 then StartB.Line := 1;
      if EndB.Line < 1 then EndB.Line := 1;
      if StartB.Char < 1 then StartB.Char := 1;
      if EndB.Char < 1 then EndB.Char := 1;
      Ed.BlockBegin := StartB;
      Ed.BlockEnd := EndB;
      NewText := StripSnippetPlaceholders(NewText);
      Ed.SelText := NewText;
      try
        Ed.CaretXY := BufferCoord(StartB.Char + Length(NewText), StartB.Line);
        Ed.BlockBegin := Ed.CaretXY;
        Ed.BlockEnd := Ed.CaretXY;
      except
        // 忽略光标钳位异常
      end;
    end
    else
      Ed.SelText := NewText;
  finally
    Ed.EndUndoBlock;
  end;
end;

// 解析 {"result":{"items":[...],"isIncomplete":false}} 或 {"result":[...]}
function TLspCompletionManager.ParseCompletionResponse(const AJson: string;
  out AItems: TLspCompletionList): Boolean;
var
  ArrContent: string;
  HasArr: Boolean;
  I, Depth: Integer;
  InStr: Boolean;
  ObjStart: Integer;
  ObjStr: string;
  Item: TLspCompletionItem;
  Tmp: TList<TLspCompletionItem>;
  B: Boolean;
begin
  Result := False;
  SetLength(AItems.Items, 0);
  AItems.IsIncomplete := False;

  if FindJsonBoolField(AJson, 'isIncomplete', B) then
    AItems.IsIncomplete := B
  else if Pos('"isIncomplete":true', AJson) > 0 then
    AItems.IsIncomplete := True;

  HasArr := ExtractJsonArrayContent(AJson, 'items', ArrContent);
  if not HasArr then
  begin
    // 兼容 bare-array: "result": [ ... ]
    HasArr := ExtractJsonArrayContent(AJson, 'result', ArrContent);
    if not HasArr then
      Exit;
  end;

  Tmp := TList<TLspCompletionItem>.Create;
  try
    I := 1;
    while I <= Length(ArrContent) do
    begin
      // 跳过空白/逗号
      while (I <= Length(ArrContent)) and (ArrContent[I] in [' ', #9, #10, #13, ',']) do
        Inc(I);
      if I > Length(ArrContent) then
        Break;
      if ArrContent[I] <> '{' then
      begin
        Inc(I);
        Continue;
      end;
      ObjStart := I;
      Depth := 0;
      InStr := False;
      while I <= Length(ArrContent) do
      begin
        if InStr then
        begin
          if ArrContent[I] = '\' then
            Inc(I)
          else if ArrContent[I] = '"' then
            InStr := False;
        end
        else
        begin
          if ArrContent[I] = '"' then
            InStr := True
          else if ArrContent[I] = '{' then
            Inc(Depth)
          else if ArrContent[I] = '}' then
          begin
            Dec(Depth);
            if Depth = 0 then
            begin
              ObjStr := Copy(ArrContent, ObjStart, I - ObjStart + 1);
              if ParseSingleItem(ObjStr, Item) then
                Tmp.Add(Item);
              Inc(I);
              Break;
            end;
          end;
        end;
        Inc(I);
      end;
    end;
    AItems.Items := Tmp.ToArray;
    Result := Length(AItems.Items) > 0;
  finally
    Tmp.Free;
  end;
end;

function TLspCompletionManager.ParseSingleItem(const AItemJson: string;
  out AItem: TLspCompletionItem): Boolean;
var
  S, EditObj, RangeObj, StartObj, EndObj, DocObj: string;
  N: Integer;
begin
  Result := False;
  // record 默认初始化 (托管类型不可 FillChar)
  AItem.DisplayLabel := '';
  AItem.Kind := 0;
  AItem.Detail := '';
  AItem.Documentation := '';
  AItem.InsertText := '';
  AItem.SortText := '';
  AItem.FilterText := '';
  AItem.TextEdit.HasEdit := False;
  AItem.TextEdit.StartLine := 0;
  AItem.TextEdit.StartChar := 0;
  AItem.TextEdit.EndLine := 0;
  AItem.TextEdit.EndChar := 0;
  AItem.TextEdit.NewText := '';

  if not FindJsonStringField(AItemJson, 'label', S) then
    Exit;
  AItem.DisplayLabel := S;

  if FindJsonIntField(AItemJson, 'kind', N) then
    AItem.Kind := N;
  if FindJsonStringField(AItemJson, 'detail', S) then
    AItem.Detail := S;
  // documentation 可能是字符串或 {kind,value} 对象
  if FindJsonStringField(AItemJson, 'documentation', S) then
    AItem.Documentation := S
  else if ExtractJsonObject(AItemJson, 'documentation', DocObj) then
  begin
    if FindJsonStringField(DocObj, 'value', S) then
      AItem.Documentation := S;
  end;
  if FindJsonStringField(AItemJson, 'insertText', S) then
    AItem.InsertText := S;
  if FindJsonStringField(AItemJson, 'sortText', S) then
    AItem.SortText := S;
  if FindJsonStringField(AItemJson, 'filterText', S) then
    AItem.FilterText := S
  else
    AItem.FilterText := AItem.DisplayLabel;

  // textEdit (优先级最高)
  if ExtractJsonObject(AItemJson, 'textEdit', EditObj) then
  begin
    AItem.TextEdit.HasEdit := True;
    if FindJsonStringField(EditObj, 'newText', S) then
      AItem.TextEdit.NewText := S;
    if ExtractJsonObject(EditObj, 'range', RangeObj) then
    begin
      if ExtractJsonObject(RangeObj, 'start', StartObj) then
      begin
        FindJsonIntField(StartObj, 'line', AItem.TextEdit.StartLine);
        FindJsonIntField(StartObj, 'character', AItem.TextEdit.StartChar);
      end;
      if ExtractJsonObject(RangeObj, 'end', EndObj) then
      begin
        FindJsonIntField(EndObj, 'line', AItem.TextEdit.EndLine);
        FindJsonIntField(EndObj, 'character', AItem.TextEdit.EndChar);
      end;
    end
    else
    begin
      // 兼容 insertReplaceEdit: 直接含 insert/replace, 取 replace 为准
      // (若无 range 则保持 HasEdit 但范围为 0, 调用方回退到单词替换)
    end;
  end;

  Result := AItem.DisplayLabel <> '';
end;

// 全局初始化
procedure InitializeLspCompletion(AEditor: TCustomSynEdit; ATransport: TLspTransport);
begin
  if not Assigned(LspCompletionManager) then
    LspCompletionManager := TLspCompletionManager.Create(AEditor, ATransport)
  else
  begin
    LspCompletionManager.SetEditor(AEditor);
    LspCompletionManager.SetTransport(ATransport);
  end;
end;

procedure EnsureLspCompletionCreated;
begin
  if not Assigned(LspCompletionManager) then
    LspCompletionManager := TLspCompletionManager.Create(nil, nil);
end;

initialization
  LspCompletionManager := nil;

finalization
  if Assigned(LspCompletionManager) then
    FreeAndNil(LspCompletionManager);

end.
