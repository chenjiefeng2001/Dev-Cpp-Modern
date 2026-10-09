unit Vcl.ExtDlgs;

// ---------------------------------------------------------------------------
// FPC compatibility shim: `uses Vcl.ExtDlgs` resolves HERE, on the FPC side
// only. Same mechanism as Source/Fpc/UI/Compat/Vcl.VirtualImage.pas (F3-8):
// the Delphi tree keeps the dotted unit name, the FPC search path supplies the
// implementation, and the Delphi build is never edited. Runs alongside the
// `{$IFDEF FPC}` uses-rewrite in tools/fpc_uses_rewrite.py -- this shim is for
// the SYMBOLS the LCL does not spell the way Delphi does.
//
// WHAT IS A RE-EXPORT AND WHAT IS NEW CODE
// ========================================
// Classes the LCL already ships under its own ExtDlgs unit are ALIASED here,
// because a subclass would be a different type (the Vcl.VirtualImage precedent:
// measured -- a subclass breaks DFM streaming assignment).
//
// TOpenTextFileDialog / TSaveTextFileDialog are the NEW part. Vcl.ExtDlgs in
// Delphi 11 (C:\Program Files (x86)\Embarcadero\Studio\37.0\source\vcl\Vcl.ExtDlgs.pas,
// lines 466-530) implements the encoding combo through IFileDialogCustomize --
// the Vista IFileDialog API. The LCL's TOpenDialog has NO such extension hook
// (checked: C:\lazarus\lcl\dialogs.pp TFileDialog exposes no customize point),
// so the embedded combo cannot be ported as-is. What is ported instead is the
// observable contract the callers use, measured over the four call sites:
// Editor.pas:2379 and main.pas:2194 use Create(Self), FixStyle, Filter, Title,
// Options + ofAllowMultiSelect, Execute, Files, FileName, InitialDir,
// DefaultExt, FilterIndex, and EncodingIndex (Editor presets it from the
// editor's current TEncoding; main reads it after Execute). Every one of those
// is a real TOpenDialog property or the one property declared below; nothing is
// stubbed, and the encoding choice is an explicit property the host form sets.
//
// WHAT IS DELIBERATELY *NOT* PORTED
// ================================
// The style-manager helper in Source/Utils.pas (TOpenTextFileDialogHelper,
// lines 158-161 and 1241-1254) is not reachable here: its body touches the
// Delphi dialog's private FComboBox/FLabel/FPanel children and TSysStyleManager,
// which do not exist on the LCL side. Its declaration, its implementation and
// the two FixStyle call sites are wrapped in {$IFNDEF FPC} in the sources, so
// both trees keep their own behaviour.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

interface

uses
  Classes, Controls, Forms, Dialogs, ExtDlgs;

type
  // --- re-exports of the LCL's own ExtDlgs surface (alias, not subclass) ----
  TOpenPictureDialog = ExtDlgs.TOpenPictureDialog;
  TSavePictureDialog = ExtDlgs.TSavePictureDialog;
  TCalculatorDialog = ExtDlgs.TCalculatorDialog;
  TCalendarDialog = ExtDlgs.TCalendarDialog;

  // --- the encoding-aware open/save text dialogs (new; see header) ---------
  TOpenTextFileDialog = class(TOpenDialog)
  private
    FEncodingIndex: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    // Which of the host's Encodings[] entries the text is read/written as.
    // Defaults to 0 (ANSI). Editor.pas presets it before Execute from its
    // editor's TEncoding; main.pas reads it after Execute. There is no embedded
    // combo in the LCL path (see header), so the host sets it explicitly.
    property EncodingIndex: Integer read FEncodingIndex write FEncodingIndex default 0;
  end;

  { TSaveTextFileDialog }

  TSaveTextFileDialog = class(TOpenTextFileDialog)
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

{ TOpenTextFileDialog }

constructor TOpenTextFileDialog.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FEncodingIndex := 0;
  Title := '';
end;

{ TSaveTextFileDialog }

constructor TSaveTextFileDialog.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
end;

end.
