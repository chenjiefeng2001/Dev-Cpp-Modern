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

unit ProcessListFrm;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, Buttons, ExtCtrls, MultiLangSupport,DataFrm;

type
  TProcessListForm = class(TForm)
    OKBtn: TBitBtn;
    CancelBtn: TBitBtn;
    ProcessCombo: TComboBox;
    MainLabel: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    procedure LoadText;
    { Private declarations }
  public
    ProcessList : TList;
    { Public declarations }
  end;

var
  ProcessListForm: TProcessListForm;

{$IFDEF FPC}
// FPC 3.2.2 ships no tlhelp32 unit at all (checked under both units\x86_64-win64
// and source\), so the three calls this form makes are declared externally here,
// the same way Instances.pas declares GetModuleFileNameEx.
//
// The names are deliberately the UNSUFFIXED Delphi ones bound to the W exports.
// Delphi's tlhelp32 does exactly that in Unicode mode -- its `Process32First` IS
// `Process32FirstW` -- so the body below compiles unchanged under both compilers
// and resolves to the same entry point.
const
  TH32CS_SNAPALL = $0000000F;

type
  TProcessEntry32 = record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ProcessID: DWORD;
    th32DefaultHeapID: DWORD_PTR;
    th32ModuleID: DWORD;
    cntThreads: DWORD;
    th32ParentProcessID: DWORD;
    pcPriClassBase: Longint;
    dwFlags: DWORD;
    szExeFile: array[0..MAX_PATH - 1] of WideChar;
  end;

function CreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle; stdcall;
  external 'kernel32' name 'CreateToolhelp32Snapshot';
function Process32First(hSnapshot: THandle; var lppe: TProcessEntry32): BOOL; stdcall;
  external 'kernel32' name 'Process32FirstW';
function Process32Next(hSnapshot: THandle; var lppe: TProcessEntry32): BOOL; stdcall;
  external 'kernel32' name 'Process32NextW';
{$ENDIF}

implementation

uses 
  {$IFDEF FPC}
  devcfg
  {$ELSE}
  tlhelp32, devcfg
  {$ENDIF}
;

{$R *.dfm}

procedure TProcessListForm.FormCreate(Sender: TObject);
var
  t  : THandle;
  pe : TProcessEntry32;
  HasProcess: boolean;
begin
  LoadText;
  ProcessList := TList.Create;
  t := CreateToolhelp32Snapshot(TH32CS_SNAPALL, 0);
  try
    pe.dwSize:= SizeOf(pe);
    HasProcess := Process32First(t, pe);
    while HasProcess do begin
      ProcessCombo.Items.Add(pe.szExeFile);
      ProcessList.Add(pointer(pe.th32ProcessId));
      HasProcess := Process32Next(t, pe);
    end;
  finally
    CloseHandle(t);
  end;
end;

procedure TProcessListForm.FormDestroy(Sender: TObject);
begin
  ProcessList.Free;
end;

procedure TProcessListForm.LoadText;
begin
	// Set interface font
	Font.Name := devData.InterfaceFont;
	Font.Size := devData.InterfaceFontSize;

  Caption := Lang[ID_ITEM_ATTACHPROCESS];
  MainLabel.Caption := Lang[ID_MSG_ATTACH];
  MainLabel.Width := 360;
  OKBtn.Caption := Lang[ID_BTN_OK];
  CancelBtn.Caption := Lang[ID_BTN_CANCEL];
end;

end.
