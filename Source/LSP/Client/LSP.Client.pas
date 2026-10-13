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

unit LSP.Client;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, SyncObjs, Types,
  {$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Types,
  {$ENDIF}
  {$IFDEF FPC}
  System.IOUtils, Forms, ExtCtrls, Graphics,
  {$ELSE}
  System.IOUtils, Vcl.Forms, Vcl.ExtCtrls, Vcl.Graphics,
  {$ENDIF}
  SynEditHighlighter, SynEdit;

{LSP Diagnostics 渲染器
  负责将 clangd 通过 textDocument/publishDiagnostics 推送的诊断信息
  渲染到 SynEdit 控件上，显示波浪线错误、警告和信息。}
type
  // 诊断严重程度
  TLspDiagnosticSeverity = (dsError, dsWarning, dsInformation, dsHint);

  // 单条诊断信息
  TLspDiagnostic = record
    Range: TRect; // 起始行/列和结束行/列
    Severity: TLspDiagnosticSeverity;
    Code: String; // 错误代码 (如 "E0028")
    Message: String; // 人类可读的消息
    Source: String; // 来源 (如 "clangd")
  end;

  // 诊断管理器 - 维护当前打开文件的活动诊断列表
  TLspDiagnosticsManager = class
  private
    FEditor: TSynEdit;
    FDiagnostics: TList<TLspDiagnostic>;
    FCurrentFile: String;
    FOnDiagnosticChange: TNotifyEvent;
    // 内部方法
    procedure ClearOldDiagnostics(const AOldFile: String);
    procedure ApplyDiagnostic(const ADiag: TLspDiagnostic);
  public
    constructor Create(AEditor: TSynEdit);
    destructor Destroy; override;
    
    // 更新诊断 - 由 LSP 传输层调用
    procedure UpdateDiagnostics(const AFilePath: String; const ADiagnostics: Array of TLspDiagnostic);
    procedure Clear;
    
    // 事件
    property OnDiagnosticChange: TNotifyEvent read FOnDiagnosticChange write FOnDiagnosticChange;
  end;

// 全局诊断管理器
var
  LspDiagnosticsManager: TLspDiagnosticsManager;

// 初始化诊断管理器
procedure InitializeLspDiagnostics(AEditor: TSynEdit);

implementation

{ TLspDiagnosticsManager }

constructor TLspDiagnosticsManager.Create(AEditor: TSynEdit);
begin
  inherited Create;
  FEditor := AEditor;
  FDiagnostics := TList<TLspDiagnostic>.Create;
  // 注册行标记change事件
  FEditor.MarkersChanged := procedure(Sender: TObject)
    begin
      // 重新计算所有诊断标记位置
      RecalculateMarkers;
    end;
end;

destructor TLspDiagnosticsManager.Destroy;
begin
  Clear;
  FDiagnostics.Free;
  inherited;
end;

procedure TLspDiagnosticsManager.UpdateDiagnostics(const AFilePath: String; const ADiagnostics: Array of TLspDiagnostic);
var
  I: Integer;
  NewFile: Boolean;
  Diag: TLspDiagnostic;
begin
  NewFile := (FCurrentFile <> AFilePath);
  FCurrentFile := AFilePath;
  
  // 清除旧诊断 (如果文件改变)
  if NewFile then
    Clear;
  
  // 记录新诊断
  for I := Low(ADiagnostics) to High(ADiagnostics) do
  begin
    Diag := ADiagnostics[I];
    // 调整范围以适应 0-based 索引
    // LSP 使用 1-based 行号，SynEdit 使用 0-based
    // 调整范围
    var StartLine := Diag.Range.Top; // 已是 0-based (我们在转换时处理)
    var EndLine := Diag.Range.Bottom;
    
    // 确保行号在有效范围内
    if (StartLine >= 0) and (StartLine < FEditor.Lines.Count) then
    begin
      // 应用诊断 - 创建行标记
      ApplyDiagnostic(Diag);
    end;
  end;
  
  // 触发变更事件
  if Assigned(FOnDiagnosticChange) then
    FOnDiagnosticChange(Self);
end;

procedure TLspDiagnosticsManager.Clear;
var
  I: Integer;
begin
  // 移除所有行标记
  for I := 0 to FEditor.Markers.Count - 1 do
  begin
    // 检查是否为诊断标记
    // 简化处理：移除所有标记 (实际应过滤)
    FEditor.Markers.Delete(I);
    Dec(I);
  end;
  FDiagnostics.Clear;
  FCurrentFile := '';
end;

procedure TLspDiagnosticsManager.ApplyDiagnostic(const ADiag: TLspDiagnostic);
var
  LineCtrl: TColor;
  Marker: TMarker;
  StartCol, EndCol: Integer;
  LineText: String;
begin
  // 根据严重程度确定颜色
  case ADiag.Severity of
    dsError: LineCtrl := clRed;
    dsWarning: LineCtrl := clYellow;
    dsInformation: LineCtrl := clBlue;
    dsHint: LineCtrl := clGreen;
  else
    LineCtrl := clRed;
  end;
  
  // 创建行标记
  Marker := TMarker.Create(FEditor);
  Marker.Style := msBar;
  Marker.Color := LineCtrl;
  Marker.TopLine := ADiag.Range.Top;
  Marker.BottomLine := ADiag.Range.Bottom;
  
  // 如果有结束列，设置结束位置
  if ADiag.Range.Right - ADiag.Range.Left > 0 then
    Marker.EndColumn := ADiag.Range.Right;
  
  // 设置工具提示
  Marker.ToolDescription := Format(' [%s] %s', [ADiag.Source, ADiag.Message]);
  
  // 添加到编辑器
  FEditor.Markers.Add(Marker);
  
  // 记录诊断以便潜在的撤销
  FDiagnostics.Add(ADiag);
end;

procedure TLspDiagnosticsManager.RecalculateMarkers;
var
  I: Integer;
  Diag: TLspDiagnostic;
begin
  // 清除并重新应用所有诊断
  Clear;
  for I := 0 to FDiagnostics.Count - 1 do
  begin
    Diag := FDiagnostics[I];
    ApplyDiagnostic(Diag);
  end;
end;

// 全局初始化
procedure InitializeLspDiagnostics(AEditor: TSynEdit);
begin
  LspDiagnosticsManager := TLspDiagnosticsManager.Create(AEditor);
end;

initialization
  LspDiagnosticsManager := nil;

finalization
  if Assigned(LspDiagnosticsManager) then
    LspDiagnosticsManager.Free;
end.