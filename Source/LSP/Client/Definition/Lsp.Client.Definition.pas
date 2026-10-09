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

unit LSP.Client.Definition;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections, SyncObjs, Windows,
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections, System.SyncObjs,
  {$ENDIF}
  {$IFDEF FPC}
  Lsp.Transport, Lsp.DocumentSync,
  {$ELSE}
  LSP.Transport, Lsp.DocumentSync,
  {$ENDIF}
  Lsp.Editor.Types, Lsp.Editor.Interfaces;

// 跳转目标 (Location / LocationLink 归一化)
type
  TLspLocation = record
    Uri: string;
    FilePath: string; // 本地路径 (URI 解码后)
    StartLine: Integer; // 0-based
    StartChar: Integer; // 0-based
    EndLine: Integer;
    EndChar: Integer;
    IsLink: Boolean; // True=来自 LocationLink(targetUri)
  end;

// 导航回调 (由 main.pas 实现并挂接, 避免本单元依赖主窗体形成 uses 环)
  TLspNavigateEvent = procedure(const AFileName: string; ALine, AChar: Integer) of object;

// 请求上下文
  TLspDefinitionRequestContext = record
    RequestId: Integer;
    FileName: string;
    Line: Integer; // 0-based
    Char: Integer; // 0-based
  end;

// 跳转管理器: 异步、无阻塞、按请求 ID 丢弃过期响应
// 多目标取首个 (后续可扩展选择器); null 结果走 OnNoResult 回退旧 parser 跳转
  TLspDefinitionManager = class
  private
    FEditor: IEditorControlAdapter;
    FTransport: TLspTransport;
    FCurrentFile: string;
    FOnNavigate: TLspNavigateEvent;
    FOnNoResult: TNotifyEvent;
    FNextRequestId: Integer;
    FActiveRequestId: Integer;
    FActiveContext: TLspDefinitionRequestContext;
    FLastLocations: TArray<TLspLocation>;
    procedure HandleTransportMessage(const AMessage: string);
    procedure ProcessResponseOnUIThread(const AMessage: string; AReqId: Integer);
    procedure DoNoResult(AReqId: Integer);
    function ExtractRequestId(const AJson: string): Integer;
    function ParseDefinitionResponse(const AJson: string;
      out ALocations: TArray<TLspLocation>): Boolean;
    function ParseLocationObject(const AObj: string;
      out ALoc: TLspLocation): Boolean;
    function ParseRangeObject(const ARangeObj: string;
      out ASLine, ASChar, AELine, AEChar: Integer): Boolean;
    function PathToLspUri(const AFileName: string): string;
    function LspUriToPath(const AUri: string): string;
  public
    constructor Create(const AEditor: IEditorControlAdapter;
      ATransport: TLspTransport);
    destructor Destroy; override;

    procedure SetEditor(const AEditor: IEditorControlAdapter);
    procedure SetTransport(ATransport: TLspTransport);
    procedure SetCurrentFile(const AFileName: string);
    // 编辑器析构前调用: 作废在途请求、清除回调、摘除悬空引用
    procedure EditorDestroyed(const AEditor: IEditorControlAdapter);

    function IsServiceReady: Boolean;
    // ALine/AChar 均为 0-based. 返回 False=服务不可用, 调用方走同步回退
    function RequestDefinition(ALine, AChar: Integer): Boolean;
    function GetLastLocations: TArray<TLspLocation>;

    property OnNavigate: TLspNavigateEvent read FOnNavigate write FOnNavigate;
    property OnNoResult: TNotifyEvent read FOnNoResult write FOnNoResult;
    property CurrentFile: string read FCurrentFile write SetCurrentFile;
  end;

// 全局跳转管理器 (延迟创建)
var
  LspDefinitionManager: TLspDefinitionManager;

procedure InitializeLspDefinition(const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
procedure EnsureLspDefinitionCreated;

implementation

// ---------- 独立 JSON 小工具 (与补全/签名/悬停同构) ----------

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

{ TLspDefinitionManager }

constructor TLspDefinitionManager.Create(
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
  SetLength(FLastLocations, 0);
  SetEditor(AEditor);
  SetTransport(ATransport);
end;

destructor TLspDefinitionManager.Destroy;
begin
  FActiveRequestId := -1;
  if Assigned(FTransport) then
  try
    FTransport.UnsubscribeMessage(HandleTransportMessage);
  except
  end;
  FOnNavigate := nil;
  FOnNoResult := nil;
  inherited;
end;

procedure TLspDefinitionManager.SetEditor(
  const AEditor: IEditorControlAdapter);
begin
  FEditor := AEditor;
end;

procedure TLspDefinitionManager.SetTransport(ATransport: TLspTransport);
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

procedure TLspDefinitionManager.SetCurrentFile(const AFileName: string);
begin
  FCurrentFile := AFileName;
end;

procedure TLspDefinitionManager.EditorDestroyed(
  const AEditor: IEditorControlAdapter);
begin
  // 作废在途请求 + 清除可能悬空的编辑器方法回调 + 摘除引用
  FActiveRequestId := -1;
  FActiveContext.RequestId := -1;
  FActiveContext.FileName := '';
  FActiveContext.Line := 0;
  FActiveContext.Char := 0;
  // Interface equality below compares the interface POINTER (VMT + Self),
  // not the underlying object. It is correct here only because the caller
  // passes the very interface value TEditor cached -- see
  // TEditor.GetAdapter. If that cache is ever removed and adapters start
  // being built per call, this comparison silently turns False and the
  // teardown never fires. Do not 'simplify' the caching.
  FOnNoResult := nil;
  if FEditor = AEditor then
    FEditor := nil;
end;

function TLspDefinitionManager.IsServiceReady: Boolean;
begin
  Result := Assigned(FTransport) and (FTransport.State = tsReady);
end;

function TLspDefinitionManager.PathToLspUri(const AFileName: string): string;
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

function TLspDefinitionManager.LspUriToPath(const AUri: string): string;
var
  P: string;
  Raw: UTF8String;
  I, Code: Integer;
  Hex: string;
begin
  P := Trim(AUri);
  if Pos('file://', LowerCase(P)) = 1 then
    Delete(P, 1, Length('file://'));
  // %XX 按字节累积后再整体 UTF-8 解码 (中文路径在 URI 中是多字节 %E4%B8%AD 形式,
  // 若逐字节 Char() 会产生孤立宽字符乱码 —— 与发送侧同类的编码陷阱)
  Raw := '';
  I := 1;
  while I <= Length(P) do
  begin
    if (P[I] = '%') and (I + 2 <= Length(P)) then
    begin
      Hex := Copy(P, I + 1, 2);
      Code := StrToIntDef('$' + Hex, -1);
      if (Code >= 0) and (Code <= 255) then
      begin
        Raw := Raw + AnsiChar(Code);
        Inc(I, 3);
        Continue;
      end;
    end;
    if Ord(P[I]) < 128 then
      Raw := Raw + AnsiChar(Ord(P[I]))
    else
      Raw := Raw + UTF8String(P[I]);
    Inc(I);
  end;
  Result := string(Raw);
  // file:///D:/x -> D:/x (Windows 盘符)
  if (Length(Result) >= 3) and (Result[1] = '/') and (Result[3] = ':') and
    (UpCase(Result[2]) in ['A'..'Z']) then
    Delete(Result, 1, 1);
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
end;

function TLspDefinitionManager.RequestDefinition(ALine, AChar: Integer): Boolean;
var
  ReqId: Integer;
  ParamsJson, Request: string;
begin
  Result := False;
  if not Assigned(FEditor) then
    Exit;
  if not IsServiceReady then
    Exit;

  if ALine < 0 then ALine := 0;
  if AChar < 0 then AChar := 0;

  // FlushOnDemand: 保证 clangd 按最新文本定位符号
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
    '{"jsonrpc":"2.0","id":%d,"method":"textDocument/definition","params":%s}',
    [ReqId, ParamsJson]);
  FTransport.SendPayload(Request);
  Result := True;
end;

function TLspDefinitionManager.GetLastLocations: TArray<TLspLocation>;
begin
  Result := Copy(FLastLocations, 0, Length(FLastLocations));
end;

function TLspDefinitionManager.ExtractRequestId(const AJson: string): Integer;
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

procedure TLspDefinitionManager.HandleTransportMessage(const AMessage: string);
var
  ReqId: Integer;
  Locs: TArray<TLspLocation>;
begin
  if AMessage = '' then
    Exit;
  if Pos('"method"', AMessage) > 0 then
    Exit;
  ReqId := ExtractRequestId(AMessage);
  if (ReqId < 0) or (ReqId <> FActiveRequestId) then
    Exit;
  if not ParseDefinitionResponse(AMessage, Locs) or (Length(Locs) = 0) then
  begin
    // null / 空结果: 回退旧 parser 跳转 (调用方挂接 OnNoResult)
    TThread.Queue(nil,
      procedure
      begin
        DoNoResult(ReqId);
      end);
    Exit;
  end;
  TThread.Queue(nil,
    procedure
    begin
      ProcessResponseOnUIThread(AMessage, ReqId);
    end);
end;

procedure TLspDefinitionManager.DoNoResult(AReqId: Integer);
begin
  if AReqId <> FActiveRequestId then
    Exit;
  FActiveRequestId := -1;
  if Assigned(FOnNoResult) then
  try
    FOnNoResult(Self);
  except
  end;
end;

procedure TLspDefinitionManager.ProcessResponseOnUIThread(const AMessage: string;
  AReqId: Integer);
var
  Locs: TArray<TLspLocation>;
begin
  if AReqId <> FActiveRequestId then
    Exit;
  FActiveRequestId := -1;
  if not ParseDefinitionResponse(AMessage, Locs) or (Length(Locs) = 0) then
  begin
    DoNoResult(AReqId);
    Exit;
  end;
  FLastLocations := Copy(Locs, 0, Length(Locs));
  // 多目标取首个 (后续可扩展选择器); 坐标已是 0-based, 回调方转 1-based
  if Assigned(FOnNavigate) then
  try
    FOnNavigate(Locs[0].FilePath, Locs[0].StartLine, Locs[0].StartChar);
  except
  end;
end;

// 响应四形态: null | Location | Location[] | LocationLink[]
function TLspDefinitionManager.ParseDefinitionResponse(const AJson: string;
  out ALocations: TArray<TLspLocation>): Boolean;
var
  ResultObj, ArrContent: string;
  RawItems: TArray<string>;
  List: TList<TLspLocation>;
  Loc: TLspLocation;
  I: Integer;
  Tok: string;
begin
  Result := False;
  SetLength(ALocations, 0);
  if Pos('"result":null', AJson) > 0 then
    Exit;
  List := TList<TLspLocation>.Create;
  try
    if ExtractJsonObject(AJson, 'result', ResultObj) then
    begin
      // 单个 Location 或 LocationLink
      if ParseLocationObject(ResultObj, Loc) then
        List.Add(Loc);
    end
    else if ExtractJsonArrayContent(AJson, 'result', ArrContent) then
    begin
      RawItems := SplitTopLevelItems(ArrContent);
      for I := Low(RawItems) to High(RawItems) do
      begin
        Tok := Trim(RawItems[I]);
        if (Tok <> '') and (Tok[1] = '{') then
          if ParseLocationObject(Tok, Loc) then
            List.Add(Loc);
      end;
    end
    else
      Exit;
    if List.Count = 0 then
      Exit;
    ALocations := List.ToArray;
    Result := True;
  finally
    List.Free;
  end;
end;

function TLspDefinitionManager.ParseLocationObject(const AObj: string;
  out ALoc: TLspLocation): Boolean;
var
  S, RangeObj: string;
begin
  Result := False;
  ALoc.Uri := '';
  ALoc.FilePath := '';
  ALoc.StartLine := 0;
  ALoc.StartChar := 0;
  ALoc.EndLine := 0;
  ALoc.EndChar := 0;
  ALoc.IsLink := False;

  // LocationLink 优先 (targetUri + targetSelectionRange ?? targetRange)
  if FindJsonStringField(AObj, 'targetUri', S) then
  begin
    ALoc.Uri := S;
    ALoc.IsLink := True;
    if ExtractJsonObject(AObj, 'targetSelectionRange', RangeObj) or
      ExtractJsonObject(AObj, 'targetRange', RangeObj) then
      ParseRangeObject(RangeObj, ALoc.StartLine, ALoc.StartChar,
        ALoc.EndLine, ALoc.EndChar);
  end
  else if FindJsonStringField(AObj, 'uri', S) then
  begin
    ALoc.Uri := S;
    if ExtractJsonObject(AObj, 'range', RangeObj) then
      ParseRangeObject(RangeObj, ALoc.StartLine, ALoc.StartChar,
        ALoc.EndLine, ALoc.EndChar);
  end
  else
    Exit;

  ALoc.FilePath := LspUriToPath(ALoc.Uri);
  Result := ALoc.FilePath <> '';
end;

function TLspDefinitionManager.ParseRangeObject(const ARangeObj: string;
  out ASLine, ASChar, AELine, AEChar: Integer): Boolean;
var
  StartObj, EndObj: string;
begin
  ASLine := 0;
  ASChar := 0;
  AELine := 0;
  AEChar := 0;
  Result := False;
  if ExtractJsonObject(ARangeObj, 'start', StartObj) then
  begin
    FindJsonIntField(StartObj, 'line', ASLine);
    FindJsonIntField(StartObj, 'character', ASChar);
    Result := True;
  end;
  if ExtractJsonObject(ARangeObj, 'end', EndObj) then
  begin
    FindJsonIntField(EndObj, 'line', AELine);
    FindJsonIntField(EndObj, 'character', AEChar);
  end;
end;

// 全局初始化
procedure InitializeLspDefinition(const AEditor: IEditorControlAdapter;
  ATransport: TLspTransport);
begin
  if not Assigned(LspDefinitionManager) then
    LspDefinitionManager := TLspDefinitionManager.Create(AEditor, ATransport)
  else
  begin
    LspDefinitionManager.SetEditor(AEditor);
    LspDefinitionManager.SetTransport(ATransport);
  end;
end;

procedure EnsureLspDefinitionCreated;
begin
  if not Assigned(LspDefinitionManager) then
    LspDefinitionManager := TLspDefinitionManager.Create(nil, nil);
end;

initialization
  LspDefinitionManager := nil;

finalization
  if Assigned(LspDefinitionManager) then
    FreeAndNil(LspDefinitionManager);

end.
