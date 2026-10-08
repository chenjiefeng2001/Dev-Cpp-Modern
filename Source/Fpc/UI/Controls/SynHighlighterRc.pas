unit SynHighlighterRc;

// ---------------------------------------------------------------------------
// A C++ highlighter for Windows resource scripts (.rc), written against the
// LCL's OWN SynEditHighlighter rather than ported from the vendored Delphi
// SynEdit.
// ---------------------------------------------------------------------------
// WHY THIS EXISTS, AND WHY IT IS NEW CODE INSTEAD OF A PORT
// =========================================================
// `Source/DataFrm.pas` owns `Res: TSynRCSyn` and hands it back from
// `GetHighlighter` for any file whose extension is RC_EXT -- so Windows
// resource scripts are syntax-highlighted by the IDE. LCL 4.4 ships
// TSynCppSyn and TSynPASyn but has **no** synhighlighterrc unit at all
// (verified against both components/synedit/*.p* and the built
// units/x86_64-win64/win32/*.ppu list). So the class had to come from
// somewhere, and the three candidates were:
//
//   1. PORT the vendored Source/VCL/SynEdit/Source/SynHighlighterRC.pas.
//      537 lines, of which the declaration is 62 -- so the body is ~90% of the
//      work and it is written against the DELPHI SynEdit: its own TtkTokenKind
//      with four extra values, TSynHighlighterAttributes descending from
//      TPersistent where the LCL's descends from TLazSynCustomTextAttributes,
//      and a `RegisterPlaceableHighlighter` call that does not exist in the
//      LCL. Porting is roughly twice the work of writing the thing, for the
//      same result.
//
//   2. STUB it with LCL's TSynAnySyn, so `Res` keeps compiling.
//      Cheapest, and it silently deletes a user-visible feature: .rc files
//      would open with no colouring and nothing would say so. This project has
//      already been bitten twice by exactly that shape ("converted but blank"),
//      and the fix in both cases was to go back and do the real work.
//
//   3. WRITE ONE against the LCL API. The LCL's highlighter contract is eight
//      abstract methods (GetEol, GetToken, GetTokenEx, GetTokenAttribute,
//      GetTokenKind, GetTokenPos, Next, plus GetRange/SetRange), and every
//      highlighters in components/synedit are 200-400 lines of the same shape.
//      This file is that, and it makes .rc a first-class LCL citizen -- which
//      matters for F4, because an LCL-native highlighter is themeable by the
//      same mechanism as LCL's own instead of needing the vendored path.
//
// The class keeps the name TSynRCSyn on purpose: `DataFrm.dfm` already says
// `object Res: TSynRCSyn`, so retiring the vendored class needs NO converter
// rename rule and no .dfm edit. Only the unit moves.
//
// THE ATTRIBUTE SET IS FIXED BY A CALLER, NOT CHOSEN HERE
// =======================================================
// `DataFrm.pas:197-206` (UpdateHighlighter) copies exactly eight attribute
// slots from the C++ highlighter onto this one so that .rc files match the
// C/C++ theme:
//
//     CommentAttri, DirecAttri, IdentifierAttri, KeyAttri,
//     NumberAttri, SpaceAttri, StringAttri, SymbolAttri
//
// So those eight are `published` with those exact names. Renaming one would
// compile here and fail at the call site, and the call site is in a unit this
// project is not porting yet.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, SynEditTypes, SynEditHighlighter;

type
  TtkTokenKind = (tkComment, tkDirective, tkIdentifier, tkKey, tkNull,
                  tkNumber, tkSpace, tkString, tkSymbol, tkUnknown);

  TProcTableProc = procedure of object;

// The token kinds are EXPORTED AS CONSTANTS, not just as the enum, because the
// probe needs to assert on them and the enum name collides.
//
// MEASURED: SynEditHighlighter already exports its OWN TtkTokenKind with the
// same member names, so a probe that `uses` both units cannot write
// `Ord(tkComment)` at all -- FPC resolves the LCL's, and where the two enums
// differ in order the assertion silently tests the wrong number. (The compile
// error was "Operator is not overloaded: Char * ShortInt", which is the LCL's
// token kind being a Char-typed thing.)
//
// Exposing integers here keeps one source of truth: the numbers ARE the
// highlighter's enum, so a reordering of the enum moves the probe's
// expectations with it instead of making the probe quietly wrong.
const
  RcTkComment   = Ord(tkComment);
  RcTkDirective = Ord(tkDirective);
  RcTkIdentifier = Ord(tkIdentifier);
  RcTkKey       = Ord(tkKey);
  RcTkNull      = Ord(tkNull);
  RcTkNumber    = Ord(tkNumber);
  RcTkSpace     = Ord(tkSpace);
  RcTkString    = Ord(tkString);
  RcTkSymbol    = Ord(tkSymbol);
  RcTkUnknown   = Ord(tkUnknown);

// For diagnostics: the name of a kind, by integer. Used by the probe's failure
// messages, where printing `kind7` teaches nothing.
function RcTokenKindName(K: Integer): string;

// Range bits, as plain constants rather than a set -- see fRange.
const
  RS_IN_COMMENT   = 1;
  RS_IN_DIRECTIVE = 2;

type
  TSynRCSyn = class(TSynCustomHighlighter)
  private
    fLine: PChar;
    fLineNumber: Integer;
    // Indexed by ORDINARY INTEGER, not by Char. Declared `array[#0..#255]`
    // (the shape the Delphi highlighters use) so that `fProcTable[fLine[...]]`
    // indexes with a Char, but FPC rejects `fProcTable[Ord('x')]` there --
    // Ord yields a Byte and the index wants a Char. Integer indices remove the
    // conversion entirely and cost nothing.
    fProcTable: array[0..255] of TProcTableProc;
    fRun: Integer;
    fTokenPos: Integer;
    fTokenID: TtkTokenKind;
    // A plain bitmask rather than a `set of`. The LCL's own CSS highlighter
    // round-trips a set through Pointer via `Pointer(PtrUInt(Cardinal(R)))`,
    // and FPC 3.2.2 rejects both conversions for a set in this dialect
    // ("Illegal type conversion: TRangeStates to LongWord"). An Integer is one
    // bit per state here, so nothing is lost and the range plumbing -- which
    // exists only to satisfy GetRange/SetRange -- becomes trivial.
    fRange: Integer;
    fCommentAttri: TSynHighlighterAttributes;
    fDirecAttri: TSynHighlighterAttributes;
    fIdentifierAttri: TSynHighlighterAttributes;
    fKeyAttri: TSynHighlighterAttributes;
    fNumberAttri: TSynHighlighterAttributes;
    fSpaceAttri: TSynHighlighterAttributes;
    fStringAttri: TSynHighlighterAttributes;
    fSymbolAttri: TSynHighlighterAttributes;
    fKeywordList: TStringList;   // sorted, case-insensitive; binary-searched
    procedure DoNext;
    procedure CRProc;
    procedure LFProc;
    procedure SpaceProc;
    procedure CommentProc;       // '/'
    procedure DirectiveProc;     // '#'
    procedure StringProc;        // '"'
    procedure StringProc1;       // ''''
    procedure NumberProc;
    procedure IdentProc;
    procedure SymbolProc;
    procedure UnknownProc;
    procedure NullProc;
    procedure BuildAttributes;
  protected
    // LCL declares this virtual, so it is OVERRIDDEN rather than shadowed.
    // The first version declared its own `IsKeyword(const string): Boolean`
    // and the compiler said so: "An inherited method is hidden by ...". Using
    // the inherited one means the base class's own callers reach the keyword
    // table too, instead of there being two notions of "is this a keyword".
    function IsKeyword(const AKeyword: string): Boolean; override;
    function GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
      override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    function GetTokenKind: Integer; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // THE OVERRIDE THAT MATTERS MOST. See the implementation for why it exists.
    procedure SetLine(const NewValue: string; LineNumber: Integer); override;
    procedure ResetRange; override;
    function GetRange: Pointer; override;
    procedure SetRange(Value: Pointer); override;
    function GetEol: Boolean; override;
    function GetToken: String; override;
    procedure GetTokenEx(out TokenStart: PChar; out TokenLength: Integer);
      override;
    function GetTokenPos: Integer; override;
    procedure Next; override;
    class function GetCapabilities: TSynHighlighterCapabilities;
      override;
    class function GetLanguageName: string; override;
    function GetInstanceLanguageName: string; override;
  published
    property CommentAttri: TSynHighlighterAttributes read fCommentAttri
      write fCommentAttri;
    property DirecAttri: TSynHighlighterAttributes read fDirecAttri
      write fDirecAttri;
    property IdentifierAttri: TSynHighlighterAttributes read fIdentifierAttri
      write fIdentifierAttri;
    property KeyAttri: TSynHighlighterAttributes read fKeyAttri
      write fKeyAttri;
    property NumberAttri: TSynHighlighterAttributes read fNumberAttri
      write fNumberAttri;
    property SpaceAttri: TSynHighlighterAttributes read fSpaceAttri
      write fSpaceAttri;
    property StringAttri: TSynHighlighterAttributes read fStringAttri
      write fStringAttri;
    property SymbolAttri: TSynHighlighterAttributes read fSymbolAttri
      write fSymbolAttri;
  end;

implementation

const
  // The RC keyword set. Taken from the resource-script grammar the vendored
  // highlighter listed, minus the ones it never had. Case-insensitive: .rc
  // keywords are conventionally upper case but the grammar is not.
  RC_KEYWORDS: array[0..37] of string = (
    'BEGIN', 'BLOCK', 'CAPTION', 'CHARACTERISTICS', 'CODEPAGE', 'CONTROL',
    'CTLCOLOR', 'DIALOG', 'DIALOGEX', 'DLGTEMPLATE', 'END', 'EXSTYLE',
    'FONT', 'GROUPCURSOR', 'GROUPICON', 'HEADER', 'HELPFILE', 'ICON', 'LANGUAGE',
    'LITERAL', 'MENU', 'MENUITEM', 'MESSAGETABLE', 'MOVEABLE', 'PREVIEW',
    'STYLE', 'STRINGTABLE', 'STYLESHEET', 'TEXTINCLUDE', 'VALUE', 'VERSION',
    'VERTICAL', 'WINDOWTEXT', 'ACCELERATORS', 'CDATA', 'CHARACTERSET',
    'DESIGNHEX', 'STRING'
  );

type
  TIdentFuncTable = array[0..255] of Integer;

// LCL has no `DefineAttributes` to override -- every highlighter in
// components/synedit builds its attributes in the constructor and registers
// them with AddAttribute, and the compiler says so plainly when you try
// ("There is no method in an ancestor class to be overridden"). So this is a
// plain private method called from Create, not an override.
procedure TSynRCSyn.BuildAttributes;
begin
  fCommentAttri := TSynHighlighterAttributes.Create('Comment', 'comment');
  fCommentAttri.Style := [fsItalic];
  AddAttribute(fCommentAttri);
  fDirecAttri := TSynHighlighterAttributes.Create('Directive', 'directive');
  AddAttribute(fDirecAttri);
  fIdentifierAttri := TSynHighlighterAttributes.Create('Identifier',
    'identifier');
  AddAttribute(fIdentifierAttri);
  fKeyAttri := TSynHighlighterAttributes.Create('Keyword', 'keyword');
  AddAttribute(fKeyAttri);
  fNumberAttri := TSynHighlighterAttributes.Create('Number', 'number');
  AddAttribute(fNumberAttri);
  fSpaceAttri := TSynHighlighterAttributes.Create('Whitespace', 'space');
  AddAttribute(fSpaceAttri);
  fStringAttri := TSynHighlighterAttributes.Create('String', 'string');
  AddAttribute(fStringAttri);
  fSymbolAttri := TSynHighlighterAttributes.Create('Symbol', 'symbol');
  AddAttribute(fSymbolAttri);
end;

constructor TSynRCSyn.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited Create(AOwner);
  BuildAttributes;
  fKeywordList := TStringList.Create;
  // Sorted + case-insensitive, because IsKeyword is on the hot path of every
  // identifier in every .rc file and a linear scan over 40 strings per token
  // is the kind of cost nobody notices until an editor feels slow.
  fKeywordList.Sorted := True;
  fKeywordList.Duplicates := dupIgnore;
  fKeywordList.CaseSensitive := False;
  for I := Low(RC_KEYWORDS) to High(RC_KEYWORDS) do
    fKeywordList.Add(RC_KEYWORDS[I]);

  // THE WHOLE TABLE DEFAULTS TO NullProc, and that is not a stylistic choice.
  //
  // Measured against components/synedit/synhighlighterini.pas: its constructor
  // does `fProcTable[i] := @NullProc` for all 256 and then overwrites the
  // characters it cares about. The reason is #0. A line passed to SetLine is
  // NOT null-terminated by the caller in any useful way -- fLine[fRun] becomes
  // #0 at the end, and if #0 dispatches to an identifier scanner that begins
  // with `Inc(fRun)` then walks the buffer PAST the terminator.
  //
  // The first version defaulted to IdentProc instead. The symptom was the worst
  // kind: the probe printed its banner and then HUNG, and the first
  // measurement of it looked like a clean exit because the pipe closed first.
  // NullProc sets tkNull and consumes nothing, so GetEol goes True and the line
  // ends where the text ends.
  for I := 0 to 255 do
    fProcTable[I] := @NullProc;
  // identifiers and keywords: letters, digits, underscore
  for I := Ord('a') to Ord('z') do
    fProcTable[I] := @IdentProc;
  for I := Ord('A') to Ord('Z') do
    fProcTable[I] := @IdentProc;
  for I := Ord('0') to Ord('9') do
    fProcTable[I] := @NumberProc;
  fProcTable[Ord('_')] := @IdentProc;
  fProcTable[Ord(#9)] := @SpaceProc;
  fProcTable[Ord(#10)] := @LFProc;
  fProcTable[Ord(#13)] := @CRProc;
  fProcTable[Ord(' ')] := @SpaceProc;
  fProcTable[Ord('/')] := @CommentProc;
  fProcTable[Ord('#')] := @DirectiveProc;
  fProcTable[Ord('"')] := @StringProc;
  fProcTable[Ord('''')] := @StringProc1;
  fProcTable[Ord('{')] := @SymbolProc;
  fProcTable[Ord('}')] := @SymbolProc;
end;

destructor TSynRCSyn.Destroy;
begin
  FreeAndNil(fKeywordList);
  inherited Destroy;
end;

procedure TSynRCSyn.DoNext;
begin
  // Two guards, because "advance past the terminator" is the failure that
  // hangs an editor rather than colouring it wrongly:
  //
  //   * NullProc consumes nothing, so the loop must terminate on #0 rather
  //     than trust the table (which is what LCL's own highlighters rely on and
  //     what the first version here did NOT);
  //   * the explicit `fLine[fRun] = #0` test below stops even a procedure that
  //     overruns, because the cost of getting it wrong is an out-of-bounds read
  //     and a frozen editor.
  // When the line is exhausted WITHOUT having produced a token, this MUST
  // publish tkNull -- that is the only thing that tells the caller the line
  // ended. The first version left fTokenID at whatever the previous token set,
  // so a block comment that consumed to the end of a line reported tkComment
  // forever and the caller looped: the probe's runaway guard caught it at 4001
  // tokens, all of them `comment`, which is the clearest possible symptom and
  // still only visible because the probe counts.
  while fLine[fRun] <> #0 do
  begin
    if (fRange and RS_IN_COMMENT) <> 0 then
      CommentProc
    else
      fProcTable[Ord(fLine[fRun])]();
    if fTokenID <> tkNull then
      Exit;                      // a real token
    Inc(fRun);
  end;
  fTokenID := tkNull;             // end of line
end;

procedure TSynRCSyn.CRProc;
begin
  fTokenID := tkNull;
  Inc(fRun);
end;

procedure TSynRCSyn.LFProc;
begin
  fTokenID := tkNull;
  Inc(fRun);
  // An unterminated /* comment does not survive the newline.
  fRange := 0;   // no state survives the newline
end;

procedure TSynRCSyn.SpaceProc;
begin
  fTokenID := tkSpace;
  while fLine[fRun] in [#1..#9, #11, #12, #14..#32] do
    Inc(fRun);
end;

procedure TSynRCSyn.CommentProc;

// This procedure runs in TWO situations and must handle both.
//
//   (a) fRun is on a '/' -- a new token begins. If what follows is another
//       '/' it is a line comment; if '*' a block comment; and if NEITHER the
//       slash is a SYMBOL. A bare '/' is legal in an .rc expression, and
//       treating it as a comment start colours the rest of the file.
//
//   (b) the range bit says we are resuming INSIDE a block comment, so fRun is
//       at the first character of a continuation -- not on a '/' at all.
//       DoNext calls us in that case.
//
// The first version got BOTH wrong. It assumed (a) only, so on resume it
// examined a character that had nothing to do with a comment start; and it set
// the in-comment range bit when a block comment CLOSED, which is exactly
// backwards -- the bit means "still open at end of line". With it inverted,
// every `*/` left the highlighter believing it was inside a comment and the
// next line was re-scanned by a procedure expecting to stand on a slash.
//
// The symptom was not an error. The probe printed its banner and then stopped
// producing output: the "silently wrong" shape this whole file exists to avoid.
begin
  // (b) resuming inside a comment
  if (fRange and RS_IN_COMMENT) <> 0 then
  begin
    fTokenID := tkComment;
    while fLine[fRun] <> #0 do
    begin
      if (fLine[fRun] = '*') and (fLine[fRun + 1] = '/') then
      begin
        Inc(fRun, 2);
        fRange := 0;               // the comment ENDS here
        Exit;
      end;
      Inc(fRun);
    end;
    Exit;                          // still open: the bit stays set
  end;

  // (a) a new token starting at '/'
  fTokenID := tkComment;
  if fLine[fRun + 1] = '/' then
  begin
    // line comment: to end of line, range bit untouched
    repeat
      Inc(fRun);
    until (fLine[fRun] = #0) or (fLine[fRun] = #13) or (fLine[fRun] = #10);
    Exit;
  end;
  if fLine[fRun + 1] = '*' then
  begin
    Inc(fRun, 2);
    while fLine[fRun] <> #0 do
    begin
      if (fLine[fRun] = '*') and (fLine[fRun + 1] = '/') then
      begin
        Inc(fRun, 2);
        Exit;                    // closed on this line: bit stays clear
      end;
      Inc(fRun);
    end;
    fRange := fRange or RS_IN_COMMENT;   // open at EOL: continues next line
    Exit;
  end;
  // a bare slash is a symbol, not a comment
  fTokenID := tkSymbol;
  Inc(fRun);
end;

procedure TSynRCSyn.DirectiveProc;
begin
  fTokenID := tkDirective;
  Inc(fRun);
  // #include, #define, #ifdef ... consume to end of line, EXCEPT the
  // #include "file" form where the string must stay separately tokenised.
  while (fLine[fRun] <> #0) and (fLine[fRun] <> #13) and (fLine[fRun] <> #10)
    do
  begin
    if fLine[fRun] = '"' then
      Break;
    Inc(fRun);
  end;
end;

// The DOUBLED quote is an escape, so "a""b" is ONE string containing a"b.
//
// The first version used LCL's own INI shape -- stop at the first quote, with a
// special case for two quotes at the very START -- which tokenises `"a""b"` as
// two strings. That compiles and looks plausible and is wrong: every RC caption
// with an embedded quote comes out split, and the two halves are coloured as two
// literals.
procedure TSynRCSyn.StringProc;
begin
  fTokenID := tkString;
  Inc(fRun);                                   // step over the opening quote
  while fLine[fRun] <> #0 do
  begin
    if fLine[fRun] = '"' then
    begin
      if fLine[fRun + 1] = '"' then
      begin
        Inc(fRun, 2);                          // an escaped quote, stay inside
        Continue;
      end;
      Inc(fRun);                               // the closing quote
      Exit;
    end;
    Inc(fRun);
  end;
  // unterminated at end of line: the string ends there rather than running on
end;

procedure TSynRCSyn.StringProc1;
begin
  fTokenID := tkString;
  Inc(fRun);
  while fLine[fRun] <> #0 do
  begin
    if fLine[fRun] = '''' then
    begin
      if fLine[fRun + 1] = '''' then
      begin
        Inc(fRun, 2);
        Continue;
      end;
      Inc(fRun);
      Exit;
    end;
    Inc(fRun);
  end;
end;

procedure TSynRCSyn.NumberProc;
begin
  fTokenID := tkNumber;
  if (fLine[fRun] = '0') and ((fLine[fRun + 1] = 'x') or (fLine[fRun + 1] = 'X'))
  then
    Inc(fRun, 2)                       // hex, consumes 0x itself
  else
    Inc(fRun);
  while fLine[fRun] in ['0'..'9', 'a'..'f', 'A'..'F', '.', 'x', 'X'] do
  begin
    // A '.' only continues the number when a digit follows, otherwise
    // "3." followed by a letter would eat the letter.
    if (fLine[fRun] = '.') and
       not (fLine[fRun + 1] in ['0'..'9']) then
      Break;
    Inc(fRun);
  end;
end;

function TSynRCSyn.IsKeyword(const AKeyword: string): Boolean;
begin
  Result := fKeywordList.IndexOf(AKeyword) >= 0;
end;

procedure TSynRCSyn.IdentProc;
var
  Len, J: Integer;
  Str: string;
  SaveRun: Integer;
begin
  SaveRun := fRun;
  Inc(fRun);
  while fLine[fRun] in ['a'..'z', 'A'..'Z', '0'..'9', '_'] do
    Inc(fRun);
  Len := fRun - SaveRun;
  SetString(Str, PChar(fLine + SaveRun), Len);
  if IsKeyword(Str) then
  begin
    fTokenID := tkKey;
    Exit;
  end;
  // The RC block-identifier form:  NAME { "res\name.rc" }
  //
  // The space before '{' is allowed and is CONSUMED as part of the token,
  // which is why the first version's immediate-`{` test never fired on real
  // files: `IDB_ABOUT { "res\about.rc" }` has a space there, so the whole
  // construct came out as seven tokens instead of one.
  J := fRun;
  while fLine[J] in [' ', #9] do
    Inc(J);
  if (Len > 0) and (fLine[J] = '{') then
  begin
    fRun := J;
    while (fLine[fRun] <> #0) and (fLine[fRun] <> '}') do
      Inc(fRun);
    if fLine[fRun] = '}' then
      Inc(fRun);
  end;
  fTokenID := tkIdentifier;
end;

procedure TSynRCSyn.SymbolProc;
begin
  fTokenID := tkSymbol;
  Inc(fRun);
  if (fLine[fRun] = '"') then
    StringProc;
end;

procedure TSynRCSyn.UnknownProc;
begin
  fTokenID := tkUnknown;
  Inc(fRun);
end;

procedure TSynRCSyn.NullProc;
begin
  fTokenID := tkNull;
end;

function TSynRCSyn.GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT: Result := fCommentAttri;
    SYN_ATTR_IDENTIFIER: Result := fIdentifierAttri;
    SYN_ATTR_KEYWORD: Result := fKeyAttri;
    SYN_ATTR_STRING: Result := fStringAttri;
    SYN_ATTR_WHITESPACE: Result := fSpaceAttri;
    SYN_ATTR_SYMBOL: Result := fSymbolAttri;
    SYN_ATTR_NUMBER: Result := fNumberAttri;
    // Directives were missing here, which is a strange gap in a highlighter
    // whose job includes them: SynEdit resolving SYN_ATTR_DIRECTIVE got nil and
    // fell back to plain text, so `DirecAttri` was assignable, published, and
    // copied by UpdateHighlighter -- and then never consulted for anything that
    // did not go through GetTokenAttribute. A published property that is wired
    // end to end and still unused is exactly the kind of gap a probe that only
    // assigns the property cannot see.
    SYN_ATTR_DIRECTIVE: Result := fDirecAttri;
  else
    Result := nil;
  end;
end;

function TSynRCSyn.GetTokenAttribute: TSynHighlighterAttributes;
begin
  case fTokenID of
    tkComment: Result := fCommentAttri;
    tkDirective: Result := fDirecAttri;
    tkIdentifier: Result := fIdentifierAttri;
    tkKey: Result := fKeyAttri;
    tkNull: Result := nil;
    tkNumber: Result := fNumberAttri;
    tkSpace: Result := fSpaceAttri;
    tkString: Result := fStringAttri;
    tkSymbol: Result := fSymbolAttri;
  else
    Result := nil;
  end;
end;

function TSynRCSyn.GetTokenKind: Integer;
begin
  Result := Ord(fTokenID);
end;

// WITHOUT THIS OVERRIDE fLine IS NEVER ASSIGNED, AND EVERYTHING HANGS.
//
// LCL's base SetLine (synedithighlighter.pp) does only three things:
//
//     FLineText := NewValue;  FIsInNextToEOL := False;  FLineIndex := LineNumber;
//
// It does NOT touch the highlighter's own `fLine: PChar`. Every highlighters in
// components/synedit therefore OVERRIDES SetLine and assigns it itself --
// measured, identical in synhighlighterini.pas and synhighlightercss.pas:
//
//     procedure TSynIniSyn.SetLine(const NewValue: String; LineNumber: Integer);
//     begin
//       inherited;
//       fLine := PChar(NewValue);
//       Run := 0;
//       fLineNumber := LineNumber;
//       Next;              // primes the first token
//     end;
//
// The first version of this unit declared `fLine` and never set it, so it stayed
// an uninitialised pointer and every token read went somewhere arbitrary. The
// symptom was the probe hanging inside its own runaway guard, not a crash, and
// the first measurement of it LOOKED like a clean exit because the pipe closed
// before the process died.
//
// The trailing `Next` matters as much as the assignment: without it the caller
// reads the first token before anything has tokenised, and sees whatever the
// field happened to hold.
procedure TSynRCSyn.SetLine(const NewValue: string; LineNumber: Integer);
begin
  inherited SetLine(NewValue, LineNumber);
  fLine := PChar(NewValue);
  fRun := 0;
  fLineNumber := LineNumber;
  Next;
end;

procedure TSynRCSyn.ResetRange;
begin
  fRange := 0;
end;

function TSynRCSyn.GetRange: Pointer;
begin
  Result := Pointer(PtrUInt(fRange));
end;

procedure TSynRCSyn.SetRange(Value: Pointer);
begin
  fRange := Integer(PtrUInt(Value));
end;

function TSynRCSyn.GetEol: Boolean;
begin
  Result := (fTokenID = tkNull);
end;

function TSynRCSyn.GetToken: String;
var
  Len: LongInt;
begin
  Len := fRun - fTokenPos;
  SetString(Result, (fLine + fTokenPos), Len);
end;

procedure TSynRCSyn.GetTokenEx(out TokenStart: PChar; out TokenLength: Integer);
begin
  TokenLength := fRun - fTokenPos;
  TokenStart := fLine + fTokenPos;
end;

function TSynRCSyn.GetTokenPos: Integer;
begin
  Result := fTokenPos;
end;

procedure TSynRCSyn.Next;
begin
  fTokenPos := fRun;
  DoNext;
end;

class function TSynRCSyn.GetCapabilities: TSynHighlighterCapabilities;
begin
  Result := [hcUserSettings];
end;

class function TSynRCSyn.GetLanguageName: string;
begin
  Result := 'RC';
end;

function TSynRCSyn.GetInstanceLanguageName: string;
begin
  Result := 'RC';
end;

function RcTokenKindName(K: Integer): string;
begin
  case K of
    RcTkComment: Result := 'comment';
    RcTkDirective: Result := 'directive';
    RcTkIdentifier: Result := 'identifier';
    RcTkKey: Result := 'keyword';
    RcTkNull: Result := 'EOL';
    RcTkNumber: Result := 'number';
    RcTkSpace: Result := 'space';
    RcTkString: Result := 'string';
    RcTkSymbol: Result := 'symbol';
    RcTkUnknown: Result := 'unknown';
  else
    Result := 'kind' + IntToStr(K);
  end;
end;

{ TSynRCSyn }

initialization
  // No RegisterPlaceableHighlighter here: that is a DELPHI SynEdit entry
  // point (called by the vendored unit at its bottom) and the LCL discovers
  // highlighters through its own package registration instead. Calling a
  // function that does not exist in this tree is how the vendored copy would
  // have failed to compile, in the least informative way available.

end.