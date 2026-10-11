unit SynEditDataObject;{$H+}
{
  The contents of this file are subject to the Mozilla Public License
  Version 1.1 (the "License"); you may not use this file except in compliance
  with the License. You may obtain a copy of the License at
  http://www.mozilla.org/MPL/

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
  the specific language governing rights and limitations under the License.

  Contributors to the SynEdit and mwEdit projects are listed in the
  Contributors.txt file.

  Alternatively, the contents of this file may be used under the terms of the
  GNU General Public License Version 2 or later (the "GPL"), in which case
  the provisions of the GPL are applicable instead of those above.
  If you wish to allow use of your version of this file only under the terms
  of the GPL and not to allow others to use your version of this file
  under the MPL, indicate your decision by deleting the provisions above and
  replace them with the notice and other provisions required by the GPL.
  If you do not delete the provisions above, a recipient may use your version
  of this file under either the MPL or the GPL.

  This unit implements the IDataObject interface for Clipboard and Drag & Drop
  operations.
  Code based on Grahame Marsh's articles on OLE Drag & Drop
  published in UNDO (www.undo.com)
}

interface
uses
  Windows,
  SysUtils,
  Classes,
  ActiveX,
  Generics.Collections;

Type

  TSynEnumFormatEtc = class (TInterfacedObject, IEnumFORMATETC)
  private
    FList : TArray<TClipFormat>;
    FIndex : integer;
  protected
    function GetFormatEtc(ClipFormat : TClipFormat): TFormatEtc;
    {IEnumFORMATETC}
    // FPC的 ActiveX ppu 将这些参数声明为无符号（LongWord/
    // PULONG），而 Delphi 用 Longint/PLongint。接口参数必须一字差
    // 不差地匹配，否则 FPC 报 “No matching implementation for interface
    // method”。以编译器解析到的为准。
    function Next (celt: LongWord; out elt: TFormatEtc; pceltFetched: PLongWord): HResult; stdcall;
    function Skip (celt: LongWord): HResult; stdcall;
    function Reset : HResult; stdcall;
    function Clone (out Enum: IEnumFormatEtc): HResult; stdcall;
  public
    constructor Create (FormatList : TArray<TClipFormat>; Index : integer = 0);
  end;

  TSynEditDataObject = class (TInterfacedObject, IDataObject)
  private
    fText : string;
    FFormatEtc : TList<TClipFormat>;
    MemoryStream : TMemoryStream;
  protected
    function GetData (const formatetcIn: TFormatEtc; out medium: TStgMedium): HResult; overload; stdcall;
    function GetDataHere (const formatetc: TFormatEtc; out medium: TStgMedium): HResult; overload; stdcall;
    function QueryGetData (const formatetc: TFormatEtc): HResult; overload; stdcall;
    function GetCanonicalFormatEtc (const formatetc: TFormatEtc; out formatetcOut: TFormatEtc): HResult; overload; stdcall;
    function SetData (const formatetc: TFormatEtc; var medium: TStgMedium; fRelease: BOOL): HResult; overload; stdcall;
    function EnumFormatEtc (dwDirection: LongWord; out enumFormatEtc: IEnumFormatEtc): HResult; overload; stdcall;
    function DAdvise (const formatetc: TFormatEtc; advf: LongWord; const advSink: IAdviseSink; out dwConnection: LongWord): HResult; overload; stdcall;
    function DUnadvise (dwConnection: LongWord): HResult; overload; stdcall;
    function EnumDAdvise (out enumAdvise: IEnumStatData): HResult; overload; stdcall;
  public
    constructor Create(ASynEdit : TObject);
    destructor Destroy; override;
  end;

function MakeGlobal (Value : integer) : hGlobal; overload;
function MakeGlobal (const S: string): hGlobal; overload;
function MakeGlobal (var P; Size : integer) : hGlobal; overload;
function HasFormat(DataObject : IDataObject; Format : TClipFormat): Boolean;

var
  SynEditClipboardFormat: UINT;

implementation

uses
  SynEdit;

function MakeGlobal (const S: string): hGlobal;
var
  P : PChar;
  Size : Integer;
begin
  Size := ByteLength(S) + SizeOf(Char);
  Result := GlobalAlloc (GHND, Size);
  if Result = 0 then
    OutOfMemoryError;
  P := GlobalLock (Result);
  try
    Move(PChar(S)^, P^, Size)
  finally
    GlobalUnlock (Result)
  end
end;

function MakeGlobal (Value : integer) : hGlobal;
begin
  Result := MakeGlobal (Value, sizeof (integer))
end;

function MakeGlobal (var P; Size : integer) : hGlobal;
var
  D : pointer;
begin
  Result := GlobalAlloc (GHND, Size);
  if Result = 0 then
    OutOfMemoryError;
  D := GlobalLock (Result);
  try
    Move (P, D^, Size)
  finally
    GlobalUnlock (Result)
  end
end;

function HasFormat(DataObject : IDataObject; Format : TClipFormat):Boolean;
Var
  FormatEnumerator : IEnumFormatEtc;
  FormatEtc  : TFormatEtc;
  Returned : integer;
begin
  Result := False;
  if (DataObject.EnumFormatEtc (DATADIR_GET, FormatEnumerator) = S_OK) then begin
    FormatEnumerator.Reset;
    while FormatEnumerator.Next (1, FormatEtc, @Returned) = S_OK do
      if FormatEtc.cfFormat = Format then
        Exit(True);
  end;
end;

constructor TSynEditDataObject.Create(ASynEdit : TObject);
begin
  inherited Create;
  MemoryStream := TMemoryStream.Create;
  FFormatEtc := TList<TClipFormat>.Create;
  FFormatEtc.Add(CF_UNICODETEXT);
  FFormatEtc.Add(SynEditClipboardFormat); // InternalFormat
  fText := (ASynEdit as TCustomSynEdit).SelText;
  MemoryStream.Write((ASynEdit as TCustomSynEdit).ActiveSelectionMode,
    SizeOf(TCustomSynEdit(ASynEdit).ActiveSelectionMode));
end;

destructor TSynEditDataObject.Destroy;
begin
  FFormatEtc.Free;
  MemoryStream.Free;
  inherited Destroy
end;

function TSynEditDataObject.GetData (const formatetcIn: TFormatEtc; out medium: TStgMedium): HResult;
begin
  try
    Result := DV_E_FORMATETC;
    ZeroMemory (@Medium, sizeof (TStgMedium));
    if FormatEtcIn.tymed and TYMED_HGLOBAL = TYMED_HGLOBAL then
    begin
      Medium.tymed := TYMED_HGLOBAL;
      if FormatEtcIn.cfFormat = CF_UNICODETEXT then
        Medium.hGlobal := MakeGlobal(FText)
      else if FormatEtcIn.cfFormat = SynEditClipboardFormat then
        Medium.hGlobal := MakeGlobal(MemoryStream.Memory^, MemoryStream.Position)
      else
        Exit;
      Result := S_OK
    end
  except
    Result := E_UNEXPECTED;
  end
end;

function TSynEditDataObject.GetDataHere (const formatetc: TFormatEtc; out medium: TStgMedium): HResult;
begin
  Result := E_NOTIMPL;
end;

function TSynEditDataObject.QueryGetData (const formatetc: TFormatEtc): HResult;
Var
  ClipFormat : TClipFormat;
begin
  for ClipFormat in FFormatEtc do
    if (formatetc.cfFormat = ClipFormat)  and
      (formatetc.tymed and TYMED_HGLOBAL = TYMED_HGLOBAL)
    then
      Exit(S_OK);
  Exit(DV_E_FORMATETC);
end;

function TSynEditDataObject.GetCanonicalFormatEtc (const formatetc: TFormatEtc; out formatetcOut: TFormatEtc): HResult;
begin
  FormatEtcOut.ptd := nil;
  Result := DATA_S_SAMEFORMATETC;
end;

function TSynEditDataObject.SetData (const formatetc: TFormatEtc; var medium: TStgMedium; fRelease: BOOL): HResult;
begin
  Result := E_NOTIMPL;
end;

function TSynEditDataObject.EnumFormatEtc (dwDirection: LongWord; out enumFormatEtc: IEnumFormatEtc): HResult;
begin
  try
    if dwDirection = DATADIR_GET then
    begin
      EnumFormatEtc := TSynEnumFormatEtc.Create(FFormatEtc.ToArray);
      Result := S_OK
    end else
      Result := E_NOTIMPL;
  except
    Result := E_UNEXPECTED;
  end
end;

function TSynEditDataObject.DAdvise (const formatetc: TFormatEtc; advf: LongWord; const advSink: IAdviseSink; out dwConnection: LongWord): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TSynEditDataObject.DUnadvise (dwConnection: LongWord): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TSynEditDataObject.EnumDAdvise (out enumAdvise: IEnumStatData): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;


//=== BASE ENUM FORMATETC CLASS ================================================

constructor TSynEnumFormatEtc.Create(FormatList: TArray<TClipFormat>;
  Index: integer);
begin
  inherited Create;
  FList := FormatList;
  FIndex := Index;
end;

function TSynEnumFormatEtc.GetFormatEtc(ClipFormat: TClipFormat): TFormatEtc;
begin
  with Result do
  begin
    cfFormat := ClipFormat;
    dwAspect := DVASPECT_CONTENT;
    ptd := nil;
    tymed := TYMED_HGLOBAL;
    lindex := -1;
  end;
end;

// The ppu declares this parameter \out tagFORMATETC\, typed -- the source of
// the RTL unit spells it untyped, but the ppu the compiler resolves is what
// an implementation has to match, so the type is stated here.
function TSynEnumFormatEtc.Next (celt: LongWord; out elt: TFormatEtc; pceltFetched: PLongWord): HResult;
var
  I : integer;
  FormatEtc: PFormatEtc;
begin
  I := 0;
  FormatEtc:= PFormatEtc(@Elt);
  while (I < Celt) and (FIndex < Length(FList)) do
  begin
    FormatEtc^ := GetFormatEtc(FList[FIndex]);
    Inc(FormatEtc);
    Inc (FIndex);
    Inc (I)
  end;

  if (pCeltFetched <> nil) then pCeltFetched^:= i;

  if (I = Celt) then
    Result:= S_OK
  else
    Result:= S_FALSE;
end;

function TSynEnumFormatEtc.Skip (celt: LongWord): HResult;
begin
  Result := S_OK;
  if Celt <= Length(FList) - FIndex then
    FIndex := FIndex + Celt
  else begin
    FIndex := Length(FList);
    Result := S_FALSE
  end
end;

function TSynEnumFormatEtc.Reset : HResult;
begin
  FIndex := 0;
  Result := S_OK;
end;

function TSynEnumFormatEtc.Clone (out Enum: IEnumFormatEtc): HResult;
begin
  Result := S_OK;
  Enum := TSynEnumFormatEtc.Create (FList, FIndex);
end;


initialization
  OleInitialize(nil);
  SynEditClipboardFormat := RegisterClipboardFormat ('Internal SynEdit clipboard format');
finalization
  OleFlushClipboard;
  OleUninitialize;
end.
