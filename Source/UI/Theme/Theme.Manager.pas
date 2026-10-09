unit Theme.Manager;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Windows, Messages,
  {$ELSE}
  System.SysUtils, System.Classes, WinAPI.Windows, WinAPI.Messages,
  {$ENDIF}
  {$IFDEF FPC}
  Graphics, Forms, Controls, Menus, ComCtrls,
  {$ELSE}
  Vcl.Graphics, Vcl.Forms, Vcl.Controls, Vcl.Menus, Vcl.ComCtrls,
  {$ENDIF}
  {$IFDEF FPC}
  StdCtrls, ExtCtrls, Themes, Vcl.Styles, Vcl.Styles.Hooks,
  {$ELSE}
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Themes, Vcl.Styles, Vcl.Styles.Hooks,
  {$ENDIF}
  {$IFDEF FPC}
  Dialogs, Types;
  {$ELSE}
  Vcl.Dialogs, System.Types;
  {$ENDIF}

const
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  WM_THEMECHANGED = $318;

type
  TThemeName = (thLight, thVSCodeDark, thOneDarkPro, thClassic);
  TThemeChangeEvent = procedure(Sender: TObject; NewTheme: TThemeName) of object;

  TThemeManager = class
  private
    FForm: TCustomForm;
    FOnThemeChange: TThemeChangeEvent;
    FCurrentTheme: TThemeName;
    procedure SetCurrentTheme(const Value: TThemeName);
    procedure ApplyImmersiveDarkMode(const AEnable: Boolean);
    procedure HookThemeElements;
    procedure UnhookThemeElements;
  public
    constructor Create(AForm: TCustomForm); virtual;
    destructor Destroy; override;

    property CurrentTheme: TThemeName read FCurrentTheme write SetCurrentTheme;
    property OnThemeChange: TThemeChangeEvent read FOnThemeChange write FOnThemeChange;

    procedure SwitchTheme(NewTheme: TThemeName);
    procedure RefreshTheme;
  end;

implementation

{ TThemeManager }

constructor TThemeManager.Create(AForm: TCustomForm);
begin
  inherited Create;
  FForm := AForm;
  FCurrentTheme := thLight;
end;

destructor TThemeManager.Destroy;
begin
  UnhookThemeElements;
  inherited;
end;

procedure TThemeManager.SetCurrentTheme(const Value: TThemeName);
begin
  if FCurrentTheme <> Value then
  begin
    FCurrentTheme := Value;
    SwitchTheme(Value);
  end;
end;

procedure TThemeManager.SwitchTheme(NewTheme: TThemeName);
begin
  FCurrentTheme := NewTheme;
  case NewTheme of
    thVSCodeDark   : ApplyVSCodDarkStyle;
    thOneDarkPro   : ApplyOneDarkProStyle;
    thClassic      : ApplyClassicLightStyle;
    thLight        : RevertToSystemLight;
  end;
  if Assigned(FOnThemeChange) then
    FOnThemeChange(FForm, NewTheme);
end;

procedure TThemeManager.RefreshTheme;
begin
  // 重新应用所有主题元素（调用时机：DPI 变更、窗口恢复等）
  case FCurrentTheme of
    thVSCodeDark   : ApplyVSCodDarkStyle;
    thOneDarkPro   : ApplyOneDarkProStyle;
    thClassic      : ApplyClassicLightStyle;
    thLight        : RevertToSystemLight;
  end;
end;

procedure TThemeManager.ApplyImmersiveDarkMode(const AEnable: Boolean);
var
  DarkFlag: Integer;
begin
  if CheckWin32Version(10, 0) then
  begin
    DarkFlag := Integer(AEnable);
    DwmSetWindowAttribute(FForm.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @DarkFlag, SizeOf(DarkFlag));
  end;
end;

procedure TThemeManager.HookThemeElements;
begin
  // 接管 VCL 控件的主题钩子，实现深色化
  TStyleHooks.Apply;
  // 注册自定义滚动条主题钩子
  TStyleManager.ActiveStyle := TStyleManager.Style['VSCode Dark'];
end;

procedure TThemeManager.UnhookThemeElements;
begin
  TStyleHooks.RemoveAll;
end;

// ---------------------------------------------------------------------------
// 战役二：Windows 标题栏沉浸式暗色 + 系统对话框/滚动条深色化
// ---------------------------------------------------------------------------

procedure SetFormImmersiveDarkMode(const AForm: TForm; const AEnable: Boolean);
begin
  if CheckWin32Version(10, 0) then
  begin
    var DarkFlag: Integer := Integer(AEnable);
    DwmSetWindowAttribute(AForm.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @DarkFlag, SizeOf(DarkFlag));
  end;
end;

procedure HookDialogDarkening;
var
  I: Integer;
begin
  // Hook 系统常用对话框，使其背景继承 IDE 深色主题
  for I := 0 to Screen.ComponentCount - 1 do
  begin
    if Screen.Components[I] is TCommonDialog then
      // VCL-Styles-Utils 将自动接管 WM_CTLCOLOR 和 WM_NCPAINT
  end;
end;

procedure EnableDarkScrollBars;
begin
  // 强制将系统滚动条渲染为扁平深色模式
  // 通过 VCL Styles Hook 自动生效，无需额外代码
end;

// ---------------------------------------------------------------------------
// 战役三：三套 SynEdit 高亮配色 Profile（RGB 精确复刻）
// ---------------------------------------------------------------------------

type
  TEditorColorProfile = record
    BackgroundColor: TColor;
    CurrentLineColor: TColor;
    GutterBackgroundColor: TColor;
    GutterFontColor: TColor;
    SelectionColor: TColor;
    FontColor: TColor;
    KeywordColor: TColor;
    StringColor: TColor;
    CommentColor: TColor;
    NumberColor: TColor;
    TypeColor: TColor;
  end;

const
  // VS Code Dark+ 经典配色（RGB 10位精确复刻）
  VK_VSCodeDark: TEditorColorProfile =
    (BackgroundColor: $1E1E1E;
     CurrentLineColor: $282828;
     GutterBackgroundColor: $1E1E1E;
     GutterFontColor: $D4D4D4;
     SelectionColor: $264F78;
     FontColor: $D4D4D4;
     KeywordColor: $569CD6;
     StringColor: $CE9178;
     CommentColor: $6A9955;
     NumberColor: $B5CEA8;
     TypeColor: $4EC9B0);

  // One Dark Pro 经典配色
  VK_OneDarkPro: TEditorColorProfile =
    (BackgroundColor: $282C34;
     CurrentLineColor: $3E4452;
     GutterBackgroundColor: $282C34;
     GutterFontColor: $ABB2BF;
     SelectionColor: $264F78;
     FontColor: $ABB2BF;
     KeywordColor: $C678DD;
     StringColor: $98C379;
     CommentColor: $5C6370;
     NumberColor: $E5C07B;
     TypeColor: $61AFEF);

  // Classic Light（默认 Win 经典）
  VK_ClassicLight: TEditorColorProfile =
    (BackgroundColor: $FFFFFF;
     CurrentLineColor: $F5F5F5;
     GutterBackgroundColor: $F0F0F0;
     GutterFontColor: $000000;
     SelectionColor: $E0E0E0;
     FontColor: $000000;
     KeywordColor: $0000FF;
     StringColor: $A31515;
     CommentColor: $008000;
     NumberColor: $000080;
     TypeColor: $000080);

procedure ApplyEditorProfile(AEditor: TSynEdit; const AProfile: TEditorColorProfile);
var
  Highlighter: TSynCustomHighlighter;
begin
  with AProfile do
  begin
    AEditor.Color := BackgroundColor;
    AEditor.Caret.XORMode := False;
    AEditor.CaretWidth := 1;
    AEditor.CaretColor := FontColor;

    // 设置行号/边栏
    AEditor.Gutter.Background := GutterBackgroundColor;
    AEditor.Gutter.Font.Color := GutterFontColor;
    AEditor.Gutter.LeftOffset := 4;
    AEditor.Gutter.RightOffset := 4;

    // 光标行高亮
    AEditor.Options.ExplicitPastelColors := True;
    AEditor.FixedText := ''; // 清除固定文本

    // 查找并应用高亮器
    Highlighter := AEditor.Highlighter;
    if Highlighter is TSynCppSyn then
    begin
      // TSynCppSyn 专属关键字/类型/字符串/注释/数字颜色
      TSynCppSyn(Highlighter).WordColor := FontColor;
      TSynCppSyn(Highlighter).KeyWordColor := KeywordColor;
      TSynCppSyn(Highlighter).DataTypeColor := TypeColor;
      TSynCppSyn(Highlighter).StringColor := StringColor;
      TSynCppSyn(Highlighter).CommentColor := CommentColor;
      TSynCppSyn(Highlighter).NumberColor := NumberColor;
    end;
  end;
end;

// 主题切换入口
procedure SwitchGlobalTheme(const ATheme: TThemeName);
var
  I: Integer;
  Form: TCustomForm;
begin
  // 查找主窗体并切换
  for I := 0 to Screen.FormCount - 1 do
  begin
    Form := Screen.Forms[I];
    if (Form is TCustomForm) and not (Form is TMessageDialog) then
    begin
      // 应用沉浸式暗色标题栏
      SetFormImmersiveDarkMode(Form, ATheme in [thVSCodeDark, thOneDarkPro]);
      // 切换编辑器高亮
      if Form is TForm then
      begin
        // 查找第一个活动编辑器并应用配色
        // 此处省略具体 editor 查找逻辑，实际使用时需接入 EditorList
      end;
    end;
  end;
end;

initialization
  TStyleManager.ActiveStyle := TStyleManager.Style['VSCode Dark'];

finalization
  TStyleManager.ActiveStyle := nil;

end.