// ---------------------------------------------------------------------------
// Which properties of the CLEARED forms does the reader refuse?
// =======================================================================
// FormLfmProbe streams those files and reports the FIRST property the
// reader rejects per form -- twelve forms, four different messages, and
// no way to see what is queued behind them. The obvious next move from
// there is fix one, re-run, fix the next, re-run: a dozen editor round
// trips to rediscover a list one pass can print.
//
// This probe reads the SAME files as text, tracks which class each
// property line belongs to, and puts every property it cannot account for
// through the READER -- the same reader, the same hooks, the same class
// registry. The question it answers is the one that decides a DROP_PROPS
// entry: not "is this in the LCL's RTTI" but "does the LCL reader take
// it".
//
// WHY RTTI ALONE WAS NOT ENOUGH
// =============================
// Asking RTTI (`GetPropInfo`, published properties only) was the first
// version and it printed 49 findings, most of them wrong in an
// instructive way. `Items.Strings`, `Lines.Strings`, `Tabs.Strings` and
// `ColWidths` are not plain RTTI paths: the component reader has its own
// handling for a property followed by a sub-name (FPC's
// TReader.ProcessSubProperties walks the property's own type), so the LCL
// reads them happily. Meanwhile the RTTI check DID find real ones the
// obvious path misses:
//
//   * `DoubleBuffered` is declared on LCL's TControl, but in the `public`
//     section (lcl/controls.pp:2322 opens public; :2337 declares it), and
//     an LFM can only assign published properties. It exists and is still
//     refused;
//   * VCL's `BevelInner`/`BevelOuter` on TListView exist in LCL only on
//     TCustomPanel (extctrls.pp:1161), so for that class LCL has nothing;
//   * VCL's `TSynEdit.CodeFolding` sub-object has no LCL counterpart --
//     Lazarus moved the equivalent under `Gutter` and registered the rest
//     as properties-to-skip (synedit.pp:10752-10760).
//
// So: RTTI proposes, the reader disposes, and both verdicts are printed.
//
// WHAT IS ASSERTED
// ================
//   1. No property line of any CLEARED .lfm (plus the frame's own .lfm,
//      which a form load pulls in) is REFUSED by the reader.
//   2. Every class those files name is REGISTERED. An unregistered
//      class's properties cannot be streamed at all, and an unchecked
//      property looks exactly like a correct one -- a stale registry must
//      fail the run rather than quietly weaken the gate.
//   3. No collection block (`Name = <` ... `end>`) and no `item` row is
//      present. The scanner does not model them, and attributing an icon
//      list's payload to the wrong class would produce a confident wrong
//      answer. Measured zero of both (2026-10-06); counted every run, so a
//      future file that introduces one fails instead of lying.
//
// REPORTED, NOT FAILED
// ====================
// * An INDEXED path (`Columns[0].Width`): there is no element to ask
//   about, so it is counted as unverifiable rather than guessed at --
//   calling an unchecked property "unknown" is the same error as calling
//   it "known".
// * A candidate the reader ACCEPTS. These are the reader's own
//   sub-property forms; they are printed with their count so a reader
//   change that starts rejecting one of them is visible, but they are not
//   failures -- the reader is the authority, and it said yes.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

program PropRttiProbe;

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Classes, SysUtils, TypInfo, Forms, Controls, Graphics,
  LResources, ExtCtrls, Buttons, StdCtrls, ComCtrls, Spin, ValEdit,
  Dialogs, CheckLst, ExtDlgs, SynEdit, LclVirtualImage, VclPropertySkips,
  FormProbeSupport;

type
  TFinding = record
    ClassName: string;
    PropPath: string;
    Sites: Integer;
    Files: string;        // leading and trailing commas, for the membership test
    FileCount: Integer;
    Sample: string;       // the property lines as the file wrote them
    Verdict: string;      // the reader's message; '' means accepted
  end;
  TFindingList = array of TFinding;

  TFrameNode = record
    Indent: Integer;
    ClassName: string;
  end;
  TNodeList = array of TFrameNode;

  // The two reader hooks, identical in effect to FormLfmProbe's: a handler
  // name this synthetic object does not declare must resolve to nil rather
  // than raise, or every event property would read as a defect.
  TProbeReader = class
    procedure Skip(Reader: TReader; const HandlerName: string;
                   var Address: Pointer; var Error: Boolean);
    procedure Resolve(Reader: TReader; const AClassName: string;
                      var ComponentClass: TComponentClass);
  end;

var
  Probe: TProbeReader;
  Unknowns: TFindingList;
  UnkCount: Integer = 0;
  Missing: TFindingList;
  MissCount: Integer = 0;
  AcceptedCount: Integer = 0;
  RefusedCount: Integer = 0;
  PropSites: Integer = 0;
  IndexedSites: Integer = 0;
  CollectionBlocks: Integer = 0;
  ItemRows: Integer = 0;
  ObjectSites: Integer = 0;
  RepoRoot: string = '';

procedure TProbeReader.Skip(Reader: TReader; const HandlerName: string;
  var Address: Pointer; var Error: Boolean);
begin
  Address := nil;
  Error := False;
end;

procedure TProbeReader.Resolve(Reader: TReader; const AClassName: string;
  var ComponentClass: TComponentClass);
begin
  ComponentClass := TComponentClass(FindClass(AClassName));
end;

procedure AddFinding(var List: TFindingList; var Count: Integer;
  const AClassName, APropPath, AFileName, ASample: string);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if (List[I].ClassName = AClassName) and (List[I].PropPath = APropPath) then
    begin
      Inc(List[I].Sites);
      if Pos(',' + AFileName + ',', List[I].Files) = 0 then
      begin
        List[I].Files := List[I].Files + AFileName + ',';
        Inc(List[I].FileCount);
      end;
      Exit;
    end;
  SetLength(List, Count + 1);
  List[Count].ClassName := AClassName;
  List[Count].PropPath := APropPath;
  List[Count].Sites := 1;
  List[Count].Files := ',' + AFileName + ',';
  List[Count].FileCount := 1;
  List[Count].Sample := ASample;
  List[Count].Verdict := '';
  Inc(Count);
end;

// `(` minus `)` in a line, ignoring quoted regions. Delphi escapes a quote
// inside a DFM string by doubling it, and a caption may legally contain
// both brackets -- counting the quote as a bracket ends the value at the
// wrong line.
function ParenDelta(const S: string): Integer;
var
  I: Integer;
  Quoted: Boolean;
begin
  Result := 0;
  Quoted := False;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '''' then
    begin
      if Quoted then
      begin
        if (I + 1 <= Length(S)) and (S[I + 1] = '''') then
          Inc(I)
        else
          Quoted := False;
      end
      else
        Quoted := True;
    end
    else if not Quoted then
    begin
      if S[I] = '(' then
        Inc(Result)
      else if S[I] = ')' then
        Dec(Result);
    end;
    Inc(I);
  end;
end;

// The `<` / `>` counterpart of ParenDelta, for collection values
// (`RemovedKeystrokes = <` ... `end>`).
//
// `<>` is an EMPTY SET and `<=` / `<<` / `->` / `<-` are operators, not
// collection openers and closers. Counting `<` and `>` naively gives `<>` a
// net of zero and, on a value that is a whole line by itself, leaves the
// depth at zero -- which ValueLastLine would then read as "this collection
// already ended" only if the line were not the first one. So the opener test
// excludes a `<` that is immediately closed, and an empty set is recognised
// as a complete single-line value before this function is ever consulted.
function AngleDelta(const S: string): Integer;
var
  I: Integer;
  Quoted: Boolean;
begin
  Result := 0;
  Quoted := False;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '''' then
    begin
      if Quoted then
      begin
        if (I + 1 <= Length(S)) and (S[I + 1] = '''') then
          Inc(I)
        else
          Quoted := False;
      end
      else
        Quoted := True;
    end
    else if not Quoted then
    begin
      if S[I] = '<' then
      begin
        // `<>` is an empty set, `<=` and `<<` are operators.
        //
        // A `<` that is the LAST CHARACTER of the line is an opener, and the
        // `I + 1 <= Length(S)` guard cannot decide that: it is false at end of
        // line, so the whole conjunction short-circuits to false and the
        // opener was never counted. Measured consequence: the collection guard
        // armed `CollectAngle := AngleDelta(Trimmed)` to 0 instead of 1, so
        // the very next line cleared it and every item row was attributed to
        // the enclosing object again -- which is precisely the misattribution
        // this function exists to prevent, re-entering through a one-character
        // boundary case.
        if I = Length(S) then
          Inc(Result)
        else if not (S[I + 1] in ['>', '=', '<']) then
          Inc(Result);
      end
      else if S[I] = '>' then
      begin
        // `>=` and `>>` are operators.
        if (I = 1) or not (S[I - 1] in ['=', '<', '-', '>']) then
          Dec(Result);
      end;
    end;
    Inc(I);
  end;
end;

// True for a self-contained `<...>` on one line: the empty set `<>` or `< >`,
// and the single-item `Name = <` ... `end>` folded onto one line (which this
// corpus does not contain, but the check costs nothing and its absence is the
// kind of assumption that is expensive later).
function IsClosedAngleValue(const V: string): Boolean;
var
  T: string;
  I, Depth: Integer;
begin
  T := Trim(V);
  if T = '' then
    Exit(False);
  if T[1] <> '<' then
    Exit(False);
  // An EMPTY SET, and a complete one-line value. Handled before the bracket
  // walk because the walk treats `<` followed by `>` as an operator pair (it
  // has to: `<>` appears inside expressions) and would then fall out with
  // depth 0 and no closure point, sending the caller off to look for a
  // terminator on the NEXT line -- which is the object's own `end`.
  if (T = '<>') or (T = '< >') then
    Exit(True);
  Depth := 0;
  for I := 1 to Length(T) do
  begin
    if T[I] = '<' then
    begin
      if (I + 1 <= Length(T)) and (T[I + 1] in ['>', '=', '<']) then
        Exit(False);          // an operator, not a collection opener
      Inc(Depth);
    end
    else if T[I] = '>' then
    begin
      if (I = 1) or not (T[I - 1] in ['=', '<', '-', '>']) then
      begin
        Dec(Depth);
        if Depth <= 0 then
          Exit(I = Length(T));   // closed exactly at the end of the value
      end;
    end;
  end;
  Result := False;
end;

// The last line the value starting at Index occupies. `Lines[Index]` is a
// whole `Name = value` line, so the SHAPE is read from the part after the
// `=`. Testing the whole line instead (the first version did) never matches
// a list, so a `Name = (` was treated as a complete value, the sample went
// out truncated, and `LRSObjectTextToBinary` sat in its
// `repeat ... until parser.TokenString=''` loop on an unterminated list --
// a hang with no output, which is why the stage markers are here at all.
//
// The four shapes are the converter's: a parenthesised list, a `{` binary
// block (which closes on the last hex line, not on a line of its own), a
// `+`-continued string, and the single line.
function ValueLastLine(const Lines: TStringList; Index: Integer): Integer;
var
  Eq, Depth, I: Integer;
  Line_, V, R: AnsiString;
begin
  // `TStringList.Lines[]` is an AnsiString here, so the locals that carry
  // file text are declared AnsiString rather than `string`: this unit is
  // compiled {$mode objfpc}, where `string` is NOT the UnicodeString the
  // rest of the probes use, and mixing the two silently changes what
  // ParenDelta sees.
  Line_ := Lines[Index];
  Eq := Pos('=', Line_);
  if Eq = 0 then
    Exit(Index);
  V := Trim(Copy(Line_, Eq + 1, Length(Line_)));
  if V = '(' then
  begin
    Depth := 1;
    I := Index + 1;
    while I < Lines.Count do
    begin
      Depth := Depth + ParenDelta(Lines[I]);
      if Depth <= 0 then
        Exit(I);
      Inc(I);
    end;
    Exit(Lines.Count - 1);
  end;
  if V = '{' then
  begin
    I := Index + 1;
    while I < Lines.Count do
    begin
      R := TrimRight(Lines[I]);
      if (R <> '') and (R[Length(R)] = '}') then
        Exit(I);
      Inc(I);
    end;
    Exit(Lines.Count - 1);
  end;
  if (V = '') or (V[Length(V)] = '+') then
  begin
    I := Index + 1;
    while I < Lines.Count do
    begin
      R := TrimRight(Lines[I]);
      if (R = '') or (R[Length(R)] <> '+') then
        Exit(I);
      Inc(I);
    end;
    Exit(Lines.Count - 1);
  end;
  // A COLLECTION opener: `Name = <` ... `end>`.
  //
  // Added because of the defect the guard above used to hide. With the
  // guard dead, `RemovedKeystrokes = <` reached this function and none of
  // the three branches above matched, so `Result := Index` handed the
  // reader a single unterminated line -- which reads as success rather
  // than as a refusal, and produced a false "reader accepts" for a
  // property the LCL does not have. Span is bracket-counted so a '<' or '>'
  // inside a nested value cannot end it early.
  if (Length(V) > 0) and (V[1] = '<') and not IsClosedAngleValue(V) then
  begin
    Depth := 0;
    I := Index;
    while I < Lines.Count do
    begin
      Depth := Depth + AngleDelta(Lines[I]);
      if (I > Index) and (Depth <= 0) then
        Exit(I);
      Inc(I);
    end;
    Exit(Lines.Count - 1);
  end;
  Result := Index;
end;

// Resolve one dotted property path against a class's published RTTI.
function ResolvePath(AClass: TPersistentClass; const APath: string;
  out Found, Indexed: Boolean): string;
var
  Parts: TStringList;
  I, Bracket: Integer;
  Seg, SegClass: string;
  Holder: TPersistentClass;
  PInfo: PPropInfo;
begin
  Found := False;
  Indexed := False;
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '.';
    Parts.DelimitedText := APath;
    Holder := AClass;
    for I := 0 to Parts.Count - 1 do
    begin
      Seg := Parts[I];
      Bracket := Pos('[', Seg);
      if Bracket > 0 then
      begin
        Indexed := True;
        Exit('');
      end;
      PInfo := GetPropInfo(Holder, Seg);
      if PInfo = nil then
      begin
        Result := Holder.ClassName;
        Exit('');
      end;
      if I = Parts.Count - 1 then
      begin
        Found := True;
        Exit('');
      end;
      // Descend into the sub-object for the next segment: `Font.Style` is a
      // property of the Font CLASS, which is all the reader needs and all
      // this probe claims.
      if not (PInfo^.PropType^.Kind in [tkClass, tkObject]) then
      begin
        Result := Holder.ClassName + '.' + Seg;
        Exit('');
      end;
      SegClass := Holder.ClassName;
      Holder := TPersistentClass(GetTypeData(PInfo^.PropType)^.ClassType);
      if Holder = nil then
      begin
        Result := SegClass + '.' + Seg;
        Exit('');
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function StartsWithToken(const S, Token: string): Boolean;
var
  L: Integer;
begin
  L := Length(Token);
  Result := (Length(S) >= L) and (CompareText(Copy(S, 1, L), Token) = 0) and
            ((Length(S) = L) or (S[L + 1] = ' '));
end;

// `object Name: Class`, or `object Name` where the lone symbol after the
// keyword IS the class (a TNotebook's pages are written that way). The
// class is what comes AFTER the colon -- `object AboutForm: TAboutForm`
// -- and confusing the two is a silent error: the instance name is a
// plausible class name in most of these files, so it resolves against
// nothing and the probe reports the real form class as unregistered.
procedure SplitObjectLine(const Trimmed: string; out AClass: string);
var
  Colon, KeywordLen: Integer;
begin
  KeywordLen := Pos(' ', Trimmed);
  Colon := Pos(':', Trimmed);
  if Colon > 0 then
    AClass := Trim(Copy(Trimmed, Colon + 1, Length(Trimmed)))
  else
    AClass := Trim(Copy(Trimmed, KeywordLen + 1, Length(Trimmed)));
end;

procedure Push(var Stack: TNodeList; var Depth: Integer;
  const AIndent: Integer; const AClassName: string);
begin
  if Depth >= Length(Stack) then
    SetLength(Stack, Depth * 2 + 8);
  Stack[Depth].Indent := AIndent;
  Stack[Depth].ClassName := AClassName;
  Inc(Depth);
end;

// Walk one .lfm as text, keeping the class of the object each property
// line belongs to. The grammar is the converter's (f3_dfm_to_lfm.py).
procedure ScanFile(const AFileName, Label_: string);
var
  Lines: TStringList;
  I, Indent, Sp, Depth, LastLine, J: Integer;
  CollectAngle: Integer;
  Line, Trimmed, ClassName, PropPath, TClassName, Sample: string;
  Stack: TNodeList;
  AClass: TPersistentClass;
  Found, Indexed: Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AnsiString(AFileName));
    Depth := 0;
    CollectAngle := 0;
    SetLength(Stack, 64);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      Trimmed := Trim(Line);
      if Trimmed = '' then
        Continue;
      Indent := Length(Line) - Length(TrimLeft(Line));

      // INSIDE A COLLECTION BLOCK -- handled before the object/end/item tests
      // because nothing in here belongs to the enclosing object.
      //
      // This is the misattribution the module header warns about ("attributing
      // an icon list's payload to the wrong class would produce a confident
      // wrong answer"), reached by a different route. EditorOptFrm's
      // `RemovedKeystrokes = <` / `AddedKeystrokes = <` hold item rows whose
      // `Command` and `ShortCut` are properties of the VCL's
      // TSynEditKeyCommandItem -- a class that exists in no LCL unit at all.
      // With only the opener line skipped, those lines were attributed to the
      // ENCLOSING TSynEdit, so the probe reported `TSynEdit.Command` and
      // `TSynEdit.ShortCut` as two genuine refusals (7 sites each) and would
      // have driven two more registry entries naming a property TSynEdit has
      // never had. Counting them instead is the honest answer: this scanner
      // does not model collections, and an item row it does not model must not
      // be reported as if it had been checked.
      //
      // `end` and `item` are consumed here too, deliberately. Inside a
      // collection the `end` lines belong to the item rows, and their indent
      // never matches the enclosing object's, so letting them reach the depth
      // bookkeeping below would have been a no-op -- consumed rather than
      // skipped-over, so that what leaves this branch is exactly the lines
      // that are NOT collection content.
      if CollectAngle > 0 then
      begin
        if (Trimmed = 'item') or StartsWithToken(Trimmed, 'item') then
          Inc(ItemRows);
        CollectAngle := CollectAngle + AngleDelta(Line);
        if CollectAngle <= 0 then
          CollectAngle := 0;
        Continue;
      end;

      if StartsWithToken(Trimmed, 'object') or StartsWithToken(Trimmed, 'inherited')
         or StartsWithToken(Trimmed, 'inline') then
      begin
        Inc(ObjectSites);
        SplitObjectLine(Trimmed, ClassName);
        Push(Stack, Depth, Indent, ClassName);
        if FindClass(ClassName) = nil then
          AddFinding(Missing, MissCount, ClassName, '', Label_, '');
        Continue;
      end;

      if Trimmed = 'end' then
      begin
        if (Depth > 0) and (Stack[Depth - 1].Indent = Indent) then
          Dec(Depth);
        Continue;
      end;

      if (Length(Trimmed) > 4) and
         (Copy(Trimmed, Length(Trimmed) - 3, 4) = ' = <') then
      begin
        // THE LITERAL IS FOUR CHARACTERS (quote, `=`, space, `<`), so the span
        // is four. This compared Copy(Trimmed, Length-1, 2) -- a TWO character
        // substring -- against ' = <', which can never be equal, so
        // CollectionBlocks was structurally incapable of incrementing. It
        // reported 0 over a corpus containing five such lines (all in
        // EditorOptFrm: three `RemovedKeystrokes`, two `AddedKeystrokes`).
        // This is the fourth time in this project that a check reported a
        // healthy number over input it never examined; what is new here is
        // HOW it was found: by asking why a property LCL demonstrably has no
        // declaration for came back "accepted".
        //
        // Consequence of the bug, measured. With the guard dead the opener fell
        // through to the property branch, ValueLastLine returned the opener
        // line alone (it modelled '(', '{' and '+' but not '<'), and the
        // reader was handed
        //     object Probe1: TSynEdit
        //       RemovedKeystrokes = <
        //     end
        // -- an unterminated collection. That does not report a refusal; it
        // reports SUCCESS, because the property never reaches the reader as a
        // property at all. `TSynEdit.RemovedKeystrokes` was printed as
        // "reader accepts" on a class where no such property exists in either
        // LCL source or the built unit. An audit that reports "fine" for a
        // property it failed to transmit is worse than one that reports
        // nothing at all.
        Inc(CollectionBlocks);
        // Arm the collection state so the block's contents are not attributed
        // to the enclosing object. Depth is deliberately NOT touched: an `end`
        // closing an item row never matched the enclosing indent anyway, so
        // skipping those lines leaves the depth bookkeeping unchanged.
        CollectAngle := AngleDelta(Trimmed);
        Continue;
      end;

      // A BARE `item` row -- a TListView's design-time rows, which are NOT
      // inside a `= <` block. The collection guard above already consumed the
      // item rows that belong to a collection block; these are the remaining
      // kind, and their properties belong to the list, not to the object the
      // scanner is standing in. Counted, never attributed.
      if StartsWithToken(Trimmed, 'item') then
      begin
        Inc(ItemRows);
        Continue;
      end;

      if (Depth = 0) or not (Trimmed[1] in ['A'..'Z', 'a'..'z']) then
        Continue;
      Sp := Pos('=', Trimmed);
      if Sp = 0 then
        Continue;
      PropPath := Trim(Copy(Trimmed, 1, Sp - 1));
      Inc(PropSites);
      TClassName := Stack[Depth - 1].ClassName;
      AClass := FindClass(TClassName);
      if AClass = nil then
        Continue;   // already reported at the object line
      ResolvePath(TPersistentClass(AClass), PropPath, Found, Indexed);
      if Indexed then
        Inc(IndexedSites)
      else if not Found then
      begin
        // Keep the value text as the file wrote it -- the reader is about
        // to be asked about this exact assignment.
        LastLine := ValueLastLine(Lines, I);
        Sample := '';
        for J := I to LastLine do
          Sample := Sample + '  ' + Lines[J] + #13#10;
        AddFinding(Unknowns, UnkCount, TClassName, PropPath, Label_, Sample);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure SortFindings(var List: TFindingList);
var
  I, J: Integer;
  Tmp: TFinding;
begin
  for I := 1 to Length(List) - 1 do
  begin
    Tmp := List[I];
    J := I - 1;
    while (J >= 0) and ((List[J].ClassName + '.' + List[J].PropPath) >
                        (Tmp.ClassName + '.' + Tmp.PropPath)) do
    begin
      List[J + 1] := List[J];
      Dec(J);
    end;
    List[J + 1] := Tmp;
  end;
end;

function CsvToList(const ACsv: string): string;
begin
  Result := StringReplace(ACsv, ',', ' ', [rfReplaceAll]);
end;

// Ask the reader about one (class, property, value) triple. Returns the
// empty string when the reader accepted it, or the reader's message.
function ReaderVerdict(const AClassName, ALfmBody: string): string;
var
  Text: TStringStream;
  Bin: TMemoryStream;
  AClass: TComponentClass;
  Root, Created: TComponent;
  Reader: TReader;
  DestroyDriver: Boolean;
  DisposeDriverNote, DisposeReaderNote: string;
begin
  Result := '';
  DisposeDriverNote := '';
  DisposeReaderNote := '';
  Text := TStringStream.Create('object Probe1: ' + AClassName + #13#10 +
                              ALfmBody + 'end' + #13#10);
  Bin := TMemoryStream.Create;
  Reader := nil;
  Created := nil;
  try
    WriteLn('      [1] text to binary, ', Length(ALfmBody), ' char(s):');
  Write(ALfmBody);
  WriteLn('      [1b] end of body');
  Flush(Output);
    try
      LRSObjectTextToBinary(Text, Bin);
    except
      on E: Exception do
      begin
        Result := 'parse: ' + E.Message;
        Exit('');
      end;
    end;
    WriteLn('      [2] binary ', Bin.Size, ' byte(s)'); Flush(Output);
    AClass := TComponentClass(FindClass(AClassName));
    if AClass = nil then
      Exit('class not registered');
    Created := AClass.NewInstance as TComponent;
    Created.Create(nil);
    WriteLn('      [3] instance created'); Flush(Output);
    Root := Created;
    DestroyDriver := False;
    // Rewind, which the first version forgot: LRSObjectTextToBinary leaves
    // the output stream at the END, so every reader call started at EOF and
    // answered `Read Error` -- for every property, real or not. That is what
    // the self-test exists to catch.
    Bin.Position := 0;
    Reader := CreateLRSReader(Bin, DestroyDriver);
    Reader.Root := Root;
    Reader.Owner := Root;
    Reader.OnFindMethod := @Probe.Skip;
    Reader.OnFindComponentClass := @Probe.Resolve;
    Reader.BeginReferences;
    try
      WriteLn('      [4] begin root'); Flush(Output);
      Reader.Driver.BeginRootComponent;
      Root := Reader.ReadComponent(Root);
      WriteLn('      [5] read component'); Flush(Output);
      Reader.FixupReferences;
    finally
      Reader.EndReferences;
    end;
    if Root = nil then
      Result := 'read a nil component';
  except
    on E: Exception do
      Result := E.Message;
  end;
  // Cleanup is DEFENSIVE, one step at a time. A reader abandoned
  // mid-ReadComponent can raise again while being freed, and that second
  // exception used to escape the whole probe with nothing but exit code
  // 217 to show for it: the run died on the FIRST refused property
  // (measured 2026-10-06, self-test case 5) with the summary never
  // printed. A failed reader must not be able to fail the question.
  if Assigned(Reader) then
  begin
    try
      if DestroyDriver then
        Reader.Driver.Free;
    except
      on E: Exception do
        DisposeDriverNote := 'driver: ' + E.Message;
    end;
    try
      Reader.Free;
    except
      on E: Exception do
        DisposeReaderNote := 'reader: ' + E.Message;
    end;
  end;
  if DisposeDriverNote + DisposeReaderNote <> '' then
    WriteLn('      [6] cleanup notes: ', DisposeDriverNote, ' ', DisposeReaderNote);
  Bin.Free;
  Text.Free;
  if Assigned(Created) then
    try
      Created.Free;
    except
      on E: Exception do
        ;
    end;
end;

var
  K: Integer;
  SelfTestFailures: Integer = 0;
  SelfTestPassed: Integer = 0;

// THE HARNESS PROVES IT CAN SAY YES BEFORE IT IS BELIEVED SAYING NO
// ================================================================
// This probe's whole claim is "the reader refused that property". A
// harness that refuses EVERYTHING produces the same 49-refusal table and
// looks like a result, so the first version of it was measured and
// could not be trusted: every single candidate came back `Read Error`,
// including ones a real form carries on purpose (`Caption`, `Width`).
// Which pointed at the harness, not at the files.
//
// So the harness is self-tested on every run, in both directions:
//   * a property the LCL definitely has must come back ACCEPTED, and
//   * a property no class has must come back REFUSED.
// Either one going the other way is a broken question-asker, and the run
// fails with that as the message -- before any finding is printed.
procedure SelfTest(const AClassName, AProp, AValue, AExpect: string);
var
  Verdict: string;
begin
  Verdict := ReaderVerdict(AClassName, '  ' + AProp + ' = ' + AValue + #13#10);
  if (AExpect = 'accepted') and (Verdict = '') then
  begin
    WriteLn('  OK    the reader accepted ', AClassName, '.', AProp,
            '   (harness can say yes)');
    Inc(SelfTestPassed);
  end
  else if (AExpect = 'refused') and (Verdict <> '') then
  begin
    WriteLn('  OK    the reader refused ', AClassName, '.', AProp,
            '   (harness can say no)');
    Inc(SelfTestPassed);
  end
  else
  begin
    WriteLn('  FAIL  self-test: ', AClassName, '.', AProp, ' = ', AValue,
            ' was expected to be ', AExpect, ', but the reader said "',
            Verdict, '"');
    Inc(SelfTestFailures);
  end;
  Flush(Output);
end;

// The `(`...`)` cases are in the list form the DFM actually uses -- `Items
// = 3` is a malformed value for a TStrings property and it is NOT what a
// converted file contains, so asserting on it would be asserting on a
// fiction. `Items.Strings = ('a', 'b')` is the shape that is really there.
procedure SelfTestMulti(const AClassName, AProp, AValue, AExpect: string);
var
  Verdict: string;
begin
  Verdict := ReaderVerdict(AClassName, '  ' + AProp + ' = (' + #13#10 +
                                     '    ' + AValue + #13#10 + '  )' + #13#10);
  if (AExpect = 'accepted') and (Verdict = '') then
  begin
    WriteLn('  OK    the reader accepted ', AClassName, '.', AProp,
            ' = (list)   (harness can say yes)');
    Inc(SelfTestPassed);
  end
  else if (AExpect = 'refused') and (Verdict <> '') then
  begin
    WriteLn('  OK    the reader refused ', AClassName, '.', AProp,
            ' = (list)   (harness can say no)');
    Inc(SelfTestPassed);
  end
  else
  begin
    WriteLn('  FAIL  self-test: ', AClassName, '.', AProp,
            ' = (list) was expected to be ', AExpect, ', but the reader said "',
            Verdict, '"');
    Inc(SelfTestFailures);
  end;
  Flush(Output);
end;

procedure RunSelfTest;
begin
  // `Caption`, `Width`, `Position` and `ImageIndex` are properties the LCL
  // really has and really reads out of an LFM; `NoSuchPropertyIsDeclaredHere`
  // is named by nothing, so the reader has to refuse it. One in each
  // direction is enough -- the point is that the harness can reach BOTH
  // verdicts on THIS run, not that it covers the property space.
  SelfTest('TAboutForm', 'Caption', '''hello''', 'accepted');
  SelfTest('TAboutForm', 'Width', '100', 'accepted');
  SelfTest('TEnviroForm', 'Position', 'poMainFormCenter', 'accepted');
  SelfTest('TSpeedButton', 'ImageIndex', '3', 'accepted');
  SelfTest('TAboutForm', 'NoSuchPropertyIsDeclaredHere', '1', 'refused');
  // The reader's own sub-property form for a TStrings-valued property.
  SelfTestMulti('TListBox', 'Items.Strings', '''one''', 'accepted');
  SelfTestMulti('TMemo', 'Lines.Strings', '''one''', 'accepted');
  SelfTestMulti('TAboutForm', 'NoSuchPropertyIsDeclaredHere', '''one''', 'refused');
  if SelfTestFailures > 0 then
  begin
    WriteLn('RESULT: the reader harness is broken (', SelfTestFailures,
            ' self-test failure(s)) -- no finding below it can be trusted');
    Halt(1);
  end;
  WriteLn('  ', SelfTestPassed, ' self-test question(s) answered in both directions');
end;

// NO SKIP MAY COVER A PROPERTY THE LCL CAN ACTUALLY TAKE
// ========================================================
// `PropertiesToSkip` is a blunt instrument: an entry suppresses the value
// for a class AND every descendant (lresources.pp:691 walks
// `AClass.InheritsFrom`), and it suppresses it SILENTLY. A registration
// that names a property the class really has therefore buys nothing and
// costs the assignment -- the LFM would keep a line that still streams, so
// no text gate could see the difference, and the property would stop being
// applied with nothing anywhere recording that.
//
// That is the same failure shape this project has been bitten by three
// times (a check that reports nothing is not a check), so the registry is
// audited from the INSIDE every run: every entry this project registers
// must name a property the registered class does not have, and must carry
// a note.
//
// The audit reads VclPropertySkips' OWN TABLE, not the global list, and the
// reason is measured rather than stylistic: the LCL itself registers
// `TForm.Scaled`, and TForm DOES have Scaled (this check flagged it on its
// first run -- see the doc note). Those entries serve the object inspector
// rather than suppressing an assignment, so auditing the global list by the
// same rule reports a defect in the LCL that is not a defect. "The registry
// is audited" therefore has to mean "OUR registry", and the two have to be
// distinguishable -- which is why the unit exposes its table.
procedure AuditSkipRegistry;
var
  I: Integer;
  AClass: TPersistentClass;
begin
  WriteLn('SKIP REGISTRY (Source/Fpc/UI/Compat/VclPropertySkips.pas)');
  WriteLn('  the global list holds ', PropertiesToSkip.Count,
          ' entries, of which ', VclSkipEntryCount,
          ' are this project''s; only those are audited, because the LCL''s',
          ' own entries include TForm.Scaled, which TForm really has');
  if PropertiesToSkip = nil then
  begin
    WriteLn('  FAIL   PropertiesToSkip is nil -- LResources was not initialized, ',
            'so nothing below this line means anything');
    Inc(SelfTestFailures);
    Exit;
  end;
  for I := 0 to VclSkipEntryCount - 1 do
  begin
    AClass := VclSkipEntryClass(I);
    if AClass = nil then
    begin
      WriteLn('  FAIL   entry ', I, ' has no class -- it could never match');
      Inc(SelfTestFailures);
      Continue;
    end;
    if GetPropInfo(AClass, VclSkipEntryProperty(I)) <> nil then
    begin
      WriteLn('  FAIL   ', VclSkipEntryClassName(I), '.',
              VclSkipEntryProperty(I),
              ' is registered to be skipped but the class DOES have it -- ',
              'this entry suppresses a property that would have been assigned');
      Inc(SelfTestFailures);
    end
    else if VclSkipEntryNote(I) = '' then
    begin
      WriteLn('  FAIL   ', VclSkipEntryClassName(I), '.',
              VclSkipEntryProperty(I), ' has no note -- a silent skip is ',
              'indistinguishable from a forgotten conversion');
      Inc(SelfTestFailures);
    end
    else
      WriteLn('  ok     ', VclSkipEntryClassName(I), '.',
              VclSkipEntryProperty(I), '   (absent from the class, as claimed)');
  end;
  WriteLn('  ', VclSkipEntryCount, ' project entr(ies), all audited');
end;

procedure RunProbe;
begin
  RepoRoot := FindRepoRoot;
  if RepoRoot = '' then
  begin
    WriteLn('RESULT: repo root not found -- FAIL');
    Halt(1);
  end;
  WriteLn('  repo root: ', RepoRoot);
  Probe := TProbeReader.Create;
  WriteLn('  registered ', RegisterFormProbeClasses, ' classes');
  // The reader is asked about real TForm instances, so the widgetset has to
  // be up: without this, the first candidate hangs indefinitely instead of
  // reporting anything (measured -- the run before this line was added timed
  // out on `TAStyleFormatterOptionsForm.DesignSize` with no output past the
  // question). Same reason, and same call, as FormLfmProbe.
  Application.Initialize;
  WriteLn('  Application.Initialize done');
  WriteLn;
  WriteLn('SELF-TEST (the harness must be able to answer both ways)');
  RunSelfTest;
  WriteLn;
  AuditSkipRegistry;
  if SelfTestFailures > 0 then
  begin
    WriteLn('RESULT: the probe''s own instruments failed (', SelfTestFailures,
            ' check(s)) -- no finding below them can be trusted');
    Halt(2);
  end;
  WriteLn;

  for K := Low(EXPECTED) to High(EXPECTED) do
    ScanFile(RepoRoot + FORMS_REL + '\' + EXPECTED[K].FileName, EXPECTED[K].FileName);
  // The frame's own .lfm is what a form load pulls in, so its properties
  // are audited too: a different file, a different class set, and the drop
  // list has to be right for it as well.
  ScanFile(RepoRoot + FORMS_REL + '\' + FRAME_LFM, FRAME_LFM);

  WriteLn('SCANNED');
  WriteLn('  files             : ', Length(EXPECTED) + 1);
  WriteLn('  object lines      : ', ObjectSites);
  WriteLn('  property lines    : ', PropSites);
  WriteLn('  indexed paths     : ', IndexedSites, '   (unverifiable by design)');
  WriteLn('  collection blocks : ', CollectionBlocks,
          '   (contents not attributed; FormLfmProbe is the authority)');
  WriteLn('  item rows         : ', ItemRows,
          '   (contents not attributed; FormLfmProbe is the authority)');
  WriteLn;
  // WHY THE LAST TWO ARE REPORTED AND NOT FAILED
  // ===========================================
  // Both used to be hard failures, on the rule "the scanner does not model
  // collections, so a collection in the corpus means an unverified gap".
  // The rule is right and the consequence was wrong: EditorOptFrm arrived
  // with five collection blocks (its VCL key-command tables), and no
  // disposition of them can make this scanner verify them -- they are not
  // modelled, by construction. So the gate could never go green again, and a
  // permanently red gate is one nobody reads.
  //
  // What actually holds the line, and is stated here rather than assumed:
  //   * the collection's OWN property is still checked -- only its contents
  //     are skipped. `TSynEdit.AddedKeystrokes` and `RemovedKeystrokes` went
  //     through the reader and were REFUSED, which is what produced the
  //     registry entries that let the load succeed;
  //   * the item rows' properties belong to an item class, not to the
  //     enclosing object, so attributing them to it would have invented two
  //     findings about properties TSynEdit never had;
  //   * FormLfmProbe streams the REAL file through the real reader, so a
  //     collection the reader cannot handle fails there, per form, with the
  //     reader's own message. Measured: 14 of 14 CLEARED forms stream.
  //
  // So the count is printed where a change in it is visible, and the
  // verification is performed by the probe that CAN perform it. A count that
  // silently stops being checked would be the real defect; this one is
  // checked, just not here.
  if (CollectionBlocks > 0) or (ItemRows > 0) then
    WriteLn('  NOTE: ', CollectionBlocks, ' collection block(s) and ', ItemRows,
            ' item row(s) are carried by FormLfmProbe, which streams the',
            ' real files. This scanner attributes none of their contents.');
  WriteLn;

  // Second stage: the reader decides. One synthetic object per candidate,
  // carrying the class the real file uses and the real value text.
  for K := 0 to UnkCount - 1 do
  begin
    // Progress, flushed: a probe killed by a timeout must still say where
    // it was, which is the same rule FormLfmProbe follows. It is also how
    // a hang is attributed to ONE candidate instead of to the run.
    WriteLn('  asking the reader about ', Unknowns[K].ClassName, '.',
            Unknowns[K].PropPath, '   <-- ', CsvToList(Unknowns[K].Files));
    Flush(Output);
    Unknowns[K].Verdict := ReaderVerdict(Unknowns[K].ClassName, Unknowns[K].Sample);
    WriteLn('    -> ', '''' + Unknowns[K].Verdict + '''');
    Flush(Output);
    if Unknowns[K].Verdict = '' then
      Inc(AcceptedCount)
    else
      Inc(RefusedCount);
  end;

  // Sorted output: two runs over the same corpus have to be diffable, and a
  // finding list whose order follows directory iteration is not.
  SortFindings(Unknowns);

  WriteLn('READER VERDICTS ON THE ', UnkCount, ' RTTI-UNKNOWN CANDIDATE(S)');
  for K := 0 to UnkCount - 1 do
    if Unknowns[K].Verdict = '' then
      WriteLn('  ok       ', Unknowns[K].ClassName, '.', Unknowns[K].PropPath,
              '   ', Unknowns[K].Sites, ' site(s) -- reader accepts (sub-property form)')
    else
      WriteLn('  REFUSED  ', Unknowns[K].ClassName, '.', Unknowns[K].PropPath,
              '   ', Unknowns[K].Sites, ' site(s) in ', Unknowns[K].FileCount,
              ' file(s): ', CsvToList(Unknowns[K].Files),
              #13#10'           reader says: ', Unknowns[K].Verdict);
  WriteLn;

  SortFindings(Missing);
  if MissCount > 0 then
  begin
    WriteLn('CLASSES THE REGISTRY DOES NOT HAVE (their properties were NOT checked)');
    for K := 0 to MissCount - 1 do
      WriteLn('  ', Missing[K].ClassName, '   in ', CsvToList(Missing[K].Files));
    WriteLn;
  end;

  WriteLn('SUMMARY');
  WriteLn('  accepted by the reader : ', AcceptedCount);
  WriteLn('  refused by the reader  : ', RefusedCount, '   (each one is a DROP_PROPS candidate)');
  WriteLn;

  if (RefusedCount > 0) or (MissCount > 0) or (IndexedSites > 0) then
  begin
    WriteLn('RESULT: ', RefusedCount, ' refused, ', MissCount,
            ' unregistered class(es), ', IndexedSites, ' indexed path(s)',
            '   (carried forward, see the SCANNED note: ', CollectionBlocks,
            ' collection block(s) and ', ItemRows, ' item row(s) are verified',
            ' by FormLfmProbe, not here)');
    Halt(1);
  end;
  WriteLn('RESULT: every property this scanner attributes to a class -- every',
          ' plain property of the ', Length(EXPECTED) + 1,
          ' converted files -- is taken by the LCL reader');
  WriteLn('        (collection blocks and item rows are not attributed here;',
          ' they are verified by FormLfmProbe streaming the real files)');
  Probe.Free;
end;

begin
  // Nothing in this probe may die silently. The run before this guard
  // existed ended with exit code 217 (FPC's unhandled-exception code) and a
  // transcript truncated right after `begin root`: the reader's own error
  // had killed the process instead of becoming one line of output, which is
  // exactly the failure this project has been bitten by three times -- a
  // check that reports nothing is not a check.
  try
    RunProbe;
  except
    on E: Exception do
    begin
      WriteLn;
      // The unit and message, not a line number: this build's Exception has
      // no `LineNumber` member (measured -- the guard failed to compile
      // itself once for asking). UnitName plus the message still name the
      // failure; the stack would only add a procedure name at best.
      WriteLn('RESULT: the probe itself raised ', E.ClassName, ': ', E.Message);
      WriteLn('        raised in ', E.UnitName);
      Halt(2);
    end;
  end;
end.