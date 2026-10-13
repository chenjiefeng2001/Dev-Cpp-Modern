unit LclTextInput;

{$mode delphiunicode}{$H+}

interface

uses
  Dialogs, SysUtils;

// UnicodeInputQuery is InputQuery for callers that are Unicode.
//
// Why it exists -- the evidence, not a preference:
//
//   C:\lazarus\lcl\controls.pp:21    mode objfpc, H+
//   C:\lazarus\lcl\lcltype.pp:68     TTranslateString = type String;
//   C:\lazarus\lcl\controls.pp:1579   property Text: TCaption read GetText write SetText;
//
// The LCL is compiled objfpc, where `string` IS AnsiString, so TCaption and
// therefore TCustomEdit.Text are AnsiString. Dialogs.InputQuery's value parameter
// is `var Value: string` -- also AnsiString. Under -Mdelphiunicode every one of
// our call sites holds a UnicodeString, and the compiler reports the mismatch as
//
//     Call by var for arg no. 3 has to match exactly:
//     Got "UnicodeString" expected an open array of AnsiString
//
// The important consequence is the one that is easy to get wrong: building our
// own dialog does NOT fix this. A hand-rolled TForm with a TEdit on it reads the
// same AnsiString out of the same edit control. The widgetset has no Unicode
// text-entry path to relocate the problem into, so this is a recorded capability
// boundary rather than a shortcut around a cheap fix.
//
// What we do get is the system code page, which is what the widgetset can offer
// at all: on this machine GetACP() is 936 (GBK), so CJK and accented Latin text
// round-trips faithfully. The translation strings go through the same code page,
// which is the same limitation already recorded for fStrings.LoadFromFile with
// TEncoding.ANSI -- the .lng files carry their own code page, not the ACP.
//
// Returns False if the user cancels; AValue is then left untouched.
function UnicodeInputQuery(const ACaption, APrompt: UnicodeString; var AValue: UnicodeString): Boolean;

implementation

function UnicodeInputQuery(const ACaption, APrompt: UnicodeString; var AValue: UnicodeString): Boolean;
var
  CaptionAnsi: AnsiString;
  PromptAnsi: AnsiString;
  ValueAnsi: AnsiString;
begin
  // TEncoding.Default is the TUnicodeSystemEncoding for this platform, i.e. it
  // uses the ACP -- NOT UTF-8. Using UTF-8 here would look correct in a test on
  // an ASCII prompt and then mangle every non-ASCII character, because the
  // dialog itself is interpreting these bytes as ACP.
  //
  // GetBytes/GetString rather than TEncoding.GetAnsiString: GetAnsiString takes
  // a TBytes and returns an AnsiString, so it would force a byte buffer on the
  // decode side anyway. This way each side asks the encoding to do what it is
  // actually for.
  CaptionAnsi := TEncoding.Default.GetString(TEncoding.Default.GetBytes(ACaption));
  PromptAnsi := TEncoding.Default.GetString(TEncoding.Default.GetBytes(APrompt));
  ValueAnsi := TEncoding.Default.GetString(TEncoding.Default.GetBytes(AValue));

  Result := InputQuery(CaptionAnsi, PromptAnsi, ValueAnsi);

  if Result then
    AValue := TEncoding.Default.GetString(TEncoding.Default.GetBytes(ValueAnsi));
end;

end.
