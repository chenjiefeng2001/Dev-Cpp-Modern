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

unit Lsp.DocumentSync;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Vcl.ExtCtrls,
  LSP.Transport;

// 文档同步策略: 第一阶段全量文本 (TextDocumentSyncKind.Full=1),
// 稳定可靠; 增量同步作为后续优化
const
  LSP_SYNC_DEBOUNCE_MS = 250;

// 被跟踪的单个打开文档
type
  TTrackedDoc = class
  public
    FileName: string;    // 原始大小写 (显示/调试用)
    Uri: string;
    LanguageId: string;  // "c" / "cpp"
    Version: Integer;    // 已发送给服务端的最新版本
    OpenedSent: Boolean; // didOpen 是否已送达
    LastSentText: string;
    PendingText: string; // 待发送的最新文本
    Dirty: Boolean;
    constructor Create(const AFileName, AUri, ALangId, AText: string);
  end;

// 文档同步管理器: didOpen/didChange/didClose/didSave + 防抖 + 按需冲刷
  TLspDocumentSyncManager = class
  private
    FDocs: TObjectDictionary<string, TTrackedDoc>;
    FTransport: TLspTransport;
    FDebounce: TTimer;
    function NormalizeKey(const AFileName: string): string;
    function FindDoc(const AFileName: string): TTrackedDoc;
    function TransportReady: Boolean;
    function SendNotify(const AMethod, AParams: string): Boolean;
    procedure DebounceFired(Sender: TObject);
    procedure SendDidOpen(ADoc: TTrackedDoc);
    procedure SendDidChange(ADoc: TTrackedDoc; const AText: string);
    procedure SendDidClose(ADoc: TTrackedDoc);
    procedure SendDidSave(ADoc: TTrackedDoc);
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetTransport(ATransport: TLspTransport);

    function IsCppFile(const AFileName: string): Boolean;
    function LanguageIdOf(const AFileName: string): string;
    function PathToLspUri(const AFileName: string): string;
    function EscapeJsonString(const S: string): string;

    // 生命周期 (Editor 侧调用; transport 未就绪时仅记录状态)
    procedure DidOpenFile(const AFileName, AText: string);
    procedure DidCloseFile(const AFileName: string);
    procedure DidSaveFile(const AFileName, AText: string);
    // 每次文本变更调用 (Editor.OnChange); 250ms 防抖后批量发送
    procedure NotifyChanged(const AFileName, AText: string);
    // 请求前即时冲刷: 有脏数据立刻发送, 返回 True=已与服务端一致
    function FlushFile(const AFileName, AText: string): Boolean;
    procedure FlushAll;
    // 传输就绪后调用: 把已跟踪的打开文档补发 didOpen
    procedure ResyncAll;
    function TrackedCount: Integer;
  end;

// 全局单例 (延迟创建; Destroy 路径请用 Assigned(LspDocumentSyncManager) 判空,
// 避免在编辑器析构时无谓创建)
var
  LspDocumentSyncManager: TLspDocumentSyncManager;

function LspDocSync: TLspDocumentSyncManager;
procedure EnsureLspDocSyncCreated;
// Completion/SignatureHelp 在 Request 前调用: 先冲刷脏文本再发请求
function LspFlushPendingDocument(const AFileName, AText: string): Boolean;

implementation

{ TTrackedDoc }

constructor TTrackedDoc.Create(const AFileName, AUri, ALangId, AText: string);
begin
  inherited Create;
  FileName := AFileName;
  Uri := AUri;
  LanguageId := ALangId;
  Version := 1;
  OpenedSent := False;
  LastSentText := '';
  PendingText := AText;
  Dirty := True; // 新跟踪文档视为脏, 首次 flush 时发送
end;

{ TLspDocumentSyncManager }

constructor TLspDocumentSyncManager.Create;
begin
  inherited Create;
  FDocs := TObjectDictionary<string, TTrackedDoc>.Create([doOwnsValues]);
  // 注意: 本对象必须在主线程创建 (TTimer 依赖消息循环)
  FDebounce := TTimer.Create(nil);
  FDebounce.Enabled := False;
  FDebounce.Interval := LSP_SYNC_DEBOUNCE_MS;
  FDebounce.OnTimer := DebounceFired;
end;

destructor TLspDocumentSyncManager.Destroy;
begin
  if Assigned(FDebounce) then
  begin
    FDebounce.Enabled := False;
    FreeAndNil(FDebounce);
  end;
  FreeAndNil(FDocs);
  inherited;
end;

procedure TLspDocumentSyncManager.SetTransport(ATransport: TLspTransport);
begin
  FTransport := ATransport;
end;

function TLspDocumentSyncManager.NormalizeKey(const AFileName: string): string;
begin
  Result := LowerCase(Trim(AFileName));
end;

function TLspDocumentSyncManager.FindDoc(const AFileName: string): TTrackedDoc;
begin
  if Assigned(FDocs) and FDocs.TryGetValue(NormalizeKey(AFileName), Result) then
  begin
    // found
  end
  else
    Result := nil;
end;

function TLspDocumentSyncManager.TransportReady: Boolean;
begin
  Result := Assigned(FTransport) and (FTransport.State = tsReady);
end;

function TLspDocumentSyncManager.IsCppFile(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Trim(AFileName)));
  Result := (Ext = '.c') or (Ext = '.h') or (Ext = '.cpp') or (Ext = '.hpp') or
    (Ext = '.cc') or (Ext = '.cxx') or (Ext = '.hh') or (Ext = '.hxx') or
    (Ext = '.c++') or (Ext = '.cp') or (Ext = '.cppm') or (Ext = '.ixx');
end;

function TLspDocumentSyncManager.LanguageIdOf(const AFileName: string): string;
begin
  if LowerCase(ExtractFileExt(Trim(AFileName))) = '.c' then
    Result := 'c'
  else
    Result := 'cpp';
end;

function TLspDocumentSyncManager.PathToLspUri(const AFileName: string): string;
var
  P: string;
begin
  P := Trim(AFileName);
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

function TLspDocumentSyncManager.EscapeJsonString(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: ; // CRLF 中的 CR 跳过, 统一由 #10 产生 \n
    else
      if C < #32 then
        Result := Result + Format('\u%.4x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
end;

function TLspDocumentSyncManager.SendNotify(const AMethod,
  AParams: string): Boolean;
begin
  Result := False;
  if not TransportReady then
    Exit;
  try
    Result := FTransport.SendNotification(AMethod, AParams);
  except
    Result := False;
  end;
end;

procedure TLspDocumentSyncManager.DidOpenFile(const AFileName, AText: string);
var
  Key: string;
  Doc: TTrackedDoc;
begin
  if Trim(AFileName) = '' then
    Exit;
  if not IsCppFile(AFileName) then
    Exit;
  Key := NormalizeKey(AFileName);
  if not FDocs.TryGetValue(Key, Doc) then
  begin
    Doc := TTrackedDoc.Create(Trim(AFileName), PathToLspUri(AFileName),
      LanguageIdOf(AFileName), AText);
    FDocs.Add(Key, Doc);
  end
  else
  begin
    // 已跟踪 (如 Create 末尾的显式 didOpen 撞见 OnChange 提前建的记录):
    // 文本与已发送一致则直接消脏, 否则标记脏走防抖
    if Doc.OpenedSent and (AText = Doc.LastSentText) then
    begin
      Doc.PendingText := AText;
      Doc.Dirty := False;
    end
    else if AText <> Doc.PendingText then
    begin
      Doc.PendingText := AText;
      Doc.Dirty := True;
      if Assigned(FDebounce) then
      begin
        FDebounce.Enabled := False;
        FDebounce.Enabled := True;
      end;
    end;
  end;
  if TransportReady and not Doc.OpenedSent then
    SendDidOpen(Doc);
end;

procedure TLspDocumentSyncManager.DidCloseFile(const AFileName: string);
var
  Key: string;
  Doc: TTrackedDoc;
begin
  if Trim(AFileName) = '' then
    Exit;
  Key := NormalizeKey(AFileName);
  if not FDocs.TryGetValue(Key, Doc) then
    Exit;
  if TransportReady and Doc.OpenedSent then
    SendDidClose(Doc);
  FDocs.Remove(Key);
end;

procedure TLspDocumentSyncManager.DidSaveFile(const AFileName, AText: string);
var
  Doc: TTrackedDoc;
begin
  if Trim(AFileName) = '' then
    Exit;
  if not IsCppFile(AFileName) then
    Exit;
  Doc := FindDoc(AFileName);
  if not Assigned(Doc) then
  begin
    DidOpenFile(AFileName, AText);
    Doc := FindDoc(AFileName);
    if not Assigned(Doc) then
      Exit;
  end;
  // 保存成功意味着落盘文本 == AText: 先把脏数据冲掉, 再发 didSave
  FlushFile(AFileName, AText);
  if TransportReady and Doc.OpenedSent then
    SendDidSave(Doc);
end;

procedure TLspDocumentSyncManager.NotifyChanged(const AFileName, AText: string);
var
  Doc: TTrackedDoc;
begin
  if Trim(AFileName) = '' then
    Exit;
  if not IsCppFile(AFileName) then
    Exit;
  Doc := FindDoc(AFileName);
  if not Assigned(Doc) then
  begin
    // OnChange 先于 didOpen 的竞态 (极少): 直接按打开处理
    DidOpenFile(AFileName, AText);
    Exit;
  end;
  if AText = Doc.PendingText then
    Exit; // 无实质变化 (如程序化刷新)
  Doc.PendingText := AText;
  Doc.Dirty := True;
  // 防抖: 250ms 无新变更才批量发送
  if Assigned(FDebounce) then
  begin
    FDebounce.Enabled := False;
    FDebounce.Enabled := True;
  end;
end;

function TLspDocumentSyncManager.FlushFile(const AFileName,
  AText: string): Boolean;
var
  Doc: TTrackedDoc;
begin
  Result := False;
  if Trim(AFileName) = '' then
    Exit;
  if not IsCppFile(AFileName) then
    Exit;
  Doc := FindDoc(AFileName);
  if not Assigned(Doc) then
  begin
    DidOpenFile(AFileName, AText);
    Doc := FindDoc(AFileName);
    if not Assigned(Doc) then
      Exit;
  end
  else
  begin
    // 调用方提供的是最新文本: 若与待发不一致则更新
    if AText <> Doc.PendingText then
    begin
      Doc.PendingText := AText;
      Doc.Dirty := True;
    end;
  end;
  if not TransportReady then
    Exit; // 记录已更新, 待 ResyncAll/就绪后补发
  if not Doc.OpenedSent then
  begin
    SendDidOpen(Doc);
    Result := True;
    Exit;
  end;
  if Doc.Dirty or (Doc.PendingText <> Doc.LastSentText) then
    SendDidChange(Doc, Doc.PendingText)
  else
    Result := True; // 已一致, 无需发送
  Result := not Doc.Dirty;
end;

procedure TLspDocumentSyncManager.FlushAll;
var
  Pair: TPair<string, TTrackedDoc>;
begin
  if not Assigned(FDocs) then
    Exit;
  for Pair in FDocs do
  begin
    if not Pair.Value.OpenedSent then
    begin
      if TransportReady then
        SendDidOpen(Pair.Value);
    end
    else if Pair.Value.Dirty then
      FlushFile(Pair.Value.FileName, Pair.Value.PendingText);
  end;
end;

procedure TLspDocumentSyncManager.ResyncAll;
var
  Pair: TPair<string, TTrackedDoc>;
begin
  // 传输刚就绪 (或重连): 所有已跟踪文档重发 didOpen (服务端无状态),
  // 版本重置为 1
  if not TransportReady then
    Exit;
  if not Assigned(FDocs) then
    Exit;
  for Pair in FDocs do
  begin
    Pair.Value.Version := 1;
    Pair.Value.OpenedSent := False;
    SendDidOpen(Pair.Value);
  end;
end;

function TLspDocumentSyncManager.TrackedCount: Integer;
begin
  if Assigned(FDocs) then
    Result := FDocs.Count
  else
    Result := 0;
end;

procedure TLspDocumentSyncManager.DebounceFired(Sender: TObject);
var
  Pair: TPair<string, TTrackedDoc>;
  AnyDirty: Boolean;
begin
  if Assigned(FDebounce) then
    FDebounce.Enabled := False;
  if not TransportReady then
    Exit; // 保持 Dirty, 待 ResyncAll
  if not Assigned(FDocs) then
    Exit;
  try
    AnyDirty := False;
    for Pair in FDocs do
    begin
      if not Pair.Value.OpenedSent then
        SendDidOpen(Pair.Value)
      else if Pair.Value.Dirty then
      begin
        SendDidChange(Pair.Value, Pair.Value.PendingText);
        AnyDirty := True;
      end;
    end;
    // 若发送期间又有新变更进来, Dirty 会被重新置位, 下轮继续
    if AnyDirty then
    begin
      // no-op, 下次 NotifyChanged 会重启 timer
    end;
  except
    // 定时器回调永不抛异常
  end;
end;

procedure TLspDocumentSyncManager.SendDidOpen(ADoc: TTrackedDoc);
var
  Params: string;
begin
  ADoc.Version := 1;
  Params := Format(
    '{"textDocument":{"uri":"%s","languageId":"%s","version":1,"text":"%s"}}',
    [ADoc.Uri, ADoc.LanguageId, EscapeJsonString(ADoc.PendingText)]);
  if SendNotify('textDocument/didOpen', Params) then
  begin
    ADoc.OpenedSent := True;
    ADoc.LastSentText := ADoc.PendingText;
    ADoc.Dirty := False;
  end;
end;

procedure TLspDocumentSyncManager.SendDidChange(ADoc: TTrackedDoc;
  const AText: string);
var
  Params: string;
begin
  Inc(ADoc.Version);
  Params := Format(
    '{"textDocument":{"uri":"%s","version":%d},"contentChanges":[{"text":"%s"}]}',
    [ADoc.Uri, ADoc.Version, EscapeJsonString(AText)]);
  if SendNotify('textDocument/didChange', Params) then
  begin
    ADoc.LastSentText := AText;
    ADoc.PendingText := AText;
    ADoc.Dirty := False;
  end
  else
  begin
    // 发送失败 (如管道瞬断): 版本回滚, 保持 Dirty 下次重试
    Dec(ADoc.Version);
    ADoc.PendingText := AText;
    ADoc.Dirty := True;
  end;
end;

procedure TLspDocumentSyncManager.SendDidClose(ADoc: TTrackedDoc);
var
  Params: string;
begin
  Params := Format('{"textDocument":{"uri":"%s"}}', [ADoc.Uri]);
  SendNotify('textDocument/didClose', Params);
end;

procedure TLspDocumentSyncManager.SendDidSave(ADoc: TTrackedDoc);
var
  Params: string;
begin
  Params := Format('{"textDocument":{"uri":"%s"}}', [ADoc.Uri]);
  SendNotify('textDocument/didSave', Params);
end;

// 全局单例
function LspDocSync: TLspDocumentSyncManager;
begin
  if not Assigned(LspDocumentSyncManager) then
    LspDocumentSyncManager := TLspDocumentSyncManager.Create;
  Result := LspDocumentSyncManager;
end;

procedure EnsureLspDocSyncCreated;
begin
  if not Assigned(LspDocumentSyncManager) then
    LspDocumentSyncManager := TLspDocumentSyncManager.Create;
end;

function LspFlushPendingDocument(const AFileName, AText: string): Boolean;
begin
  Result := False;
  try
    Result := LspDocSync.FlushFile(AFileName, AText);
  except
    Result := False;
  end;
end;

initialization
  LspDocumentSyncManager := nil;

finalization
  if Assigned(LspDocumentSyncManager) then
    FreeAndNil(LspDocumentSyncManager);

end.
