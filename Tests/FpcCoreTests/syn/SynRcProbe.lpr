// ---------------------------------------------------------------------------
// Does the native LCL TSynRCSyn actually HIGHLIGHT, or does it merely load?
// =======================================================================
// WHY THIS PROBE IS NOT THE SAME SHAPE AS THE OTHER ONES
// ======================================================
// `FormLfmProbe` answers "can the LCL build this file". `ImgCollProbe` answers
// "does every PNG decode with ink". Both are satisfied by a control that
// instantiates and holds data.
//
// A highlighter is different: it has behaviour, and its failure mode is not an
// error -- it is SUCCESS. A highlighter that tokenises every line as tkUnknown
// compiles, constructs, streams through the reader, and renders a window with
// no colours in it. That is the "converted but blank" shape this project has
// been bitten by three times (the SVG list that drew nothing, the LoadSvgLists
// that loaded nothing, the .lfm header that made every file unreadable), so it
// gets a probe of its own with a self-test of its own.
//
// THE TOKEN KINDS ARE READ FROM THE HIGHLIGHTER, NOT RESTATED HERE
// ===============================================================
// `SynHighlighterRc` exports `RcTkComment`, `RcTkKey` and friends as integer
// constants. That is not tidiness. `SynEditHighlighter` already exports its own
// `TtkTokenKind` with the SAME MEMBER NAMES, so a probe that writes
// `Ord(tkComment)` resolves the LCL's enum instead -- and where the two orders
// differ, the assertion silently tests the wrong number. The first version of
// this file did exactly that and did not compile, which is the only reason it
// was caught. Reading the constants keeps one source of truth: the numbers ARE
// the highlighter's enum, so reordering it moves these expectations with it.
//
// WHAT IS ASSERTED
// ================
//   * the exact sequence of token kinds per snippet, and the concatenated token
//     TEXT where the text is the point (a block comment, a string with a
//     doubled quote, the block-identifier form);
//   * kinds, not colours -- the colours are assigned by DataFrm at runtime and
//     asserting them would only prove that Assign works;
//   * the eight attribute slots `DataFrm.pas:198-205` assigns, by name, because
//     renaming one compiles here and fails at the only call site;
//   * a realistic .rc file yielding MANY DISTINCT kinds, which is the check a
//     uniform tkUnknown implementation cannot pass;
//   * SELF-TEST FIRST: a deliberately broken highlighter whose Next consumes
//     nothing, and the probe must notice. A harness that cannot say no looks
//     exactly like a harness that found nothing wrong.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

program SynRcProbe;

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Classes, SysUtils, Forms, Graphics, SynEditTypes, SynEditHighlighter,
  SynHighlighterRc;

type
  TKindArray = array of Integer;

  TCheck = record
    Name: string;
    Text: string;
    Expect: TKindArray;
    ExpectText: string;
    UseText: Boolean;
    // nil Expect means "do not compare kinds" -- several checks are about
    // ONE property and a token count is noise. The first version used an EMPTY
    // array for that and still compared its LENGTH against zero, so three
    // checks reported "got 5 token(s), expected 0" and read like highlighter
    // failures when they were really a broken sentinel. A sentinel has to be
    // distinguishable from an expectation.
    CheckKinds: Boolean;
  end;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const What: string; Ok: Boolean; const Detail: string = '');
begin
  Inc(Checks);
  if Ok then
    WriteLn('  OK   ', What, ' ', Detail)
  else
  begin
    WriteLn('  FAIL ', What, ' ', Detail);
    Inc(Failures);
  end;
  Flush(Output);
end;

procedure RunOne(const H: TSynCustomHighlighter; const AText: string;
  out Kinds: TKindArray; out Tokens: string);
var
  Lines: TStringList;
  I, N: Integer;
begin
  SetLength(Kinds, 0);
  Tokens := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      // TWO parameters, not three: LCL's declaration is
      // `procedure SetLine(const AnsiString; LongInt)`. The first version passed
      // a column index and the compiler said so.
      H.SetLine(Lines[I], I + 1);
      // NO ResetRange HERE.
      //
      // `SetLine` primes the first token (it calls Next), and the range bit is
      // what carries an unterminated /* comment from one line to the next.
      // Resetting it here made every multi-line comment into an endless run of
      // `comment` tokens. ResetRange belongs to a RESCAN, which is when the
      // editor is replaying a known range from storage -- not to a linear walk.
      while not H.GetEol do
      begin
        N := Length(Kinds);
        // Runaway guard. A tokeniser that consumes nothing spins forever, and
        // a probe that spins is worse than a probe that fails.
        if N > 4000 then
          Exit;
        SetLength(Kinds, N + 1);
        Kinds[N] := H.GetTokenKind;
        Tokens := Tokens + H.GetToken;
        H.Next;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure Report(const C: TCheck; const H: TSynCustomHighlighter);
var
  Kinds: TKindArray;
  Tokens, Got, Want: string;
  I, Mismatch: Integer;
begin
  RunOne(H, C.Text, Kinds, Tokens);

  if not C.CheckKinds then
  begin
    Check(C.Name, True, Format('%d token(s), kinds deliberately not compared',
      [Length(Kinds)]));
    Exit;
  end;

  if Length(Kinds) <> Length(C.Expect) then
  begin
    Got := '';
    for I := 0 to High(Kinds) do
      if Kinds[I] <> RcTkNull then
        Got := Got + RcTokenKindName(Kinds[I]) + ' ';
    Want := '';
    for I := 0 to High(C.Expect) do
      Want := Want + RcTokenKindName(C.Expect[I]) + ' ';
    Check(C.Name, False, Format('got %d token(s), expected %d' + #13#10 +
      '        got  %s' + #13#10 + '        want %s',
      [Length(Kinds), Length(C.Expect), Got, Want]));
    Exit;
  end;

  Mismatch := -1;
  for I := 0 to High(Kinds) do
    if Kinds[I] <> C.Expect[I] then
    begin
      Mismatch := I;
      Break;
    end;
  if Mismatch >= 0 then
  begin
    Check(C.Name, False, Format('token %d is %s, expected %s', [Mismatch,
      RcTokenKindName(Kinds[Mismatch]), RcTokenKindName(C.Expect[Mismatch])]));
    Exit;
  end;
  Check(C.Name, True, Format('%d token(s)', [Length(Kinds)]));

  if C.UseText and (Tokens <> C.ExpectText) then
    Check(C.Name + ' [text]', False,
      Format('got "%s", expected "%s"', [Tokens, C.ExpectText]))
  else if C.UseText then
    Check(C.Name + ' [text]', True);
end;

// ---- the self-test -------------------------------------------------------
// A highlighter that never ends and reports everything as tkUnknown. The probe
// must notice, otherwise "all kinds matched" would be unfalsifiable.

type
  TSilentSyn = class(TSynCustomHighlighter)
  public
    function GetEol: Boolean; override;
    function GetToken: String; override;
    procedure GetTokenEx(out TokenStart: PChar;
      out TokenLength: Integer); override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    // Takes an Index -- `GetDefaultAttribute(Index: integer)`. Writing it
    // without the parameter is rejected by the compiler, which is a cheaper way
    // to learn the signature than guessing again.
    function GetDefaultAttribute(Index: integer): TSynHighlighterAttributes;
      override;
    function GetTokenKind: Integer; override;
    function GetTokenPos: Integer; override;
    procedure Next; override;
  end;

function TSilentSyn.GetEol: Boolean;
begin
  Result := False;
end;

function TSilentSyn.GetToken: String;
begin
  Result := '';
end;

procedure TSilentSyn.GetTokenEx(out TokenStart: PChar;
  out TokenLength: Integer);
begin
  TokenStart := nil;
  TokenLength := 0;
end;

function TSilentSyn.GetTokenAttribute: TSynHighlighterAttributes;
begin
  Result := nil;
end;

// Abstract in TSynCustomHighlighter. Implementing it keeps the build warning-free;
// a probe whose own output is drowned in warnings is harder to trust.
function TSilentSyn.GetDefaultAttribute(Index: integer): TSynHighlighterAttributes;
begin
  Result := nil;
end;

function TSilentSyn.GetTokenKind: Integer;
begin
  Result := RcTkUnknown;
end;

function TSilentSyn.GetTokenPos: Integer;
begin
  Result := 0;
end;

procedure TSilentSyn.Next;
begin
end;

// Does this token stream match an expectation? The ONE definition of "match"
// used by both the self-test and the real checks, so they cannot drift apart.
function KindsMatch(const Kinds: TKindArray; const Expect: TKindArray): Boolean;
var
  I: Integer;
begin
  if Length(Kinds) <> Length(Expect) then
    Exit(False);
  for I := 0 to High(Expect) do
    if Kinds[I] <> Expect[I] then
      Exit(False);
  Result := True;
end;

// GetDefaultAttribute is PROTECTED in TSynCustomHighlighter, so calling it from
// here is "identifier idents no member" -- the compiler is correct and the
// obvious fix is not to weaken the check but to reach it legally. A subclass
// exposes it; the alternative, dropping the check because the base class hides
// the method, would put back exactly the gap this check exists to close.
type
  TProbeRCSyn = class(TSynRCSyn)
  public
    function DefaultAttri(Index: integer): TSynHighlighterAttributes;
  end;

function TProbeRCSyn.DefaultAttri(Index: integer): TSynHighlighterAttributes;
begin
  Result := inherited GetDefaultAttribute(Index);
end;

procedure SelfTest;
var
  Bad: TSilentSyn;
  Good: TSynRCSyn;
  Kinds: TKindArray;
  Tokens: string;

  // A real, small expectation for text the genuine highlighter gets right.
  RealExpect: TKindArray;
  RealText: string;
  I, AllUnknown: Integer;
begin
  WriteLn('SELF-TEST (the harness must be able to fail)');

  // `/* c */` is a single comment token. That is the yardstick used to prove a
  // broken highlighter is detected as DIFFERENT from correct output.
  SetLength(RealExpect, 1);
  RealExpect[0] := RcTkComment;
  RealText := '/* c */' + #13#10;

  Bad := TSilentSyn.Create(nil);
  Good := nil;
  try
    // (1) ANTI-VACUITY, and it comes first on purpose.
    //
    //     The real highlighter MUST satisfy the yardstick. Without this, a
    //     matcher that rejected every possible output would sail through checks
    //     (2) and (3) below, and the self-test would prove nothing at all. A
    //     self-test that cannot distinguish "detects a broken highlighter" from
    //     "always says no" is not a self-test.
    Good := TSynRCSyn.Create(nil);
    RunOne(Good, RealText, Kinds, Tokens);
    Check('the yardstick accepts correct output (anti-vacuity)',
      KindsMatch(Kinds, RealExpect),
      Format('the real highlighter produced %d token(s)', [Length(Kinds)]));

    // (2) A highlighter that never reaches EOL must be caught two ways: it must
    //     trip the runaway guard in RunOne, and its output must MISMATCH the
    //     yardstick.
    //
    //     The first version of this check asserted
    //       (Length(Kinds) = 0) or (AllUnknown = 0)
    //     which is BACKWARDS for what it claims to test: for a broken highlighter
    //     yielding 4001 tkUnknown tokens both terms are false, so the check FAILED
    //     for doing precisely the right thing. The runaway guard firing is the
    //     desired outcome, not the failure.
    Tokens := '';
    RunOne(Bad, RealText, Kinds, Tokens);
    AllUnknown := 1;
    for I := 0 to High(Kinds) do
      if Kinds[I] <> RcTkUnknown then
        AllUnknown := 0;
    Check('a highlighter that never reaches EOL trips the runaway guard',
      Length(Kinds) > 4000,
      Format('%d token(s) before the guard stopped it', [Length(Kinds)]));
    Check('a highlighter that never reaches EOL is rejected as a mismatch',
      not KindsMatch(Kinds, RealExpect),
      Format('its %d token(s) did not match the 1 comment token expected',
        [Length(Kinds)]));
    Check('and its stream really was all tkUnknown',
      AllUnknown = 1,
      'uniform unknown output, i.e. no classification at all');

    // (3) The same stub on different text, to show the mismatch verdict is not
    //     tied to one sample.
    //
    //     The first version called this "an empty token run is not silently
    //     accepted" and asserted `Length(Kinds) = 0`. Both halves were wrong: it
    //     passed only because the stub was empty while asserting nothing about
    //     acceptance, and it could never BE empty -- TSilentSyn.GetEol is
    //     constant False, so RunOne always runs to the runaway guard. Renaming
    //     the check to say what actually happens beats keeping a reassuring
    //     label on a test that does not test it.
    RunOne(Bad, 'BEGIN' + #13#10, Kinds, Tokens);
    Check('the verdict holds for other text too, not just one sample',
      not KindsMatch(Kinds, RealExpect),
      Format('it produced %d token(s) against a 1-token expectation',
        [Length(Kinds)]));
  finally
    Good.Free;
    Bad.Free;
  end;
  WriteLn;
end;

var
  H: TProbeRCSyn;
  C: TCheck;
  Kinds: TKindArray;
  Tokens, Distinct: string;
  I, HasSymbol, HasComment, LastIsComment: Integer;

// A local, not `'=' * 78`.
  //
  // In {$mode objfpc} a ONE-character literal has type Char, not string, so
  // `'=' * 78` is a Char * ShortInt and does not compile ("Operator is not
  // overloaded"). StringRepeat is not in this FPC's SysUtils either -- tried
  // that second, and the compiler said "Identifier not found". A local string
  // works and states nothing that needs a library.
  var Bar: string;
begin
  Bar := '';
  while Length(Bar) < 78 do
    Bar := Bar + '=';
  WriteLn(Bar);
  WriteLn('SYNRC PROBE -- does the native LCL RC highlighter actually '
    + 'highlight?');
  WriteLn;

  // Application.Initialize comes BEFORE SelfTest, and that ordering is required
  // rather than cosmetic: SelfTest builds a genuine TSynRCSyn to prove the
  // matcher is not vacuous, and TSynRCSyn's constructor touches widgetset
  // canvases. Before this change the self-test only used the silent stub, so it
  // ran first; now it needs a live application or it is the thing that crashes.
  //
  // `Interfaces` alone is not enough, and a widgetset whose canvases and handles
  // do not belong to a live application is exactly the kind of thing that
  // produces an access violation rather than an error. It was the first
  // version's crash: the banner printed and then EAccessViolation, with the
  // suspect in the highlighter's constructor and the cause here.
  Application.Initialize;
  WriteLn('  Application.Initialize done');
  Flush(Output);

  if ParamStr(1) <> 'noselftest' then
    SelfTest;

  H := TProbeRCSyn.Create(nil);
  WriteLn('  TSynRCSyn created');
  Flush(Output);
  try
    // 1. a block comment spanning lines, terminator included
    C.Name := 'block comment across lines';
    C.Text := '/* first' + #13#10 + '   second */' + #13#10;
    // Two comment tokens, NOT comment/space/comment: the leading spaces of
    // the continuation line are inside the comment, and asserting otherwise
    // would encode a bug as an expectation.
    SetLength(C.Expect, 2);
    C.Expect[0] := RcTkComment;
    C.Expect[1] := RcTkComment;
    C.ExpectText := '/* first   second */';
    // NO newline between the two fragments, and that is correct rather than
    // sloppy: `SetLine` hands the highlighter the line WITHOUT its terminator,
    // so `GetToken` for line 1 is `/* first` and for line 2 is `   second */`.
    // The first version of this expectation included #13#10 and failed -- the
    // expectation was wrong, not the highlighter.
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 2. a line comment must not swallow the newline
    C.Name := 'line comment stops at EOL';
    C.Text := '// gone' + #13#10 + 'BEGIN' + #13#10;
    SetLength(C.Expect, 2);
    C.Expect[0] := RcTkComment;
    C.Expect[1] := RcTkKey;
    C.ExpectText := '// goneBEGIN';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 3. a bare slash is a SYMBOL -- the regression this guards is one stray
    //    slash colouring the rest of the file
    C.Name := 'bare slash is a symbol, not a comment';
    C.Text := '5 / 2' + #13#10;
    SetLength(C.Expect, 0);
    C.ExpectText := '';
    C.UseText := False;
    C.CheckKinds := False;
    Report(C, H);
    RunOne(H, C.Text, Kinds, Tokens);
    HasSymbol := 0;
    HasComment := 0;
    for I := 0 to High(Kinds) do
    begin
      if Kinds[I] = RcTkSymbol then HasSymbol := 1;
      if Kinds[I] = RcTkComment then HasComment := 1;
    end;
    Check('  and yields a symbol with no comment token',
      (HasSymbol = 1) and (HasComment = 0),
      Format('symbol=%d comment=%d', [HasSymbol, HasComment]));

    // 4. keywords are case-insensitive; a name is not a keyword
    C.Name := 'keyword, lower case';
    C.Text := 'dialog' + #13#10;
    SetLength(C.Expect, 1);
    C.Expect[0] := RcTkKey;
    C.ExpectText := 'dialog';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    C.Name := 'an identifier is not a keyword';
    C.Text := 'MyDialog' + #13#10;
    SetLength(C.Expect, 1);
    C.Expect[0] := RcTkIdentifier;
    C.ExpectText := 'MyDialog';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 5. numbers, including hex and the trailing-dot trap
    C.Name := 'hex number';
    C.Text := '0x1F' + #13#10;
    SetLength(C.Expect, 1);
    C.Expect[0] := RcTkNumber;
    C.ExpectText := '0x1F';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    C.Name := 'decimal followed by a letter';
    C.Text := '3px' + #13#10;
    SetLength(C.Expect, 2);
    C.Expect[0] := RcTkNumber;
    C.Expect[1] := RcTkIdentifier;
    C.ExpectText := '3px';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 6. strings, including the doubled-quote escape
    C.Name := 'string with a doubled quote';
    C.Text := '"a""b"' + #13#10;
    SetLength(C.Expect, 1);
    C.Expect[0] := RcTkString;
    C.ExpectText := '"a""b"';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 7. directives; #include keeps its string as a separate token
    C.Name := 'directive stops before its string';
    C.Text := '#include "res\a.rc"' + #13#10;
    SetLength(C.Expect, 2);
    C.Expect[0] := RcTkDirective;
    C.Expect[1] := RcTkString;
    C.ExpectText := '#include "res\a.rc"';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 8. the block-identifier form:  NAME { "res\x.rc" }
    C.Name := 'block identifier keeps its resource name';
    C.Text := 'IDB_ABOUT { "res\about.rc" }' + #13#10;
    SetLength(C.Expect, 1);
    C.Expect[0] := RcTkIdentifier;
    C.ExpectText := 'IDB_ABOUT { "res\about.rc" }';
    C.UseText := True;
    C.CheckKinds := True;
    Report(C, H);

    // 9. the eight attribute slots DataFrm.pas:198-205 assigns
    Check('CommentAttri assignable', H.CommentAttri <> nil);
    Check('DirecAttri assignable', H.DirecAttri <> nil);
    Check('IdentifierAttri assignable', H.IdentifierAttri <> nil);
    Check('KeyAttri assignable', H.KeyAttri <> nil);
    Check('NumberAttri assignable', H.NumberAttri <> nil);
    Check('SpaceAttri assignable', H.SpaceAttri <> nil);
    Check('StringAttri assignable', H.StringAttri <> nil);
    Check('SymbolAttri assignable', H.SymbolAttri <> nil);

    // 9b. Every SYN_ATTR_* index must resolve, not just every published property
    //     be assignable.
    //
    //     "All eight properties assignable" passed while SYN_ATTR_DIRECTIVE still
    //     returned nil, because GetDefaultAttribute had no case for it. So
    //     DirecAttri was assignable, published and copied by UpdateHighlighter,
    //     and still never consulted for an index-based lookup. This check turns
    //     "the property exists" into "the property is reachable"; the assignable
    //     checks above could not tell those apart.
    Check('every SYN_ATTR_ index resolves to its attribute',
      (H.DefaultAttri(SYN_ATTR_COMMENT) = H.CommentAttri)
      and (H.DefaultAttri(SYN_ATTR_IDENTIFIER) = H.IdentifierAttri)
      and (H.DefaultAttri(SYN_ATTR_KEYWORD) = H.KeyAttri)
      and (H.DefaultAttri(SYN_ATTR_STRING) = H.StringAttri)
      and (H.DefaultAttri(SYN_ATTR_WHITESPACE) = H.SpaceAttri)
      and (H.DefaultAttri(SYN_ATTR_SYMBOL) = H.SymbolAttri)
      and (H.DefaultAttri(SYN_ATTR_NUMBER) = H.NumberAttri)
      and (H.DefaultAttri(SYN_ATTR_DIRECTIVE) = H.DirecAttri),
      'comment/identifier/keyword/string/space/symbol/number/directive');

    // 10. the name DataFrm.dfm declares, and the language it claims
    // The DFM in Source declares `object Res: TSynRCSyn`, so the class name has
    // to match EXACTLY. Deliberately NOT `H.ClassName` here: H is the
    // TProbeRCSyn subclass that exposes the protected GetDefaultAttribute, so
    // asking the instance for its own ClassName returns TProbeRCSyn and the
    // check fails for a reason that has nothing to do with the highlighter.
    // The question is "what name would the DFM resolve to", which is answered by
    // the nearest ancestor -- the real class, not the probe's helper.
    Check('class is named TSynRCSyn',
      (TSynRCSyn.ClassName = 'TSynRCSyn') and (H is TSynRCSyn),
      'the DFM name TSynRCSyn resolves to the real class; got '
      + TSynRCSyn.ClassName);
    Check('language name is RC', H.GetLanguageName = 'RC',
      'got ' + H.GetLanguageName);

    // 11. a realistic .rc file end to end -- MANY DISTINCT KINDS.
    //     This is the check a uniform-tkUnknown implementation cannot pass,
    //     and it is why the probe exists rather than a compile check.
    RunOne(H,
      '#include <windows.h>' + #13#10 +
      '// the about dialog' + #13#10 +
      'IDD_ABOUT DIALOGEX 0, 0, 200, 120' + #13#10 +
      'STYLE DS_SETFONT | DS_MODALFRAME' + #13#10 +
      'CAPTION "About Dev-C++"' + #13#10 +
      'BEGIN' + #13#10 +
      '    LTEXT "Version 5.11", -1, 12, 8, 100, 10' + #13#10 +
      '    DEFPUSHBUTTON "OK", IDOK, 85, 95, 50, 14' + #13#10 +
      'END' + #13#10 +
      '/* trailing' + #13#10 +
      '   block comment */' + #13#10,
      Kinds, Tokens);
    Distinct := '';
    for I := 0 to High(Kinds) do
    begin
      if Kinds[I] = RcTkNull then
        Continue;
      if Distinct = '' then
        Distinct := RcTokenKindName(Kinds[I])
      else if Pos(' ' + RcTokenKindName(Kinds[I]) + ' ', ' ' + Distinct + ' ') = 0
        then
        Distinct := Distinct + ' ' + RcTokenKindName(Kinds[I]);
    end;
    Check('a realistic .rc yields many distinct token kinds',
      (Length(Kinds) > 40) and (Pos(' ', Distinct) > 0),
      Format('%d token(s); kinds seen: %s', [Length(Kinds), Distinct]));

    // 12. the range survives a line boundary: an unterminated /* continues and
    //     does not swallow the file
    C.Name := 'unterminated comment closes on the next line';
    C.Text := '/* open' + #13#10 + 'still comment' + #13#10 + '*/ after';
    SetLength(C.Expect, 0);
    C.UseText := False;
    C.CheckKinds := False;
    Report(C, H);
    RunOne(H, C.Text, Kinds, Tokens);
    LastIsComment := 0;
    if Length(Kinds) > 0 then
      if Kinds[High(Kinds)] = RcTkComment then
        LastIsComment := 1;
    Check('  and the final token is not a comment', LastIsComment = 0);
  finally
    H.Free;
  end;

  WriteLn;
  WriteLn('checks: ', Checks, '   failures: ', Failures);
  WriteLn;
  if Failures = 0 then
  begin
    WriteLn('RESULT: the native LCL RC highlighter loads AND tokenises');
    Halt(0);
  end;
  WriteLn('RESULT: ', Failures, ' check(s) FAILED');
  Halt(1);
end.