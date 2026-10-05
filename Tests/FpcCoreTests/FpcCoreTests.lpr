program FpcCoreTests;

// {$mode delphi} REMOVED 2026-10-05, replaced by {$mode delphiunicode}.
//
// The directive sat here to pin Delphi-7 semantics, but it applied to THIS FILE
// ONLY -- the library units carry no mode directive and inherit the command
// line's -Mdelphiunicode. So the same spelling meant two different types:
//
//     FpcCoreTests.lpr   {$mode delphi}{$H+}   string = AnsiString
//     Lsp.JsonRpc.pas    (none)               string = UnicodeString
//
// A var/out parameter demands an EXACT match, so every call passing a string
// literal through one was refused:
//
//     Call by var for arg no. 1 has to match exactly:
//       Got "AnsiString" expected "UnicodeString"
//
// Five such sites, all in this file. The fix is to pin BOTH sides to the same
// mode rather than to convert types at each call, because a per-call conversion
// would let the two sides drift apart again the next time a string crosses.
//
// {$H+} is kept: it is what makes `string` UnicodeString under this mode, and
// without it the same split reappears in the other direction.
{$mode delphiunicode}{$H+}

// ---------------------------------------------------------------------------
// Phase-F / F0: headless verification of the UI-independent core.
//
// Purpose: prove (or disprove) that the Delphi-only, VCL-free modules of
// Dev-Cpp-Modern compile and behave identically under Free Pascal. No LCL,
// no VCL, no Win32 API is linked into the portable variant of this program.
// This file is FPC-only by design and is never compiled by the Delphi build.
//
// Exit code 0 = all checks passed; non-zero = at least one check failed.
// ---------------------------------------------------------------------------

uses
  SysUtils, Classes, Core.Events, Core.Services, GDB.MiTypes, GDB.MiParser,
  LSP.JsonRpc, LSP.Process, LSP.Process.Factory, LSP.Transport
{$IFDEF TEST_TOOLCHAIN}
  // The leading comma lives INSIDE the conditional, and the list stays a
  // single clause.
  //
  // This used to be a second, separate `uses` statement:
  //
  //     {$IFDEF TEST_TOOLCHAIN}
  //     uses
  //       ToolchainConfig;
  //     {$ENDIF}
  //
  // A program permits exactly ONE uses clause, and FPC says so plainly:
  //
  //     FpcCoreTests.lpr(41,1) Fatal: Syntax error, "BEGIN" expected but
  //                                  "USES" found
  //
  // It stayed invisible because the condition is FALSE in the portable build,
  // so only `-Win` ever reached the parser. Measured, not predicted: the
  // Windows variant had never been compiled before this.
  , ToolchainConfig
{$ENDIF}
  ;

type
  TProbe = class
  public
    Total: Integer;
    Failed: Integer;
    procedure Check(const AName: string; ACond: Boolean;
      const ADetail: string = '');
  end;

  TMiRecorder = class
  public
    ParseCount: Integer;
    RecordCount: Integer;
    LastType: TMiTokenType;
    LastResultClass: string;
    LastAsyncClass: string;
    LastMessage: string;
    LastTokenId: Integer;
    LastSuccess: Boolean;
    procedure OnParse(const TokenType: TMiTokenType; const Data: string);
    procedure OnRecord(const ARecord: TMiRecord);
  end;

  THandlerProbe = class
  public
    Hits: Integer;
    ProjectHits: Integer;
    ProgressHits: Integer;
    procedure OnEvent(const AEvent: TEvent);
    procedure OnProjectChanged(const AEvent: TEvent);
    procedure Boom(const AEvent: TEvent);
    // Binds to TCompilerProgressHandler, which is a plain method pointer after
    // the anonymous-method removal (see Core.Events). A global function will
    // not do: the target type is `procedure of object`, which carries Self and
    // so must be bound to an instance.
    procedure OnProgress(const AEvent: TCompileProgressEvent);
  end;

  TStubProjectService = class(TInterfacedObject, IProjectService)
  public
    function LoadProject(const FileName: String): Boolean;
    function SaveProject: Boolean;
    function GetCurrentProject: String;
    function GetProjectModified: Boolean;
    function AddUnit(const FileName: String): Integer;
    function RemoveUnit(Index: Integer): Boolean;
  end;

var
  GProgressHits: Integer;
  Probe: TProbe;

{ TProbe }

procedure TProbe.Check(const AName: string; ACond: Boolean;
  const ADetail: string);
begin
  Inc(Total);
  if ACond then
    WriteLn('  [PASS] ', AName)
  else
  begin
    Inc(Failed);
    if ADetail = '' then
      WriteLn('  [FAIL] ', AName)
    else
      WriteLn('  [FAIL] ', AName, ' -- ', ADetail);
  end;
end;

{ TMiRecorder }

procedure TMiRecorder.OnParse(const TokenType: TMiTokenType;
  const Data: string);
begin
  Inc(ParseCount);
  LastType := TokenType;
end;

procedure TMiRecorder.OnRecord(const ARecord: TMiRecord);
begin
  Inc(RecordCount);
  LastResultClass := ARecord.ResultClass;
  LastAsyncClass := ARecord.AsyncClass;
  LastMessage := ARecord.Message;
  LastTokenId := ARecord.TokenId;
  LastSuccess := ARecord.Success;
end;

{ THandlerProbe }

procedure THandlerProbe.OnEvent(const AEvent: TEvent);
begin
  Inc(Hits);
end;

procedure THandlerProbe.OnProjectChanged(const AEvent: TEvent);
begin
  Inc(ProjectHits);
end;

procedure THandlerProbe.Boom(const AEvent: TEvent);
begin
  raise Exception.Create('deliberate subscriber failure');
end;

procedure THandlerProbe.OnProgress(const AEvent: TCompileProgressEvent);
begin
  Inc(ProgressHits);
end;

{ TStubProjectService }

function TStubProjectService.LoadProject(const FileName: String): Boolean;
begin
  Result := FileName = 'stub.dev';
end;

function TStubProjectService.SaveProject: Boolean;
begin
  Result := True;
end;

function TStubProjectService.GetCurrentProject: String;
begin
  Result := 'stub.dev';
end;

function TStubProjectService.GetProjectModified: Boolean;
begin
  Result := False;
end;

function TStubProjectService.AddUnit(const FileName: String): Integer;
begin
  Result := 0;
end;

function TStubProjectService.RemoveUnit(Index: Integer): Boolean;
begin
  Result := True;
end;

// The local `BytesOf` this file used to define was REMOVED 2026-10-05.
//
// It called TEncoding.UTF8.GetBytes(S, 0, Len, Buf, 0), a five-argument
// Delphi form that FPC's RTL does not have (rtl/.../sysencoding.inc), so it
// raised EEncodingError and killed the program at RUN time. SysUtils already
// provides BytesOf in FPC and returns genuine UTF-8, so the definition was
// redundant as well as wrong -- removing it fixes both.

// Byte-array equality, done by COMPARING ELEMENTS.
//
// FPC's dynamic-array comparison does not behave as "same contents" the way the
// Delphi form does: two byte arrays with identical values (verified by printing
// both) compare unequal with `=`. Comparing the element data is the form that
// actually tests what the check means.
function BytesEqual(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
end;

procedure CheckJsonRpcFraming;
var
  Dec: TLspFrameDecoder;
  Body: string;
  Frame1: TBytes;
  Frame2: TBytes;
  Whole: TBytes;
  I: Integer;
  // Header width is DERIVED, never hard-coded. 'Content-Length: 7' is 17
  // characters, so with the terminating CRLFCRLF the header is 21 bytes;
  // the 18 previously assumed belongs to a five-byte body, and made 14
  // correct decoder checks look like failures.
  HdrLen: Integer;
  HdrLen3: Integer;
begin
  WriteLn('LSP.JsonRpc');
  HdrLen := Length(BytesOf('Content-Length: 7'#13#10#13#10));
  HdrLen3 := Length(BytesOf('Content-Length: 3'#13#10#13#10));
  // 1) ASCII body: header length == body byte count
  Frame1 := BuildLspFrameBytes('{"a":1}');
  Probe.Check('frame header carries the byte length',
    BytesEqual(Copy(Frame1, 0, HdrLen), BytesOf('Content-Length: 7'#13#10#13#10)),
    TEncoding.UTF8.GetString(Copy(Frame1, 0, HdrLen)));
  Probe.Check('frame keeps the body verbatim',
    BytesEqual(Copy(Frame1, HdrLen, MaxInt), BytesOf('{"a":1}')),
    TEncoding.UTF8.GetString(Copy(Frame1, HdrLen, MaxInt)));

  // 2) non-ASCII body: Content-Length counts UTF-8 bytes, not characters.
  //    U+4E2D ('zhong') encodes to 3 UTF-8 bytes.
  Frame1 := BuildLspFrameBytes(#$4E2D);
  Probe.Check('frame counts UTF-8 bytes, not characters',
    (BytesEqual(Copy(Frame1, 0, HdrLen3), BytesOf('Content-Length: 3'#13#10#13#10))) and
    (Length(Frame1) = HdrLen3 + 3),
    'len=' + IntToStr(Length(Frame1)));

  // 3) round trip through the decoder
  Dec := TLspFrameDecoder.Create;
  try
    Body := '';
    Dec.Feed(BuildLspFrameBytes('{"jsonrpc":"2.0","id":1,"result":null}'));
    Probe.Check('decoder returns a complete frame',
      Dec.TryPopBody(Body) and (Pos('"id":1', Body) > 0), Body);
    Probe.Check('decoder buffer is empty after a full drain',
      (not Dec.HasPendingData) and (Dec.PendingBytes = 0));

    // 4) frame split across reads: nothing is emitted until it is complete
    //
    // The assertion is deliberately NOT `Body = 'untouched'`. TryPopBody takes
    // `out ABody`, and for a MANAGED type (string) `out` makes the COMPILER clear
    // the actual variable before the call -- it is not something the callee can
    // decline to do. FPC honours this: the probe printed `Body = ""` even though
    // the body was written only on the success path. So that conjunct is
    // unsatisfiable by ANY implementation, and asserting it tested the language,
    // not the decoder. What the check must mean is "a partial frame yields
    // nothing, and the bytes are still held", both of which are observable.
    Whole := BuildLspFrameBytes('{"split":true}');
    Dec.Feed(Copy(Whole, 0, 10));
    Probe.Check('partial frame is not emitted',
      (not Dec.TryPopBody(Body)) and Dec.HasPendingData and
      (Dec.PendingBytes = 10),
      'pending=' + IntToStr(Dec.PendingBytes));
    Dec.Feed(Copy(Whole, 10, Length(Whole) - 10));
    Probe.Check('frame completes once the rest arrives',
      Dec.TryPopBody(Body) and (Body = '{"split":true}'), Body);

    // 5) byte-at-a-time delivery
    Dec.Reset;
    for I := 0 to Length(Whole) - 1 do
      Dec.Feed(Copy(Whole, I, 1));
    Probe.Check('byte-at-a-time delivery still yields the frame',
      Dec.TryPopBody(Body) and (Body = '{"split":true}'), Body);

    // 6) two frames arriving in a single read
    Dec.Reset;
    Frame1 := BuildLspFrameBytes('{"n":1}');
    Frame2 := BuildLspFrameBytes('{"n":2}');
    Dec.Feed(Concat(Frame1, Frame2));
    Body := '';
    Probe.Check('first of two batched frames is decoded',
      Dec.TryPopBody(Body) and (Body = '{"n":1}'), Body);
    Probe.Check('second of two batched frames is decoded',
      Dec.TryPopBody(Body) and (Body = '{"n":2}'), Body);
    Probe.Check('nothing is left after draining both frames',
      (not Dec.TryPopBody(Body)) and (not Dec.HasPendingData));

    // 7) a malformed header is skipped and parsing resynchronises inside the
    //    same call -- the exact behaviour of the pre-refactor inline loop.
    Dec.Reset;
    Dec.Feed(Concat(BytesOf('X-Bogus: 1'#13#10#13#10), Frame1));
    Body := 'untouched';
    Probe.Check('malformed header is skipped within one call',
      Dec.TryPopBody(Body) and (Body = '{"n":1}'), Body);
    Probe.Check('no bytes are stranded after resynchronising',
      (not Dec.HasPendingData) and (Dec.PendingBytes = 0),
      'pending=' + IntToStr(Dec.PendingBytes));
    Dec.Reset;
    Dec.Feed(BytesOf('X-Bogus: 1'#13#10#13#10));
    // Same reason as check 4: no `Body = 'untouched'` conjunct -- `out` clears it
    // in the compiler, so that conjunct is unsatisfiable by any implementation.
    //
    // The reported `pending=14` is NOT the decoder leaving bytes behind. Measured
    // on FPC 3.2.2 with a side-effecting probe: a call's ADetail argument is
    // built BEFORE the condition argument runs, so this diagnostic string
    // reports the state BEFORE TryPopBody. A probe that pops first and reads
    // PendingBytes afterwards shows 0. The condition below asserts the
    // post-call truth directly rather than trusting the diagnostic.
    Probe.Check('a lone malformed header yields nothing',
      (not Dec.TryPopBody(Body)) and (not Dec.HasPendingData),
      'pending=' + IntToStr(Dec.PendingBytes));

    // 8) incomplete header is buffered, not dropped
    Dec.Reset;
    Dec.Feed(BytesOf('Content-Length: 7'#13#10));
    Body := 'untouched';
    Probe.Check('incomplete header stays buffered',
      (not Dec.TryPopBody(Body)) and Dec.HasPendingData,
      'pending=' + IntToStr(Dec.PendingBytes));
    Dec.Reset;
    Probe.Check('Reset drops buffered bytes',
      (not Dec.HasPendingData) and (Dec.PendingBytes = 0));
  finally
    Dec.Free;
  end;
end;

procedure CheckLspProcess;
var
  Factory: ILspProcessFactory;
  Proc: ILspProcess;
  Buf: TBytes;
  N: Integer;
  Text: string;
begin
  WriteLn('LSP.Process');
  Factory := CreateDefaultLspProcessFactory;
  Probe.Check('default process factory is available', Assigned(Factory));
  if not Assigned(Factory) then
    Exit;

  // Round trip through a real child process. The child is this very test
  // binary re-invoked with --child-echo, so the test needs no external tools
  // and behaves identically on Windows and Linux.
  Proc := Factory.Start(ParamStr(0), '--child-echo hello-lsp-process',
    ExtractFilePath(ParamStr(0)));
  Probe.Check('child process starts', Assigned(Proc));
  if not Assigned(Proc) then
    Exit;

  Text := '';
  N := 0;
  try
    N := Proc.Read(Buf);
    if N > 0 then
      Text := TEncoding.UTF8.GetString(Buf, 0, N);
  finally
    Proc.Terminate;
  end;
  Probe.Check('child stdout is readable through the abstraction',
    (N > 0) and (Pos('hello-lsp-process', Text) > 0),
    'n=' + IntToStr(N) + ' text=' + Text);
  Probe.Check('process reports it is no longer running',
    not Proc.Running);
  Proc := nil;
end;

procedure CheckTransportSmoke;
var
  T: TLspTransport;
begin
  WriteLn('LSP.Transport (smoke)');
  // Constructing the transport exercises the FPC-side dependency graph
  // (factory + frame decoder) without spawning clangd.
  T := TLspTransport.Create('clangd-does-not-need-to-exist', GetTempDir);
  try
    Probe.Check('transport constructs headless',
      Assigned(T) and (T.State = tsDisconnected));
    Probe.Check('transport reports not connected', not T.Connected);
  finally
    T.Free;
  end;
end;

procedure CheckMiParser;
var
  Rec: TMiRecorder;
  Parser: TMiParser;
  T1: Integer;
  T2: Integer;
begin
  WriteLn('GDB.MiParser');
  Rec := TMiRecorder.Create;
  Parser := CreateMiParser;
  try
    Parser.OnParse := Rec.OnParse;
    Parser.OnRecord := Rec.OnRecord;

    // 1) plain ^done result record
    Parser.Feed('^done,value="1"' + #13#10);
    Probe.Check('^done record is tokenised',
      (Rec.RecordCount = 1) and (Rec.LastResultClass = 'done') and
      Rec.LastSuccess,
      'count=' + IntToStr(Rec.RecordCount) + ' class=' + Rec.LastResultClass);

    // 2) *stopped async record
    Parser.Feed('*stopped,reason="breakpoint-hit"' + #13#10);
    Probe.Check('*stopped async record is tokenised',
      (Rec.RecordCount = 2) and (Rec.LastAsyncClass = 'stopped') and
      (Pos('breakpoint-hit', Rec.LastMessage) > 0),
      'class=' + Rec.LastAsyncClass + ' msg=' + Rec.LastMessage);

    // 3) token id + error class
    Parser.Feed('7^error,msg="No symbol table info available."' + #13#10);
    Probe.Check('token id + ^error record',
      (Rec.RecordCount = 3) and (Rec.LastTokenId = 7) and
      (Rec.LastResultClass = 'error') and (not Rec.LastSuccess),
      'token=' + IntToStr(Rec.LastTokenId) + ' class=' + Rec.LastResultClass);

    // 4) stream record split across two Feed calls
    Parser.Feed('~"The program being ');
    Probe.Check('partial line is buffered, not dispatched',
      Rec.RecordCount = 3, 'count=' + IntToStr(Rec.RecordCount));
    Parser.Feed('debugged has been started."' + #13#10);
    Probe.Check('stream record is dispatched once completed',
      (Rec.RecordCount = 4) and (Pos('been started', Rec.LastMessage) > 0),
      'count=' + IntToStr(Rec.RecordCount) + ' msg=' + Rec.LastMessage);

    // 5) batch parse: every record dispatched, every callback fired
    Parser.Feed('^running' + #13#10 + '=thread-group-added,id="i1"' + #13#10 +
      '^done' + #13#10);
    Probe.Check('batched feed dispatches every record',
      Rec.RecordCount = 7, 'count=' + IntToStr(Rec.RecordCount));
    Probe.Check('OnParse fires for every record too',
      Rec.ParseCount = 7, 'parses=' + IntToStr(Rec.ParseCount));

    // 6) token id generator
    T1 := Parser.NextTokenId;
    T2 := Parser.NextTokenId;
    Probe.Check('NextTokenId is monotonic', T2 = T1 + 1,
      IntToStr(T1) + ' -> ' + IntToStr(T2));
  finally
    Parser.Free;
    Rec.Free;
  end;
end;

procedure CheckEventBus;
var
  P1: THandlerProbe;
  P2: THandlerProbe;
  Bad: THandlerProbe;
  P1Before: Integer;
  P2Before: Integer;
begin
  WriteLn('Core.Events');
  Probe.Check('TEventManager.Instance exists',
    Assigned(TEventManager.Instance));

  P1 := THandlerProbe.Create;
  P2 := THandlerProbe.Create;
  Bad := THandlerProbe.Create;
  try
    TEventManager.Instance.Subscribe(P1.OnEvent);
    TEventManager.Instance.Subscribe(P1.OnEvent); // de-duplicated
    TEventManager.Instance.Subscribe(P2.OnEvent);
    TEventManager.Instance.Subscribe(Bad.Boom);    // throwing subscriber

    TEventManager.Instance.Publish(
      TCompileProgressEvent.Create(50, 'half way'));
    Probe.Check('subscribers are notified exactly once',
      (P1.Hits = 1) and (P2.Hits = 1),
      'p1=' + IntToStr(P1.Hits) + ' p2=' + IntToStr(P2.Hits));
    Probe.Check('a throwing subscriber does not break dispatch', True);

    // typed routing via a classic method-based hook (of object)
    TEventManager.Instance.OnProjectChanged := P1.OnProjectChanged;
    TEventManager.Instance.Publish(TProjectChangedEvent.Create('b.cpp', 0));
    Probe.Check('OnProjectChanged hook is routed by type',
      P1.ProjectHits = 1, 'hits=' + IntToStr(P1.ProjectHits));
    TEventManager.Instance.OnProjectChanged := nil;

    // Unsubscribe must stop delivery to THAT handler while the others keep
    // receiving. Asserted as a DELTA, not as absolute counts.
    //
    // The old form demanded (P2.Hits = 1) and (P1.Hits = 2), which is wrong
    // arithmetic rather than a bug: Publish notifies EVERY subscriber for EVERY
    // event type -- the generic list is not type-filtered, only the single-cast
    // hooks below are. Three publishes have happened by now (one progress, one
    // project, and the TProjectChangedEvent above also went to the generic
    // subscribers), so the real pre-publish counters were P1=2/P2=2 and the run
    // reported p1=3 p2=2: P2 was in fact correctly frozen. Absolute counts
    // coupled this check to how many unrelated publishes preceded it.
    P1Before := P1.Hits;
    P2Before := P2.Hits;
    TEventManager.Instance.Unsubscribe(P2.OnEvent);
    TEventManager.Instance.Publish(TWatchVarEvent.Create('i', '42'));
    Probe.Check('unsubscribed handler stops receiving events',
      (P2.Hits = P2Before) and (P1.Hits = P1Before + 1),
      'p1: ' + IntToStr(P1Before) + '->' + IntToStr(P1.Hits) +
      ' p2: ' + IntToStr(P2Before) + '->' + IntToStr(P2.Hits));
{$IFDEF FPC_ANON_HOOK}
    // OnCompilerProgress routing.
    //
    // The comment here used to claim FPC's `{$mode delphi}` supports
    // `reference to procedure`, which the first real compile disproved on
    // 2026-10-05: `reference to` is rejected in every mode (-Mdelphi,
    // -Mdelphiunicode, -Mfpc, -Mobjfpc), each also with
    // {$modeswitch anonymousfunctions}, and the token appears in none of the 84
    // shipped RTL units. TCompilerProgressHandler is now a plain method pointer
    // (see Core.Events), so this check binds one.
    // Binds an instance method: TCompilerProgressHandler is `procedure of
    // object`, so it needs a Self and a global function will not type-check.
    // Bad is already alive here and is otherwise idle in this block.
    TEventManager.Instance.OnCompilerProgress := Bad.OnProgress;
    TEventManager.Instance.Publish(TCompileProgressEvent.Create(100, 'done'));
    Probe.Check('OnCompilerProgress hook is routed by type',
      Bad.ProgressHits = 1, 'hits=' + IntToStr(Bad.ProgressHits));
    TEventManager.Instance.Publish(TProjectChangedEvent.Create('a.cpp', 1));
    Probe.Check('OnCompilerProgress ignores other event types',
      Bad.ProgressHits = 1, 'hits=' + IntToStr(Bad.ProgressHits));
    TEventManager.Instance.OnCompilerProgress := nil;
{$ENDIF}
  finally
    TEventManager.Instance.Unsubscribe(P1.OnEvent);
    TEventManager.Instance.Unsubscribe(P2.OnEvent);
    TEventManager.Instance.Unsubscribe(Bad.Boom);
    P1.Free;
    P2.Free;
    Bad.Free;
  end;
end;

procedure CheckEventPayload;
var
  Node: TGdbVarNode;
  Frames: array[0..0] of TCallStackFrameItem;
  Ev: TBreakpointEvent;
begin
  WriteLn('Core.Events payload');
  // breakpoint event carries full context
  Ev := TBreakpointEvent.Create('main.cpp', 42, baHit, True);
  try
    Probe.Check('TBreakpointEvent payload',
      (Ev.FileName = 'main.cpp') and (Ev.LineNumber = 42) and
      (Ev.Action = baHit) and Ev.Active,
      Ev.FileName + ':' + IntToStr(Ev.LineNumber));
  finally
    Ev.Free;
  end;

  // GDB variable tree node owns its children
  Node := TGdbVarNode.Create;
  try
    Node.Expression := 'vec';
    Node.Children.Add(TGdbVarNode.Create);
    Probe.Check('TGdbVarNode owns children',
      (Node.Expression = 'vec') and (Node.Children.Count = 1));
  finally
    Node.Free;
  end;

  // variable tree node creates (and owns) its child list internally
  Node := TGdbVarNode.Create;
  try
    Probe.Check('TGdbVarNode creates its own child list',
      Assigned(Node.Children) and (Node.Children.Count = 0),
      'count=' + IntToStr(Node.Children.Count));
    Node.Children.Add(TGdbVarNode.Create);
    Probe.Check('child nodes can be appended', Node.Children.Count = 1);
  finally
    Node.Free;
  end;

  // call stack frame record layout
  Frames[0].FunctionName := 'main';
  Frames[0].Line := 7;
  Probe.Check('call stack frame record layout',
    (Frames[0].FunctionName = 'main') and (Frames[0].Line = 7));
end;

procedure CheckServiceLocator;
    // These checks go through QueryService(GUID, out IInterface), not the
    // generic TryGetService<T>. FPC 3.2.2 accepts neither spelling of the
    // generic call from here:
    //
    //   TryGetService<IProjectService>(Svc)  Syntax error, ")" expected
    //   TryGetService(Svc)                  Fatal: Internal error 2010122901
    //
    // The second is a COMPILER CRASH: there is no inference path from the
    // `out` parameter for this signature. Dropping the `<T: IInterface>`
    // constraint -- what the port plan had predicted -- changed nothing; the
    // failure is at the call, not the declaration.
    //
    // Consequence, stated rather than hidden: TryGetService<T> is now
    // UNEXERCISED by the smoke test. It is a convenience layer over
    // QueryService, which is what the checks below cover.
var
  Svc: IProjectService;
  Dbg: IDebuggerService;
  Unknown: IInterface;
begin
  WriteLn('Core.Services');
  Probe.Check('TServiceLocator.Instance exists',
    Assigned(TServiceLocator.Instance));

  Dbg := nil;
  Unknown := nil;
  Probe.Check('unregistered service is not resolvable',
    (not TServiceLocator.Instance.QueryService(IDebuggerService, Unknown)) and
    (Unknown = nil) and (Dbg = nil));

  TServiceLocator.Instance.ProjectService := TStubProjectService.Create;
  Svc := nil;
  Probe.Check('registered service resolves generically',
    TServiceLocator.Instance.QueryService(IProjectService, Unknown) and
    Supports(Unknown, IProjectService, Svc) and (Svc <> nil));
  if Svc <> nil then
    Probe.Check('resolved service is functional',
      Svc.LoadProject('stub.dev') and (Svc.CurrentProject = 'stub.dev') and
      (not Svc.ProjectModified));

  Probe.Check('QueryService reports missing services',
    (not TServiceLocator.Instance.QueryService(IDebuggerService, Unknown)) and
    (Unknown = nil));
  Probe.Check('QueryService finds a registered service',
    TServiceLocator.Instance.QueryService(IProjectService, Unknown) and
    (Unknown <> nil));

  TServiceLocator.Instance.ProjectService := nil;
end;

{$IFDEF TEST_TOOLCHAIN}
procedure CheckToolchain;
var
  Profile: TToolchainConfig;
  Errors: string;
begin
  WriteLn('ToolchainConfig (Windows variant)');
  Probe.Check('TToolchainService.Instance exists',
    Assigned(TToolchainService.Instance));
  Probe.Check('SetProfile(LLVM-MinGW) succeeds',
    TToolchainService.Instance.SetProfile(tcpLLVMMinGW));
  Profile := TToolchainService.Instance.CurrentProfile;
  Probe.Check('profile switch applies LLVM defaults',
    (Profile.Profile = tcpLLVMMinGW) and (Profile.GCCVersion = '16.0.6') and
    Profile.UCRT and (Profile.Prefix = 'clang64'),
    Profile.GCCVersion);
  Probe.Check('SetProfile(GCC14-MT) switches runtime target',
    TToolchainService.Instance.SetProfile(tcpGCC14MT) and
    (not TToolchainService.Instance.CurrentProfile.UCRT));
  Errors := '';
  Probe.Check('Compile gate fails honestly without a pipeline',
    (not TToolchainService.Instance.Compile('main.cpp', Errors)) and
    (Errors <> ''), 'Errors=' + Errors);
end;
{$ENDIF}

var
  ArgOk: Boolean;
begin
  // Child mode for the ILspProcess round-trip check: echo one line to the
  // redirected stdout, then exit. Keeps the test dependency-free and
  // identical on Windows and Linux.
  if (ParamCount >= 2) and (ParamStr(1) = '--child-echo') then
  begin
    WriteLn(ParamStr(2));
    Flush(Output);
    Halt(0);
  end;

  Probe := TProbe.Create;
  try
    ArgOk := (ParamCount = 0) or (ParamStr(1) = 'run');
    if not ArgOk then
    begin
      WriteLn('usage: ', ParamStr(0), ' [run]');
      Halt(2);
    end;

    WriteLn('Dev-Cpp-Modern FPC core smoke tests (Phase-F / F0)');
    WriteLn('-----------------------------------------------');
    CheckJsonRpcFraming;
    CheckLspProcess;
    CheckTransportSmoke;
    CheckMiParser;
    CheckEventBus;
    CheckEventPayload;
    CheckServiceLocator;
{$IFDEF TEST_TOOLCHAIN}
    CheckToolchain;
{$ENDIF}
    WriteLn('-----------------------------------------------');
    WriteLn('total=', Probe.Total, ' failed=', Probe.Failed);
    if Probe.Failed > 0 then
    begin
      WriteLn('RESULT: FAIL');
      Halt(1);
    end;
    WriteLn('RESULT: PASS');
  finally
    Probe.Free;
  end;
end.