unit MainUi;

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Windows, Forms, ComCtrls,
  {$ELSE}
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.Forms, Vcl.ComCtrls,
  {$ENDIF}
  {$IFDEF FPC}
  ExtCtrls, MultiLangSupport;
  {$ELSE}
  Vcl.ExtCtrls, MultiLangSupport;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Anti-corruption layer for the main window (Phase-F / F1).
//
// Business units must not reach into MainForm.* directly: that coupling is
// what makes main.pas impossible to decompose, and therefore what blocks the
// headless (FPC) verification of the compiler/debugger logic.
//
// This unit is the single sanctioned place where MainForm.* may appear. It is
// listed as `facade` in tools/mainform_baseline.json, so the ratchet gate
// (tools/qa_check.py) fails if any *other* unit starts touching the god form.
//
// Semantics of each entry point mirror the previous inline call sites exactly:
//   CompileProgressReset(Max)  == Min := 0; Max := N; Position := 0
//   ShowError(Text)            == MessageBox(MainForm.Handle, ..., ID_ERROR)
// Compiler.pas was the first consumer (22 references removed).
// ---------------------------------------------------------------------------

// Refresh the title bar from the current project/run state.
procedure RefreshAppTitle;

// Compile progress bar control. The four entry points mirror the four
// distinct original call shapes; merging them would change behaviour.
procedure CompileProgressReset(AMax: Integer); // Min := 0; Max := AMax; Position := 0
procedure CompileProgressMax(AMax: Integer);   // Max := AMax only
procedure CompileProgressStep;                 // StepIt
procedure CompileProgressRewind;               // Position := 0 only

// True when the "compile and run" action is currently available.
function CanRunCompile: Boolean;
// Execute the "compile and run" action (same as actCompRunExecute(nil)).
procedure RunCompileAction;

// Show a modal error box owned by the main window, using the localisable
// "Error" caption (ID_ERROR) exactly as the previous call sites did.
procedure ShowError(const AMessage: string);

// ---------------------------------------------------------------------------
// Project slice (TProject) -- F1, second batch.
//
// IMPORTANT (why TObject and not TEditor here): main.pas uses Project, and
// Editor uses main. Exposing TEditor/TEditorList in this unit's *interface*
// would create the cycle Project -> MainUi -> Editor -> main -> Project,
// which Delphi rejects outright. The editor types are therefore confined to the
// implementation section (implementation cycles are legal), and callers cast
// explicitly -- e.g. `TEditor(MainUi.FindOpenEditor(Name))` -- which keeps the
// type check the old `MainForm.EditorList.NewEditor(...)` call had.
//
// Parameter names mirror EditorList's real signatures on purpose, so a forwarder
// cannot silently swap meaning (NewEditor is (InProject, NewFile)).
// ---------------------------------------------------------------------------

// Dialog / form owner for modals opened by business units.
function DialogOwner: TComponent;

// Editor list forwarding (former MainForm.EditorList.*)
function FindOpenEditor(const AFileName: string): TObject;   // FileIsOpen(Name)
function CreateEditor(const AFileName: string; AInProject,
  ANewFile: Boolean): TObject;                              // NewEditor(...)
procedure ForceCloseEditor(AEditor: TObject);
function TryCloseEditor(AEditor: TObject): Boolean;         // CloseEditor(...)
function EditorPageCount: Integer;
function EditorAt(AIndex: Integer): TObject;                // EditorList[Index]
procedure VisibleEditors(out AFocused, AOther: TObject);   // GetVisibleEditors

// Project tree (former MainForm.ProjectView.*)
function AddProjectRootNode(const AName: string): TTreeNode;
function AddProjectChildNode(const AText: string;
  AParent: TTreeNode): TTreeNode;
procedure ProjectViewBeginUpdate;
procedure ProjectViewEndUpdate;
procedure ExpandProjectView;                                // FullExpand
function ProjectViewItemCount: Integer;
function ProjectViewItem(AIndex: Integer): TTreeNode;
procedure SelectProjectNode(ANode: TTreeNode);             // Select(ANode)

// Output panes (former MainForm.CompilerOutput / LogOutput)
function CompilerOutputItemCount: Integer;
function CompilerOutputItemText(AIndex: Integer): string;   // Caption + #10 + SubItems.Text
function LogOutputText: string;                             // TMemo: Text = Lines.Text

// File monitor (former MainForm.FileMonitor.BeginUpdate/EndUpdate)
procedure FileMonitorBeginUpdate;
procedure FileMonitorEndUpdate;

// ---------------------------------------------------------------------------
// Editor slice (TEditor) -- F1, third batch.
//
// TEditor decides whether the IDE can ever swap its editor engine (LCL
// SynEdit, Monaco, WebView2) without dragging the god form along, so its 68
// former `MainForm.*` references are worth naming precisely.
//
// Two rules govern this section:
//
//  1. Domain services (Debugger, CppParser, the current TProject) are handed
//     over as TObject, never as widgets. Each of those types is already in
//     Editor.pas's own uses, so the call site casts explicitly and keeps full
//     compile-time checking: TCppParser(MainUi.SharedCppParser).ParseFile(..)
//     still fails to build the day TCppParser changes shape.
//
//  2. Genuinely UI-shaped state (status bar text, popup menu, bookmark menu
//     ticks) is collapsed into a *semantic* operation rather than leaking the
//     widget -- a leaked TStatusBar is just the god form wearing a hat.
//     SetStatusbarEditMode is the model: the caller picks the language string,
//     the facade decides that it belongs in Panels[1].
// ---------------------------------------------------------------------------

// Mirrors Debugger.TEvalReadyEvent. Declared structurally identical here so
// the Debugger unit never appears in this interface; the conversion back to the
// real event type happens inside the implementation.
type
  TCodeEvalReady = procedure(const AValue: string) of object;

// -- Debugger slice (17 former MainForm.Debugger.* references) ---------------
// BreakPoints is the debugger's breakpoint TList; callers keep iterating and
// casting PBreakPoint entries exactly as before (that type lives in
// DebugReader.pas, which Editor.pas already uses).
function BreakPoints: TList;
procedure AddBreakPoint(ALine: Integer; AEditor: TObject);
procedure RemoveBreakPoint(ALine: Integer; AEditor: TObject);
procedure DeleteBreakPointsOf(AEditor: TObject);
procedure AddWatchVar(const AName: string);
procedure SendDebuggerCommand(const ACommand, AParams: string);
procedure SetEvalReadyHandler(AHandler: TCodeEvalReady);
function DebuggerExecuting: Boolean;

// -- Parser slice (12 former MainForm.CppParser.* references) ---------------
function SharedCppParser: TObject;                                // -> TCppParser

// -- Project slice (7 former MainForm.Project.* references) -----------------
function CurrentProject: TObject;                                 // -> TProject

// -- File monitor, the two remaining members --------------------------------
procedure MonitorFile(const AFileName: string);
procedure UnMonitorFile(const AFileName: string);

// -- Class browser (4 former MainForm.ClassBrowser.* references) -------------
procedure SetClassBrowserFile(const AFileName: string);
procedure ClassBrowserBeginUpdate;
procedure ClassBrowserEndUpdate;

// -- Output panes: the raw item lists (6 former MainForm.<X>Output.Items) ----
// TListItems comes from ComCtrls, already in this interface.
function CompilerOutputItems: TListItems;
function ResourceOutputItems: TListItems;
function FindOutputItems: TListItems;

// -- Title, actions, status bar ---------------------------------------------
procedure UpdateCompilerList;
procedure GotoImplDeclInEditor(AEditor: TObject);  // actGotoImplDeclEditorExecute
procedure OpenFilesFromList(const AFiles: TStrings); // OpenFileList(TStringList)
procedure SetStatusbarLineCol;
procedure SetStatusbarEditMode(const AText: string); // Statusbar.Panels[1].Text
procedure SetCurrentPageHint(const AText: string);
procedure SetToggleBookmarksChecked(AIndex: Integer; AChecked: Boolean);

// -- Widget handles the editor genuinely owns -------------------------------
function CodeCompletionBox: TObject;                            // -> TCodeCompletion
function EditorPopupMenu: TObject;                              // -> TPopupMenu
function FindEditorByFileName(const AFileName: string): TObject;

// ---------------------------------------------------------------------------
// Self-test slice (TTestClass) -- F1, fourth batch.
//
// TTestClass drives the editor/editor-list/layout assertions from a menu action
// (main.pas: actRunTests), so it is user-reachable and its 153 references are
// the single largest remaining block. They collapse into three shapes:
//
//   * status bar narration (48)   -> SetStatusbarMessage
//   * editor-list state (97)     -> page controls as TObject + layout predicates
//   * action/bookmark clicking (8) -> Click/Checked helpers
// ---------------------------------------------------------------------------

// -- status bar (48 former MainForm.SetStatusbarMessage references) ----------
procedure SetStatusbarMessage(const AText: string);

// -- page controls (40 former Left/Right/FocusedPageControl references) ------
// TObject + explicit cast at the call site, matching the TTreeNode/TListItems
// discipline already used above. TPageControl lives in ComCtrls.
function LeftPageControl: TObject;
function RightPageControl: TObject;
function FocusedPageControl: TObject;

// -- editor lookup / lifecycle (12) ----------------------------------------
function EditorByIndex(APageIndex: Integer;
  APageControl: TObject): TObject;                    // GetEditor(-1, PC) = current
function PreviousEditor(AEditor: TObject): TObject;   // GetPreviousEditor
function CreateEditorInPage(AFileName: string; AInProject,
  ANewFile: Boolean; APageControl: TObject): TObject;  // NewEditor(..., PC)
function SwapEditor(AEditor: TObject): Boolean;
procedure SelectNextEditorPage;
procedure SelectPrevEditorPage;

// -- layout state (20 former `Layout = lstXxx` assertions) ------------------
// Deliberately four predicates rather than the TLayoutShowType enum: leaking
// the enum would pull EditorList into this interface.
function EditorLayoutIsNone: Boolean;
function EditorLayoutIsLeft: Boolean;
function EditorLayoutIsRight: Boolean;
function EditorLayoutIsBoth: Boolean;

// -- action list (2) --------------------------------------------------------
function ActionCount: Integer;
function ActionAt(AIndex: Integer): TObject;           // -> TCustomAction

// -- bookmark menu items (5) -----------------------------------------------
procedure ClickToggleBookmark(AIndex: Integer);
function ToggleBookmarkChecked(AIndex: Integer): Boolean;
procedure ClickGotoBookmark(AIndex: Integer);

// -- new-source action (1) -------------------------------------------------
procedure ExecuteNewSource;

// -- window identification (1) ------------------------------------------
// A string, not a TClass: handing the caller TMainForm.ClassRef would
// re-export the god class through the very door this unit exists to close.
function MainWindowClassName: string;

// ---------------------------------------------------------------------------
// Find & replace results slice (TFindForm) -- F1, fifth batch.
//
// FindFrm's 20 references are not 20 independent couplings. Nineteen are one
// repeated gesture -- "walk the editor list or the project unit list, touch
// the Find results list" -- and the three that set up the results page are a
// single user-visible action. So they collapse into five entry points plus one
// action, rather than twenty mechanical forwarders.
//
// ShowFindResults is the model: the old call site was three statements about
// three separate widgets (MessageControl.ActivePageIndex, FindSheet.Caption,
// OpenCloseMessageSheet). A leaked TPageControl plus a leaked TTabSheet is the
// god form wearing a hat; one `ShowFindResults(Count)` says what the user
// actually asked for.
// ---------------------------------------------------------------------------

procedure BeginFindOutputUpdate;                     // FindOutput.Items.BeginUpdate
procedure EndFindOutputUpdate;                       // FindOutput.Items.EndUpdate
procedure ClearFindOutput;                           // FindOutput.Clear
procedure AddFindOutputItem(const ALine, ACol, AFileName, AMsg,
  AKeyword: string);                                // AddFindOutputItem(...)
procedure ShowFindResults(AMatchCount: Integer);     // see above

// ---------------------------------------------------------------------------
// Project unit list slice (TFindForm) -- F1, fifth batch.
//
// TProject, TUnitList and TProjUnit stay in this implementation: Project.pas
// already uses this unit, so naming those types in the *interface* would
// close a cycle Delphi rejects. The dialogs only ever iterate, so they get
// Count plus two indexed accessors returning TObject / string.
//
// CloseProjectUnitOfEditor collapses IndexOf + CloseUnit into one call on
// purpose: every caller wrote exactly that pair, and the -1 case is the same
// latent hazard in all of them. One site to reason about beats three.
// ---------------------------------------------------------------------------

function ProjectUnitCount: Integer;
function ProjectUnitFileName(AIndex: Integer): string;
function ProjectUnitEditor(AIndex: Integer): TObject;         // -> TEditor
procedure CloseProjectUnitOfEditor(AEditor: TObject);        // CloseUnit(Units.IndexOf(e))

// ---------------------------------------------------------------------------
// Profiling target slice (TProfileAnalysisForm) -- F1, fifth batch.
//
// The Gprof front end resolves its target the same way in all four places:
// "the project's executable if a project is open, otherwise the active
// editor's file with the extension swapped". These two readers are that
// choice, split at the seam the call sites already had.
//
// ActiveEditorFileName keeps the original's missing nil-editor guard on
// purpose. Every call site sits in the `else` of `Assigned(CurrentProject)`,
// where a possibly-nil TEditor was already dereferenced through `.FileName`.
// Returning '' would turn a crash into a wrong command line -- a worse
// failure, and a behaviour change, which is not this batch's business.
// ---------------------------------------------------------------------------

function ProjectExecutable: string;                          // Project.Executable
function ActiveEditorFileName: string;                       // GetEditor.FileName
// -- window identification (1) ------------------------------------------
// A string, not a TClass: handing the caller TMainForm.ClassRef would
// re-export the god class through the very door this unit exists to close.
function MainWindowClassName: string;

// ---------------------------------------------------------------------------
// Project identity slice (TFilePropertiesForm) -- F1, sixth batch.
//
// FilePropertiesFrm reads exactly three things about the project: its file
// name, its directory and its name -- and then always combines the directory
// with a path the dialog already has. That is why these are not three
// getters but one predicate plus one derived answer:
//
//   IsProjectFile(Name)  -- "is this file one of ours", i.e. the old
//                           `Project.Units.IndexOf(Name) <> -1`
//   ProjectRelativePath  -- the old `ExtractRelativePath(Project.Directory,
//                           Name)`, which appeared at both call sites
//
// ProjectName is the odd one out: it is the human-readable project title and
// nothing else in the IDE needs it for anything, so it stays a plain reader.
//
// Returning '' when no project is open is the right answer for all four: the
// original call sites sat inside `Assigned(CurrentProject)` / `SameStr('.dev')`
// guards, and a blank relative path is what the dialog already displays for
// "not in a project" (line 295 assigns '-'), so nothing new can be observed.
// ---------------------------------------------------------------------------

function IsProjectFile(const AFileName: string): Boolean;
function ProjectRelativePath(const AFileName: string): string;

// ---------------------------------------------------------------------------
// Project metadata slice (Macros / Utils) -- F1, eleventh batch, step 1.
//
// The macro engine and the path resolver both ask the same handful of
// questions about the open project, and MainUi already answers four of them
// from earlier slices (ProjectExecutable, ProjectName, ProjectFileName,
// ProjectDirectory). Only <SOURCESPCLIST> was missing.
//
// ProjectUnitList returns TProject.ListUnitStr(' ') verbatim -- the same
// separator, the same formatting. Wrapping it is deliberate: the argument IS
// the formatting choice, so a caller that could pass its own separator would
// be a caller re-inventing the macro format. Macros.pas asks for the unit
// list; it does not decide what a unit list looks like.
// ---------------------------------------------------------------------------

function ProjectUnitList(const ASeparator: string): string;
function ProjectName: string;
function ProjectFileName: string;

// ---------------------------------------------------------------------------
// Navigation slice (TViewToDoForm) -- F1, sixth batch.
//
// The TODO view's only reason to know the god form is the double-click
// gesture: "take me to the line this item refers to". Expressed as a handle
// pair -- GetEditorFromFileName then SetCaretPosAndActivate -- the dialog
// would need the editor's real type, which drags `editor` and the whole
// SynEdit surface back into view code that has no business editing text.
//
// NavigateToFileAndLine says the one thing the user asked for. It returns
// False when the file is not open, which is what the old `if Assigned(e)`
// guard was deciding, so the caller's "close the dialog only if we really
// navigated" logic is preserved exactly.
//
// SetCaretPosAndActivate (not GotoLine) is deliberate: the original used the
// former and the difference is that it also raises the page control. Silently
// swapping in the plainer call would change what the user sees.
// ---------------------------------------------------------------------------

function NavigateToFileAndLine(const AFileName: string; ALine: Integer): Boolean;

// ---------------------------------------------------------------------------
// Class-creation wizard slice (TNewClassForm) -- F1, seventh batch.
//
// The C++ "new class" wizard is the last pure-dialog unit, and its 15
// references are the same three gestures as every dialog before it: ask the
// project where new files go, ask the parser what classes exist, ask the
// class browser what is selected. None of that is the wizard's business.
//
// The two entries worth arguing about:
//
// AddProjectUnit + OpenProjectUnit are deliberately NOT collapsed into one
// "create and open" action. The original is
//     idx := Project.NewUnit(False, nil, Name);
//     e   := Project.OpenUnit(idx);          // <-- runs BEFORE the check
//     if idx = -1 then begin Error; Exit; end;
// so the caller needs `idx` to make its own decision, and OpenUnit is
// invoked with -1 on the failure path. Folding the pair would silently skip
// that call. A latent oddity stays exactly as it was; a behaviour change
// does not ride along with a refactor.
//
// IsClassInCurrentProject replaces a thirteen-line statement walk that mixed
// the parser's node chain with the project's unit list. The walk answers one
// question -- "is the named base class declared in a file of THIS project",
// which the wizard uses only to choose `#include "x"` over `#include <x>`.
// Note what is deliberately NOT used: TStatement._InProject. It is a
// parse-time snapshot (CppParser.pas:440) and would go stale the moment a
// file joins the project; Project.Units.IndexOf is a live query. The
// equivalence looked obvious and is false.
// ---------------------------------------------------------------------------

// -- project file placement -------------------------------------------------
function ProjectDirectory: string;
function AddProjectUnit(const AFileName: string): Integer;   // NewUnit(False, nil, Name)
function OpenProjectUnit(AIndex: Integer): TObject;          // OpenUnit(Index) -> TEditor

// -- parser / class browser queries ----------------------------------------
function ClassBrowserSelectedClass: TObject;                 // -> PStatement, or nil
procedure ListClassNames(AList: TStrings);                   // CppParser.GetClassesList
function IsClassInCurrentProject(const AClassName: string): Boolean;

// ---------------------------------------------------------------------------
// Code-generation slice (TNewVarFrm / TNewFunctionFrm) -- F1, eighth batch.
//
// The two "new member" wizards share one workflow with NewClassFrm: ask the
// parser where a class is declared, ask it for the .cpp/.h pair, ask it where
// a member should go, then write into the editor. Only the parser calls are
// new; the rest reuses ListClassNames / ClassBrowserSelectedClass /
// FindEditorByFileName from the F1-j slice.
//
// SuggestMemberInsertionLine is the interesting one. Its real signature takes
// a `TStatementClassScope` -- an enum declared in CBUtils -- and a `var
// AddScopeStr` out-parameter. Naively forwarding it would put CBUtils in this
// interface, which is exactly the "enum must not show up at the door" rule
// this unit exists to enforce, and it would drag the whole parser type graph
// along with it. So the scope arrives as a plain Integer and the out-parameter
// becomes a second Boolean result. The call sites were already passing a
// locally computed `VarScope` integer, so nothing is lost and the mapping is
// checked at runtime by the facade rather than by the compiler -- which is a
// real trade-off, accepted knowingly and documented here rather than hidden.
//
// GetSourcePair is a pair of outs; it is collapsed the same way: a Boolean
// "resolved" answer plus the two strings, because the two call sites only
// ever use the result when both were filled.
// ---------------------------------------------------------------------------

procedure ClassSourcePair(const ADefinitionFile: string; out ACppFile,
  AHeaderFile: string);
function SuggestMemberInsertionLine(AStatement: TObject; AScope: Integer;
  out AAddScopeStr: Boolean): Integer;   // -1 = no suggestion (as before)

// ---------------------------------------------------------------------------
// Debugger inspection slice (TCPUForm) -- F1, eighth batch.
//
// CPUFrm is the disassembly/register/backtrace window. Twelve of its fourteen
// references are `MainForm.Debugger.*`, and TDebugger is emphatically NOT
// allowed in this interface -- a typed debugger handle would re-export the
// whole debug engine through the anti-corruption layer. So:
//
//   * Executing and SendCommand need no new entry points at all. Executing is
//     already DebuggerExecuting; SendCommand already exists as
//     SendDebuggerCommand. Nothing new, and that is the point: the slice is
//     mostly reuse.
//   * The three Reader lists are a REGISTRATION protocol, not a query. The
//     window hands the reader its own TList/TStringList so the GDB output
//     parser fills them in, and hands them back as nil on close. Forwarding
//     the assignment verbatim (as TObject/TStrings) is deliberate: this is
//     buffer ownership, and inventing a "give me your registers" API would
//     be a redesign of the debugger's data path, not a decoupling of it.
//   * SendDisassembly assembles `disas` + the cooked command and exists only
//     so the GDB spelling stays in one place; the disassembly-flavor toggles
//     stay in the debugger vocabulary where they belong.
// ---------------------------------------------------------------------------

procedure SetDebugOutputSinks(ARegisters, ADisassembly, ABacktrace: TObject);
procedure ClearDebugOutputSinks;
procedure SendDisassembly(const ACommand: string);
procedure SetDisassemblyFlavor(const AFlavor: string);   // 'att' | 'intel'
// ---------------------------------------------------------------------------
// Residual-dialog slice -- F1, ninth batch (the last of the dialogs).
//
// Nine units, twelve references, four new entry points. Eight of the twelve
// were pure reuse (ProjectName, ProjectDirectory, CurrentProject,
// EditorByIndex), which is the point of having a facade at all.
//
// The four new ones:
//
// ApplyIdeFont -- the environment dialog restyles the main window from the
//   user's settings. Exposing "the main window's font" would be the god form
//   wearing a hat; "apply this font to the IDE" is the whole truth.
//
// CopyProjectViewTo -- the options dialog wants the project tree's image list
//   and every row. TListView comes from ComCtrls, already in this interface,
//   so handing over the target control leaks no new type and keeps the bulk
//   `Items.Assign` intact -- a loop of AddProjectChildNode-style calls would
//   have lost the item Data pointers.
//
// RemoveProjectEditor -- forwards Project.RemoveEditor(index, DoClose). The
//   Boolean result is passed through even though both call sites discard it:
//   a forwarder that quietly drops a result invites the next caller to
//   wonder why it is gone.
//
// MainFormHandle -- Templates.pas reached the god form through the VCL's
//   `Application.MainForm` instead of the unit's own global. Same object, two
//   spellings, and the ratchet counts them inconsistently (see the F1-l
//   notes in the migration plan). Deliberately UNGUARDED: the original
//   `Application.MainForm.Handle` raises when the form is not up yet, and
//   returning 0 would turn that crash into a message box parented to the
//   screen -- a behaviour change smuggled in as a convenience.
// ---------------------------------------------------------------------------

procedure ApplyIdeFont(const AName: string; ASize: Integer);
procedure CopyProjectViewTo(AListView: TListView);
function RemoveProjectEditor(AIndex: Integer; ADoClose: Boolean): Boolean;
function MainFormHandle: HWND;
// ---------------------------------------------------------------------------
// Debug-session command slice (TDebugger / TDebugReader) -- F1, tenth batch.
//
// This is step 1 of F1-m and covers only the COMMAND-shaped couplings: the
// engine telling the UI to do something. The survey split all 21 into
// Command (13) / Notification (6) / Query (3), and the Command half is
// almost entirely wiring rather than design -- nine of the thirteen land on
// entry points that already exist.
//
// Four need a name, and the naming rule is the same as everywhere else: say
// what the user asked for, not which widget was poked.
//
//   StopDebugSession  -- DebugReader asked the debugger to stop. Not exposed
//                        as `Debugger.Stop` because the caller has no business
//                        holding TDebugger; the session lifecycle is the
//                        thing being asked for.
//   ClearBreakpointMarks
//                     -- RemoveActiveBreakpoints clears the *marks* in the UI.
//                        "Breakpoints" alone would promise removing the
//                        breakpoints themselves, which this does not do.
//   OpenCpuWindow     -- ViewCPUItemClick(nil) creates and shows the window.
//                        The facade says "show it"; the `if not Assigned`
//                        guard stays inside main.pas, because whether a second
//                        window is legal is a main-form decision.
//   RestoreLeftPageIndex
//                     -- Debugger.Stop restores the page index it backed up.
//                        Handing over the backup value rather than making the
//                        facade fetch it keeps the ownership where it is:
//                        the debugger remembers what to restore.
//
// The three Query-shaped couplings are deliberately NOT here: reading
// edGdbCommand.Text needs the echo policy designed first, and OnEvalReady
// already has a bridge (SetEvalReadyHandler). Doing those now would smuggle a
// design decision into a wiring commit.
// ---------------------------------------------------------------------------

procedure StopDebugSession;
procedure ClearBreakpointMarks;
procedure OpenCpuWindow;
procedure RestoreLeftPageIndex(AIndex: Integer);
procedure RefreshWatchVars;

// ---------------------------------------------------------------------------
// Debug-session notification slice -- F1, tenth batch, step 2.
//
// Step 1 took the thirteen COMMAND couplings. These three are what is left of
// the NOTIFICATION half: the engine reporting that something happened.
//
// FireEvalReady is the other end of the bridge F1-b started. SetEvalReadyHandler
// is the SUBSCRIBE side (Editor registers OnMouseOverEvalReady, main registers
// OnInputEvalReady); nothing on the RAISE side existed, so the reader fired the
// handler by reaching through MainForm.Debugger -- the engine talking to itself
// via the god form, the same shape step 1 removed for SendCommand.
//
// The Assigned guard moves INSIDE this entry point and must not be dropped.
// The original `if doevalready and Assigned(...OnEvalReady)` skipped the call
// when no handler was registered, which is the common case: the editor
// registers only while a hint is up, and cancels it on CancelHint. Firing
// unconditionally would raise an access violation on every GDB value block
// that arrives with no watcher attached.
//
// AppendDebugOutput takes the raw GDB line. The caller has already normalised
// it (`#26` -> `->`) before calling, and that normalisation stays in the reader
// because it is a protocol detail, not a presentation one. TMemo.Lines comes
// from Classes, already reachable from this interface via TStrings.
// ---------------------------------------------------------------------------

procedure FireEvalReady(const AValue: string);
procedure AppendDebugOutput(const ALine: string);

// ---------------------------------------------------------------------------
// GDB command echo slice (TDebugger) -- F1, tenth batch, step 3.
//
// This is the last of the three Query couplings and the only one the F1-m
// survey predicted would need real design rather than wiring. The short version
// of the finding, because it changes what the design has to be:
//
//   Twelve call sites ask for the command to be echoed into the combo
//   (main.pas x7, ServicesImpl.pas x4, edGdbCommandKeyPress x1) -- and NOT ONE
//   of them ever reads edGdbCommand.Text. The box is a display of the last
//   command, not a channel the engine parses. So this is not "the engine
//   depends on UI state" after all; it is "the engine asks the UI to show a
//   string", which is a Command wearing a Query's clothes.
//
// What still has to be modelled is the overwrite guard. CommandChanged is set
// in exactly one place (main.pas:5203, on user keystrokes) and means "the text
// in the box is the user's own word -- do not clobber it". Without it, a step
// or continue would overwrite half-typed text.
//
// So the flag stays in the debugger (it owns it, and F1 already wired
// SetToggleBookmarksChecked-style accessors around similar state), and the
// DECISION moves to the facade, where the box lives:
//
//   old:  if (not CommandChanged) or (MainForm.edGdbCommand.Text = '') then
//   new:  if (not ShouldEchoGdbCommand) or (not GdbCommandIsUserOwned) then
//
// Same predicate, same operand order, same short-circuit. The engine stops
// reading a widget; the facade stops guessing on its behalf.
//
// EchoGdbCommand performs the write and clears the flag, exactly as the old
// block did, so "echo happened" and "flag cleared" cannot drift apart.
// ---------------------------------------------------------------------------

function GdbCommandIsUserOwned: Boolean;              // edGdbCommand.Text <> ''
procedure SetGdbCommandUserOwned(AValue: Boolean);
procedure EchoGdbCommand(const ACommand, AParams: string);
procedure RestoreLeftPageIndex(AIndex: Integer);
procedure RefreshWatchVars;

// ---------------------------------------------------------------
// Auto-save timer slice (TMainForm.AutoSaveTimer) -- F1, step 2.
//
// The eight `MainForm.AutoSaveTimer` / `MainForm.EditorSaveTimer`
// references EditorOptFrm.pas held in btnOkClick were not eight
// couplings. They were ONE -- "apply the editor auto-save settings to
// the running timer" -- written out statement by statement, which is
// exactly the shape that tempts a migration into eight thin forwarders.
// The one-call rule earned its keep here.
//
// Note what is deliberately NOT a parameter: the timer itself and the
// OnTimer handler. A caller that could hand over its own TTimer or its
// own callback would be re-coupling the very widget the facade exists to
// hide -- and the handler is not the caller's to choose, it is the god
// form's own method, which is the whole reason the timer lives here.
//
// AIntervalMinutes is in MINUTES, matching devEditor.Interval. Both
// copies of this logic (main.pas FormCreate and btnOkClick) did the
// *60*1000 conversion at the call site; doing it here instead means the
// two can no longer disagree about units.
// ---------------------------------------------------------------

procedure ApplyEditorAutoSave(const AEnabled: Boolean;
  AIntervalMinutes: Integer);

// ---------------------------------------------------------------
// Compiler-set selection slice (TdevCompilerSets) -- F1, step 3.
//
// devCFG asked the god form one question -- "which compiler set is
// in effect?" -- and paid for it with two MainForm reads: the compile
// target, then the project's chosen set. Both belong to the same
// decision, so they come back as ONE integer.
//
// The integers are ctNone/ctFile/ctProject as declared in main.pas,
// and that declaration deliberately does NOT cross this interface.
// Exposing TTarget would drag a god-form type into the uses clause
// of every consumer for the privilege of one comparison. The caller
// passes its default index and gets back an override; the enum test
// itself stays beside the enum, the only place it can be maintained
// without touching a consumer.
//
// Returns ADefaultIndex unchanged when there is no form, no project,
// or the compile target is not ctProject -- exactly what the original
// `case` fell through to, so no branch was invented here.
// ---------------------------------------------------------------

function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;

// ---------------------------------------------------------------
// Project unit lookup slice (TProject.fUnits) -- F1, step 4.
//
// ProjectUnitIndexOf is GetUnitFromString, renamed and moved. The body
// is already a pure query -- `fUnits.IndexOf(ExpandFileTo(s, Directory))`
// touches nothing but the project's own fields -- so this adds
// indirection, not logic, and the name now says what the caller means
// ("which unit is this file?") rather than which string form it takes.
//
// It returns -1 when absent, exactly as IndexOf did, so the caller's
// existing -1 test keeps working unchanged.
//
// Note the guard asymmetry with CloseProjectUnitOfEditor: THAT entry
// point forwards IndexOf's result into CloseUnit without re-checking it,
// while here the caller must still test -1 before acting. See the step 4
// notes in tools/_f1q_editorlist_migrate.py -- the caller keeps the
// guard, because TProject.CloseUnit indexes fUnits[index] unguarded.
// ---------------------------------------------------------------

function ProjectUnitIndexOf(const AFileName: string): Integer;

implementation

// Implementation-only dependencies: editor types must not leak into the
// interface (see the interface note about circular unit references), and the
// VCL widget units used by the project/output slices are needed here only.
uses
  {$IFDEF FPC}
  System.Actions, StdCtrls, Editor, EditorList, devFileMonitor,
  {$ELSE}
  System.Actions, Vcl.StdCtrls, Editor, EditorList, devFileMonitor,
  {$ENDIF}
  {$IFDEF FPC}
  Debugger, DebugReader, Project, FileCtrl, ClassBrowser, CppParser,
  {$ELSE}
  Debugger, DebugReader, Project, System.FileCtrl, ClassBrowser, CppParser,
  {$ENDIF}
  CBUtils, CPUFrm, main;

procedure RefreshAppTitle;
begin
  if Assigned(MainForm) then
    MainForm.UpdateAppTitle;
end;

procedure CompileProgressReset(AMax: Integer);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.pbCompilation.Min := 0;
  MainForm.pbCompilation.Max := AMax;
  MainForm.pbCompilation.Position := 0;
end;

procedure CompileProgressStep;
begin
  if Assigned(MainForm) then
    MainForm.pbCompilation.StepIt;
end;

procedure CompileProgressMax(AMax: Integer);
begin
  if Assigned(MainForm) then
    MainForm.pbCompilation.Max := AMax;
end;

procedure CompileProgressRewind;
begin
  if Assigned(MainForm) then
    MainForm.pbCompilation.Position := 0;
end;

function CanRunCompile: Boolean;
begin
  Result := Assigned(MainForm) and MainForm.actCompRun.Enabled;
end;

procedure RunCompileAction;
begin
  if Assigned(MainForm) then
    MainForm.actCompRunExecute(nil);
end;

procedure ShowError(const AMessage: string);
begin
  if not Assigned(MainForm) then
    Exit;
  MessageBox(MainForm.Handle, PChar(AMessage), PChar(Lang[ID_ERROR]),
    MB_OK or MB_ICONERROR);
end;

{ Project slice implementation }

function DialogOwner: TComponent;
begin
  Result := MainForm;
end;

function FindOpenEditor(const AFileName: string): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.FileIsOpen(AFileName);
end;

function CreateEditor(const AFileName: string; AInProject,
  ANewFile: Boolean): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.NewEditor(AFileName, AInProject, ANewFile);
end;

procedure ForceCloseEditor(AEditor: TObject);
begin
  if Assigned(MainForm) then
    MainForm.EditorList.ForceCloseEditor(TEditor(AEditor));
end;

function TryCloseEditor(AEditor: TObject): Boolean;
begin
  Result := False;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.CloseEditor(TEditor(AEditor));
end;

function EditorPageCount: Integer;
begin
  Result := 0;
  if Assigned(MainForm) then
    Result := MainForm.EditorList.PageCount;
end;

function EditorAt(AIndex: Integer): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList[AIndex];
end;

procedure VisibleEditors(out AFocused, AOther: TObject);
var
  L: TEditor;
  R: TEditor;
begin
  AFocused := nil;
  AOther := nil;
  if not Assigned(MainForm) then
    Exit;
  MainForm.EditorList.GetVisibleEditors(L, R);
  AFocused := L;
  AOther := R;
end;

function AddProjectRootNode(const AName: string): TTreeNode;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ProjectView.Items.Add(nil, AName);
end;

function AddProjectChildNode(const AText: string;
  AParent: TTreeNode): TTreeNode;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ProjectView.Items.AddChild(AParent, AText);
end;

procedure ProjectViewBeginUpdate;
begin
  if Assigned(MainForm) then
    MainForm.ProjectView.Items.BeginUpdate;
end;

procedure ProjectViewEndUpdate;
begin
  if Assigned(MainForm) then
    MainForm.ProjectView.Items.EndUpdate;
end;

procedure ExpandProjectView;
begin
  if Assigned(MainForm) then
    MainForm.ProjectView.FullExpand;
end;

function ProjectViewItemCount: Integer;
begin
  Result := 0;
  if Assigned(MainForm) then
    Result := MainForm.ProjectView.Items.Count;
end;

function ProjectViewItem(AIndex: Integer): TTreeNode;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ProjectView.Items[AIndex];
end;

procedure SelectProjectNode(ANode: TTreeNode);
begin
  if Assigned(MainForm) then
    MainForm.ProjectView.Select(ANode);
end;

function CompilerOutputItemCount: Integer;
begin
  Result := 0;
  if Assigned(MainForm) then
    Result := MainForm.CompilerOutput.Items.Count;
end;

function CompilerOutputItemText(AIndex: Integer): string;
begin
  Result := '';
  if not Assigned(MainForm) then
    Exit;
  with MainForm.CompilerOutput.Items[AIndex] do
    Result := Caption + #10 + SubItems.Text;
end;

function LogOutputText: string;
begin
  Result := '';
  if Assigned(MainForm) then
    Result := MainForm.LogOutput.Text;
end;

procedure FileMonitorBeginUpdate;
begin
  if Assigned(MainForm) then
    MainForm.FileMonitor.BeginUpdate;
end;

procedure FileMonitorEndUpdate;
begin
  if Assigned(MainForm) then
    MainForm.FileMonitor.EndUpdate;
end;

{ Editor slice implementation }

function BreakPoints: TList;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.Debugger.BreakPointList;
end;

procedure AddBreakPoint(ALine: Integer; AEditor: TObject);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.AddBreakPoint(ALine, TEditor(AEditor));
end;

procedure RemoveBreakPoint(ALine: Integer; AEditor: TObject);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.RemoveBreakPoint(ALine, TEditor(AEditor));
end;

procedure DeleteBreakPointsOf(AEditor: TObject);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.DeleteBreakPointsOf(TEditor(AEditor));
end;

procedure AddWatchVar(const AName: string);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.AddWatchVar(AName);
end;

procedure SendDebuggerCommand(const ACommand, AParams: string);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.SendCommand(ACommand, AParams);
end;

procedure SetEvalReadyHandler(AHandler: TCodeEvalReady);
begin
  if Assigned(MainForm) then
    MainForm.Debugger.OnEvalReady := TEvalReadyEvent(AHandler);
end;

function DebuggerExecuting: Boolean;
begin
  Result := Assigned(MainForm) and MainForm.Debugger.Executing;
end;

function SharedCppParser: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.CppParser;
end;

function CurrentProject: TObject;
begin
  Result := MainForm.Project;
end;

procedure MonitorFile(const AFileName: string);
begin
  if Assigned(MainForm) then
    MainForm.FileMonitor.Monitor(AFileName);
end;

procedure UnMonitorFile(const AFileName: string);
begin
  if Assigned(MainForm) then
    MainForm.FileMonitor.UnMonitor(AFileName);
end;

procedure SetClassBrowserFile(const AFileName: string);
begin
  if Assigned(MainForm) then
    MainForm.ClassBrowser.CurrentFile := AFileName;
end;

procedure ClassBrowserBeginUpdate;
begin
  if Assigned(MainForm) then
    MainForm.ClassBrowser.BeginUpdate;
end;

procedure ClassBrowserEndUpdate;
begin
  if Assigned(MainForm) then
    MainForm.ClassBrowser.EndUpdate;
end;

function CompilerOutputItems: TListItems;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.CompilerOutput.Items;
end;

function ResourceOutputItems: TListItems;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ResourceOutput.Items;
end;

function FindOutputItems: TListItems;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.FindOutput.Items;
end;

procedure UpdateCompilerList;
begin
  if Assigned(MainForm) then
    MainForm.UpdateCompilerList;
end;

procedure GotoImplDeclInEditor(AEditor: TObject);
begin
  if Assigned(MainForm) then
    MainForm.actGotoImplDeclEditorExecute(AEditor);
end;

procedure OpenFilesFromList(const AFiles: TStrings);
begin
  if Assigned(MainForm) then
    MainForm.OpenFileList(TStringList(AFiles));
end;

procedure SetStatusbarLineCol;
begin
  if Assigned(MainForm) then
    MainForm.SetStatusbarLineCol;
end;

procedure SetStatusbarEditMode(const AText: string);
begin
  if Assigned(MainForm) then
    MainForm.Statusbar.Panels[1].Text := AText;
end;

procedure SetCurrentPageHint(const AText: string);
begin
  if Assigned(MainForm) then
    MainForm.CurrentPageHint := AText;
end;

procedure SetToggleBookmarksChecked(AIndex: Integer; AChecked: Boolean);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.TogglebookmarksPopItem.Items[AIndex - 1].Checked := AChecked;
  MainForm.TogglebookmarksItem.Items[AIndex - 1].Checked := AChecked;
end;

function CodeCompletionBox: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.CodeCompletion;
end;

function EditorPopupMenu: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorPopup;
end;

function FindEditorByFileName(const AFileName: string): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.GetEditorFromFileName(AFileName);
end;

{ Self-test slice implementation }

procedure SetStatusbarMessage(const AText: string);
begin
  if Assigned(MainForm) then
    MainForm.SetStatusbarMessage(AText);
end;

function LeftPageControl: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.LeftPageControl;
end;

function RightPageControl: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.RightPageControl;
end;

function FocusedPageControl: TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.FocusedPageControl;
end;

function EditorByIndex(APageIndex: Integer; APageControl: TObject): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.GetEditor(APageIndex, TPageControl(APageControl));
end;

function PreviousEditor(AEditor: TObject): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.GetPreviousEditor(TEditor(AEditor));
end;

function CreateEditorInPage(AFileName: string; AInProject,
  ANewFile: Boolean; APageControl: TObject): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.NewEditor(AFileName, AInProject, ANewFile,
    TPageControl(APageControl));
end;

function SwapEditor(AEditor: TObject): Boolean;
begin
  Result := False;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.EditorList.SwapEditor(TEditor(AEditor));
end;

procedure SelectNextEditorPage;
begin
  if Assigned(MainForm) then
    MainForm.EditorList.SelectNextPage;
end;

procedure SelectPrevEditorPage;
begin
  if Assigned(MainForm) then
    MainForm.EditorList.SelectPrevPage;
end;

function EditorLayoutIsNone: Boolean;
begin
  Result := Assigned(MainForm) and (MainForm.EditorList.Layout = lstNone);
end;

function EditorLayoutIsLeft: Boolean;
begin
  Result := Assigned(MainForm) and (MainForm.EditorList.Layout = lstLeft);
end;

function EditorLayoutIsRight: Boolean;
begin
  Result := Assigned(MainForm) and (MainForm.EditorList.Layout = lstRight);
end;

function EditorLayoutIsBoth: Boolean;
begin
  Result := Assigned(MainForm) and (MainForm.EditorList.Layout = lstBoth);
end;

function ActionCount: Integer;
begin
  Result := 0;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ActionList.ActionCount;
end;

function ActionAt(AIndex: Integer): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ActionList.Actions[AIndex];
end;

procedure ClickToggleBookmark(AIndex: Integer);
begin
  if Assigned(MainForm) then
    MainForm.ToggleBookmarksItem.Items[AIndex - 1].Click;
end;

function ToggleBookmarkChecked(AIndex: Integer): Boolean;
begin
  Result := False;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.ToggleBookmarksItem.Items[AIndex - 1].Checked;
end;

procedure ClickGotoBookmark(AIndex: Integer);
begin
  if Assigned(MainForm) then
    MainForm.GotoBookmarksItem.Items[AIndex - 1].Click;
end;

procedure ExecuteNewSource;
begin
  if Assigned(MainForm) then
    MainForm.actNewSource.Execute;
end;

function MainWindowClassName: string;
begin
  // ClassRef is valid without an instance, so this is safe even
  // before the main form exists.
  Result := TMainForm.ClassName;
end;

{ Find & replace results slice implementation }

procedure BeginFindOutputUpdate;
begin
  if Assigned(MainForm) then
    MainForm.FindOutput.Items.BeginUpdate;
end;

procedure EndFindOutputUpdate;
begin
  if Assigned(MainForm) then
    MainForm.FindOutput.Items.EndUpdate;
end;

procedure ClearFindOutput;
begin
  if Assigned(MainForm) then
    MainForm.FindOutput.Clear;
end;

procedure AddFindOutputItem(const ALine, ACol, AFileName, AMsg,
  AKeyword: string);
begin
  if Assigned(MainForm) then
    MainForm.AddFindOutputItem(ALine, ACol, AFileName, AMsg, AKeyword);
end;

procedure ShowFindResults(AMatchCount: Integer);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.MessageControl.ActivePageIndex := 4; // Find Tab
  if AMatchCount > 0 then
    MainForm.FindSheet.Caption := Lang[ID_SHEET_FIND] + ' (' +
      IntToStr(AMatchCount) + ')';
  MainForm.OpenCloseMessageSheet(True);
end;

{ Project unit list slice implementation }

function ProjectUnitCount: Integer;
begin
  Result := 0;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Units.Count;
end;

function ProjectUnitFileName(AIndex: Integer): string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Units[AIndex].FileName;
end;

function ProjectUnitEditor(AIndex: Integer): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Units[AIndex].Editor;
end;

procedure CloseProjectUnitOfEditor(AEditor: TObject);
begin
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  MainForm.Project.CloseUnit(MainForm.Project.Units.IndexOf(TEditor(AEditor)));
end;

{ Profiling target slice implementation }

function ProjectExecutable: string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Executable;
end;

function ActiveEditorFileName: string;
begin
  Result := '';
  if not Assigned(MainForm) then
    Exit;
  // No nil guard on GetEditor -- see the interface note: the original call
  // sites dereferenced a possibly-nil TEditor through .FileName.
  Result := MainForm.EditorList.GetEditor.FileName;
end;

function ActiveEditorFileName: string;
begin
  Result := '';
  if not Assigned(MainForm) then
    Exit;
  // No nil guard on GetEditor -- see the interface note: the original call
  // sites dereferenced a possibly-nil TEditor through .FileName.
  Result := MainForm.EditorList.GetEditor.FileName;
end;

{ Project identity slice implementation }

function IsProjectFile(const AFileName: string): Boolean;
begin
  Result := False;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Units.IndexOf(AFileName) <> -1;
end;

function ProjectRelativePath(const AFileName: string): string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := ExtractRelativePath(MainForm.Project.Directory, AFileName);
end;


function ProjectUnitList(const ASeparator: string): string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.ListUnitStr(ASeparator);
end;

function ProjectName: string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Name;
end;

function ProjectFileName: string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.FileName;
end;

{ Navigation slice implementation }

function NavigateToFileAndLine(const AFileName: string; ALine: Integer): Boolean;
var
  e: TEditor;
begin
  Result := False;
  if not Assigned(MainForm) then
    Exit;
  e := MainForm.EditorList.GetEditorFromFileName(AFileName);
  if not Assigned(e) then
    Exit;
  e.SetCaretPosAndActivate(ALine, 1);
  Result := True;
end;

{ Class-creation wizard slice implementation }

function ProjectDirectory: string;
begin
  Result := '';
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.Directory;
end;

function AddProjectUnit(const AFileName: string): Integer;
begin
  Result := -1;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.NewUnit(False, nil, AFileName);
end;

function OpenProjectUnit(AIndex: Integer): TObject;
begin
  Result := nil;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.OpenUnit(AIndex);
end;

function ClassBrowserSelectedClass: TObject;
var
  Node: TTreeNode;
begin
  Result := nil;
  if not Assigned(MainForm) then
    Exit;
  // Same shape as main.pas's own ClassBrowser.Selected access, moved into a
  // unit that sits in the same unit graph -- no new visibility requirement.
  Node := MainForm.ClassBrowser.Selected;
  if not Assigned(Node) or not Assigned(Node.Data) then
    Exit;
  if PStatement(Node.Data)^._Kind <> skClass then
    Exit;
  Result := PStatement(Node.Data);
end;

procedure ListClassNames(AList: TStrings);
begin
  if not Assigned(MainForm) then
    Exit;
  TCppParser(MainForm.CppParser).GetClassesList(AList);
end;

function IsClassInCurrentProject(const AClassName: string): Boolean;
var
  Node: PStatementNode;
  Statement: PStatement;
begin
  Result := False;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Node := TCppParser(MainForm.CppParser).Statements.FirstNode;
  while Assigned(Node) do begin
    Statement := Node^.Data;
    if (Statement^._Kind = skClass) and (Statement^._Command = AClassName) and
      (MainForm.Project.Units.IndexOf(Statement^._DefinitionFileName) <> -1) then
    begin
      Result := True;
      Exit;
    end;
    Node := Node^.NextNode;
  end;
end;

{ Code-generation slice implementation }

procedure ClassSourcePair(const ADefinitionFile: string; out ACppFile,
  AHeaderFile: string);
begin
  ACppFile := '';
  AHeaderFile := '';
  if not Assigned(MainForm) then
    Exit;
  TCppParser(MainForm.CppParser).GetSourcePair(ADefinitionFile, ACppFile,
    AHeaderFile);
end;

function SuggestMemberInsertionLine(AStatement: TObject; AScope: Integer;
  out AAddScopeStr: Boolean): Integer;
var
  AddScopeStr: boolean;
begin
  AAddScopeStr := False;
  Result := -1;
  if not Assigned(MainForm) then
    Exit;
  // The scope crosses the facade as an integer on purpose (see the interface
  // note): TStatementClassScope lives in CBUtils and must not be named here.
  AddScopeStr := False;
  Result := TCppParser(MainForm.CppParser).SuggestMemberInsertionLine(
    PStatement(AStatement), TStatementClassScope(AScope), AddScopeStr);
  AAddScopeStr := AddScopeStr;
end;

{ Debugger inspection slice implementation }

procedure SetDebugOutputSinks(ARegisters, ADisassembly, ABacktrace: TObject);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.Debugger.Reader.Registers := TList(ARegisters);
  MainForm.Debugger.Reader.Disassembly := TStringList(ADisassembly);
  MainForm.Debugger.Reader.Backtrace := TList(ABacktrace);
end;

procedure ClearDebugOutputSinks;
begin
  SetDebugOutputSinks(nil, nil, nil);
end;

procedure SendDisassembly(const ACommand: string);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.Debugger.SendCommand('disas', ACommand);
end;

procedure SetDisassemblyFlavor(const AFlavor: string);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.Debugger.SendCommand('set disassembly-flavor', AFlavor);
end;

{ Residual-dialog slice implementation }

procedure ApplyIdeFont(const AName: string; ASize: Integer);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.Font.Name := AName;
  MainForm.Font.Size := ASize;
end;

procedure CopyProjectViewTo(AListView: TListView);
begin
  if not Assigned(MainForm) or not Assigned(AListView) then
    Exit;
  AListView.Images := MainForm.ProjectView.Images;
  AListView.Items.Assign(MainForm.ProjectView.Items);
end;

function RemoveProjectEditor(AIndex: Integer; ADoClose: Boolean): Boolean;
begin
  Result := False;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.RemoveEditor(AIndex, ADoClose);
end;

function MainFormHandle: HWND;
begin
  // No Assigned guard on purpose -- see the interface note. The original
  // `Application.MainForm.Handle` raised in the same situation.
  Result := MainForm.Handle;
end;

{ Debug-session command slice implementation }

procedure StopDebugSession;
begin
  if Assigned(MainForm) then
    MainForm.Debugger.Stop;
end;

procedure ClearBreakpointMarks;
begin
  if Assigned(MainForm) then
    MainForm.RemoveActiveBreakpoints;
end;

procedure OpenCpuWindow;
begin
  if Assigned(MainForm) then
    MainForm.ViewCPUItemClick(nil);
end;

procedure RestoreLeftPageIndex(AIndex: Integer);
begin
  if Assigned(MainForm) then
    MainForm.LeftPageControl.ActivePageIndex := AIndex;
end;

procedure RefreshWatchVars;
begin
  if Assigned(MainForm) then
    MainForm.Debugger.RefreshWatchVars;
end;


procedure FireEvalReady(const AValue: string);
begin
  if not Assigned(MainForm) then
    Exit;
  // The guard the caller used to own. See the interface note: the editor
  // cancels its handler on CancelHint, so "no handler" is the normal state.
  if Assigned(MainForm.Debugger.OnEvalReady) then
    MainForm.Debugger.OnEvalReady(AValue);
end;

procedure AppendDebugOutput(const ALine: string);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.DebugOutput.Lines.Add(ALine);
end;


function GdbCommandIsUserOwned: Boolean;
begin
  Result := False;
  if not Assigned(MainForm) then
    Exit;
  Result := MainForm.edGdbCommand.Text <> '';
end;

procedure SetGdbCommandUserOwned(AValue: Boolean);
begin
  if not Assigned(MainForm) then
    Exit;
  MainForm.fDebugger.CommandChanged := AValue;
end;

procedure EchoGdbCommand(const ACommand, AParams: string);
begin
  if not Assigned(MainForm) then
    Exit;
  // Convert command to C string -- the original comment, kept because the
  // joining rule is not obvious: params is appended with a single space and
  // the caller has already trimmed the pair.
  if Length(AParams) > 0 then
    MainForm.edGdbCommand.Text := ACommand + ' ' + AParams
  else
    MainForm.edGdbCommand.Text := ACommand;

  // The echo consumed the right to overwrite: the box now holds an engine
  // command, not the user's word.
  MainForm.fDebugger.CommandChanged := False;
end;

procedure ApplyEditorAutoSave(const AEnabled: Boolean;
  AIntervalMinutes: Integer);
begin
  if not Assigned(MainForm) then
    Exit;
  // Behaviour carried over unchanged from btnOkClick, including the
  // `.Free` + `:= nil` pair rather than FreeAndNil: same order, same
  // visible result, so this migration cannot be blamed for a difference
  // nobody asked for.
  if AEnabled then begin
    if not Assigned(MainForm.AutoSaveTimer) then
      MainForm.AutoSaveTimer := TTimer.Create(nil);
    MainForm.AutoSaveTimer.Interval := AIntervalMinutes * 60 * 1000;
    // miliseconds to minutes
    MainForm.AutoSaveTimer.Enabled := AEnabled;
    MainForm.AutoSaveTimer.OnTimer := MainForm.EditorSaveTimer;
  end else begin
    MainForm.AutoSaveTimer.Free;
    MainForm.AutoSaveTimer := nil;
  end;
end;

function ProjectCompilerSetIndex(ADefaultIndex: Integer): Integer;
begin
  Result := ADefaultIndex;
  if not Assigned(MainForm) then
    Exit;
  if not Assigned(MainForm.Project) then
    Exit;
  // ctProject is the only branch that ever overrode the default; ctNone
  // and ctFile both assigned fDefaultIndex on the caller's side.
  if MainForm.GetCompileTarget = ctProject then
    Result := MainForm.Project.Options.CompilerSet;
end;

function ProjectUnitIndexOf(const AFileName: string): Integer;
begin
  Result := -1;
  if not Assigned(MainForm) or not Assigned(MainForm.Project) then
    Exit;
  Result := MainForm.Project.GetUnitFromString(AFileName);
end;

end.