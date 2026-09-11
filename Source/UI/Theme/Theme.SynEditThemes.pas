unit Theme.SynEditThemes;

interface

uses
  SynEdit, SynHighlighter_Cpp, Types;

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
  // --------------------
  // VS Code Dark+ 复刻
  // --------------------
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

  // --------------------
  // One Dark Pro 复刻
  // --------------------
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

  // --------------------
  // Classic Light（默认 Win 经典）
  // --------------------
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

function ApplyEditorProfile(AEditor: TSynEdit; const AProfile: TEditorColorProfile): Boolean;

implementation

function ApplyEditorProfile(AEditor: TSynEdit; const AProfile: TEditorColorProfile): Boolean;
var
  Highlighter: TSynCustomHighlighter;
begin
  Result := False;
  try
    with AProfile do
    begin
      AEditor.Color := BackgroundColor;
      AEditor.Caret.XORMode := False;
      AEditor.CaretWidth := 1;
      AEditor.CaretColor := FontColor;

      // 边栏/行号区域
      AEditor.Gutter.Background := GutterBackgroundColor;
      AEditor.Gutter.Font.Color := GutterFontColor;
      AEditor.Gutter.LeftOffset := 4;
      AEditor.Gutter.RightOffset := 4;

      // 光标行高亮条背景（由 Gutter 自动继承或单独设置）
      AEditor.Options.AutoCIgnoreCase := True;
      AEditor.Options.ExplicitPastelColors := True;

      // 将配色映射到高亮器
      Highlighter := AEditor.Highlighter;
      if Highlighter is TSynCppSyn then
      begin
        TSynCppSyn(Highlighter).WordColor := FontColor;
        TSynCppSyn(Highlighter).KeyWordColor := KeywordColor;
        TSynCppSyn(Highlighter).DataTypeColor := TypeColor;
        TSynCppSyn(Highlighter).StringColor := StringColor;
        TSynCppSyn(Highlighter).CommentColor := CommentColor;
        TSynCppSyn(Highlighter).NumberColor := NumberColor;
        Result := True;
      end
      else if Highlighter is TSynPasSyn then
      begin
        TSynPasSyn(Highlighter).WordColor := FontColor;
        TSynPasSyn(Highlighter).KeyWordColor := KeywordColor;
        TSynPasSyn(Highlighter).DataTypeColor := TypeColor;
        TSynPasSyn(Highlighter).StringColor := StringColor;
        TSynPasSyn(Highlighter).CommentColor := CommentColor;
        TSynPasSyn(Highlighter).NumberColor := NumberColor;
        Result := True;
      end;
    end;
  except
    Result := False;
  end;
end;

initialization
  // 注册默认主题为 VS Code Dark+
  // TStyleManager.ActiveStyle := TStyleManager.Style['VSCode Dark'];

finalization
  // TStyleManager.ActiveStyle := nil;

end.