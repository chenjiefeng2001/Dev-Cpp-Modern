{-------------------------------------------------------------------------------
The contents of this file are subject to the Mozilla Public License
Version 1.1 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at
http://www.mozilla.org/MPL/

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
the specific language governing rights and limitations under the License.

The Original Code is: SynEditTypes.pas, released 2000-04-07.
The Original Code is based on parts of mwCustomEdit.pas by Martin Waldenburg,
part of the mwEdit component suite.
Portions created by Martin Waldenburg are Copyright (C) 1998 Martin Waldenburg.
Unicode translation by Ma�l H�rz.
All Rights Reserved.

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

You may retrieve the latest version of this file at the SynEdit home page,
located at http://SynEdit.SourceForge.net

Known Issues:
-------------------------------------------------------------------------------}

unit SynEditTypes;{$H+}

{$I SynEdit.inc}

interface

uses
  Types,
  Math,
  {$IFNDEF FPC}{$IFNDEF FPC}{$IF CompilerVersion <= 32}
  Controls,
  {$IFEND}{$ENDIF}{$ENDIF}
  SysUtils;

const
// These might need to be localized depending on the characterset because they might be
// interpreted as valid ident characters.
  SynTabGlyph = WideChar($2192);       //'->'
  SynSoftBreakGlyph = WideChar($00AC); //'�'
  SynLineBreakGlyph = WideChar($00B6); //'�'
  SynSpaceGlyph = WideChar($2219);     //'�'

type
  ESynError = class(Exception);

  // DOS: CRLF, UNIX: LF, Mac: CR, Unicode: LINE SEPARATOR
  TSynEditFileFormat = (sffDos, sffUnix, sffMac, sffUnicode);

  TSynSearchOption = (ssoMatchCase, ssoWholeWord, ssoBackwards,
    ssoEntireScope, ssoSelectedOnly, ssoReplace, ssoReplaceAll, ssoPrompt);
  TSynSearchOptions = set of TSynSearchOption;

  TCategoryMethod = function(AChar: WideChar): Boolean of object;

  TSynEditorCommand = type word;

  THookedCommandEvent = procedure(Sender: TObject; AfterProcessing: Boolean;
    var Handled: Boolean; var Command: TSynEditorCommand; var AChar: WideChar;
    Data: pointer; HandlerData: pointer) of object;

  TSynInfoLossEvent = procedure (var Encoding: TEncoding; Cancel: Boolean) of object;

  PSynSelectionMode = ^TSynSelectionMode;
  TSynSelectionMode = (smNormal, smLine, smColumn);

  TBufferCoord = record
    Char: integer;
    Line: integer;
    class operator Equal(a, b: TBufferCoord): Boolean;
    class operator NotEqual(a, b: TBufferCoord): Boolean;
    class operator LessThan(a, b: TBufferCoord): Boolean;
    class operator LessThanOrEqual(a, b: TBufferCoord): Boolean;
    class operator GreaterThan(a, b: TBufferCoord): Boolean;
    class operator GreaterThanOrEqual(a, b: TBufferCoord): Boolean;
    class function Min(a, b: TBufferCoord): TBufferCoord; static;
    class function Max(a, b: TBufferCoord): TBufferCoord; static;
  end;

  TDisplayCoord = record
    Column: integer;
    Row: integer;
    class operator Equal(a, b: TDisplayCoord): Boolean;
    class operator NotEqual(a, b: TDisplayCoord): Boolean;
    class operator LessThan(a, b: TDisplayCoord): Boolean;
    class operator LessThanOrEqual(a, b: TDisplayCoord): Boolean;
    class operator GreaterThan(a, b: TDisplayCoord): Boolean;
    class operator GreaterThanOrEqual(a, b: TDisplayCoord): Boolean;
    class function Min(a, b: TDisplayCoord): TDisplayCoord; static;
    class function Max(a, b: TDisplayCoord): TDisplayCoord; static;
  end;

  (*  Helper methods for TControl - for backwward compatibility *)
  {$IFNDEF FPC}{$IF CompilerVersion <= 32}
  TControlHelper = class helper for TControl
  public
    function CurrentPPI: Integer;
    function FCurrentPPI: Integer;
  end;
  {$IFEND}{$ENDIF}


function DisplayCoord(AColumn, ARow: Integer): TDisplayCoord;
function BufferCoord(AChar, ALine: Integer): TBufferCoord;
function LineBreakFromFileFormat(FileFormat: TSynEditFileFormat): string;


// ---------------------------------------------------------------------------
// NEW-architecture types, carried verbatim from the LCL's synedittypes.pp.
//
// WHY ONE PORT CARRIES TWO ERAS
// =============================
// This vendored SynEditTypes is 1999-era (TBufferCoord / TDisplayCoord, the
// editor on TStrings). The LCL 4.4 synedittypes.pp declares BOTH those --
// synedit.pp still uses them -- and the typed indices below, and the LCL's own
// units (synedittextbase.pas, syneditwordwrap.pas, lazsynimm.pas) need the new
// ones. This unit OWNS the name SynEditTypes in the FPC tree, so it owes both
// surfaces. That is a debt and it is recorded here, not hidden; the
// alternative was porting vendored SynEdit.pas (10,937 lines) so the LCL
// synedit leaves the picture entirely, which was measured and rejected for
// this step.
//
// Inserted into the INTERFACE section -- the first attempt appended it after
// `end.`, where it was dead text and compiled to nothing.
// ---------------------------------------------------------------------------

type
  TSynIdentChars = set of AnsiChar; // the LCL spells it set of char under objfpc; under -Mdelphiunicode Char is WideChar and a set of it is rejected, so the element type that carries the same bytes is named explicitly

  TLineIdx = type integer; // 0..high(Integer);
  IntPos = type integer; // 1..high(Integer);
  IntIdx = type integer; // 0..high(Integer);

  TLinePos = type integer; // 1..high(Integer);
  TPhysPoint = Types.TPoint;
  TLogCaretPoint = record
    X, Y, Offs: Integer;
  end;
  THookedCommandFlag = (
    hcfInit,     // run before On[User]CommandProcess (outside UndoBlock / should not do execution)
    hcfPreExec,  // Run before CommandProcessor (unless handled by On[User]CommandProcess)
    hcfPostExec, // Run after CommandProcessor (unless handled by On[User]CommandProcess)
    hcfFinish    // Run at the very end
  );

  TLazSynBorderSide = (
    bsLeft,
    bsTop,
    bsRight,
    bsBottom
  );

  TSynCoordinateMappingFlag = (
    scmLimitToLines,
    scmIncludePartVisible,
    scmForceLeftSidePos   // do return the caret pos to the (logical) left of the char, even if the pixel is over the right half.
                          // TODO: RTL
  );

  TSynEditorOption = (
    eoAutoIndent,              // Allows to indent the caret, when new line is created with <Enter>, with the same amount of leading white space as the preceding line
    eoBracketHighlight,        // Allows to highlight bracket, which matches bracket under caret
    eoEnhanceHomeKey,          // Toggles behaviour of <Home> key on line with leading spaces. If turned on, key will jump to first non-spacing char, if it's nearer to caret position. (Similar to Visual Studio.)
    eoGroupUndo,               // When undoing/redoing actions, handle all continous changes of the same kind in one call instead undoing/redoing each command separately
    eoHalfPageScroll,          // When scrolling with <PageUp> and <PageDown> keys, only scroll a half page at a time
    eoHideRightMargin,         // Hides the vertical "right margin" line
    eoKeepCaretX,              // When moving through lines without "Scroll past EOL" option, keeps the X position of the caret
    eoNoCaret,                 // Hides caret (text blinking cursor) totally
    eoNoSelection,             // Disables any text selection
    eoPersistentCaret,         // Do not hide caret when focus is lost from control. (TODO: Windows still hides caret, if another component sets up a caret.)
    eoScrollByOneLess,         // Scroll vertically, by <PageUp> and <PageDown> keys, less by one line
    eoScrollPastEof,           // When scrolling to end-of-file, show last line at the top of the control, instead of the bottom
    eoScrollPastEol,           // Allows caret to go into empty space beyond end-of-line position
                               // The caret can move (and the scrollbar provides scrolling for) up to either
                               // - the length of the longest Line
                               // - MaxLeftChar
    eoScrollHintFollows,       // The hint, showing vertical scroll position, follows the mouse cursor
    eoShowScrollHint,          // Shows hint, with the current scroll position, when scrolling vertically by dragging the scrollbar slider
    eoShowSpecialChars,        // Shows non-printable characters (spaces, tabulations) with greyed symbols
    eoSmartTabs,               // When using <Tab> key, caret will go to the next non-space character of the previous line
    eoTabIndent,               // Allows keys <Tab> and <Shift+Tab> act as block-indent and block-unindent, for selected blocks
    eoTabsToSpaces,            // Converts tab characters to a specified number of space characters
    eoTrimTrailingSpaces,      // Spaces at the end of lines will be trimmed and not saved to file

    // Not implemented
    eoAutoSizeMaxScrollWidth,  //TODO Automatically resizes the MaxScrollWidth property when inserting text
    eoDisableScrollArrows,     //TODO Disables the scroll bar arrow buttons when you can't scroll in that direction any more
    eoHideShowScrollbars,      //TODO If enabled, then the scrollbars will only show when necessary. If you have "Scroll past EOL" option, then the horizontal bar will always be there (it uses MaxLength instead)
    eoDropFiles,               //TODO Allows control to accept file drag-drop operation
    eoSmartTabDelete,          //TODO Similar to "Smart tabs", but when you delete characters
    eoSpacesToTabs,            // Converts long substrings of space characters to tabs and spaces
    eoAutoIndentOnPaste,       // Allows to indent text pasted from clipboard
    //eoSpecialLineDefaultFg,    //TODO disables the foreground text color override when using the OnSpecialLineColor event

    // Only for compatibility, moved to TSynEditorMouseOptions
    // keep in one block
    eoAltSetsColumnMode,       // Allows to activate "column" selection mode, if <Alt> key is pressed and text is being selected with mouse
    eoDragDropEditing,         // Allows to drag-and-drop text blocks within the control
    eoRightMouseMovesCursor,   // When clicking with the right mouse button, for a popup menu, move the caret to clicked position
    eoDoubleClickSelectsLine,  // Selects entire line with double-click, otherwise double-click selects only current word
    eoShowCtrlMouseLinks       // Pressing <Ctrl> key (SYNEDIT_LINK_MODIFIER) will highlight the word under mouse cursor
    );

  TSynEditorOption2 = (
    eoCaretSkipsSelection,     // Allows <Left> and <Right> keys to move caret to selected block edges, without deselecting the block
    eoCaretMoveEndsSelection,  // <Left> and <Right> will clear the selection, but the caret will NOT move.
                               // Combine with eoCaretSkipsSelection, and the caret will move to the other selection bound, if needed
                               // Kind of overrides eoPersistentBlock
    eoCaretSkipTab,            // Disables caret positioning inside tab-characters internal area
    eoAlwaysVisibleCaret,      // Keeps caret on currently visible control area, when scrolling control
    eoEnhanceEndKey,           // Toggles behaviour of <End> key on line with trailing spaces. If turned on, key will jump to last non-spacing char, if it's nearer to caret position.
    eoFoldedCopyPaste,         // Remember folding states of blocks, on Copy/Paste operations
    eoPersistentBlock,         // Keeps selection, even if caret moves away or text is edited
    eoOverwriteBlock,          // Allows to overwrite currently selected block, when pasting or typing new text
    eoAutoHideCursor,          // Hide mouse cursor, when new text is typed
    eoColorSelectionTillEol,   // Colorize selection background only till EOL of each line, not till edge of control
    eoPersistentCaretStopBlink,// only if eoPersistentCaret > do not blink, draw fixed line
    eoNoScrollOnSelectRange,   // SelectALl, SelectParagraph, SelectToBrace will not scroll
    eoAcceptDragDropEditing,   // Accept dropping text dragged from a SynEdit (self or other).
                               // OnDragOver: To use OnDragOver, this flag should NOT be set.
                               // WARNING: Currently OnDragOver also works, if drag-source is NOT TSynEdit, this may be change for other drag sources.
                               //          This may in future affect if OnDragOver is called at all or not.
    eoScrollPastEolAddPage,    // Allows caret to go into empty space beyond end-of-line position
                               // - Limit to length of longest line + width of one page
                               // if eoScrollPastEol also is set, the bigger of the 2 limits is used
    eoScrollPastEolAutoCaret,  // Allows caret to go into empty space beyond end-of-line position
                               // Limit will follow the caret / scrollbar-range extends when caret goes further
    eoBookmarkRestoresScroll   // Bookmarks also restore scroll pos
  );

  TSynFrameEdges = (
    sfeNone,
    sfeAround,      // frame around
    sfeBottom,      // bottom part of the frame
    sfeLeft         // left part of the frame
  );

  TSynLineState = (slsNone, slsSaved, slsUnsaved);

  TSynLineStyle = (
    slsSolid,  // PS_SOLID pen
    slsDashed, // PS_DASH pen
    slsDotted, // PS_DOT
    slsWaved   // solid wave
  );

  TSynMouseLocationInfo = record
    LastMouseCaret: TPoint;  // Char; physical (screen)
    LastMousePoint: TPoint;  // Pixel
  end;

  TSynPaintEvent = (peBeforePaint, peAfterPaint);

  TSynScrollEvent = (peBeforeScroll, peAfterScroll, peAfterScrollFailed);

  TSynStatusChange = (scCaretX, scCaretY,
    scLeftChar, scTopLine, scLinesInWindow, scCharsInWindow,
    scInsertMode, scModified, scSelection, scReadOnly,
    scFocus,     // received or lost focus
    scOptions    // some Options were changed (only triggered by some optinos)
   );

  TSynVisibleSpecialChar = (vscSpace, vscTabAtFirst, vscTabAtLast);
implementation
Uses
  SynUnicode;

function DisplayCoord(AColumn, ARow: Integer): TDisplayCoord;
begin
  Result.Column := AColumn;
  Result.Row := ARow;
end;

function BufferCoord(AChar, ALine: Integer): TBufferCoord;
begin
  Result.Char := AChar;
  Result.Line := ALine;
end;

{ TBufferCoord }

class operator TBufferCoord.Equal(a, b: TBufferCoord): Boolean;
begin
  Result := (a.Char = b.Char) and (a.Line = b.Line);
end;

class operator TBufferCoord.GreaterThan(a, b: TBufferCoord): Boolean;
begin
  Result :=  (b.Line < a.Line)
    or ((b.Line = a.Line) and (b.Char < a.Char))
end;

class operator TBufferCoord.GreaterThanOrEqual(a, b: TBufferCoord): Boolean;
begin
  Result :=  (b.Line < a.Line)
    or ((b.Line = a.Line) and (b.Char <= a.Char))
end;

class operator TBufferCoord.LessThan(a, b: TBufferCoord): Boolean;
begin
  Result :=  (b.Line > a.Line)
    or ((b.Line = a.Line) and (b.Char > a.Char))
end;

class operator TBufferCoord.LessThanOrEqual(a, b: TBufferCoord): Boolean;
begin
  Result :=  (b.Line > a.Line)
    or ((b.Line = a.Line) and (b.Char >= a.Char))
end;

class function TBufferCoord.Max(a, b: TBufferCoord): TBufferCoord;
begin
  if (b.Line < a.Line)
    or ((b.Line = a.Line) and (b.Char < a.Char))
  then
    Result := a
  else
    Result := b;
end;

class function TBufferCoord.Min(a, b: TBufferCoord): TBufferCoord;
begin
  if (b.Line < a.Line)
    or ((b.Line = a.Line) and (b.Char < a.Char))
  then
    Result := b
  else
    Result := a;
end;

class operator TBufferCoord.NotEqual(a, b: TBufferCoord): Boolean;
begin
  Result := (a.Char <> b.Char) or (a.Line <> b.Line);
end;

{ TDisplayCoord }

class operator TDisplayCoord.Equal(a, b: TDisplayCoord): Boolean;
begin
  Result := (a.Row = b.Row) and (a.Column = b.Column);
end;

class operator TDisplayCoord.GreaterThan(a, b: TDisplayCoord): Boolean;
begin
  Result :=  (b.Row < a.Row)
    or ((b.Row = a.Row) and (b.Column < a.Column))
end;

class operator TDisplayCoord.GreaterThanOrEqual(a, b: TDisplayCoord): Boolean;
begin
  Result :=  (b.Row < a.Row)
    or ((b.Row = a.Row) and (b.Column <= a.Column))
end;

class operator TDisplayCoord.LessThan(a, b: TDisplayCoord): Boolean;
begin
  Result :=  (b.Row > a.Row)
    or ((b.Row = a.Row) and (b.Column > a.Column))
end;

class operator TDisplayCoord.LessThanOrEqual(a, b: TDisplayCoord): Boolean;
begin
  Result :=  (b.Row > a.Row)
    or ((b.Row = a.Row) and (b.Column >= a.Column))
end;

class function TDisplayCoord.Max(a, b: TDisplayCoord): TDisplayCoord;
begin
  if (b.Row < a.Row)
    or ((b.Row = a.Row) and (b.Column < a.Column))
  then
    Result := a
  else
    Result := b;
end;

class function TDisplayCoord.Min(a, b: TDisplayCoord): TDisplayCoord;
begin
  if (b.Row < a.Row)
    or ((b.Row = a.Row) and (b.Column < a.Column))
  then
    Result := b
  else
    Result := a;
end;

class operator TDisplayCoord.NotEqual(a, b: TDisplayCoord): Boolean;
begin
  Result := (a.Row <> b.Row) or (a.Column <> b.Column);
end;

function LineBreakFromFileFormat(FileFormat: TSynEditFileFormat): string;
begin
  case FileFormat of
    sffDos: Result := WideCRLF;
    sffUnix: Result := WideLF;
    sffMac: Result := WideCR;
    sffUnicode: Result := WideLineSeparator;
  end;
end;

{$IFNDEF FPC}{$IF CompilerVersion <= 32}
{ TControlHelper }

function TControlHelper.CurrentPPI: Integer;
begin
  Result := Screen.PixelsPerInch;
end;

function TControlHelper.FCurrentPPI: Integer;
begin
  Result := Screen.PixelsPerInch;
end;
{$IFEND}{$ENDIF}



end.

