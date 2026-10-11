// FPC-side compat unit for Delphi's Vcl.BaseImageCollection.
//
// Measured before written, and the measurement is the whole of the justification
// for how small this is. Across the tree:
//
//   TBaseImageCollection   0 uses
//   TBaseVirtualImageList   0 uses
//   TImageCollectionItem    0 uses
//   TVirtualImageItem       0 uses
//
// so nothing in the tree needs any of those. The one real contract is in
// Tools/Packman/Main.pas:
//
//   ToolBar1.Images := VirtualImageList;    // TToolBar.Images : TCustomImageList
//   MainMenu1.Images := VirtualImageList;    // TMainMenu.Images : TCustomImageList
//
// which needs TVirtualImageList to be assignable to TCustomImageList, and the
// same image list is never filled -- the field is only ever read out, never
// written to, by either form. TImageList already IS a TCustomImageList, so a
// descendant of it satisfies the contract without any new behaviour.
//
// The class is a distinct descendant rather than an alias so that a caller can
// tell it apart from a plain TImageList in the debugger, which is the only
// difference that can be observed here.
unit Vcl.BaseImageCollection;

{$mode delphiunicode}{$H+}

interface

uses
  Classes, Graphics, ImgList, Controls, ExtCtrls;

type
  { Delphi's base class for the image collections. Nothing in this tree uses it
    by name (measured: 0 references); it exists so that a uses clause naming
    Vcl.BaseImageCollection resolves, and so that the collection types below
    have a base with their own name. }
  TBaseImageCollection = class(TImageList)
  end;

  { DataFrm.pas declares three of these and never reads or writes any of them
    (measured: one occurrence each, the declaration). The LCL's TImageList is
    the image list those fields would have to be filled from. }
  TImageCollection = class(TBaseImageCollection)
  end;

  { Packman assigns its VirtualImageList to two TCustomImageList properties
    and never fills it. A TImageList descendant satisfies that exactly. }
  TVirtualImageList = class(TBaseImageCollection)
  end;

implementation

end.
