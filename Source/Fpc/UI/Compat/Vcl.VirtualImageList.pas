// FPC-side compat unit for Delphi's Vcl.VirtualImageList.
//
// The measurement is on Vcl.BaseImageCollection. This type's entire contract in
// this tree is two assignments in Tools/Packman/Main.pas:
//
//   ToolBar1.Images := VirtualImageList;
//   MainMenu1.Images := VirtualImageList;
//
// both TCustomImageList properties. The field is never filled, so a descendant
// of the LCL's TImageList (which is a TCustomImageList) satisfies it exactly,
// with no behaviour invented here.
//
// Re-declared rather than re-exported from Vcl.BaseImageCollection because FPC
// has no transitive interface visibility (AGENTS.md section 1) and
// Tools/Packman/Main.pas names Vcl.VirtualImageList in its own uses clause.
unit Vcl.VirtualImageList;

{$mode delphiunicode}{$H+}

interface

uses
  Classes, Graphics, ImgList, Controls, ExtCtrls;

type
  TVirtualImageList = class(TImageList)
  end;

implementation

end.
