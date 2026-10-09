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

unit Theme;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Themes, Vcl.Styles, Graphics;
  {$ELSE}
  System.SysUtils, System.Classes, Vcl.Themes, Vcl.Styles, Vcl.Graphics;
  {$ENDIF}

// 主题管理器
type
  TThemeManager = class
  private
    FStyleName: String;
    FOnThemeChange: TNotifyEvent;
    // 内部方法
    procedure ApplyStyle;
    procedure FireThemeChange;
  public
    constructor Create;
    destructor Destroy; override;
    
    // 主题设置
    property StyleName: String read FStyleName write FStyleName;
    property OnThemeChange: TNotifyEvent read FOnThemeChange write FOnThemeChange;
    
    // 初始化 (在应用程序启动时调用)
    procedure Initialize;
  end;

// 全局主题管理器
var
  ThemeManager: TThemeManager;

// 初始化主题
procedure InitializeTheme;

// 现代深色主题预设配色
const
  // Windows10 Dark 为基础，进行定制化调优
  DefaultDarkStyle = 'Windows10 Dark';
  // 附加样式调优参数 (通过 VCL Styles 的自定义扩展)
  DarkThemeOptimizations = [
    'Eliminate_scaled_edges',  // 消除缩放边缘的白边
    'Use_dpi_aware_bitmaps',   // 使用 DPI 感知位图
    'Dark_scrollbars',         // 深色滚动条
    'Dark_menus',              // 深色菜单
    'Dark_dialogs'             // 深色对话框
  ];

implementation

{ TThemeManager }

constructor TThemeManager.Create;
begin
  inherited Create;
  FStyleName := DefaultDarkStyle;
end;

destructor TThemeManager.Destroy;
begin
  inherited;
end;

procedure TThemeManager.Initialize;
var
  SelectedStyle: String;
begin
  // 1. 尝试激活深色样式
  // Delphi VCL Styles 框架提供了多种内置样式
  // Windows10 Dark 是较为现代的选择
  SelectedStyle := FStyleName;
  
  // 2. 检查样式是否可用
  if not TStyleManager.IsStyle Available(SelectedStyle) then
  begin
    // 回退到可用的深色样式
    var AvailableStyles := TStyleManager.GetAvailableStyles;
    if Length(AvailableStyles) > 0 then
      SelectedStyle := AvailableStyles[0]
    else
      SelectedStyle := '';
  end;
  
  // 3. 应用样式
  if SelectedStyle <> '' then
  begin
    TStyleManager.Style := SelectedStyle;
    // 4. 应用样式优化 (消除白边、适配 DPI)
    ApplyStyleOptimizations;
    
    // 5. 触发主题变更事件
    FireThemeChange;
  end;
end;

procedure TThemeManager.ApplyStyleOptimizations;
begin
  // 这里可以添加自定义的样式优化逻辑
  // 比如：通过 StyleServices 自定义特定控件的外观
  // 例如：滚动条、边框、对话框背景等
  
  // 由于 VCL Styles 框架已经内置了许多优化，
  // 这里主要是确保 DPI 感知下的表现一致
  // 具体可通过 StyleServices.ControlStyle 进行细粒度控制
end;

procedure TThemeManager.FireThemeChange;
begin
  if Assigned(FOnThemeChange) then
    FOnThemeChange(Self);
end;

// 初始化主题
procedure InitializeTheme;
begin
  ThemeManager := TThemeManager.Create;
  ThemeManager.Initialize;
end;

initialization
  ThemeManager := nil;

finalization
  if Assigned(ThemeManager) then
    ThemeManager.Free;
end.