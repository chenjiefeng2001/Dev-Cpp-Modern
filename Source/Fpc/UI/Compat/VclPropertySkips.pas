// ---------------------------------------------------------------------------
// The VCL properties the LCL reader refuses, declared skippable
// =======================================================================
// `PropRttiProbe` puts every property of the 13 CLEARED converted forms to
// the real LCL reader and reports 17 that it refuses. This unit is the
// other half of that measurement: it registers exactly those 17 as
// properties-to-skip, so the loader accepts the converted files unchanged.
//
// WHY NOT DELETE THEM IN THE CONVERTER
// ===================================
// The obvious move is to add them to f3_dfm_to_lfm.py's DROP_PROPS. It is
// the wrong move, and the reason is already written in that file:
//
//   "Silently discarding a real property is worse than leaving an unknown
//    one in, because the LCL loader reports what it dislikes and a dropped
//    one reports because the LCL loader complains about what it does not
//    recognise, whereas a property we removed early is invisible: it simply
//    never gets checked."
//
// DROP_PROPS exists for properties that are Delphi's bookkeeping
// (PixelsPerInch, Explicit*, OldCreateOrder, Ctl3D) -- values with no
// meaning outside the Delphi designer. These 17 are different: each is a
// real VCL property of a real control, and dropping them would delete the
// author's intent from the converted artefact while the .dfm still says it.
// The LCL has a mechanism for exactly this situation, and it is used by the
// LCL itself.
//
// THE MECHANISM, FROM THE LCL'S OWN SOURCE
// =========================================
//   * `RegisterPropertyToSkip(Class, PropName, Note, HelpKeyword)`
//     (lresources.pp:607) adds an entry to the global `PropertiesToSkip`
//     list, keyed by CLASS and lower-cased property name
//     (lresources.pp:700-715).
//   * `CreateLRSReader` installs the query hook
//     (lresources.pp:3196: `Result.OnPropertyNotFound :=
//     @(PropertiesToSkip.DoPropertyNotFound)`), so every LFM the LCL reads
//     asks the list before giving up.
//   * `TPropertiesToSkip.IndexOf` (lresources.pp:680-698) matches by
//     `AClass.InheritsFrom(Entry.Class)`, so an entry on a BASE class covers
//     its descendants and an entry on TBitBtn does not touch TSpeedButton.
//     That class scoping is why this is better than a name-only drop list.
//   * When the reader takes the skip it calls `FDriver.SkipValue` and
//     abandons the whole remaining path (reader.inc:1270-1274), so a dotted
//     `Gutter.Font.Name` needs ONE entry -- on `TSynGutter`, `Font` -- not
//     five entries for the five leaves.
//   * Lazarus uses it for the same VCL leftovers: synedit.pp:10752
//     registers `TSynGutter.ShowCodeFolding` and two siblings as
//     properties-to-skip, and customlistview.inc:794-796 registers
//     `TListItem.OverlayIndex`.
//
// WHY EACH ENTRY IS SAFE, PER PROPERTY
// =====================================
// The claim that dropping a value loses nothing has to be measured per
// property, not assumed. The evidence is in the table below and it is
// checked by a gate, not left to this comment.
//
// The one thing that is NOT claimed: that the LCL control behaves the way
// the VCL one did. Where the property carried visible behaviour, the
// substitute is named. `Gutter.Font` is the clearest case -- LCL's TSynGutter
// has no Font at all, so the gutter text takes TSynEdit's font; that is a
// visual difference, recorded in doc F3-SVG section 17, not a silent one.
// ---------------------------------------------------------------------------

{$mode objfpc}{$H+}

unit VclPropertySkips;

interface

uses
  Classes, SysUtils, LResources, Controls, Graphics, ImgList, StdCtrls,
  Buttons, ExtCtrls, ComCtrls, Spin, ValEdit, CheckLst, Forms, Dialogs,
  ExtDlgs, SynEdit, SynGutter, SynHighlighterCpp;

// Every entry this project registers, as DATA, so an external gate can audit
// it. Not a convenience: `PropertiesToSkip` is a flat list that the LCL also
// writes to, and the LCL's own entries cannot be audited by the same rule --
// `RegisterPropertyToSkip(TForm, 'Scaled', ...)` is in there, and TForm DOES
// have Scaled (measured: `PropertyRttiProbe` flagged it). Those entries exist
// for the object inspector, not to suppress an assignment, so "the list is
// audited" has to mean "OUR list is audited" and the two have to be
// distinguishable. A table here is what makes them distinguishable.
type
  TVclSkipEntry = record
    Class_: TPersistentClass;
    PropertyName: string;
    Note: string;
  end;

function VclSkipEntryCount: Integer;
// The class HANDLE, not its name. An earlier version of the audit looked the
// class up with FindClass and died with `Class "TListItems" not found` --
// LCL units do not register their own classes (stdctrls.pp:1698, measured),
// so a class that is only ever used as a property TYPE, which is exactly
// what TListItems is, is not in the registry at all. Handing out the class
// removes a failure mode that has nothing to do with what is being audited.
function VclSkipEntryClass(Index: Integer): TPersistentClass;
function VclSkipEntryClassName(Index: Integer): string;
function VclSkipEntryProperty(Index: Integer): string;
function VclSkipEntryNote(Index: Integer): string;

implementation

// Where they come from: `PropRttiProbe` scanned the 14 converted files
// (13 CLEARED forms + CompOptionsFrame.lfm), resolved each property path
// against the class RTTI, and then STREAMED a synthetic one-object LFM per
// unresolved candidate through the same reader. The site counts and the
// reader's own messages are what this list is built from -- not from
// reading LCL documentation, which is how `DoubleBuffered` would have been
// got wrong (LCL declares it, in `public`).
//
// `F3-SVG section 17` keeps the full table; the notes here carry the
// one-line reason each entry is safe.

// The table is declared before `Register` so `procedure Register` below can
// iterate it rather than restate it -- one list, two consumers (the LCL's
// registry and the audit), which is the whole point of making it data.
//
// THE EVIDENCE FOR EACH ENTRY (measured 2026-10-06, doc F3-SVG section 17)
// =======================================================================
// `ImageName` -- 50 sites in the 13 forms (TBitBtn 12, TSpeedButton 38).
//   The VCL selects an image by name. Nothing in Dev-C++ reads it: `rg
//   '\.ImageName'` over Source/**.pas outside this repository's own new
//   control returns nothing, and every one of those 50 sites also carries
//   the `ImageIndex` that TLclSvgImageList resolves. The name is a second
//   key to the same item, so what is skipped is a duplicate.
//
// `DoubleBuffered` -- 1 site.
//   LCL declares it on TControl, but in the `public` section (controls.pp
//   :2322 opens public, :2337 declares it) and an LFM can only assign
//   published properties. This is the property that makes an RTTI-only
//   audit right for the wrong reason -- the class HAS it; the reader still
//   refuses it.
//
// `WordWrap` -- 1 site. LCL publishes it on TButton (stdctrls.pp:945) but
//   TBitBtn does not descend from TButton.
//
// `StyleElements` -- 2 sites. A vcl-styles-utils concept: the vendored
//   VCL.Styles.Utils.SysStyleHook reads it to decide whether to draw a
//   client edge (line 785: `OverridePaint := seClient in FStyleElements`).
//   LCL has no styles service, and `rg StyleElements` outside Source/VCL
//   returns nothing.
//
// `BevelInner` / `BevelOuter` -- 2 sites (IconFrm's TListView), both bvNone.
//   Registered PER CLASS and not by name, and that distinction is load
//   bearing: TPanel and TImage DO publish both in LCL (extctrls.pp:1161),
//   and tree-wide there are 97 occurrences of which all but 2 are on those
//   two. A name-based drop list -- which is what f3_dfm_to_lfm.py's
//   DROP_PROPS is -- would have deleted 95 working properties.
//
// `Items.ItemData` -- 1 site. The VCL TListViewItems blob; LCL streams the
//   same list under a different name (`DefineBinaryProperty('Data', ...)`,
//   listitems.inc:547). Nothing reads the design-time items: IconFrm's
//   FormCreate does `Items.BeginUpdate; Items.Clear;` (IconFrm.pas:92-93)
//   and repopulates from the icons directory.
//
// `OnInfoTip` -- 1 site. A REAL event with a REAL handler:
//   `TIconForm.IconViewInfoTip` (IconFrm.pas:140) returns the item's full
//   path, so this is a FUNCTIONAL LOSS -- the icon browser loses its
//   tooltip -- and not a cosmetic one. LCL's TCustomListView has no
//   info-tip event (its closest relative, OnDataHint, is owner-data only).
//   Recorded rather than waved through.
//
// `UseCodeFolding` / `CodeFolding` -- 4 sites each. LCL drives folding from
//   the highlighter's hcCodeFolding capability plus a TSynGutterCodeFolding
//   gutter part; the VCL names are absent from LCL TSynEdit entirely, which
//   synedit.pp:10752 says out loud by registering
//   `TSynGutter.ShowCodeFolding` as a property to skip. Not a silent loss:
//   devCFG.pas:2551-2559 sets both from CODE on every editor it themes, and
//   that code belongs to the SynEdit port, not to this conversion.
//
// `TSynGutter.Font` -- 20 sites (5 property names x 4 forms). LCL's
//   TSynGutter has no Font, so the gutter text takes TSynEdit's font: a
//   VISUAL DIFFERENCE, recorded, and the code that drives it
//   (`Gutter.Font.Assign`, EditorOptFrm.pas:249-251) is on a form the route
//   tool still lists as blocked.
//
//   ONE entry, not five: the reader walks a dotted path segment by segment
//   and abandons the whole path at the first missing segment
//   (reader.inc:1297-1302, then :1270-1274), and at the moment of that
//   lookup the instance IS the gutter. `Gutter.Font` is therefore both the
//   sufficient spelling and the only one that can work.
//
// SPRINT F3-6 -- the six below come from EditorOptFrm, the first CLEARED form
// to carry a SynEdit highlighter and a TSynStringGrid.
// =======================================================================
// `TSynCppSyn.Options` -- 3 sites, and ONE entry for all of them.
//   `Options` is a third-party patch, not a SynEdit feature: the vendored
//   declaration is annotated `// <-- Codehunter patch` and declares
//   TSynEditHighlighterOptions, a type that appears nowhere else in the
//   vendored tree and nowhere at all in LCL. LCL's TSynCustomHighlighter
//   has no Options property (measured: `Options prop: NONE`).
//   All three values are OFF or zero -- AutoDetectEnabled = False,
//   AutoDetectLineLimit = 0, Visible = False -- so nothing is switched ON
//   that LCL then fails to honour. The loss is the CAPABILITY to
//   auto-detect a language from file content, which the VCL could express
//   and LCL cannot; it was not in use here.
//
// `TSynEdit.AddedKeystrokes` / `RemovedKeystrokes` -- 4 collection blocks
//   across 3 TSynEdits, plus one empty `<>`.
//   THE VCL's key-command binding tables, and a real FUNCTIONAL LOSS: they
//   remap keys to editor commands, and here they remap F1 to context help
//   (5 sites) and add Ctrl+F1 (16496) to it, on `CodeIns` and `seDefault`;
//   `cppEdit` additionally clears the Backspace and Enter bindings.
//   Neither property exists in ANY Lazarus SynEdit unit (measured across
//   components/synedit/*.p* for `property AddedKeystrokes` /
//   `property RemovedKeystrokes`: zero hits), so there is nothing to
//   redirect to -- not a differently-named property, not a different unit.
//
//   The loss is BOUNDED and the bound was measured rather than assumed:
//   `AddedKeystrokes` / `RemovedKeystrokes` occur in exactly two DFM files
//   (EditorOptFrm, CPUFrm) and in ZERO lines of Pascal. So no code reads or
//   writes them, and under LCL these key overrides are dropped from the
//   design-time default. The bindings recorded here are the VCL stock
//   defaults (Backspace, Enter, F1) plus the F1 remap, so the F1 -> context
//   help mapping is what a user would notice losing.
//
//   ONE entry per property, not one per inner `Command` / `ShortCut`: the
//   reader takes the skip on the collection property, calls SkipValue and
//   abandons the path, so the item rows never become properties. That was
//   verified by building it this way first and re-running the form probe --
//   adding `Command` and `ShortCut` as well would have been an over-broad
//   registry entry, which is the failure mode the audit in PropRttiProbe
//   exists to catch.
//
// `TSynGutter.BorderStyle` -- 3 sites, every one `gbsNone`.
//   LCL's TSynGutter has no BorderStyle at all (measured: the only
//   BorderStyle-bearing gutter property in the LCL is none of them), and
//   `gbsNone` is "draw no border" -- which is what LCL's gutter does. The
//   value asked for and LCL's behaviour agree, so nothing is lost; the
//   property is skipped because the NAME does not exist, not because the
//   intent differs.
//
// `TSynGutter.GradientEndColor` -- 1 site, `clBackground`.
//   A VISUAL DIFFERENCE, recorded rather than waved through: LCL's
//   TSynGutter paints a flat background and has no gradient, so the
//   gradient the VCL blended to the background colour is not reproduced.
//
// `TSynEdit.ScrollHintFormat` -- 1 site, `shfTopToBottom`.
//   VCL-only (measured absent from components/synedit/*.p*). Scrollbar
//   hint text direction; LCL's TSynEdit exposes no equivalent. Recorded.
const
  ENTRIES: array[0..18] of TVclSkipEntry = (
    (Class_: TBitBtn; PropertyName: 'ImageName';
     Note: 'VCL image selection by name; the co-located ImageIndex binds the item'),
    (Class_: TSpeedButton; PropertyName: 'ImageName';
     Note: 'VCL image selection by name; the co-located ImageIndex binds the item'),
    (Class_: TBitBtn; PropertyName: 'DoubleBuffered';
     Note: 'LCL declares it public, not published, so an LFM cannot assign it'),
    (Class_: TBitBtn; PropertyName: 'WordWrap';
     Note: 'LCL publishes WordWrap on TButton (stdctrls.pp:945), not on TBitBtn'),
    (Class_: TBitBtn; PropertyName: 'StyleElements';
     Note: 'vcl-styles-utils concept; LCL has no styles service'),
    (Class_: TListBox; PropertyName: 'StyleElements';
     Note: 'vcl-styles-utils concept; LCL has no styles service'),
    (Class_: TListView; PropertyName: 'BevelInner';
     Note: 'VCL TListView draws a bevel; LCL TListView has none'),
    (Class_: TListView; PropertyName: 'BevelOuter';
     Note: 'VCL TListView draws a bevel; LCL TListView has none'),
    (Class_: TListItems; PropertyName: 'ItemData';
     Note: 'LCL streams the same list as Items.Data (listitems.inc:547)'),
    (Class_: TListView; PropertyName: 'OnInfoTip';
     Note: 'LCL TListView has no info-tip event; IconFrm.IconViewInfoTip needs porting'),
    (Class_: TSynEdit; PropertyName: 'UseCodeFolding';
     Note: 'LCL folds via highlighter capabilities; the VCL name is absent'),
    (Class_: TSynEdit; PropertyName: 'CodeFolding';
     Note: 'LCL folds via highlighter capabilities; the VCL name is absent'),
    (Class_: TSynGutter; PropertyName: 'Font';
     Note: 'LCL TSynGutter has no Font; gutter text uses TSynEdit.Font'),
    (Class_: TSynCppSyn; PropertyName: 'Options';
     Note: 'Codehunter-patch TSynEditHighlighterOptions; LCL highlighter has no Options'),
    (Class_: TSynEdit; PropertyName: 'AddedKeystrokes';
     Note: 'VCL key-command table; absent from every Lazarus SynEdit unit'),
    (Class_: TSynEdit; PropertyName: 'RemovedKeystrokes';
     Note: 'VCL key-command table; absent from every Lazarus SynEdit unit'),
    (Class_: TSynGutter; PropertyName: 'BorderStyle';
     Note: 'LCL TSynGutter has no BorderStyle; all 3 sites are gbsNone, so behaviour matches'),
    (Class_: TSynGutter; PropertyName: 'GradientEndColor';
     Note: 'LCL TSynGutter paints flat; the VCL gutter blended to this colour'),
    (Class_: TSynEdit; PropertyName: 'ScrollHintFormat';
     Note: 'VCL-only scrollbar hint direction; no LCL counterpart')
  );

function VclSkipEntryCount: Integer;
begin
  Result := Length(ENTRIES);
end;

function VclSkipEntryClass(Index: Integer): TPersistentClass;
begin
  Result := ENTRIES[Index].Class_;
end;

function VclSkipEntryClassName(Index: Integer): string;
begin
  Result := ENTRIES[Index].Class_.ClassName;
end;

function VclSkipEntryProperty(Index: Integer): string;
begin
  Result := ENTRIES[Index].PropertyName;
end;

function VclSkipEntryNote(Index: Integer): string;
begin
  Result := ENTRIES[Index].Note;
end;

procedure Register;
var
  I: Integer;
begin
  for I := Low(ENTRIES) to High(ENTRIES) do
    RegisterPropertyToSkip(ENTRIES[I].Class_, ENTRIES[I].PropertyName,
                           ENTRIES[I].Note, '');
end;

initialization
  // Registering in the unit's initialization is what makes the list live for
  // a reader that never names this unit: the loader looks the list up
  // globally (lresources.pp:3196), so the application only has to USE the
  // unit -- the LFM reader does not.
  Register;

end.