// ---------------------------------------------------------------------------
// What FormLfmProbe and PropRttiProbe must agree on, in ONE place
// =======================================================================
// Both probes read the SAME converted artefacts -- the .lfm files of the
// forms `tools/f3_load_routes.py` reports as CLEARED -- and both have to
// agree on which forms those are and which classes those files name.
// Two copies of that list is the failure this unit exists to prevent:
// the first version of FormLfmProbe carried its own 13-entry table, and
// the property audit added here needed the same table plus the same 42
// class registrations. A stale copy is worse than no probe at all --
// the audit would report "every property is known" about a form set
// that has since changed.
//
// WHAT IS HERE AND WHY IT IS NOT OPTIONAL
// ======================================
//   * The 13 form classes, as stubs. The LFM's first line names a class
//     string (`object CompOptForm: TCompOptForm`) and the reader resolves
//     it through the global registry, so a stub is the only way to load
//     a form whose real unit is not ported yet. Each is registered under
//     exactly the name its LFM carries.
//   * TCompOptionsFrame, also a stub, but with the two handlers its own
//     converted LFM names as PUBLISHED methods. That word is load
//     bearing: the frame's LFM is loaded through the LCL's own reader
//     (InitLazResourceComponent -> ReadRootComponent), which has no
//     method hook, and FPC's reader resolves a handler name through
//     RTTIGetMethod, which only sees PUBLISHED methods. A `public`
//     declaration compiled fine and then failed at stream time with
//     `tabs.OnChange: Invalid value for property`.
//   * RegisterFormProbeClasses: the complete class list, measured from
//     the files rather than guessed. The LCL units do NOT register their
//     own widgets at runtime -- StdCtrls keeps registration inside
//     `procedure Register` (stdctrls.pp:1698), which only a design-time
//     package calls -- so every widget class has to be named here or
//     streaming fails with `Class "TButton" not found`.
//   * The CLEARED table, with the maintenance rule that belongs to it.
//
// MEASURED, NOT GUESSED
// =====================
// `EXPECTED` is the CLEARED block of `python tools/f3_load_routes.py`
// (13 forms), and the 42 class names were extracted from those 13 files
// plus CompOptionsFrame.lfm. Recompute both after any status change:
//
//   python tools/f3_load_routes.py
//   (and update the stub classes below to match)
//
// A missing entry shows up as a FAIL that names the file; a missing
// registration shows up as EClassNotFound naming the class. Neither
// fails silently, which is the property this unit is protecting.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

unit FormProbeSupport;

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ImgList, ExtCtrls, Buttons,
  StdCtrls, ComCtrls, Spin, ValEdit, Dialogs, CheckLst, ExtDlgs, SynEdit,
  SynHighlighterCpp, Grids, ColorBox, LclVirtualImage;

type
  // The fourteen window classes the route tool reports as CLEARED, each
  // under exactly the name its LFM's first line uses.
  TAStyleFormatterOptionsForm = class(TForm);
  TAboutForm = class(TForm);
  TClangFormatterOptionsForm = class(TForm);
  TCompOptForm = class(TForm);
  TEditorOptForm = class(TForm);
  TEnviroForm = class(TForm);
  TFormatterOptionsForm = class(TForm);
  TIconForm = class(TForm);
  TLangForm = class(TForm);
  TNewTemplateForm = class(TForm);
  TParamsForm = class(TForm);
  TProjectOptionsFrm = class(TForm);
  TToolEditForm = class(TForm);
  TToolForm = class(TForm);

  // The embedded frame, as a stub whose two handlers are PUBLISHED --
  // see the header.
  TCompOptionsFrame = class(TFrame)
  published
    procedure tabsChange(Sender: TObject);
    procedure vleSetEditText(Sender: TObject; ACol, ARow: Integer;
                             const Value: string);
  end;

  // One CLEARED form: the LFM file name, the instance name the LFM
  // declares, and the class that instance must stream back as.
  TFormExpectation = record
    FileName: string;
    InstanceName: string;
    ClassName: string;
  end;

const
  // Maintenance rule: this list IS the route tool's CLEARED set at the
  // time of writing. Recompute it with `python tools/f3_load_routes.py`
  // after any form changes status. F3-4 moved CompOptionsFrm and
  // ProjectOptionsFrm in by retiring the vendored TCompOptionsList and
  // porting the frame.
  EXPECTED: array[0..13] of TFormExpectation = (
    (FileName: 'AStyleFormatterOptionsFrm.lfm';
     InstanceName: 'AStyleFormatterOptionsForm';
     ClassName: 'TAStyleFormatterOptionsForm'),
    (FileName: 'AboutFrm.lfm';
     InstanceName: 'AboutForm';
     ClassName: 'TAboutForm'),
    (FileName: 'ClangFormatterOptionsFrm.lfm';
     InstanceName: 'ClangFormatterOptionsForm';
     ClassName: 'TClangFormatterOptionsForm'),
    (FileName: 'CompOptionsFrm.lfm';
     InstanceName: 'CompOptForm';
     ClassName: 'TCompOptForm'),
    (FileName: 'EditorOptFrm.lfm';
     InstanceName: 'EditorOptForm';
     ClassName: 'TEditorOptForm'),
    (FileName: 'EnviroFrm.lfm';
     InstanceName: 'EnviroForm';
     ClassName: 'TEnviroForm'),
    (FileName: 'FormatterOptionsFrm.lfm';
     InstanceName: 'FormatterOptionsForm';
     ClassName: 'TFormatterOptionsForm'),
    (FileName: 'IconFrm.lfm';
     InstanceName: 'IconForm';
     ClassName: 'TIconForm'),
    (FileName: 'LangFrm.lfm';
     InstanceName: 'LangForm';
     ClassName: 'TLangForm'),
    (FileName: 'NewTemplateFrm.lfm';
     InstanceName: 'NewTemplateForm';
     ClassName: 'TNewTemplateForm'),
    (FileName: 'ParamsFrm.lfm';
     InstanceName: 'ParamsForm';
     ClassName: 'TParamsForm'),
    (FileName: 'ProjectOptionsFrm.lfm';
     InstanceName: 'ProjectOptionsFrm';
     ClassName: 'TProjectOptionsFrm'),
    (FileName: 'ToolEditFrm.lfm';
     InstanceName: 'ToolEditForm';
     ClassName: 'TToolEditForm'),
    (FileName: 'ToolFrm.lfm';
     InstanceName: 'ToolForm';
     ClassName: 'TToolForm')
  );

  // Anchored by walking up from the executable for a file that must
  // exist, so the probes run from any directory. The root that was
  // settled on is always printed.
  MANIFEST_REL = 'Source\Fpc\UI\Data\img_manifest.json';
  FORMS_REL = 'Source\Fpc\UI\Forms';
  FRAME_LFM = 'CompOptionsFrame.lfm';

function RegisterFormProbeClasses: Integer;
function FindRepoRoot: string;
function ParentDir(const ADir: string): string;

implementation

procedure TCompOptionsFrame.tabsChange(Sender: TObject);
begin
end;

procedure TCompOptionsFrame.vleSetEditText(Sender: TObject; ACol, ARow: Integer;
  const Value: string);
begin
end;

// One level up, or '' at the root. Hand-rolled for the two measured
// reasons ImgCollProbe records: IncludeTrailingPathDelimiter on ''
// returns the separator, and LastDelimiter mis-fires on
// multi-separator paths. A backwards character scan has neither problem.
function ParentDir(const ADir: string): string;
var
  S: string;
  I: Integer;
begin
  S := ExcludeTrailingPathDelimiter(ADir);
  for I := Length(S) downto 1 do
    if (S[I] = '\') or (S[I] = '/') then
      Exit(IncludeTrailingPathDelimiter(Copy(S, 1, I)));
  Result := '';
end;

function FindRepoRoot: string;
var
  D, Tried: string;
begin
  D := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Tried := '';
  while D <> '' do
  begin
    if FileExists(D + MANIFEST_REL) then
      Exit(D);
    Tried := Tried + #13#10 + '    tried: ' + D + MANIFEST_REL;
    D := ParentDir(D);
  end;
  WriteLn('  walk from "', ExtractFilePath(ParamStr(0)), '" visited:', Tried);
  Result := '';
end;

// Registers everything above and reports how many classes went in, so a
// stale table shows up as a NUMBER rather than as a mystery later.
function RegisterFormProbeClasses: Integer;
begin
  RegisterClass(TAStyleFormatterOptionsForm);
  RegisterClass(TAboutForm);
  RegisterClass(TClangFormatterOptionsForm);
  RegisterClass(TCompOptForm);
  RegisterClass(TEditorOptForm);
  RegisterClass(TEnviroForm);
  RegisterClass(TFormatterOptionsForm);
  RegisterClass(TIconForm);
  RegisterClass(TLangForm);
  RegisterClass(TNewTemplateForm);
  RegisterClass(TParamsForm);
  RegisterClass(TProjectOptionsFrm);
  RegisterClass(TToolEditForm);
  RegisterClass(TToolForm);
  RegisterClass(TCompOptionsFrame);

  // StdCtrls: design-time-only Register procedure (stdctrls.pp:1698).
  RegisterClass(TButton);
  RegisterClass(TLabel);
  RegisterClass(TEdit);
  RegisterClass(TMemo);
  RegisterClass(TCheckBox);
  RegisterClass(TListBox);
  RegisterClass(TComboBox);
  RegisterClass(TGroupBox);
  // Buttons
  RegisterClass(TBitBtn);
  RegisterClass(TSpeedButton);
  // ExtCtrls
  RegisterClass(TPanel);
  RegisterClass(TImage);
  RegisterClass(TBevel);
  RegisterClass(TRadioGroup);
  RegisterClass(TTimer);
  // EditorOptFrm (F3-6) brought three widgetset classes this list had never
  // been asked about, because no earlier CLEARED form used them. All three are
  // LCL-native and were verified by declaration, not by name: TTrackBar in
  // lcl/comctrls.pp (base TCustomTrackBar), TColorBox in lcl/colorbox.pas
  // (base TCustomColorBox) and TStringGrid in lcl/grids.pp (base
  // TCustomStringGrid). Registering the real classes rather than stubs is the
  // point -- EditorOptFrm sets real properties on all three.
  RegisterClass(TTrackBar);
  RegisterClass(TColorBox);
  RegisterClass(TStringGrid);
  // ComCtrls
  RegisterClass(TPageControl);
  RegisterClass(TTabSheet);
  RegisterClass(TTabControl);
  RegisterClass(TListView);
  RegisterClass(TTreeView);
  // ValEdit / Spin / CheckLst / ImgList
  RegisterClass(TValueListEditor);
  RegisterClass(TSpinEdit);
  RegisterClass(TCheckListBox);
  RegisterClass(TImageList);
  // Dialogs / ExtDlgs
  RegisterClass(TOpenDialog);
  RegisterClass(TOpenPictureDialog);
  // SynEdit (the probes link the Lazarus package; the vendored VCL copy
  // is not FPC-compilable yet) and the F3-3 control.
  RegisterClass(TSynEdit);
  RegisterClass(TLclVirtualImage);
  // The REAL LCL C++ highlighter, not a stub (F3-6). This is the class the
  // sprint retired the vendored TSynCppSyn in favour of: Lazarus ships it as
  // SynHighlighterCpp in components/synedit/synhighlightercpp.pp -- note the
  // .pp extension, which is why searching Lazarus for "*.pas" finds nothing and
  // the class reads as absent. Registering the genuine type is what makes the
  // EditorOptFrm result meaningful: a stub would stream the same LFM while
  // proving nothing about whether the LCL can actually build the highlighter.
  RegisterClass(TSynCppSyn);

  Result := 15 + 33;   // 14 form stubs + the frame, then 33 widget classes
end;

end.