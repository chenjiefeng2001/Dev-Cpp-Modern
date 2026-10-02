unit Lsp.Editor.Types;

{ ---------------------------------------------------------------------------
  Lsp.Editor.Types -- VCL/LCL-free value types for the editor adapter contract.

  WHY A SEPARATE UNIT
  -------------------
  IEditorControlAdapter's signatures need coordinates, and those coordinates
  must not be TBufferCoord / TDisplayCoord / TPoint. Those come from SynEdit
  and SynEditTypes (VCL) -- naming them here would put the god editor's types
  straight back into the contract, which is the entire thing the contract
  exists to prevent. So the shapes are re-declared here as plain records.

  This unit depends on NOTHING. That is deliberate and load-bearing: it is the
  one file both the VCL adapter and the future LCL adapter can include without
  dragging their respective toolkits into each other. Compare Source/Core/,
  which holds the same "zero VCL" property for the service layer; keeping the
  editor contract OUT of Core/ is what preserves Core's "directly portable"
  rating (see the migration plan's assessment table).

  BASE CONVENTION
  ---------------
  Lines and Chars are 1-BASED, because SynEdit is 1-based on both and the LSP
  client layer converts from LSP's 0-based exactly once, at the protocol edge
  (see Completion:832-839, which does the +1 and clamps). Re-basing here
  would mean a second conversion inside the adapter and two places to get
  wrong. Pixel points are absolute SCREEN pixels, matching ClientToScreen's
  result, because every caller of that method immediately goes on to ask the
  Screen object for a monitor work area -- screen-relative is the space those
  callers live in.
  --------------------------------------------------------------------------- }

interface

type
  { A position in the text buffer. 1-based on both axes. }
  TLspBufferCoord = record
    Line: Integer;
    Char: Integer;
  end;

  { A position in screen pixels. }
  TLspPixelPoint = record
    X: Integer;
    Y: Integer;
  end;

  { The visual style of a gutter/diagnostic marker.

    Replaces TSynEditMarkerStyle. Only the members the client layer actually
    uses are modelled: Lsp.Client.pas:169 sets `Style := msBar`, and nothing
    in the layer ever reads it back. Keeping msBar as the sole value would be
    "faithful to today" but would make the contract lie to the next caller, so
    the enum is named for the intent instead.
  }
  TLspMarkerStyle = (lmsBar, lmsUnderline, lmsBoxed);

  { A diagnostic marker, as the LSP layer understands it.

    Note this is a VALUE, not a handle, and that is the whole point: the real
    code constructs a TMarker object, mutates five properties, then hands the
    object to Markers.Add. Modelling it as a value lets the adapter own the
    object entirely, so SynEdit's marker class never crosses the contract.
  }
  TLspMarkerSpec = record
    Style: TLspMarkerStyle;
    TopLine: Integer;               { 1-based }
    BottomLine: Integer;            { 1-based, >= TopLine }
    EndColumn: Integer;             { 0 = whole line }
    Red, Green, Blue: Byte;         { explicit RGB: TColor is Vcl.Graphics }
    ToolDescription: string;        { tooltip text, may be empty }
  end;

implementation

end.
