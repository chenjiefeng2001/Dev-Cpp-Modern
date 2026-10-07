// ---------------------------------------------------------------------------
// Do the 13 CLEARED forms' .lfm files actually LOAD?
// =======================================================================
// f3_lfm_check.py proves the converted LFM is a faithful TREE of the DFM
// -- same objects, same properties, same order. That is a text
// comparison. It cannot prove that the LCL's own component reader
// accepts the result, which is the question §13.2 of the SVG plan
// calls "the cheapest remaining evidence": a form with no blocking
// control and real icon lists has nothing between it and a compile
// EXCEPT this unknown. SvgLfmProbe answered it for the SVG list
// fragments; ImgCollProbe answered it for the TVirtualImage
// fragment. Neither answered it for a whole WINDOW, because until
// F3-3 no whole window was unblocked. Now thirteen are.
//
// It streams the REAL generated .lfm files -- every one the route
// tool calls CLEARED -- rather than an LFM the probe writes itself.
// A hand-written fixture would agree with the LCL by construction
// and prove only that the LCL can load something shaped like a form;
// feeding it the converter's actual output is what makes a converter
// bug (a property the LCL cannot assign, an enum it renamed, a
// component it dropped) visible here instead of inside a window
// somebody opens later.
//
// WHAT IS ASSERTED, AND WHY EACH ONE
// ==================================
//   1. The file PARSES (LRSObjectTextToBinary). A syntax error the
//      converter wrote -- a `>` that should be `end>`, a property
//      line it mangled -- fails here, not in the designer.
//   2. The file STREAMS (TReader over the same driver the LCL's own
//      ReadComponentFromBinaryStream builds) and returns a non-nil
//      root. Parsing proves the text is well-formed; streaming
//      proves the LCL can INSTANTIATE it -- every class name
//      resolves, every property assigns. These are different
//      failures and the two-stage split is what tells them apart.
//   3. The root is the form class the DFM declared, under the name
//      the DFM gave it. The consumer forms are referenced by name
//      from code (CompOptionsFrm1.FillOptions and friends), so a
//      silent rename would compile and fail at runtime.
//   4. The root is a TForm and the tree is non-trivial -- BOTH in
//      owned components (TComponent children: timers, dialogs,
//      frames) and in parented controls (TWinControl children).
//      The first version of this probe would have passed a form
//      whose every child streamed but never got parented; the flat
//      converter output actually measured (MiniLfmTest, 2026-10-06)
//      dropped the children entirely, which is why assertion 4
//      exists at all.
//   5. The two frame-bearing forms (CompOptionsFrm, ProjectOptionsFrm)
//      get a focused check: their inline TCompOptionsFrame must come
//      back attached to the form, with the frame's OWN children
//      (tabs, vle) present under it -- the full Delphi embedded-frame
//      protocol, not just a stub the reader happened to survive.
//   6. Events are NOT asserted. An LFM names handlers (`OnClick =
//      btnOkClick`) that live in the form class; a probe that
//      declared a stub class has no such methods, so OnFindMethod
//      deliberately resolves every handler to nil. The claim under
//      test is "the LCL can build this form", not "the handlers
//      exist" -- the handlers belong to the ported units, which
//      fpc's own compiler checks.
//
// WHY EVERY CLASS IS REGISTERED BY HAND
// =====================================
// A component reader resolves every class name through the global
// registry, and the first draft of this probe assumed the LCL units
// "register their own widgets on initialization". Measured, they do
// not: LCL's StdCtrls registers TButton & co. inside `procedure
// Register` (stdctrls.pp:1698), which only a design-time package
// ever calls -- MiniLfmTest streamed a NESTED TButton against the
// stock LCL and got `EClassNotFound: Class "TButton" not found`.
// So the probes register the complete list of class names that
// appears in the thirteen files. That list was MEASURED from the
// LFM files, not guessed (42 distinct names), and a class missing
// from it fails with "Class Txxx not found", naming the fix.
// It lives in FormProbeSupport because PropRttiProbe needs the
// identical list, and two copies is a second thing to drift.
//
// THE FRAME MECHANISM (CompOptionsFrm / ProjectOptionsFrm)
// ========================================================
// The DFM embeds TCompOptionsFrame as `inline CompOptionsFrame1`,
// whose children appear as `inherited tabs` / `inherited vle` --
// full property state, C++Builder-written. At runtime the reader
// resolves an inherited entry by NAME against the current lookup
// root (FPC reader.inc:908: FLookupRoot.FindComponent), and the
// frame instance BECOMES the lookup root (csInline). The children
// must therefore already exist when the form's reader reaches the
// inline block -- and they do, because TCustomFrame.Create calls
// InitInheritedComponent (customframe.inc:215), which the LCL
// answers from LazarusResources (lresources.pp:5846 registers the
// handler; InitLazResourceComponent finds the resource named after
// the class and ReadRootComponents it into the frame). This probe
// reproduces that mechanism exactly: it registers the converted
// CompOptionsFrame.lfm as a LazarusResources entry under the frame
// class name -- in the BINARY form lazbuild embeds, for the reason
// RegisterFrameResource gives -- so the stub frame loads its REAL
// children from the REAL converted LFM, and the form's inherited
// entries then find them by name. The stub declares the two
// PUBLISHED handlers the frame LFM names (tabsChange,
// vleSetEditText) because the resource loads through the LCL's own
// reader, which resolves methods against the instance and has no
// nil-skip hook: they must be in the published method table or
// RTTIGetMethod cannot see them, which measured as
// `tabs.OnChange: Invalid value for property`.
//
// EVENTS ON THE FORMS THEMSELVES
// ==============================
// The form load path is built HERE (CreateLRSReader + the same
// sequence LCL's ReadComponentFromBinaryStream runs), which is what
// makes OnFindMethod available: every handler resolves to nil with
// Error := False. FPC's stock FindMethod raises
// EReadError(SInvalidPropertyValue) when MethodAddress returns nil
// (reader.inc:719-731), so without this hook no stub form could
// stream at all.
//
// COMPONENT REFERENCES ACROSS MODULES (`Images = dmMain.SVGImageListMenuStyle`)
// =========================================================
// A dotted reference becomes a deferred fixup; DoFixupReferences
// moves unresolved dotted names to the GLOBAL fixup list
// (reader.inc:776-782), which is silent -- the property stays nil
// until a component of that name is created somewhere. No exception,
// by measured reader behaviour, so the probe neither needs nor
// creates a dmMain. Whether the binding VALUES are right is
// f3_imgcoll_check.py's job (text-level, 68 points); whether the
// lists they name render is ImgCollProbe's.
//
// WHY THERE IS NO Application.Run
// =============================
// Nothing here needs a message loop. `Interfaces` is still required
// (the reader calls into the widgetset), and Application.Initialize
// is still called so canvases and handles belong to a live
// widgetset -- the same measured reasons SvgLfmProbe records.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

program FormLfmProbe;

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Classes, SysUtils, Forms, Controls, Graphics, ImgList,
  LResources, ExtCtrls, Buttons, StdCtrls, ComCtrls, Spin, ValEdit,
  Dialogs, CheckLst, ExtDlgs, SynEdit, LclVirtualImage, VclPropertySkips,
  FormProbeSupport;

var
  // Counted, not silent: printed in the summary so an inherited
  // entry that had to be created fresh is visible, never invisible.
  AncestorFallbacks: Integer = 0;

type
  // The class RESOLVER. Every class name in every streamed file comes
  // through here; FindClass over the registered list is the whole
  // mechanism.
  TClassResolver = class
    procedure Resolve(Reader: TReader; const AClassName: string;
                      var ComponentClass: TComponentClass);
  end;

  // The event-method resolver: every `OnClick = btnOkClick` in the
  // thirteen files names a handler that lives in the ported form
  // units, not here. Resolving to nil (not erroring) is the
  // deliberate choice -- see assertion 6.
  TMethodResolver = class
    procedure Skip(Reader: TReader; const HandlerName: string;
                   var Address: Pointer; var Error: Boolean);
  end;

  // The ancestor resolver, armed as a TRIPWIRE rather than a path the
  // probe expects to take: an `inherited` entry whose component does
  // not pre-exist reaches OnAncestorNotFound, and FPC would otherwise
  // raise SAncestorNotFound. If this fires, it is counted and printed
  // -- it means a form carried an inherited entry the frame-resource
  // mechanism did not satisfy, which is exactly the kind of finding
  // this probe exists to surface.
  TAncestorProvider = class
    procedure Provide(Reader: TReader; const AName: string;
                      AClass: TPersistentClass; var Component: TComponent);
  end;

procedure TClassResolver.Resolve(Reader: TReader; const AClassName: string;
  var ComponentClass: TComponentClass);
begin
  // FindClass, so a class that was never registered reports
  // "Class Txxx not found" -- which is the truth and names the
  // fix -- instead of silently resolving to something else.
  ComponentClass := TComponentClass(FindClass(AClassName));
end;

procedure TMethodResolver.Skip(Reader: TReader; const HandlerName: string;
  var Address: Pointer; var Error: Boolean);
begin
  Address := nil;
  Error := False;
end;

procedure TAncestorProvider.Provide(Reader: TReader; const AName: string;
  AClass: TPersistentClass; var Component: TComponent);
begin
  Inc(AncestorFallbacks);
  WriteLn('  NOTE   inherited "', AName, '" had no pre-existing instance; ',
          'created fresh as ', AClass.ClassName);
  if Assigned(AClass) and AClass.InheritsFrom(TComponent) then
    Component := TComponentClass(AClass).Create(Reader.Owner);
end;

var
  Failures: Integer = 0;
  Loaded: Integer = 0;
  RepoRoot: string = '';
  Resolver: TClassResolver;
  MethodResolver: TMethodResolver;
  AncestorProvider: TAncestorProvider;
  K: Integer;

// One level up, or '' at the root, and the walk that anchors the probe
// to the repository, both live in FormProbeSupport -- the property
// audit needs the identical anchor, and a second copy of it would be a
// second thing to drift.

procedure Check(const What: string; Ok: Boolean; const Detail: string = '');
begin
  if Ok then
    WriteLn('  OK   ', What, ' ', Detail)
  else
  begin
    WriteLn('  FAIL ', What, ' ', Detail);
    Inc(Failures);
  end;
  // Flushed after every check: a probe killed by a timeout reports
  // nothing about where it got to when stdout is a pipe.
  Flush(Output);
end;

// Read the LFM file and register it as the frame's resource, in the
// FORM lazbuild embeds it: BINARY. This is not a stylistic choice,
// it is what the compiled artefact contains -- measured, because the
// first version of this probe registered the LFM TEXT and every
// frame-bearing form failed with `Invalid Filer Signature`.
//
// The mechanism, from the LCL's own source:
//   * InitLazResourceComponent (lresources.pp:3128-3131) wraps the
//     resource value in a TLazarusResourceStream, i.e. a plain byte
//     stream over whatever bytes were stored;
//   * it then calls `Reader.ReadRootComponent` (lresources.pp:3152),
//     and FPC's ReadRootComponent opens with Driver.BeginRootComponent;
//   * TLRSObjectReader.BeginRootComponent (lresources.pp:3990-3998)
//     reads FOUR RAW BYTES and compares them with the filer signature
//     'TPF0'. Despite the name, TLRSObjectReader is not a text parser
//     -- its `Read(var Buf; Count)` (lresources.pp:3835) is a memcpy
//     out of the raw stream, so 4 bytes of `object CompOptionsFrame`
//     are compared against 'TPF0' and rejected.
//
// So the bytes a real Lazarus binary holds are 'TPF0' followed by
// length-prefixed names: counted 2 occurrences of 'TPF0' in
// C:\lazarus\components\chmhelp\lhelp.exe, whose first one is
// 'TPF0' + spaces + two length bytes + two names. That is exactly
// what LRSObjectTextToBinary produces, which is why the resource is
// converted here rather than passed through.
//
// The previous comment in this file claimed the opposite ("TLRSObjectReader
// is a native text-LFM parser, so no LRSObjectTextToBinary conversion is
// wanted here"). It was a reasonable inference from the class name and
// it was wrong; the reader does have a text-shaped API (ReadStr, SkipValue)
// and the raw-bytes signature check is the one thing about it that is not
// text-shaped at all.
procedure RegisterFrameResource;
var
  Path: string;
  Lines: TStringList;
  Text: TStringStream;
  Bin: TMemoryStream;
  Binary: AnsiString;
begin
  Path := RepoRoot + FORMS_REL + '\CompOptionsFrame.lfm';
  Lines := TStringList.Create;
  Bin := TMemoryStream.Create;
  try
    Lines.LoadFromFile(AnsiString(Path));
    Text := TStringStream.Create(Lines.Text);
    try
      LRSObjectTextToBinary(Text, Bin);
    finally
      Text.Free;
    end;
    // The value the LCL's InitLazResourceComponent looks up is keyed
    // by CLASS NAME (lresources.pp:3124: ResName := ClassType.ClassName).
    SetString(Binary, PChar(Bin.Memory), Bin.Size);
    LazarusResources.Add('TCompOptionsFrame', 'LFM', Binary);
    WriteLn('  frame resource: TCompOptionsFrame <- ', Bin.Size,
            ' binary byte(s) from CompOptionsFrame.lfm, signature "',
            Copy(Binary, 1, 4), '"');
  finally
    Bin.Free;
    Lines.Free;
  end;
end;

procedure StreamForm(const E: TFormExpectation);
var
  Path: string;
  Mem: TFileStream;
  Bin: TMemoryStream;
  Root: TComponent;
  Reader: TReader;
  DestroyDriver: Boolean;
  AClassName: shortstring;
  IsInherited: Boolean;
  AClass: TComponentClass;
  Frame: TComponent;
  Tabs: TComponent;
  I: Integer;
begin
  WriteLn('STREAMING ', E.FileName);
  Path := RepoRoot + FORMS_REL + '\' + E.FileName;
  if not FileExists(Path) then
  begin
    WriteLn('  FAIL   file exists -- the route tool called this form ',
            'CLEARED but the converter emitted no LFM for it');
    Inc(Failures);
    Exit;
  end;

  // AnsiString, because -Mdelphiunicode makes `string` a
  // UnicodeString and TFileStream still takes an AnsiString file
  // name in this FPC. The implicit conversion compiles, but it is
  // exactly the kind of narrowing that turns a non-ASCII path into
  // "file not found" with no diagnostic.
  Mem := TFileStream.Create(AnsiString(Path), fmOpenRead or fmShareDenyWrite);
  Bin := TMemoryStream.Create;
  Reader := nil;
  Root := nil;
  try
    // Two stages, deliberately, and the split is load-bearing (the
    // full reason is in SvgLfmProbe): NOT TReader, which on this
    // build hangs on text input; and LRSObjectTextToBinary separated
    // from the streaming step, which tells a malformed LFM apart
    // from one that parses but instantiates wrongly.
    try
      LRSObjectTextToBinary(Mem, Bin);
    except
      on E: Exception do
      begin
        WriteLn('  FAIL   parse raised ', E.ClassName, ': ', E.Message);
        Inc(Failures);
        Exit;
      end;
    end;
    WriteLn('  parsed to binary: ', Bin.Size, ' byte(s)');
    Flush(Output);

    // The root class, the same way LCL's ReadComponentFromBinaryStream
    // gets it: peek the first record, resolve, instantiate, then hand
    // the instance to the reader.
    Bin.Position := 0;
    AClassName := GetClassNameFromLRSStream(Bin, IsInherited);
    Bin.Position := 0;
    AClass := TComponentClass(FindClass(string(AClassName)));
    Root := AClass.NewInstance as TComponent;
    Root.Create(nil);

    // The load sequence is LCL's own ReadComponentFromBinaryStream
    // (lresources.pp:936-1006), with two hooks the LCL version leaves
    // unset because real form classes carry real methods: the
    // event-method resolver and the ancestor tripwire.
    DestroyDriver := False;
    Reader := CreateLRSReader(Bin, DestroyDriver);
    Reader.Root := Root;
    Reader.Owner := Root;
    Reader.OnFindComponentClass := @Resolver.Resolve;
    Reader.OnFindMethod := @MethodResolver.Skip;
    Reader.OnAncestorNotFound := @AncestorProvider.Provide;
    Reader.BeginReferences;
    try
      Reader.Driver.BeginRootComponent;
      Root := Reader.ReadComponent(Root);
      Reader.FixupReferences;
    finally
      Reader.EndReferences;
    end;
  except
    on E: Exception do
    begin
      WriteLn('  FAIL   streaming raised ', E.ClassName, ': ', E.Message);
      Inc(Failures);
      Root := nil;
    end;
  end;
  if Assigned(Reader) then
  begin
    if DestroyDriver then
      Reader.Driver.Free;
    Reader.Free;
  end;
  Bin.Free;
  Mem.Free;

  if Root = nil then
  begin
    WriteLn('  FAIL   streamed to a nil component');
    Flush(Output);
    Exit;
  end;
  WriteLn('  streamed root: ', Root.ClassName, ' with ',
          Root.ComponentCount, ' owned component(s), ',
          TWinControl(Root).ControlCount, ' parented control(s)');

  // Assertion 3: the form came back as the class and under the name
  // the DFM declared -- consumers reference it by both.
  Check('root class is ' + E.ClassName, Root.ClassName = E.ClassName,
        'got ' + Root.ClassName);
  Check('root instance is ' + E.InstanceName, Root.Name = E.InstanceName,
        'got ' + Root.Name);
  // Assertion 4: a window, with something owned AND something parented.
  Check('root is a TForm', Root is TForm);
  Check('owned components are non-trivial', Root.ComponentCount > 0,
        Format('%d component(s)', [Root.ComponentCount]));
  Check('parented controls are non-trivial', TWinControl(Root).ControlCount > 0,
        Format('%d control(s)', [TWinControl(Root).ControlCount]));

  // Assertion 5: the embedded frame came through the real protocol.
  if (E.FileName = 'CompOptionsFrm.lfm') or
     (E.FileName = 'ProjectOptionsFrm.lfm') then
  begin
    Frame := nil;
    for I := 0 to Root.ComponentCount - 1 do
      if Root.Components[I] is TCompOptionsFrame then
      begin
        Frame := Root.Components[I];
        Break;
      end;
    Check('TCompOptionsFrame instance is owned by the form', Frame <> nil);
    if Frame <> nil then
    begin
      Check('frame is parented into the form tree',
          Frame.GetParentComponent <> nil,
          'parent is ' + Frame.GetParentComponent.ClassName);
      Check('frame loaded its own children from the registered resource',
            Frame.ComponentCount > 0,
            Format('%d owned component(s)', [Frame.ComponentCount]));
      Check('frame has parented controls', TWinControl(Frame).ControlCount > 0,
            Format('%d control(s)', [TWinControl(Frame).ControlCount]));
      Tabs := Frame.FindComponent('tabs');
      Check('frame''s "tabs" resolved by name', Tabs <> nil);
      if Tabs <> nil then
        Check('frame''s "vle" resolved by name',
              Frame.FindComponent('vle') <> nil);
    end;
  end;

  Root.Free;
  Inc(Loaded);
end;

begin
  // The registration list and the CLEARED table live in
  // FormProbeSupport, shared with PropRttiProbe: 42 class names
  // (13 form roots + TCompOptionsFrame + 28 LCL/widget classes),
  // MEASURED from the files, plus the reason nothing here can be left
  // to the LCL -- see that unit's header.
  WriteLn('  registered ', RegisterFormProbeClasses, ' classes');

  Resolver := TClassResolver.Create;
  MethodResolver := TMethodResolver.Create;
  AncestorProvider := TAncestorProvider.Create;
  Application.Initialize;
  WriteLn('  Application.Initialize done');

  RepoRoot := FindRepoRoot;
  if RepoRoot = '' then
  begin
    WriteLn('RESULT: repo root not found -- FAIL');
    Halt(1);
  end;
  WriteLn('  repo root: ', RepoRoot);

  RegisterFrameResource;
  WriteLn;

  for K := Low(EXPECTED) to High(EXPECTED) do
    StreamForm(EXPECTED[K]);

  Resolver.Free;
  MethodResolver.Free;
  AncestorProvider.Free;

  WriteLn;
  WriteLn('Streamed forms: ', Loaded, ' of ', Length(EXPECTED));
  WriteLn('Ancestor fallbacks (inherited entries with no pre-existing ',
          'instance): ', AncestorFallbacks);
  WriteLn;
  if Failures = 0 then
    WriteLn('RESULT: every CLEARED form loads through the real LCL reader')
  else
  begin
    WriteLn('RESULT: ', Failures, ' check(s) FAILED');
    Halt(1);
  end;
end.
