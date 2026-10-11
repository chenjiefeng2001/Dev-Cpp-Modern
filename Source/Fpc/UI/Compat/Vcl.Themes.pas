// FPC-side compat unit for Delphi's Vcl.Themes, sized by measurement.
//
// WHY THIS FILE EXISTS
// ===================
// Tools/Packman's completion proposal (Source/Fpc/UI/SynEdit/
// SynCompletionProposal.pas, 3,599 lines) is vendored Delphi code and names
// VCL's styling service at 16 sites. The LCL has no styles service at all --
// VclPropertySkips.pas:138-142 already records that as a measured fact, with
// StyleElements listed there as a deliberately skipped property for exactly this
// reason. So the surface had to be measured before anything was written, and
// the measurement turned out to be small and almost entirely satisfiable:
//
//   StyleServices.GetSystemColor(...)   14 sites   REAL implementation here
//   StyleServices.IsSystemStyle          1 site    REAL (the LCL always is)
//   StyleElements / seClient              1 site    NO equivalent -- see below
//   TStyleManager.IsCustomStyleActive     1 site    NO equivalent -- see below
//   DrawStyleEdge / eeRaisedOuter/efRect  1 site    NO equivalent -- see below
//   CurrentPPI / GetCurrentPPI            5+3 sites REAL (Screen.PixelsPerInch)
//
// WHAT IS REAL AND WHAT IS NOT
// ============================
// REAL: GetSystemColor is not a styling service at all -- it is the Win32
// `GetSysColor`, the same system colour table the VCL's implementation reads.
// Every one of the 14 call sites asks for a Windows system colour
// (clWindowText, clBtnFace, clBtnShadow, clWindow, and the unit's own
// FClBackGround / FClSelect / FClSelectText / FClTitleBackground, which are
// aliases of those). Serving them from GetSysColor is not an approximation: it
// is the same table the VCL reads, so the colours are the ones the vendored
// code would have produced on this machine. IsSystemStyle is likewise true
// rather than stubbed -- with no style service, there is always no custom
// style active.
//
// NOT REAL, AND RECORDED AS A LOSS: the VCL draws a non-client edge around a
// styled form (StyleElements := [seClient], DrawStyleEdge with
// eeRaisedOuter/efRect/efFlat). The LCL draws its own frames and has no
// equivalent call, so this unit cannot supply it. What the completion proposal
// loses is the raised outer edge around its window under a VCL visual style.
// The sites are kept and made to compile against a no-op rather than deleted,
// so that the loss is visible in the code and can be revisited if the LCL ever
// grows an edge-drawing call. VclPropertySkips records the same conclusion for
// the same construct from the other direction (the property side).
unit Vcl.Themes;

{$mode delphiunicode}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls, Windows;

type
  { VCL's style element set. Only the member the completion proposal names is
    declared; the set exists so `StyleElements := [seClient]` type-checks. Its
    meaning is not honoured (see the header). }
  TStyleElement = (seClient);
  TStyleElements = set of TStyleElement;

  { VCL's style manager, used only for IsCustomStyleActive. Declared so the
    call resolves; the answer is False here because there is no style service
    for a custom style to be active in. }
  TStyleManager = class
  public
    class function IsCustomStyleActive: Boolean; static;
    class function IsSystemStyle: Boolean; static;
  end;

type
  { VCL's global styling facade. GetSystemColor forwards to Win32; everything
    else is the single boolean, which is True here (see the header). }
  TStyleServices = class
  public
    function GetSystemColor(Color: TColor): TColor;
    function IsSystemStyle: Boolean;
  end;

var
  { The one name the vendored code uses. A singleton so the call sites read
    the same as in Delphi. }
  StyleServices: TStyleServices;

{ The edge-drawing call has no LCL equivalent. Kept as a documented no-op
  rather than removed, so that the loss stays visible at the call site.
  The edge/corner sets are declared as named types because FPC does not allow an
  anonymous `set of` in a parameter list. }
type
  TStyleEdges = set of Byte;
  TStyleCorners = set of Byte;

procedure DrawStyleEdge(ACanvas: TCanvas; ARect: TRect;
  const Edges: TStyleEdges; const Corners: TStyleCorners);

const
  eeRaisedOuter = 1;
  efRect = 1;
  efFlat = 2;

implementation

class function TStyleManager.IsCustomStyleActive: Boolean;
begin
  Result := False;   // no style service exists here, so no custom style is active
end;

class function TStyleManager.IsSystemStyle: Boolean;
begin
  Result := True;    // the corollary of the above, stated rather than assumed
end;

function TStyleServices.GetSystemColor(Color: TColor): TColor;
begin
  // Delphi's TStyleServices.GetSystemColor indexes the Win32 system colour
  // table by the clXxx constants, which are exactly the values the LCL's and
  // FPC's clWindow/clBtnFace/... constants carry. So the index goes straight
  // through; only the return type differs (GetSysColor returns COLORREF, a
  // DWORD, and TColor is a LongInt).
  Result := TColor(GetSysColor(Color));
end;

function TStyleServices.IsSystemStyle: Boolean;
begin
  Result := TStyleManager.IsSystemStyle;
end;

procedure DrawStyleEdge(ACanvas: TCanvas; ARect: TRect;
  const Edges: TStyleEdges; const Corners: TStyleCorners);
begin
  { Deliberately does nothing. The LCL has no edge-drawing call, and the
    completion proposal's frame is drawn by the LCL's own window handling, so
    drawing one here would double it. The loss is the raised outer edge a VCL
    visual style would have put around this window; recorded in the unit
    header and in VclPropertySkips for the property-side of the same fact. }
end;

initialization
  StyleServices := TStyleServices.Create;
finalization
  StyleServices.Free;
  StyleServices := nil;

end.
