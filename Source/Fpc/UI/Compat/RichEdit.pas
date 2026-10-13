unit RichEdit;

{ Delphi's TRichEdit for the FPC tree, reduced to what this project actually
  uses.

  WHY IT IS REDUCED
  =================
  Lazarus has no TRichEdit control class at all -- `rg "TRichEdit = class"` over
  the whole Lazarus tree finds nothing, only FPC's raw `richedit.pp` WinAPI unit.
  So the five `TRichEdit` components in main.dfm had no way to stream at all.

  TMemo is the right host: it provides Tag and Text, which is what the MRU code
  needs, without dragging in a control the LCL does not have.

  WHAT THESE CONTROLS ARE NOT
  ===========================
  An earlier version of this note claimed all five carry `Visible = False`, are
  never painted, and that "the only members the code touches are Tag and Text".
  That was wrong, and it was wrong in the direction that makes work look
  unnecessary, so it is corrected here rather than quietly deleted.

  Measured:
    * main.pas sets `RichEditN.Visible := True` for all five, right after
      calling AddFileRTB (main.pas:7489, 7494, 7499, 7504, 7509). They are the
      five MRU entries on the Welcome screen and they ARE painted.
    * AddFileRTB (main.pas:7516) also drives `SelStart`, `SelText` and
      `SelAttributes` -- character size and weight, so the filename renders bold
      at 11pt above the path at 9pt.

  Consequence: TMemo covers Tag, Text, SelStart and SelText, but NOT
  SelAttributes. Lazarus's richmemo package is the only thing in this Lazarus
  tree with that property and it is not installed (no richmemo.pp or .ppu
  anywhere under C:\lazarus), so the character formatting cannot be reproduced.
  AddFileRTB guards those three statements to the Delphi branch only. The text,
  its order and the selection are unchanged; the type styling is a recorded loss.

  ReadOnly and Zoom are the two streamed properties TMemo does not have. They
  are declared here so the reader has somewhere to put them instead of failing
  with "Unknown property", and they are accepted and ignored -- an MRU label has
  nothing to lock or scale.

  If any of these ever becomes a real visible editor, this unit is the place
  that has to grow: it would need an actual rich-text host rather than TMemo.
}

interface

uses
  StdCtrls;

type
  TRichEdit = class(TMemo)
  private
    FReadOnly: Boolean;
    FZoom: Integer;
    procedure SetReadOnly(const AValue: Boolean);
    procedure SetZoom(const AValue: Integer);
  published
    property ReadOnly: Boolean read FReadOnly write SetReadOnly;
    property Zoom: Integer read FZoom write SetZoom;
  end;

implementation

procedure TRichEdit.SetReadOnly(const AValue: Boolean);
begin
  // Stored, never acted on. See the unit comment: these controls are
  // Visible = False in every DFM block and are used only to carry a Tag.
  FReadOnly := AValue;
end;

procedure TRichEdit.SetZoom(const AValue: Integer);
begin
  // Same: stored and ignored.
  FZoom := AValue;
end;

end.
